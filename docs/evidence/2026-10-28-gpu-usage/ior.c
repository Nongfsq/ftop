// Lists IOReport channels whose group or subgroup mentions the GPU, with the change over one second.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
int IOReportStateGetCount(CFDictionaryRef);
int64_t IOReportStateGetResidency(CFDictionaryRef, int);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
void IOReportIterate(CFDictionaryRef, int (^)(CFDictionaryRef));

static void str(CFStringRef s, char *b, size_t n) { b[0] = 0; if (s) CFStringGetCString(s, b, n, kCFStringEncodingUTF8); }
static int gpu(const char *s) { return strcasestr(s, "gpu") || strcasestr(s, "agx") || strcasestr(s, "gfx"); }

int main(void) {
    CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
    CFArrayRef list = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    CFMutableArrayRef kept = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(list, i);
        char g[128], sg[128];
        str(IOReportChannelGetGroup(c), g, sizeof g); str(IOReportChannelGetSubGroup(c), sg, sizeof sg);
        if (gpu(g) || gpu(sg)) CFArrayAppendValue(kept, c);
    }
    CFMutableDictionaryRef chans = CFDictionaryCreateMutableCopy(NULL, 0, all);
    CFDictionarySetValue(chans, CFSTR("IOReportChannels"), kept);
    CFMutableDictionaryRef sub = NULL;
    IOReportSubscriptionRef s = IOReportCreateSubscription(NULL, chans, &sub, 0, NULL);
    CFDictionaryRef a = IOReportCreateSamples(s, sub, NULL);
    sleep(1);
    CFDictionaryRef b = IOReportCreateSamples(s, sub, NULL);
    CFDictionaryRef d = IOReportCreateSamplesDelta(a, b, NULL);
    IOReportIterate(d, ^int(CFDictionaryRef c) {
        char g[128], sg[128], n[128], st[64];
        str(IOReportChannelGetGroup(c), g, sizeof g); str(IOReportChannelGetSubGroup(c), sg, sizeof sg); str(IOReportChannelGetChannelName(c), n, sizeof n);
        int fmt = IOReportChannelGetFormat(c);
        printf("%s | %s | %s | ", g, sg, n);
        if (fmt == 2) {  // state
            int k = IOReportStateGetCount(c);
            printf("%d states:", k);
            for (int j = 0; j < k && j < 20; j++) { str(IOReportStateGetNameForIndex(c, j), st, sizeof st); printf(" %s=%lld", st, (long long)IOReportStateGetResidency(c, j)); }
        } else printf("value %lld", (long long)IOReportSimpleGetIntegerValue(c, 0));
        printf("\n");
        return 0;
    });
    return 0;
}
