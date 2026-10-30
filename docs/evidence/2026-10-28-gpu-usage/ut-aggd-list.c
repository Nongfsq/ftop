// Lists every IOReport channel (group, subgroup, name, format 1=simple 2=state 3=histogram, unit, driver);
// with a group name as argument it also prints those channels in full (CFShow, to stderr).
// Build: clang -o list ut-aggd-list.c -framework CoreFoundation -lIOReport
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
static void str(CFStringRef s, char *b, size_t n) { b[0] = 0; if (s) CFStringGetCString(s, b, n, kCFStringEncodingUTF8); }
int main(int argc, char **argv) {
    CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
    CFArrayRef list = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    printf("total %ld\n", (long)CFArrayGetCount(list));
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(list, i);
        char g[256], sg[256], n[256], u[64], d[256];
        str(IOReportChannelGetGroup(c), g, sizeof g); str(IOReportChannelGetSubGroup(c), sg, sizeof sg);
        str(IOReportChannelGetChannelName(c), n, sizeof n); str(IOReportChannelGetUnitLabel(c), u, sizeof u);
        str(IOReportChannelGetDriverName(c), d, sizeof d);
        printf("%s\t%s\t%s\tfmt=%d\tunit=%s\tdrv=%s\n", g, sg, n, IOReportChannelGetFormat(c), u, d);
        if (argc > 1 && strstr(g, argv[1])) CFShow(c);
    }
}
