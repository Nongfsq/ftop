// Prints the bucket layout (IOHistogramSegmentData: base width, scale flag, segment index, bucket count) of the GPU histograms.
// Build: clang -o cfg ut-aggd-histcfg.c -framework CoreFoundation -lIOReport
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
static void str(CFStringRef s, char *b, size_t n) { b[0] = 0; if (s) CFStringGetCString(s, b, n, kCFStringEncodingUTF8); }
int main(void) {
    CFArrayRef list = CFDictionaryGetValue(IOReportCopyAllChannels(0, 0), CFSTR("IOReportChannels"));
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(list, i);
        if (IOReportChannelGetFormat(c) != 3) continue;
        char g[256], sg[256], n[256];
        str(IOReportChannelGetGroup(c), g, sizeof g); str(IOReportChannelGetSubGroup(c), sg, sizeof sg); str(IOReportChannelGetChannelName(c), n, sizeof n);
        if (!strcasestr(g, "gpu")) continue;
        CFDictionaryRef info = CFDictionaryGetValue(c, CFSTR("IOReportChannelInfo"));
        CFDataRef cfg = info ? CFDictionaryGetValue(info, CFSTR("IOReportChannelConfig")) : NULL;
        printf("%s | %s | %s | cfg:", g, sg, n);
        if (cfg) { const uint32_t *w = (const uint32_t *)CFDataGetBytePtr(cfg); for (CFIndex k = 0; k < CFDataGetLength(cfg) / 4; k++) printf(" %u", w[k]); }
        printf("\n");
    }
}
