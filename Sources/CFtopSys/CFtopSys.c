#include "CFtopSys.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <stdarg.h>
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
    CFDictionaryRef last; // the delta of the last update, kept for the diagnostics
    freq_table tables[MAX_TABLES];
    int table_count;
    char table_node[32]; // the registry node the tables were read from
};

static void copy_string(CFStringRef s, char *out, size_t size) {
    out[0] = 0;
    if (s) CFStringGetCString(s, out, (CFIndex)size, kCFStringEncodingUTF8);
}

// Diagnostics text in a caller's buffer. A piece that does not fit is left out whole
// and the text says so at its end, so what is there is never cut mid-line.
typedef struct {
    char *buffer;
    size_t capacity, used;
    int truncated;
} text;

#define TRUNCATED_NOTE "(output truncated)\n"

static text text_begin(char *buffer, int capacity) {
    text t = {buffer, 0, 0, 0};
    if (capacity > (int)sizeof(TRUNCATED_NOTE)) t.capacity = (size_t)capacity - sizeof(TRUNCATED_NOTE);
    if (capacity > 0) buffer[0] = 0;
    return t;
}

__attribute__((format(printf, 2, 3))) static void append(text *t, const char *format, ...) {
    if (t->truncated || t->capacity == 0) return;
    va_list arguments;
    va_start(arguments, format);
    int written = vsnprintf(t->buffer + t->used, t->capacity - t->used, format, arguments);
    va_end(arguments);
    if (written < 0 || (size_t)written >= t->capacity - t->used) {
        t->truncated = 1;
        t->buffer[t->used] = 0;
    } else {
        t->used += (size_t)written;
    }
}

static int text_end(text *t) {
    if (t->truncated) {
        // Back to the end of the last whole line, then the note; room for it was held back.
        while (t->used > 0 && t->buffer[t->used - 1] != '\n') t->used--;
        memcpy(t->buffer + t->used, TRUNCATED_NOTE, sizeof(TRUNCATED_NOTE));
        t->used += sizeof(TRUNCATED_NOTE) - 1;
    }
    return (int)t->used;
}

// Reads a DVFS table (pairs of 32-bit frequency and voltage) and returns MHz values.
static int frequencies_from(CFTypeRef property, double *out) {
    int count = 0;
    if (!property || CFGetTypeID(property) != CFDataGetTypeID()) return 0;
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
        if (out[i] < 100 || out[i] > 10000) return 0;
    }
    return count;
}

static int read_frequencies(io_registry_entry_t entry, CFStringRef key, double *out) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!property) return 0;
    int count = frequencies_from(property, out);
    CFRelease(property);
    return count;
}

// Calls `visit` with the name and the properties of every node of the device tree.
typedef void (*node_visitor)(const char *node, CFDictionaryRef properties, void *context);

static void each_device_tree_node(node_visitor visit, void *context) {
    io_iterator_t iterator = 0;
    if (IORegistryCreateIterator(kIOMainPortDefault, kIODeviceTreePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS) return;
    io_object_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t name = {0};
        CFMutableDictionaryRef properties = NULL;
        if (IORegistryEntryGetName(entry, name) == KERN_SUCCESS && IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties) {
            visit(name, properties, context);
            CFRelease(properties);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
}

// The index in "voltage-states<index>-sram", or -1 for any other property name.
static int sram_table_index(const char *key) {
    int index = -1, end = 0;
    if (sscanf(key, "voltage-states%d-sram%n", &index, &end) != 1 || end == 0 || key[end] != 0 || index < 0) return -1;
    return index;
}

static int compare_tables(const void *a, const void *b) {
    return ((const freq_table *)a)->index - ((const freq_table *)b)->index;
}

typedef struct {
    freq_table tables[MAX_TABLES];
    int count, nodes;
    char node[32];
} table_search;

static void collect_tables(const void *key, const void *value, void *context) {
    table_search *search = context;
    char name[64];
    if (CFGetTypeID(key) != CFStringGetTypeID() || search->nodes != 1 || search->count >= MAX_TABLES) return;
    copy_string((CFStringRef)key, name, sizeof(name));
    freq_table *table = &search->tables[search->count];
    table->index = sram_table_index(name);
    if (table->index < 0) return;
    table->count = frequencies_from(value, table->mhz);
    if (table->count > 0) search->count++;
}

static void has_table(const void *key, const void *value, void *context) {
    char name[64];
    double mhz[MAX_STATES];
    if (CFGetTypeID(key) != CFStringGetTypeID()) return;
    copy_string((CFStringRef)key, name, sizeof(name));
    if (sram_table_index(name) >= 0 && frequencies_from(value, mhz) > 0) *(int *)context = 1;
}

static void search_tables(const char *node, CFDictionaryRef properties, void *context) {
    table_search *search = context;
    int found = 0;
    CFDictionaryApplyFunction(properties, has_table, &found);
    if (!found) return;
    search->nodes++;
    strlcpy(search->node, node, sizeof(search->node));
    CFDictionaryApplyFunction(properties, collect_tables, search);
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
                if (s->table_count > 0) strlcpy(s->table_node, name, sizeof(s->table_node));
            }
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
    }
    // A chip that keeps the same tables on a node of another name: taken only when
    // exactly one node of the device tree has them, so there is nothing to choose.
    if (s->table_count == 0) {
        table_search *search = calloc(1, sizeof(*search));
        if (search) {
            each_device_tree_node(search_tables, search);
            if (search->nodes == 1 && search->count > 0) {
                qsort(search->tables, (size_t)search->count, sizeof(freq_table), compare_tables);
                memcpy(s->tables, search->tables, sizeof(freq_table) * (size_t)search->count);
                s->table_count = search->count;
                strlcpy(s->table_node, search->node, sizeof(s->table_node));
            }
            free(search);
        }
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
    if (s->last) CFRelease(s->last);
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
// `fitting` receives how many tables have that many steps.
static const freq_table *table_for(const ftop_cpu_sampler *s, char kind, int steps, int *fitting) {
    const freq_table *first = NULL, *known = NULL;
    int agree = 1;
    int known_index = kind == 'P' ? 5 : (kind == 'E' ? 1 : -1);
    *fitting = 0;
    for (int i = 0; i < s->table_count; i++) {
        const freq_table *table = &s->tables[i];
        if (table->count != steps) continue;
        (*fitting)++;
        if (table->index == known_index) known = table;
        if (!first) first = table;
        else if (!same_frequencies(first, table)) agree = 0;
    }
    if (first && agree) return first;
    return known;
}

// Where the core part of a channel name starts: after the last underscore, or at 0.
static size_t core_part(const char *name) {
    const char *underscore = strrchr(name, '_');
    return underscore ? (size_t)(underscore - name) + 1 : 0;
}

int ftop_core_channel_parse(const char *name, char *kind, int *index) {
    if (!name) return 0;
    const char *core = name + core_part(name);
    if (core[0] < 'A' || core[0] > 'Z' || strncmp(core + 1, "CPU", 3) != 0) return 0;
    const char *digits = core + 4;
    size_t length = strlen(digits);
    if (length == 0 || length > 6) return 0;
    int value = 0;
    for (size_t i = 0; i < length; i++) {
        if (digits[i] < '0' || digits[i] > '9') return 0;
        value = value * 10 + (digits[i] - '0');
    }
    if (kind) *kind = core[0];
    if (index) *index = value;
    return 1;
}

int ftop_core_channel_compare(const char *a, const char *b) {
    char kind_a = 0, kind_b = 0;
    int index_a = 0, index_b = 0;
    if (!ftop_core_channel_parse(a, &kind_a, &index_a) || !ftop_core_channel_parse(b, &kind_b, &index_b)) return strcmp(a, b);
    size_t prefix_a = core_part(a), prefix_b = core_part(b);
    int order = strncmp(a, b, prefix_a < prefix_b ? prefix_a : prefix_b);
    if (order == 0) order = (prefix_a > prefix_b) - (prefix_a < prefix_b);
    if (order == 0) order = (kind_a > kind_b) - (kind_a < kind_b);
    if (order == 0) order = (index_a > index_b) - (index_a < index_b);
    return order != 0 ? order : strcmp(a, b);
}

static int compare_cores(const void *a, const void *b) {
    return ftop_core_channel_compare(((const ftop_core_freq *)a)->channel, ((const ftop_core_freq *)b)->channel);
}

// One core from its channel in a delta. Returns the table used, or NULL. With `out`,
// every state and its residency is written too.
static const freq_table *read_core(const ftop_cpu_sampler *s, CFDictionaryRef item, ftop_core_freq *core, text *out) {
    double total = 0, active = 0;
    double residencies[MAX_STATES];
    int active_states = 0;
    int32_t states = IOReportStateGetCount(item);
    for (int32_t j = 0; j < states; j++) {
        int64_t residency = IOReportStateGetResidency(item, j);
        if (residency < 0) residency = 0;
        char state[32];
        copy_string(IOReportStateGetNameForIndex(item, j), state, sizeof(state));
        if (out) append(out, "%s%s %lld", j == 0 ? "" : ", ", state, (long long)residency);
        total += (double)residency;
        if (is_idle_state(state)) continue;
        active += (double)residency;
        if (active_states < MAX_STATES) residencies[active_states] = (double)residency;
        active_states++;
    }
    core->steps = active_states;
    core->tables = s->table_count;
    core->fitting = 0;
    const freq_table *table = active_states > MAX_STATES ? NULL : table_for(s, core->kind, active_states, &core->fitting);
    double weighted = 0;
    if (table)
        for (int j = 0; j < active_states; j++) weighted += residencies[j] * table->mhz[j];
    core->active = total > 0 ? active / total : -1;
    core->max_mhz = table ? table->mhz[table->count - 1] : -1;
    // An idle core has no active time to weight; report the lowest step instead of nothing.
    core->mhz = !table ? -1 : (active > 0 ? weighted / active : table->mhz[0]);
    return table;
}

int ftop_cpu_sampler_update(ftop_cpu_sampler *s, ftop_core_freq *out, int capacity) {
    if (!s || !s->subscription) return -1;
    CFDictionaryRef current = IOReportCreateSamples(s->subscription, s->channels, NULL);
    if (!current) return -1;
    CFDictionaryRef delta = s->previous ? IOReportCreateSamplesDelta(s->previous, current, NULL) : NULL;
    if (s->previous) CFRelease(s->previous);
    s->previous = current;
    if (s->last) CFRelease(s->last);
    s->last = delta;
    if (!delta) return -1;

    int count = 0;
    CFTypeRef raw = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (raw && CFGetTypeID(raw) == CFArrayGetTypeID()) {
        CFArrayRef list = (CFArrayRef)raw;
        for (CFIndex i = 0; i < CFArrayGetCount(list) && count < capacity; i++) {
            CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
            ftop_core_freq core = {0};
            copy_string(IOReportChannelGetChannelName(item), core.channel, sizeof(core.channel));
            // A core channel is its cluster type letter, "CPU", and digits, alone
            // ("PCPU000") or after a cluster prefix ("PACC0_PCPU0").
            if (!ftop_core_channel_parse(core.channel, &core.kind, &core.index)) continue;
            read_core(s, item, &core, NULL);
            out[count++] = core;
        }
    }
    qsort(out, (size_t)count, sizeof(ftop_core_freq), compare_cores);
    return count;
}

// ---- Diagnostics ----

#define MAX_LISTED 48

typedef struct {
    text *out;
    const char *prefix;
    int listed, more;
} property_listing;

// One property that could be a frequency table: its size, whether it reads as one, and how it starts.
static void list_property(text *out, const char *name, CFTypeRef value) {
    if (CFGetTypeID(value) != CFDataGetTypeID()) {
        append(out, "  %s: not bytes\n", name);
        return;
    }
    const UInt8 *bytes = CFDataGetBytePtr((CFDataRef)value);
    CFIndex length = CFDataGetLength((CFDataRef)value);
    double mhz[MAX_STATES];
    int steps = frequencies_from(value, mhz);
    append(out, "  %s: %ld bytes, ", name, (long)length);
    if (steps > 0) append(out, "reads as %d steps %.0f-%.0f MHz,", steps, mhz[0], mhz[steps - 1]);
    else append(out, "does not read as frequencies,");
    // The first 32 bytes show the size of an entry and the unit.
    for (CFIndex i = 0; i < length && i < 32; i++) append(out, "%s%02x", i % 4 == 0 ? " " : "", bytes[i]);
    append(out, "%s\n", length > 32 ? " ..." : "");
}

typedef struct {
    text *out;
    const char *prefix;
    int nodes, more;
} node_listing;

static void collect_prefixed(const void *key, const void *value, void *context) {
    const char *prefix = ((void **)context)[0];
    char name[64];
    (void)value;
    if (CFGetTypeID(key) != CFStringGetTypeID()) return;
    copy_string((CFStringRef)key, name, sizeof(name));
    if (strncmp(name, prefix, strlen(prefix)) == 0) CFArrayAppendValue((CFMutableArrayRef)((void **)context)[1], key);
}

static CFComparisonResult compare_names(const void *a, const void *b, void *context) {
    (void)context;
    return CFStringCompare((CFStringRef)a, (CFStringRef)b, kCFCompareNumerically);
}

static void list_node(const char *node, CFDictionaryRef properties, void *context) {
    node_listing *nodes = context;
    CFMutableArrayRef names = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    void *collecting[2] = {(void *)nodes->prefix, names};
    CFDictionaryApplyFunction(properties, collect_prefixed, collecting);
    CFIndex count = CFArrayGetCount(names);
    if (count > 0 && nodes->nodes >= 8) nodes->more++;
    else if (count > 0) {
        nodes->nodes++;
        append(nodes->out, " node %s\n", node);
        CFArraySortValues(names, CFRangeMake(0, count), compare_names, NULL);
        for (CFIndex i = 0; i < count && i < MAX_LISTED; i++) {
            CFStringRef key = (CFStringRef)CFArrayGetValueAtIndex(names, i);
            char name[64];
            copy_string(key, name, sizeof(name));
            list_property(nodes->out, name, CFDictionaryGetValue(properties, key));
        }
        if (count > MAX_LISTED) append(nodes->out, "  and %ld more\n", (long)(count - MAX_LISTED));
    }
    CFRelease(names);
}

// Every property of the device tree whose name starts with `prefix`, by node.
// Returns how many nodes have one.
static int describe_properties(text *out, const char *prefix) {
    node_listing nodes = {out, prefix, 0, 0};
    append(out, "properties named %s* in the device tree:\n", prefix);
    each_device_tree_node(list_node, &nodes);
    if (nodes.nodes == 0) append(out, " none\n");
    if (nodes.more > 0) append(out, " and %d more nodes\n", nodes.more);
    return nodes.nodes;
}

static void list_name(const void *key, const void *value, void *context) {
    property_listing *listing = context;
    char name[64];
    if (CFGetTypeID(key) != CFStringGetTypeID()) return;
    if (listing->listed >= 160) { listing->more++; return; }
    listing->listed++;
    copy_string((CFStringRef)key, name, sizeof(name));
    if (CFGetTypeID(value) == CFDataGetTypeID()) append(listing->out, " %s(%ld)", name, (long)CFDataGetLength((CFDataRef)value));
    else append(listing->out, " %s", name);
}

// The names of all properties of a registry entry, with the byte count of each data property.
static void describe_names(text *out, io_registry_entry_t entry) {
    io_name_t name = {0};
    CFMutableDictionaryRef properties = NULL;
    IORegistryEntryGetName(entry, name);
    if (IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) != KERN_SUCCESS || !properties) return;
    property_listing listing = {out, "", 0, 0};
    append(out, "all properties of %s (bytes):", name);
    CFDictionaryApplyFunction(properties, list_name, &listing);
    if (listing.more > 0) append(out, " and %d more", listing.more);
    append(out, "\n");
    CFRelease(properties);
}

static long integer_property(io_registry_entry_t entry, CFStringRef key) {
    long result = -1;
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return -1;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value, kCFNumberLongType, &result);
    else if (CFGetTypeID(value) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)value) >= 4) {
        uint32_t raw = 0;
        memcpy(&raw, CFDataGetBytePtr((CFDataRef)value), 4);
        result = raw;
    }
    CFRelease(value);
    return result;
}

// How the device tree numbers each CPU, to tell which channel is which core.
static void describe_cpus(text *out) {
    io_registry_entry_t cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus");
    append(out, "cpus in the device tree (-1 where a property is missing):\n");
    if (!cpus) { append(out, " none\n"); return; }
    io_iterator_t iterator = 0;
    if (IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS) {
        io_object_t cpu;
        int listed = 0;
        while ((cpu = IOIteratorNext(iterator))) {
            io_name_t name = {0};
            char type[8] = "?";
            IORegistryEntryGetName(cpu, name);
            CFTypeRef raw = IORegistryEntryCreateCFProperty(cpu, CFSTR("cluster-type"), kCFAllocatorDefault, 0);
            if (raw && CFGetTypeID(raw) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)raw) > 0) {
                char letter = (char)CFDataGetBytePtr((CFDataRef)raw)[0];
                if (letter >= 'A' && letter <= 'Z') { type[0] = letter; type[1] = 0; }
            }
            if (raw) CFRelease(raw);
            if (listed++ < 128)
                append(out, " %s type %s, logical-cpu-id %ld, cpu-id %ld, cluster-id %ld, cluster-core-id %ld\n", name, type,
                       integer_property(cpu, CFSTR("logical-cpu-id")), integer_property(cpu, CFSTR("cpu-id")), integer_property(cpu, CFSTR("cluster-id")),
                       integer_property(cpu, CFSTR("cluster-core-id")));
            IOObjectRelease(cpu);
        }
        IOObjectRelease(iterator);
    }
    IOObjectRelease(cpus);
}

static io_registry_entry_t arm_io_device(const char *wanted) {
    io_iterator_t iterator = 0;
    io_registry_entry_t found = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) != KERN_SUCCESS) return 0;
    io_object_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t name = {0};
        if (!found && IORegistryEntryGetName(entry, name) == KERN_SUCCESS && strcmp(name, wanted) == 0) found = entry;
        else IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    return found;
}

int ftop_cpu_sampler_describe(ftop_cpu_sampler *s, char *buffer, int capacity) {
    if (!s || !buffer || capacity <= 0) return -1;
    text out = text_begin(buffer, capacity);

    // What decides whether a frequency can be shown comes first; the long list of states last.
    append(&out, "== CPU frequency\n");
    append(&out, "frequency tables: looked for voltage-states<N>-sram on the power manager (pmgr), else on the one device tree node that has them\n");
    if (s->table_count == 0) append(&out, " none found\n");
    for (int i = 0; i < s->table_count; i++) {
        const freq_table *table = &s->tables[i];
        append(&out, " table %s voltage-states%d-sram %d steps %.0f-%.0f MHz\n", s->table_node, table->index, table->count, table->mhz[0], table->mhz[table->count - 1]);
    }
    int nodes = describe_properties(&out, "voltage-states");
    if (s->table_count == 0 || nodes == 0) {
        io_registry_entry_t pmgr = arm_io_device("pmgr");
        if (pmgr) {
            describe_names(&out, pmgr);
            IOObjectRelease(pmgr);
        } else {
            append(&out, "no AppleARMIODevice node is named pmgr\n");
        }
    }
    describe_cpus(&out);

    append(&out, "channels of IOReport \"CPU Stats\" / \"CPU Core Performance States\" (state and residency):\n");
    CFTypeRef raw = s->last ? CFDictionaryGetValue(s->last, CFSTR("IOReportChannels")) : NULL;
    if (!s->subscription) append(&out, " IOReport gave no subscription to the group\n");
    else if (!raw || CFGetTypeID(raw) != CFArrayGetTypeID()) append(&out, " no sample yet\n");
    else {
        CFArrayRef list = (CFArrayRef)raw;
        if (CFArrayGetCount(list) == 0) append(&out, " the group has no channels\n");
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
            ftop_core_freq core = {0};
            copy_string(IOReportChannelGetChannelName(item), core.channel, sizeof(core.channel));
            int is_core = ftop_core_channel_parse(core.channel, &core.kind, &core.index);
            if (is_core) append(&out, " %s kind %c index %d: ", core.channel, core.kind, core.index);
            else append(&out, " %s not a core channel: ", core.channel);
            const freq_table *table = read_core(s, item, &core, &out);
            if (!is_core) append(&out, "\n");
            else if (table) append(&out, "; %d active states, table voltage-states%d-sram\n", core.steps, table->index);
            else append(&out, "; %d active states, no table (%d of %d tables have that many steps)\n", core.steps, core.fitting, core.tables);
        }
    }
    return text_end(&out);
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
    CFDictionaryRef last; // the delta of the last update, kept for the diagnostics
    double mhz[MAX_STATES];
    int mhz_count;
    char node[32]; // the registry node the frequency steps were read from
};

// The registry entry the graphics driver is attached to, or 0.
static io_registry_entry_t gpu_driver_node(void) {
    io_service_t driver = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (!driver) return 0;
    io_registry_entry_t parent = 0;
    if (IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) != KERN_SUCCESS) parent = 0;
    IOObjectRelease(driver);
    return parent;
}

ftop_gpu_sampler *ftop_gpu_sampler_create(void) {
    ftop_gpu_sampler *s = calloc(1, sizeof(*s));
    if (!s) return NULL;

    // The GPU's own node lists its frequency steps; the power manager's tables do not say which is the GPU's.
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS) {
        io_object_t entry;
        while ((entry = IOIteratorNext(iterator))) {
            io_name_t name = {0};
            if (s->mhz_count == 0 && IORegistryEntryGetName(entry, name) == KERN_SUCCESS && strcmp(name, "sgx") == 0) {
                s->mhz_count = read_frequencies(entry, CFSTR("perf-states"), s->mhz);
                if (s->mhz_count > 0) strlcpy(s->node, name, sizeof(s->node));
            }
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
    }
    // A chip whose GPU node has another name: the node the graphics driver is attached to is the GPU's.
    if (s->mhz_count == 0) {
        io_registry_entry_t node = gpu_driver_node();
        if (node) {
            io_name_t name = {0};
            s->mhz_count = read_frequencies(node, CFSTR("perf-states"), s->mhz);
            if (s->mhz_count > 0 && IORegistryEntryGetName(node, name) == KERN_SUCCESS) strlcpy(s->node, name, sizeof(s->node));
            IOObjectRelease(node);
        }
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
    if (s->last) CFRelease(s->last);
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
    if (s->last) CFRelease(s->last);
    s->last = delta;
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
            out->steps = active_states;
            out->table_steps = s->mhz_count;
            found = 0;
        }
    }
    return found;
}

int ftop_gpu_sampler_describe(ftop_gpu_sampler *s, char *buffer, int capacity) {
    if (!s || !buffer || capacity <= 0) return -1;
    text out = text_begin(buffer, capacity);
    append(&out, "== GPU frequency\n");
    append(&out, "frequency table: looked for perf-states on the GPU's node (sgx), else on the node the graphics driver is attached to\n");
    if (s->mhz_count > 0) {
        double low = s->mhz[0], high = s->mhz[0];
        for (int i = 1; i < s->mhz_count; i++) {
            if (s->mhz[i] < low) low = s->mhz[i];
            if (s->mhz[i] > high) high = s->mhz[i];
        }
        append(&out, " table %s perf-states %d values %.0f-%.0f MHz\n", s->node, s->mhz_count, low, high);
    } else {
        append(&out, " none found\n");
    }
    int nodes = describe_properties(&out, "perf-state");
    io_registry_entry_t node = gpu_driver_node();
    if (node) {
        io_name_t name = {0};
        IORegistryEntryGetName(node, name);
        append(&out, "the graphics driver is attached to node %s\n", name);
        if (s->mhz_count == 0 || nodes == 0) describe_names(&out, node);
        IOObjectRelease(node);
    } else {
        append(&out, "no graphics driver (IOAccelerator) with a parent node\n");
    }

    append(&out, "channels of IOReport \"GPU Stats\" / \"GPU Performance States\" (state and residency; ftop reads GPUPH):\n");
    CFTypeRef raw = s->last ? CFDictionaryGetValue(s->last, CFSTR("IOReportChannels")) : NULL;
    if (!s->subscription) append(&out, " IOReport gave no subscription to the group\n");
    else if (!raw || CFGetTypeID(raw) != CFArrayGetTypeID()) append(&out, " no sample yet\n");
    else {
        CFArrayRef list = (CFArrayRef)raw;
        if (CFArrayGetCount(list) == 0) append(&out, " the group has no channels\n");
        for (CFIndex i = 0; i < CFArrayGetCount(list) && i < MAX_LISTED; i++) {
            CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
            char channel[64];
            copy_string(IOReportChannelGetChannelName(item), channel, sizeof(channel));
            append(&out, " %s: ", channel);
            int active_states = 0;
            int32_t states = IOReportStateGetCount(item);
            for (int32_t j = 0; j < states && j < 2 * MAX_STATES; j++) {
                int64_t residency = IOReportStateGetResidency(item, j);
                char state[32];
                copy_string(IOReportStateGetNameForIndex(item, j), state, sizeof(state));
                append(&out, "%s%s %lld", j == 0 ? "" : ", ", state, (long long)residency);
                if (!is_idle_state(state)) active_states++;
            }
            append(&out, "; %d active states\n", active_states);
        }
        if (CFArrayGetCount(list) > MAX_LISTED) append(&out, " and %ld more channels\n", (long)(CFArrayGetCount(list) - MAX_LISTED));
    }
    return text_end(&out);
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
