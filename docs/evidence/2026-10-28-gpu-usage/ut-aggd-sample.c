// Samples the GPU "UT Engagement" IOReport channels next to GPU busy time, clock, power and the
// driver's Device Utilization %, one CSV row per interval.
// Build: clang -o ut-aggd-sample ut-aggd-sample.c -framework CoreFoundation -framework IOKit -lIOReport
// Usage: ut-aggd-sample <label> <seconds> <interval_ms> > out.csv   (add "noheader" as 4th arg to append)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
void IOReportMergeChannels(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
void IOReportIterate(CFDictionaryRef, int (^)(CFDictionaryRef));
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
int IOReportStateGetCount(CFDictionaryRef);
int64_t IOReportStateGetResidency(CFDictionaryRef, int);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
int IOReportHistogramGetBucketCount(CFDictionaryRef);
int64_t IOReportHistogramGetBucketHits(CFDictionaryRef, int);
int64_t IOReportHistogramGetBucketSum(CFDictionaryRef, int);

// GPU clock for P1..P13 on this Mac (sgx perf-states, as in sample.py).
static const int MHZ[] = {338, 486, 636, 796, 888, 988, 1084, 1182, 1278, 1374, 1470, 1578, 1620};
enum { MAXCOL = 2048 };
static char *names[MAXCOL];
static double vals[MAXCOL];
static int ncol;

static void str(CFStringRef s, char *b, size_t n) { b[0] = 0; if (s) CFStringGetCString(s, b, n, kCFStringEncodingUTF8); }
static void put(const char *name, double v) {
    if (ncol >= MAXCOL) return;
    if (!names[ncol]) names[ncol] = strdup(name);
    vals[ncol++] = v;
}

static double driver_pct(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (!s) return -1;
    CFDictionaryRef st = IORegistryEntryCreateCFProperty(s, CFSTR("PerformanceStatistics"), NULL, 0);
    IOObjectRelease(s);
    double v = -1;
    if (st) {
        CFNumberRef n = CFDictionaryGetValue(st, CFSTR("Device Utilization %"));
        if (n) CFNumberGetValue(n, kCFNumberDoubleType, &v);
        CFRelease(st);
    }
    return v;
}

static void add(CFMutableDictionaryRef into, const char *g, const char *sg) {
    CFStringRef gs = CFStringCreateWithCString(NULL, g, kCFStringEncodingUTF8);
    CFStringRef ss = sg ? CFStringCreateWithCString(NULL, sg, kCFStringEncodingUTF8) : NULL;
    CFMutableDictionaryRef c = IOReportCopyChannelsInGroup(gs, ss, 0, 0, 0);
    if (c) IOReportMergeChannels(into, c, NULL);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s label seconds interval_ms [noheader]\n", argv[0]); return 1; }
    const char *label = argv[1];
    double seconds = atof(argv[2]);
    int ms = atoi(argv[3]);
    int header = !(argc > 4 && !strcmp(argv[4], "noheader"));

    CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("GPU UT AggD Stats"), NULL, 0, 0, 0);
    add(ch, "GPU UT Engagement", NULL);
    add(ch, "GPU Stats", "GPU Performance States");
    add(ch, "GPU Stats", "UT Engagement centi-% Histogram");
    add(ch, "GPU Stats", "GPU Throttler Counters");
    add(ch, "GPU Stats", "PPM Target as % of Max GPU Power");
    add(ch, "GPU Stats", "Fender State");
    add(ch, "Energy Model", NULL);
    CFMutableDictionaryRef sub = NULL;
    IOReportSubscriptionRef s = IOReportCreateSubscription(NULL, ch, &sub, 0, NULL);
    if (!s) { fprintf(stderr, "subscription failed\n"); return 1; }

    CFDictionaryRef a = IOReportCreateSamples(s, sub, NULL);
    struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
    double start = t0.tv_sec + t0.tv_nsec / 1e9, prev = start;
    for (int row = 0;; row++) {
        usleep(ms * 1000);
        CFDictionaryRef b = IOReportCreateSamples(s, sub, NULL);
        struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
        double now = t1.tv_sec + t1.tv_nsec / 1e9, dt = now - prev;
        prev = now;
        CFDictionaryRef d = IOReportCreateSamplesDelta(a, b, NULL);
        ncol = 0;
        __block double busy = 0, total = 0, weighted = 0, gpu_nj = -1;
        __block int nput = 0;
        // Derived columns first, filled after the walk.
        put("interval_s", dt); put("gpuph_busy_pct", 0); put("gpuph_mhz", 0); put("gpu_w", 0); put("driver_device_pct", driver_pct());
        nput = ncol;
        IOReportIterate(d, ^int(CFDictionaryRef c) {
            char g[128], sg[128], n[128], key[512], st[64];
            str(IOReportChannelGetGroup(c), g, sizeof g); str(IOReportChannelGetSubGroup(c), sg, sizeof sg);
            str(IOReportChannelGetChannelName(c), n, sizeof n);
            if (!strcmp(g, "Energy Model")) {
                if (!strcmp(n, "GPU Energy")) gpu_nj = IOReportSimpleGetIntegerValue(c, 0);
                return 0;
            }
            int fmt = IOReportChannelGetFormat(c);
            if (!strcmp(g, "GPU UT AggD Stats")) snprintf(key, sizeof key, "aggd:%s", n + 4);
            else if (!strcmp(g, "GPU UT Engagement")) snprintf(key, sizeof key, "uthist_p%s", strrchr(sg, ' ') + 1);
            else snprintf(key, sizeof key, "%s:%s", sg, n);
            for (char *p = key; *p; p++) if (*p == ',' || *p == ' ') *p = '_';
            char col[600];
            if (fmt == 1) put(key, IOReportSimpleGetIntegerValue(c, 0));
            else if (fmt == 2) {
                int k = IOReportStateGetCount(c);
                for (int j = 0; j < k; j++) {
                    str(IOReportStateGetNameForIndex(c, j), st, sizeof st);
                    int64_t r = IOReportStateGetResidency(c, j);
                    snprintf(col, sizeof col, "%s:%s", key, st); put(col, r);
                    if (!strcmp(n, "GPUPH")) {
                        total += r;
                        if (st[0] == 'P') { int i = atoi(st + 1) - 1; busy += r; if (i >= 0 && i < 13) weighted += (double)r * MHZ[i]; }
                    }
                }
            } else if (fmt == 3) {
                int k = IOReportHistogramGetBucketCount(c);
                int64_t hits = 0, sum = 0;
                for (int j = 0; j < k; j++) {
                    int64_t h = IOReportHistogramGetBucketHits(c, j);
                    hits += h;
                    if (h) sum += IOReportHistogramGetBucketSum(c, j);  // an empty bucket's sum is a sentinel
                    snprintf(col, sizeof col, "%s:b%02d", key, j); put(col, h);
                }
                snprintf(col, sizeof col, "%s:hits", key); put(col, hits);
                snprintf(col, sizeof col, "%s:sum", key); put(col, sum);
            }
            return 0;
        });
        vals[1] = total > 0 ? 100.0 * busy / total : -1;
        vals[2] = busy > 0 ? weighted / busy : -1;
        vals[3] = gpu_nj >= 0 ? gpu_nj / 1e9 / dt : -1;
        // Raw (since boot) Min/Max: a delta of a running min or max means nothing.
        IOReportIterate(b, ^int(CFDictionaryRef c) {
            char g[128], n[128], key[256];
            str(IOReportChannelGetGroup(c), g, sizeof g); str(IOReportChannelGetChannelName(c), n, sizeof n);
            if (strcmp(g, "GPU UT AggD Stats") || (strncmp(n, "AGX.Min", 7) && strncmp(n, "AGX.Max", 7))) return 0;
            snprintf(key, sizeof key, "raw:%s", n + 4); put(key, IOReportSimpleGetIntegerValue(c, 0));
            return 0;
        });
        if (row == 0 && header) {
            printf("t,label");
            for (int i = 0; i < ncol; i++) printf(",%s", names[i]);
            printf("\n");
        }
        printf("%.3f,%s", now - start, label);
        for (int i = 0; i < ncol; i++) {
            if (vals[i] < 0 && i < nput) printf(",");  // unavailable, not zero
            else if (vals[i] == (int64_t)vals[i]) printf(",%lld", (long long)vals[i]);
            else printf(",%.3f", vals[i]);
        }
        printf("\n");
        fflush(stdout);
        CFRelease(d); CFRelease(a);
        a = b;
        if (now - start >= seconds) break;
    }
    return 0;
}
