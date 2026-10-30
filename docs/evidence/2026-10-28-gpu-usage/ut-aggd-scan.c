// Prints the change over N seconds of every IOReport channel whose group, subgroup or name
// contains one of the given words (case-insensitive), one line per channel, zero lines left out.
// Build: clang -o ut-aggd-scan ut-aggd-scan.c -framework CoreFoundation -lIOReport
// Usage: ut-aggd-scan <seconds> <word>...
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
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
static void str(CFStringRef s, char *b, size_t n) { b[0] = 0; if (s) CFStringGetCString(s, b, n, kCFStringEncodingUTF8); }
static int argn; static char **args;
static int match(const char *g, const char *sg, const char *n) {
    for (int i = 0; i < argn; i++) if (strcasestr(g, args[i]) || strcasestr(sg, args[i]) || strcasestr(n, args[i])) return 1;
    return 0;
}
int main(int argc, char **argv) {
    int seconds = atoi(argv[1]); argn = argc - 2; args = argv + 2;
    CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
    CFArrayRef list = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    CFMutableArrayRef kept = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(list, i);
        char g[256], sg[256], n[256];
        str(IOReportChannelGetGroup(c), g, sizeof g); str(IOReportChannelGetSubGroup(c), sg, sizeof sg); str(IOReportChannelGetChannelName(c), n, sizeof n);
        if (match(g, sg, n)) CFArrayAppendValue(kept, c);
    }
    CFMutableDictionaryRef chans = CFDictionaryCreateMutableCopy(NULL, 0, all);
    CFDictionarySetValue(chans, CFSTR("IOReportChannels"), kept);
    CFMutableDictionaryRef sub = NULL;
    IOReportSubscriptionRef s = IOReportCreateSubscription(NULL, chans, &sub, 0, NULL);
    CFDictionaryRef a = IOReportCreateSamples(s, sub, NULL);
    sleep(seconds);
    CFDictionaryRef b = IOReportCreateSamples(s, sub, NULL);
    IOReportIterate(IOReportCreateSamplesDelta(a, b, NULL), ^int(CFDictionaryRef c) {
        char g[256], sg[256], n[256], st[64], line[8192]; int len = 0, any = 0;
        str(IOReportChannelGetGroup(c), g, sizeof g); str(IOReportChannelGetSubGroup(c), sg, sizeof sg); str(IOReportChannelGetChannelName(c), n, sizeof n);
        int fmt = IOReportChannelGetFormat(c);
        len += snprintf(line + len, sizeof line - len, "%s | %s | %s |", g, sg, n);
        if (fmt == 1) { long long v = IOReportSimpleGetIntegerValue(c, 0); any = v != 0; len += snprintf(line + len, sizeof line - len, " %lld", v); }
        else if (fmt == 2) {
            for (int j = 0; j < IOReportStateGetCount(c) && len < 7900; j++) {
                long long r = IOReportStateGetResidency(c, j); if (!r) continue; any = 1;
                str(IOReportStateGetNameForIndex(c, j), st, sizeof st); len += snprintf(line + len, sizeof line - len, " %s=%lld", st, r);
            }
        } else if (fmt == 3) {
            long long hits = 0, sum = 0;
            for (int j = 0; j < IOReportHistogramGetBucketCount(c) && len < 7900; j++) {
                long long h = IOReportHistogramGetBucketHits(c, j); if (!h) continue; any = 1;
                hits += h; sum += IOReportHistogramGetBucketSum(c, j); len += snprintf(line + len, sizeof line - len, " b%d=%lld", j, h);
            }
            if (hits) len += snprintf(line + len, sizeof line - len, " hits=%lld sum=%lld mean=%.1f", hits, sum, (double)sum / hits);
        }
        if (any) printf("%s\n", line);
        return 0;
    });
}
