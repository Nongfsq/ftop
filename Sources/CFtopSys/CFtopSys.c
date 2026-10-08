#include "CFtopSys.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- Private IOReport declarations ----
typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);

// ---- Private IOHID event declarations (the client and service types are public) ----
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFTypeRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(CFTypeRef, int32_t);

#define MAX_STATES 64
#define MAX_TABLES 32

// One DVFS table of the power manager: `voltage-states<index>-sram`.
typedef struct {
    int index;
    int count;
    double mhz[MAX_STATES];
} freq_table;

struct ftop_cpu_sampler {
    CFMutableDictionaryRef channels;
    CFMutableDictionaryRef subscribed;
    IOReportSubscriptionRef subscription;
    CFDictionaryRef previous;
    freq_table tables[MAX_TABLES];
    int table_count;
    char description[16384];
};

static void copy_string(CFStringRef s, char *out, size_t size) {
    out[0] = 0;
    if (s) CFStringGetCString(s, out, (CFIndex)size, kCFStringEncodingUTF8);
}

// Reads a DVFS table (pairs of 32-bit frequency and voltage) and returns MHz values.
static int read_frequencies(io_registry_entry_t entry, CFStringRef key, double *out) {
    int count = 0;
    CFTypeRef property = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!property) return 0;
    if (CFGetTypeID(property) == CFDataGetTypeID()) {
        const UInt8 *bytes = CFDataGetBytePtr((CFDataRef)property);
        CFIndex length = CFDataGetLength((CFDataRef)property);
        double top = 0;
        for (CFIndex i = 0; i + 7 < length && count < MAX_STATES; i += 8) {
            uint32_t raw = 0;
            memcpy(&raw, bytes + i, sizeof(raw));
            if (raw > 0) { out[count++] = raw; if (raw > top) top = raw; }
        }
        // Early Apple Silicon tables are in Hz, later ones in kHz.
        double scale = top > 100000000.0 ? 1000000.0 : 1000.0;
        for (int i = 0; i < count; i++) {
            out[i] /= scale;
            if (out[i] < 100 || out[i] > 10000) { count = 0; break; }
        }
    }
    CFRelease(property);
    return count;
}

ftop_cpu_sampler *ftop_cpu_sampler_create(void) {
    ftop_cpu_sampler *s = calloc(1, sizeof(*s));
    if (!s) return NULL;

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS) {
        io_object_t entry;
        while ((entry = IOIteratorNext(iterator))) {
            io_name_t name = {0};
            if (IORegistryEntryGetName(entry, name) == KERN_SUCCESS && strcmp(name, "pmgr") == 0) {
                // Which table belongs to which cluster differs between chips, so every
                // table is kept and each core picks the one that fits its states.
                for (int index = 0; index < 64 && s->table_count < MAX_TABLES; index++) {
                    char key[40];
                    snprintf(key, sizeof(key), "voltage-states%d-sram", index);
                    CFStringRef property = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
                    freq_table *table = &s->tables[s->table_count];
                    table->index = index;
                    table->count = read_frequencies(entry, property, table->mhz);
                    CFRelease(property);
                    if (table->count > 0) s->table_count++;
                }
            }
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
    }

    CFDictionaryRef copied = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"), 0, 0, 0);
    if (!copied) return s;
    s->channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, copied);
    CFRelease(copied);
    s->subscription = IOReportCreateSubscription(NULL, s->channels, &s->subscribed, 0, NULL);
    if (s->subscription) s->previous = IOReportCreateSamples(s->subscription, s->channels, NULL);
    return s;
}

void ftop_cpu_sampler_destroy(ftop_cpu_sampler *s) {
    if (!s) return;
    if (s->previous) CFRelease(s->previous);
    if (s->subscription) CFRelease((CFTypeRef)s->subscription);
    if (s->subscribed) CFRelease(s->subscribed);
    if (s->channels) CFRelease(s->channels);
    free(s);
}

static int is_idle_state(const char *name) {
    return strcmp(name, "IDLE") == 0 || strcmp(name, "DOWN") == 0 || strcmp(name, "OFF") == 0;
}

static int same_frequencies(const freq_table *a, const freq_table *b) {
    return a->count == b->count && memcmp(a->mhz, b->mhz, sizeof(double) * (size_t)a->count) == 0;
}

// The table for a core with `steps` active states. A table fits when it has exactly
// that many steps. Several fitting tables are fine while they hold the same
// frequencies; when they differ, only the table known for that core type on the
// chips measured so far (5 for 'P', 1 for 'E') is trusted. Otherwise NULL.
static const freq_table *table_for(const ftop_cpu_sampler *s, char kind, int steps) {
    const freq_table *first = NULL, *known = NULL;
    int agree = 1;
    int known_index = kind == 'P' ? 5 : (kind == 'E' ? 1 : -1);
    for (int i = 0; i < s->table_count; i++) {
        const freq_table *table = &s->tables[i];
        if (table->count != steps) continue;
        if (table->index == known_index) known = table;
        if (!first) first = table;
        else if (!same_frequencies(first, table)) agree = 0;
    }
    if (first && agree) return first;
    return known;
}

static int compare_cores(const void *a, const void *b) {
    return strcmp(((const ftop_core_freq *)a)->channel, ((const ftop_core_freq *)b)->channel);
}

int ftop_cpu_sampler_update(ftop_cpu_sampler *s, ftop_core_freq *out, int capacity) {
    if (!s || !s->subscription) return -1;
    CFDictionaryRef current = IOReportCreateSamples(s->subscription, s->channels, NULL);
    if (!current) return -1;
    CFDictionaryRef delta = s->previous ? IOReportCreateSamplesDelta(s->previous, current, NULL) : NULL;
    if (s->previous) CFRelease(s->previous);
    s->previous = current;
    if (!delta) return -1;

    int count = 0;
    size_t used = 0;
    s->description[0] = 0;
    for (int i = 0; i < s->table_count; i++) {
        const freq_table *table = &s->tables[i];
        if (used + 96 < sizeof(s->description))
            used += (size_t)snprintf(s->description + used, sizeof(s->description) - used, "table voltage-states%d-sram %d steps %.0f-%.0f MHz\n", table->index, table->count, table->mhz[0], table->mhz[table->count - 1]);
    }
    CFTypeRef raw = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (raw && CFGetTypeID(raw) == CFArrayGetTypeID()) {
        CFArrayRef list = (CFArrayRef)raw;
        for (CFIndex i = 0; i < CFArrayGetCount(list) && count < capacity; i++) {
            CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
            ftop_core_freq core = {0};
            copy_string(IOReportChannelGetChannelName(item), core.channel, sizeof(core.channel));
            // A core channel is its cluster type letter, "CPU", and digits: "PCPU000".
            if (strlen(core.channel) < 5 || strncmp(core.channel + 1, "CPU", 3) != 0 || core.channel[4] < '0' || core.channel[4] > '9') {
                if (used + 64 < sizeof(s->description))
                    used += (size_t)snprintf(s->description + used, sizeof(s->description) - used, "%s skipped: not a core channel\n", core.channel);
                continue;
            }
            core.kind = core.channel[0];

            double total = 0, active = 0;
            double residencies[MAX_STATES];
            int active_states = 0, overflow = 0;
            int32_t states = IOReportStateGetCount(item);
            for (int32_t j = 0; j < states; j++) {
                int64_t residency = IOReportStateGetResidency(item, j);
                if (residency < 0) residency = 0;
                char state[32];
                copy_string(IOReportStateGetNameForIndex(item, j), state, sizeof(state));
                if (used + 64 < sizeof(s->description))
                    used += (size_t)snprintf(s->description + used, sizeof(s->description) - used, "%s %s %lld\n", core.channel, state, (long long)residency);
                total += (double)residency;
                if (is_idle_state(state)) continue;
                active += (double)residency;
                if (active_states < MAX_STATES) residencies[active_states] = (double)residency;
                else overflow = 1;
                active_states++;
            }
            const freq_table *table = overflow ? NULL : table_for(s, core.kind, active_states);
            double weighted = 0;
            if (table)
                for (int j = 0; j < active_states; j++) weighted += residencies[j] * table->mhz[j];
            if (used + 64 < sizeof(s->description))
                used += (size_t)snprintf(s->description + used, sizeof(s->description) - used, "%s table %d\n", core.channel, table ? table->index : -1);
            core.active = total > 0 ? active / total : -1;
            core.max_mhz = table ? table->mhz[table->count - 1] : -1;
            // An idle core has no active time to weight; report the lowest step instead of nothing.
            core.mhz = !table ? -1 : (active > 0 ? weighted / active : table->mhz[0]);
            out[count++] = core;
        }
    }
    CFRelease(delta);
    qsort(out, (size_t)count, sizeof(ftop_core_freq), compare_cores);
    return count;
}

int ftop_cpu_sampler_describe(ftop_cpu_sampler *s, char *buffer, int capacity) {
    if (!s || capacity <= 0) return -1;
    strlcpy(buffer, s->description, (size_t)capacity);
    return (int)strlen(buffer);
}

int ftop_cpu_cluster_types(char *out, int capacity) {
    io_registry_entry_t cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus");
    if (!cpus) return -1;
    if (capacity > 0) memset(out, 0, (size_t)capacity);
    io_iterator_t iterator = 0;
    int highest = -1;
    if (IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS) {
        io_object_t cpu;
        while ((cpu = IOIteratorNext(iterator))) {
            CFTypeRef type = IORegistryEntryCreateCFProperty(cpu, CFSTR("cluster-type"), kCFAllocatorDefault, 0);
            CFTypeRef ident = IORegistryEntryCreateCFProperty(cpu, CFSTR("logical-cpu-id"), kCFAllocatorDefault, 0);
            if (type && ident && CFGetTypeID(type) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)type) > 0) {
                int64_t index = -1;
                if (CFGetTypeID(ident) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)ident, kCFNumberSInt64Type, &index);
                else if (CFGetTypeID(ident) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)ident) >= 4) {
                    uint32_t value = 0;
                    memcpy(&value, CFDataGetBytePtr((CFDataRef)ident), 4);
                    index = value;
                }
                char kind = (char)CFDataGetBytePtr((CFDataRef)type)[0];
                // Any letter is passed on: 'P' and 'E' so far, 'M' since the M5 Pro.
                if (index >= 0 && index < capacity && kind >= 'A' && kind <= 'Z') {
                    out[index] = kind;
                    if (index > highest) highest = (int)index;
                }
            }
            if (type) CFRelease(type);
            if (ident) CFRelease(ident);
            IOObjectRelease(cpu);
        }
        IOObjectRelease(iterator);
    }
    IOObjectRelease(cpus);
    return highest + 1;
}

// Each sensor read is a round trip to the HID system; a dozen is a fair sample of the die.
#define MAX_SENSORS 12

int ftop_read_temperature(ftop_temperature *out) {
    // Matching sensors are found once; listing every HID service and reading its name
    // costs tens of milliseconds, reading the cached sensors does not.
    static IOHIDEventSystemClientRef client = NULL;
    static IOHIDServiceClientRef sensors[MAX_SENSORS];
    static int sources[MAX_SENSORS];
    static int sensor_count = -1;

    if (sensor_count < 0) {
        sensor_count = 0;
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) return -1;
        int page = 0xff00, usage = 5; // Apple vendor page, temperature sensor
        CFNumberRef pageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
        CFNumberRef usageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
        const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
        const void *values[] = {pageNumber, usageNumber};
        CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(client, match);
        CFRelease(match);
        CFRelease(pageNumber);
        CFRelease(usageNumber);

        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (!services) return -1;
        for (CFIndex i = 0; i < CFArrayGetCount(services) && sensor_count < MAX_SENSORS; i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            char name[96] = {0};
            if (product && CFGetTypeID(product) == CFStringGetTypeID()) copy_string((CFStringRef)product, name, sizeof(name));
            if (product) CFRelease(product);
            int source = 0;
            if (strncmp(name, "pACC MTR Temp", 13) == 0 || strncmp(name, "eACC MTR Temp", 13) == 0) source = 1;
            else if (strncmp(name, "PMU tdie", 8) == 0) source = 2;
            if (!source) continue;
            sensors[sensor_count] = (IOHIDServiceClientRef)CFRetain(service);
            sources[sensor_count] = source;
            sensor_count++;
        }
        CFRelease(services);
    }

    double sums[3] = {0}, maxima[3] = {0};
    int counts[3] = {0};
    for (int i = 0; i < sensor_count; i++) {
        CFTypeRef event = IOHIDServiceClientCopyEvent(sensors[i], 15, 0, 0); // temperature event
        if (!event) continue;
        double value = IOHIDEventGetFloatValue(event, 15 << 16);
        CFRelease(event);
        if (value <= 0 || value > 150) continue;
        int source = sources[i];
        sums[source] += value;
        counts[source]++;
        if (value > maxima[source]) maxima[source] = value;
    }
    int source = counts[1] > 0 ? 1 : (counts[2] > 0 ? 2 : 0);
    if (!source) return -1;
    out->average = sums[source] / counts[source];
    out->maximum = maxima[source];
    out->sensor_count = counts[source];
    out->source = source;
    return 0;
}

// ---- GPU ----

struct ftop_gpu_sampler {
    CFMutableDictionaryRef channels;
    CFMutableDictionaryRef subscribed;
    IOReportSubscriptionRef subscription;
    CFDictionaryRef previous;
    CFMutableDictionaryRef energy_channels;
    CFMutableDictionaryRef energy_subscribed;
    IOReportSubscriptionRef energy_subscription;
    CFDictionaryRef energy_previous;
    double mhz[MAX_STATES];
    int mhz_count;
};

ftop_gpu_sampler *ftop_gpu_sampler_create(void) {
    ftop_gpu_sampler *s = calloc(1, sizeof(*s));
    if (!s) return NULL;

    // The GPU's own node lists its frequency steps; the power manager's tables do not say which is the GPU's.
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS) {
        io_object_t entry;
        while ((entry = IOIteratorNext(iterator))) {
            io_name_t name = {0};
            if (s->mhz_count == 0 && IORegistryEntryGetName(entry, name) == KERN_SUCCESS && strcmp(name, "sgx") == 0)
                s->mhz_count = read_frequencies(entry, CFSTR("perf-states"), s->mhz);
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
    }

    CFDictionaryRef copied = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
    if (copied) {
        s->channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, copied);
        CFRelease(copied);
        s->subscription = IOReportCreateSubscription(NULL, s->channels, &s->subscribed, 0, NULL);
        if (s->subscription) s->previous = IOReportCreateSamples(s->subscription, s->channels, NULL);
    }
    copied = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (copied) {
        s->energy_channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, copied);
        CFRelease(copied);
        // The group has hundreds of channels; only the GPU's total is read each sample.
        CFTypeRef raw = CFDictionaryGetValue(s->energy_channels, CFSTR("IOReportChannels"));
        if (raw && CFGetTypeID(raw) == CFArrayGetTypeID()) {
            CFMutableArrayRef kept = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
            for (CFIndex i = 0; i < CFArrayGetCount((CFArrayRef)raw); i++) {
                CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex((CFArrayRef)raw, i);
                char name[64];
                copy_string(IOReportChannelGetChannelName(item), name, sizeof(name));
                if (strcmp(name, "GPU Energy") == 0) CFArrayAppendValue(kept, item);
            }
            if (CFArrayGetCount(kept) > 0) {
                CFDictionarySetValue(s->energy_channels, CFSTR("IOReportChannels"), kept);
                s->energy_subscription = IOReportCreateSubscription(NULL, s->energy_channels, &s->energy_subscribed, 0, NULL);
                if (s->energy_subscription) s->energy_previous = IOReportCreateSamples(s->energy_subscription, s->energy_channels, NULL);
            }
            CFRelease(kept);
        }
    }
    return s;
}

void ftop_gpu_sampler_destroy(ftop_gpu_sampler *s) {
    if (!s) return;
    if (s->previous) CFRelease(s->previous);
    if (s->subscription) CFRelease((CFTypeRef)s->subscription);
    if (s->subscribed) CFRelease(s->subscribed);
    if (s->channels) CFRelease(s->channels);
    if (s->energy_previous) CFRelease(s->energy_previous);
    if (s->energy_subscription) CFRelease((CFTypeRef)s->energy_subscription);
    if (s->energy_subscribed) CFRelease(s->energy_subscribed);
    if (s->energy_channels) CFRelease(s->energy_channels);
    free(s);
}

int ftop_gpu_sampler_update(ftop_gpu_sampler *s, ftop_gpu_freq *out) {
    if (!s || !s->subscription) return -1;
    CFDictionaryRef current = IOReportCreateSamples(s->subscription, s->channels, NULL);
    if (!current) return -1;
    CFDictionaryRef delta = s->previous ? IOReportCreateSamplesDelta(s->previous, current, NULL) : NULL;
    if (s->previous) CFRelease(s->previous);
    s->previous = current;
    if (!delta) return -1;

    int found = -1;
    CFTypeRef raw = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (raw && CFGetTypeID(raw) == CFArrayGetTypeID()) {
        CFArrayRef list = (CFArrayRef)raw;
        for (CFIndex i = 0; i < CFArrayGetCount(list) && found < 0; i++) {
            CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
            char channel[32];
            copy_string(IOReportChannelGetChannelName(item), channel, sizeof(channel));
            if (strcmp(channel, "GPUPH") != 0) continue;

            double total = 0, active = 0, weighted = 0;
            int active_states = 0;
            int32_t states = IOReportStateGetCount(item);
            for (int32_t j = 0; j < states; j++) {
                int64_t residency = IOReportStateGetResidency(item, j);
                if (residency < 0) residency = 0;
                char state[32];
                copy_string(IOReportStateGetNameForIndex(item, j), state, sizeof(state));
                total += (double)residency;
                if (is_idle_state(state)) continue;
                active += (double)residency;
                if (active_states < s->mhz_count) weighted += (double)residency * s->mhz[active_states];
                active_states++;
            }
            // The node lists the steps once per power domain; the first run of them is the table.
            int fits = active_states > 0 && s->mhz_count >= active_states;
            out->active = total > 0 ? active / total : -1;
            out->max_mhz = -1;
            if (fits)
                for (int j = 0; j < active_states; j++)
                    if (s->mhz[j] > out->max_mhz) out->max_mhz = s->mhz[j];
            out->mhz = fits && active > 0 ? weighted / active : -1;
            found = 0;
        }
    }
    CFRelease(delta);
    return found;
}

double ftop_gpu_sampler_energy(ftop_gpu_sampler *s) {
    if (!s || !s->energy_subscription) return -1;
    CFDictionaryRef current = IOReportCreateSamples(s->energy_subscription, s->energy_channels, NULL);
    if (!current) return -1;
    CFDictionaryRef delta = s->energy_previous ? IOReportCreateSamplesDelta(s->energy_previous, current, NULL) : NULL;
    if (s->energy_previous) CFRelease(s->energy_previous);
    s->energy_previous = current;
    if (!delta) return -1;

    double joules = -1;
    CFTypeRef raw = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (raw && CFGetTypeID(raw) == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)raw) > 0) {
        CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex((CFArrayRef)raw, 0);
        char unit[16];
        copy_string(IOReportChannelGetUnitLabel(item), unit, sizeof(unit));
        double scale = strncmp(unit, "nJ", 2) == 0 ? 1e-9 : (strncmp(unit, "uJ", 2) == 0 ? 1e-6 : (strncmp(unit, "mJ", 2) == 0 ? 1e-3 : 0));
        int64_t value = IOReportSimpleGetIntegerValue(item, 0);
        if (scale > 0 && value >= 0) joules = (double)value * scale;
    }
    CFRelease(delta);
    return joules;
}

static double number_value(CFDictionaryRef dictionary, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    double result = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result);
    return result;
}

int ftop_gpu_read_stats(ftop_gpu_stats *out) {
    // The service is found once; its statistics are read again every sample.
    static io_service_t service = 0;
    if (!service) service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (!service) return -1;
    CFTypeRef property = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (!property) return -1;
    int status = -1;
    if (CFGetTypeID(property) == CFDictionaryGetTypeID()) {
        double percent = number_value((CFDictionaryRef)property, CFSTR("Device Utilization %"));
        out->utilization = percent >= 0 ? (percent > 100 ? 1 : percent / 100) : -1;
        out->memory_bytes = number_value((CFDictionaryRef)property, CFSTR("In use system memory"));
        status = 0;
    }
    CFRelease(property);
    return status;
}

// ---- Controller (SMC) ----
// The layout of the controller's one call is not published; it is the one every
// open-source reader uses. Only reads are made.

typedef struct {
    uint32_t key;
    struct { char major, minor, build, reserved; uint16_t release; } version;
    struct { uint16_t version, length; uint32_t cpu, gpu, memory; } limits;
    struct { uint32_t size; uint32_t type; char attributes; } info;
    char result, status, command;
    uint32_t index;
    unsigned char bytes[32];
} smc_message;

enum { SMC_CALL = 2, SMC_READ_BYTES = 5, SMC_READ_INDEX = 8, SMC_READ_INFO = 9 };
#define SMC_FLOAT 0x666c7420u // 'flt '
#define MAX_SMC_SENSORS 32

static io_connect_t smc_connection(void) {
    static io_connect_t connection = 0;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (service) {
            if (IOServiceOpen(service, mach_task_self(), 0, &connection) != KERN_SUCCESS) connection = 0;
            IOObjectRelease(service);
        }
    }
    return connection;
}

static int smc_call(smc_message *input, smc_message *output) {
    io_connect_t connection = smc_connection();
    if (!connection) return -1;
    size_t size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    if (IOConnectCallStructMethod(connection, SMC_CALL, input, sizeof(*input), output, &size) != KERN_SUCCESS) return -1;
    return output->result == 0 ? 0 : -1;
}

static int smc_read_key(uint32_t key, double *out) {
    // A key's type does not change; asking for it once halves the calls of every later read.
    static uint32_t floats[MAX_SMC_SENSORS + 8];
    static int float_count = 0;
    smc_message input = {0}, info = {0}, value = {0};
    input.key = key;
    int known = 0;
    for (int i = 0; i < float_count && !known; i++) known = floats[i] == key;
    if (!known) {
        input.command = SMC_READ_INFO;
        if (smc_call(&input, &info) != 0 || info.info.type != SMC_FLOAT || info.info.size != 4) return -1;
        if (float_count < (int)(sizeof(floats) / sizeof(floats[0]))) floats[float_count++] = key;
    }
    input.info.size = 4;
    input.command = SMC_READ_BYTES;
    if (smc_call(&input, &value) != 0) return -1;
    float number = 0;
    memcpy(&number, value.bytes, sizeof(number));
    *out = number;
    return 0;
}

int ftop_smc_read_float(const char *key, double *out) {
    if (!key || strlen(key) != 4) return -1;
    uint32_t code = ((uint32_t)(unsigned char)key[0] << 24) | ((uint32_t)(unsigned char)key[1] << 16) | ((uint32_t)(unsigned char)key[2] << 8) | (uint32_t)(unsigned char)key[3];
    return smc_read_key(code, out);
}

int ftop_smc_gpu_temperature(ftop_temperature *out) {
    // Which keys exist differs between chips, so they are listed once and every "Tg" key is kept.
    static uint32_t keys[MAX_SMC_SENSORS];
    static int key_count = -1;
    if (key_count < 0) {
        key_count = 0;
        double total = 0;
        smc_message input = {0}, info = {0}, value = {0};
        input.key = 0x234b4559u; // '#KEY'
        input.command = SMC_READ_INFO;
        if (smc_call(&input, &info) != 0) return -1;
        input.info.size = info.info.size;
        input.command = SMC_READ_BYTES;
        if (smc_call(&input, &value) != 0) return -1;
        total = (double)(((uint32_t)value.bytes[0] << 24) | ((uint32_t)value.bytes[1] << 16) | ((uint32_t)value.bytes[2] << 8) | (uint32_t)value.bytes[3]);
        for (uint32_t i = 0; i < (uint32_t)total && i < 8192 && key_count < MAX_SMC_SENSORS; i++) {
            smc_message at = {0}, found = {0};
            at.command = SMC_READ_INDEX;
            at.index = i;
            if (smc_call(&at, &found) != 0) continue;
            if ((found.key >> 16) != 0x5467u) continue; // "Tg"
            double probe = 0;
            if (smc_read_key(found.key, &probe) == 0) keys[key_count++] = found.key;
        }
    }
    double sum = 0, maximum = 0;
    int count = 0;
    for (int i = 0; i < key_count; i++) {
        double value = 0;
        if (smc_read_key(keys[i], &value) != 0 || value <= 0 || value > 150) continue;
        sum += value;
        count++;
        if (value > maximum) maximum = value;
    }
    if (count == 0) return -1;
    out->average = sum / count;
    out->maximum = maximum;
    out->sensor_count = count;
    return 0;
}
