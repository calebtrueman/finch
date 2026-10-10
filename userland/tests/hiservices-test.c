/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-hiservices-test: HIServices' AXValue and text markers, the Process Manager
 * and its constants, one result per line so runs against Apple's ApplicationServices
 * and Finch's can be diffed. (Nothing here depends on the process being trusted for
 * accessibility, which differs between machines.)
 */
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

static void
show(const char *label, CFTypeRef v)
{
    char b[256] = "(null)";
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        CFStringGetCString(v, b, sizeof b, kCFStringEncodingUTF8);
    printf("%s: %s\n", label, b);
}

int
main(void)
{
    Dl_info info;
    dladdr((void *)AXValueCreate, &info);
    printf("HIServices: %s\n", info.dli_fname);

    CGPoint p = {1.5, -2}, p2;
    CGSize s = {3, 4};
    CGRect r = {{1, 2}, {3, 4}}, r2;
    CFRange range = {5, 6}, range2;
    AXError e = kAXErrorCannotComplete, e2;
    AXValueRef vp = AXValueCreate(kAXValueTypeCGPoint, &p), vs = AXValueCreate(kAXValueTypeCGSize, &s),
               vr = AXValueCreate(kAXValueTypeCGRect, &r), vg = AXValueCreate(kAXValueTypeCFRange, &range),
               ve = AXValueCreate(kAXValueTypeAXError, &e);
    printf("types %d %d %d %d %d, illegal %p\n", AXValueGetType(vp), AXValueGetType(vs), AXValueGetType(vr),
           AXValueGetType(vg), AXValueGetType(ve), (void *)AXValueCreate(kAXValueTypeIllegal, &p));
    printf("point %d %g %g\n", AXValueGetValue(vp, kAXValueTypeCGPoint, &p2), p2.x, p2.y);
    printf("point as rect %d\n", AXValueGetValue(vp, kAXValueTypeCGRect, &r2));
    printf("rect %d %g %g %g %g\n", AXValueGetValue(vr, kAXValueTypeCGRect, &r2), r2.origin.x, r2.origin.y,
           r2.size.width, r2.size.height);
    printf("range %d %ld %ld\n", AXValueGetValue(vg, kAXValueTypeCFRange, &range2), (long)range2.location,
           (long)range2.length);
    printf("error %d %d\n", AXValueGetValue(ve, kAXValueTypeAXError, &e2), e2);
    AXValueRef vp2 = AXValueCreate(kAXValueTypeCGPoint, &p);
    printf("equal %d, type id %d\n", CFEqual(vp, vp2), CFGetTypeID(vp) == AXValueGetTypeID());

    const UInt8 a[] = {1, 2, 3}, b[] = {4, 5};
    AXTextMarkerRef m = AXTextMarkerCreate(NULL, a, 3);
    printf("marker length %ld bytes %d %d %d\n", (long)AXTextMarkerGetLength(m), AXTextMarkerGetBytePtr(m)[0],
           AXTextMarkerGetBytePtr(m)[1], AXTextMarkerGetBytePtr(m)[2]);
    AXTextMarkerRangeRef mr = AXTextMarkerRangeCreateWithBytes(NULL, a, 3, b, 2);
    AXTextMarkerRef start = AXTextMarkerRangeCopyStartMarker(mr), end = AXTextMarkerRangeCopyEndMarker(mr);
    printf("range markers %ld %ld, start equal %d\n", (long)AXTextMarkerGetLength(start),
           (long)AXTextMarkerGetLength(end), CFEqual(start, m));

    AXUIElementRef app = AXUIElementCreateApplication(getpid()), app2 = AXUIElementCreateApplication(getpid());
    pid_t pid = 0;
    printf("element pid ok %d %d, equal %d\n", AXUIElementGetPid(app, &pid), pid == getpid(), CFEqual(app, app2));
    printf("timeout %d %d\n", AXUIElementSetMessagingTimeout(app, 1), AXUIElementSetMessagingTimeout(app, -1));

    ProcessSerialNumber psn, other;
    printf("current %d\n", GetCurrentProcess(&psn));
    pid = 0;
    printf("pid %d same %d\n", GetProcessPID(&psn, &pid), pid == getpid());
    printf("for pid %d\n", GetProcessForPID(getpid(), &other));
    Boolean same = false;
    printf("same process %d %d\n", SameProcess(&psn, &other, &same), same);
    ProcessSerialNumber cur = {0, kCurrentProcess};
    pid = 0;
    printf("kCurrentProcess pid %d same %d\n", GetProcessPID(&cur, &pid), pid == getpid());
    printf("missing pid %d\n", GetProcessForPID(999999, &other));
    CFStringRef name = NULL;
    printf("name %d\n", CopyProcessName(&psn, &name));
    show("name", name);
    printf("zoom %d\n", UAZoomEnabled());
    CGRect zr = {{0, 0}, {10, 10}};
    printf("zoom focus %d\n", (int)UAZoomChangeFocus(&zr, NULL, kUAZoomFocusTypeOther));
    show("prompt", kAXTrustedCheckOptionPrompt);
    return 0;
}
