/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * HIServices' accessibility client API and Universal Access settings.
 *
 * Finch has no accessibility server yet (the service that lets an assistive app read
 * and drive other apps' interfaces), so a process is never trusted: elements and
 * observers can be made, and every question about another app's interface answers
 * kAXErrorAPIDisabled, as macOS answers a process the user hasn't allowed. AXValue
 * and text markers are complete. Zoom is off. The interface settings (reduce motion,
 * increase contrast, ...) are the com.apple.universalaccess preferences, as on macOS.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* CoreFoundation's runtime (swift-corelibs' CFRuntime.h): CF types of our own. */
typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} CFRuntimeClass;

extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes,
                                          unsigned char *category);

#define REGISTER(var, cls)                                                                                        \
    static dispatch_once_t once;                                                                                  \
    dispatch_once(&once, ^{ var = _CFRuntimeRegisterClass(&cls); });                                              \
    return var

static void *
create(CFTypeID type, size_t size)
{
    return (void *)_CFRuntimeCreateInstance(NULL, type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

/* --- trust --- */

Boolean
AXIsProcessTrusted(void)
{
    return false;
}

Boolean
AXIsProcessTrustedWithOptions(CFDictionaryRef options)
{
    return false; /* there's no prompt to show: nothing can grant trust yet */
}

Boolean
AXAPIEnabled(void)
{
    return false;
}

AXError
AXMakeProcessTrusted(CFStringRef executablePath)
{
    return kAXErrorNotImplemented;
}

/* --- AXValue --- */

struct __AXValue {
    CFRuntimeBase base;
    AXValueType type;
    union {
        CGPoint point;
        CGSize size;
        CGRect rect;
        CFRange range;
        AXError error;
    } v;
};

static CFTypeID value_type;

static size_t
value_size(AXValueType type)
{
    switch (type) {
    case kAXValueTypeCGPoint: return sizeof(CGPoint);
    case kAXValueTypeCGSize: return sizeof(CGSize);
    case kAXValueTypeCGRect: return sizeof(CGRect);
    case kAXValueTypeCFRange: return sizeof(CFRange);
    case kAXValueTypeAXError: return sizeof(AXError);
    default: return 0;
    }
}

static Boolean
value_equal(CFTypeRef a, CFTypeRef b)
{
    const struct __AXValue *x = a, *y = b;
    return x->type == y->type && !memcmp(&x->v, &y->v, value_size(x->type));
}

static CFStringRef
value_description(CFTypeRef cf)
{
    const struct __AXValue *v = cf;
    switch (v->type) {
    case kAXValueTypeCGPoint:
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("<AXValue %p> {value = x:%g y:%g type = kAXValueCGPointType}"),
                                        cf, v->v.point.x, v->v.point.y);
    case kAXValueTypeCGSize:
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("<AXValue %p> {value = w:%g h:%g type = kAXValueCGSizeType}"),
                                        cf, v->v.size.width, v->v.size.height);
    case kAXValueTypeCGRect:
        return CFStringCreateWithFormat(NULL, NULL,
                                        CFSTR("<AXValue %p> {value = x:%g y:%g w:%g h:%g type = kAXValueCGRectType}"),
                                        cf, v->v.rect.origin.x, v->v.rect.origin.y, v->v.rect.size.width,
                                        v->v.rect.size.height);
    case kAXValueTypeCFRange:
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("<AXValue %p> {value = location:%ld length:%ld type = kAXValueCFRangeType}"),
                                        cf, (long)v->v.range.location, (long)v->v.range.length);
    default:
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("<AXValue %p> {value = error:%d type = kAXValueAXErrorType}"), cf,
                                        (int)v->v.error);
    }
}

static const CFRuntimeClass value_class = {0, "AXValue", NULL, NULL, NULL, value_equal, NULL, NULL, value_description,
                                           NULL, NULL, 0};

CFTypeID
AXValueGetTypeID(void)
{
    REGISTER(value_type, value_class);
}

AXValueRef
AXValueCreate(AXValueType theType, const void *valuePtr)
{
    size_t n = value_size(theType);
    if (!n || !valuePtr)
        return NULL;
    struct __AXValue *v = create(AXValueGetTypeID(), sizeof(struct __AXValue));
    v->type = theType;
    memcpy(&v->v, valuePtr, n);
    return v;
}

AXValueType
AXValueGetType(AXValueRef value)
{
    return value ? value->type : kAXValueTypeIllegal;
}

Boolean
AXValueGetValue(AXValueRef value, AXValueType theType, void *valuePtr)
{
    if (!value || value->type != theType || !valuePtr)
        return false;
    memcpy(valuePtr, &value->v, value_size(theType));
    return true;
}

/* --- text markers: opaque bytes an app hands out and takes back --- */

struct __AXTextMarker {
    CFRuntimeBase base;
    CFDataRef bytes;
};

struct __AXTextMarkerRange {
    CFRuntimeBase base;
    AXTextMarkerRef start, end;
};

static CFTypeID marker_type, marker_range_type;

static void
marker_finalize(CFTypeRef cf)
{
    CFRelease(((struct __AXTextMarker *)cf)->bytes);
}

static Boolean
marker_equal(CFTypeRef a, CFTypeRef b)
{
    return CFEqual(((struct __AXTextMarker *)a)->bytes, ((struct __AXTextMarker *)b)->bytes);
}

static CFHashCode
marker_hash(CFTypeRef cf)
{
    return CFHash(((struct __AXTextMarker *)cf)->bytes);
}

static const CFRuntimeClass marker_class = {0, "AXTextMarker", NULL, NULL, marker_finalize, marker_equal, marker_hash,
                                            NULL, NULL, NULL, NULL, 0};

static void
marker_range_finalize(CFTypeRef cf)
{
    struct __AXTextMarkerRange *r = (struct __AXTextMarkerRange *)cf;
    CFRelease(r->start);
    CFRelease(r->end);
}

static Boolean
marker_range_equal(CFTypeRef a, CFTypeRef b)
{
    const struct __AXTextMarkerRange *x = a, *y = b;
    return CFEqual(x->start, y->start) && CFEqual(x->end, y->end);
}

static const CFRuntimeClass marker_range_class = {0, "AXTextMarkerRange", NULL, NULL, marker_range_finalize,
                                                  marker_range_equal, NULL, NULL, NULL, NULL, NULL, 0};

CFTypeID
AXTextMarkerGetTypeID(void)
{
    REGISTER(marker_type, marker_class);
}

CFTypeID
AXTextMarkerRangeGetTypeID(void)
{
    REGISTER(marker_range_type, marker_range_class);
}

AXTextMarkerRef
AXTextMarkerCreate(CFAllocatorRef allocator, const UInt8 *bytes, CFIndex length)
{
    struct __AXTextMarker *m = create(AXTextMarkerGetTypeID(), sizeof(struct __AXTextMarker));
    m->bytes = CFDataCreate(allocator, bytes, length);
    return m;
}

CFIndex
AXTextMarkerGetLength(AXTextMarkerRef marker)
{
    return CFDataGetLength(marker->bytes);
}

const UInt8 *
AXTextMarkerGetBytePtr(AXTextMarkerRef theTextMarker)
{
    return CFDataGetBytePtr(theTextMarker->bytes);
}

AXTextMarkerRangeRef
AXTextMarkerRangeCreate(CFAllocatorRef allocator, AXTextMarkerRef startMarker, AXTextMarkerRef endMarker)
{
    struct __AXTextMarkerRange *r = create(AXTextMarkerRangeGetTypeID(), sizeof(struct __AXTextMarkerRange));
    r->start = CFRetain(startMarker);
    r->end = CFRetain(endMarker);
    return r;
}

AXTextMarkerRangeRef
AXTextMarkerRangeCreateWithBytes(CFAllocatorRef allocator, const UInt8 *startMarkerBytes, CFIndex startMarkerLength,
                                 const UInt8 *endMarkerBytes, CFIndex endMarkerLength)
{
    AXTextMarkerRef a = AXTextMarkerCreate(allocator, startMarkerBytes, startMarkerLength),
                    b = AXTextMarkerCreate(allocator, endMarkerBytes, endMarkerLength);
    AXTextMarkerRangeRef r = AXTextMarkerRangeCreate(allocator, a, b);
    CFRelease(a);
    CFRelease(b);
    return r;
}

AXTextMarkerRef
AXTextMarkerRangeCopyStartMarker(AXTextMarkerRangeRef textMarkerRange)
{
    return CFRetain(textMarkerRange->start);
}

AXTextMarkerRef
AXTextMarkerRangeCopyEndMarker(AXTextMarkerRangeRef textMarkerRange)
{
    return CFRetain(textMarkerRange->end);
}

/* --- elements --- */

struct __AXUIElement {
    CFRuntimeBase base;
    pid_t pid; /* 0 for the system-wide element */
};

static CFTypeID element_type;

static Boolean
element_equal(CFTypeRef a, CFTypeRef b)
{
    return ((struct __AXUIElement *)a)->pid == ((struct __AXUIElement *)b)->pid;
}

static CFHashCode
element_hash(CFTypeRef cf)
{
    return (CFHashCode)((struct __AXUIElement *)cf)->pid;
}

static CFStringRef
element_description(CFTypeRef cf)
{
    const struct __AXUIElement *e = cf;
    return e->pid ? CFStringCreateWithFormat(NULL, NULL, CFSTR("<AXUIElement %p> {pid=%d}"), cf, e->pid)
                  : CFStringCreateWithFormat(NULL, NULL, CFSTR("<AXUIElement System Wide %p>"), cf);
}

static const CFRuntimeClass element_class = {0, "AXUIElement", NULL, NULL, NULL, element_equal, element_hash, NULL,
                                             element_description, NULL, NULL, 0};

CFTypeID
AXUIElementGetTypeID(void)
{
    REGISTER(element_type, element_class);
}

static AXUIElementRef
element_create(pid_t pid)
{
    struct __AXUIElement *e = create(AXUIElementGetTypeID(), sizeof(struct __AXUIElement));
    e->pid = pid;
    return e;
}

AXUIElementRef
AXUIElementCreateApplication(pid_t pid)
{
    return element_create(pid);
}

AXUIElementRef
AXUIElementCreateSystemWide(void)
{
    return element_create(0);
}

AXError
AXUIElementGetPid(AXUIElementRef element, pid_t *pid)
{
    if (!element || !pid)
        return kAXErrorIllegalArgument;
    *pid = element->pid;
    return kAXErrorSuccess;
}

AXError
AXUIElementCopyAttributeNames(AXUIElementRef element, CFArrayRef *names)
{
    if (names)
        *names = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementCopyAttributeValue(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value)
{
    if (value)
        *value = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementGetAttributeValueCount(AXUIElementRef element, CFStringRef attribute, CFIndex *count)
{
    if (count)
        *count = 0;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementCopyAttributeValues(AXUIElementRef element, CFStringRef attribute, CFIndex index, CFIndex maxValues,
                               CFArrayRef *values)
{
    if (values)
        *values = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementIsAttributeSettable(AXUIElementRef element, CFStringRef attribute, Boolean *settable)
{
    if (settable)
        *settable = false;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementSetAttributeValue(AXUIElementRef element, CFStringRef attribute, CFTypeRef value)
{
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementCopyMultipleAttributeValues(AXUIElementRef element, CFArrayRef attributes,
                                       AXCopyMultipleAttributeOptions options, CFArrayRef *values)
{
    if (values)
        *values = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementCopyParameterizedAttributeNames(AXUIElementRef element, CFArrayRef *names)
{
    if (names)
        *names = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementCopyParameterizedAttributeValue(AXUIElementRef element, CFStringRef parameterizedAttribute,
                                           CFTypeRef parameter, CFTypeRef *result)
{
    if (result)
        *result = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementCopyActionNames(AXUIElementRef element, CFArrayRef *names)
{
    if (names)
        *names = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementCopyActionDescription(AXUIElementRef element, CFStringRef action, CFStringRef *description)
{
    if (description)
        *description = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementPerformAction(AXUIElementRef element, CFStringRef action)
{
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementCopyElementAtPosition(AXUIElementRef application, float x, float y, AXUIElementRef *element)
{
    if (element)
        *element = NULL;
    return kAXErrorAPIDisabled;
}

AXError
AXUIElementSetMessagingTimeout(AXUIElementRef element, float timeoutInSeconds)
{
    return timeoutInSeconds < 0 ? kAXErrorIllegalArgument : kAXErrorSuccess;
}

AXError
AXUIElementPostKeyboardEvent(AXUIElementRef application, CGCharCode keyChar, CGKeyCode virtualKey, Boolean keyDown)
{
    return kAXErrorAPIDisabled;
}

/* --- observers --- */

struct __AXObserver {
    CFRuntimeBase base;
    pid_t pid;
    CFRunLoopSourceRef source;
};

static CFTypeID observer_type;

static void
observer_finalize(CFTypeRef cf)
{
    struct __AXObserver *o = (struct __AXObserver *)cf;
    if (o->source) {
        CFRunLoopSourceInvalidate(o->source);
        CFRelease(o->source);
    }
}

static const CFRuntimeClass observer_class = {0, "AXObserver", NULL, NULL, observer_finalize, NULL, NULL, NULL, NULL,
                                              NULL, NULL, 0};

CFTypeID
AXObserverGetTypeID(void)
{
    REGISTER(observer_type, observer_class);
}

static void
observer_perform(void *info)
{
}

static AXError
observer_create(pid_t application, AXObserverRef *outObserver)
{
    if (!outObserver)
        return kAXErrorIllegalArgument;
    struct __AXObserver *o = create(AXObserverGetTypeID(), sizeof(struct __AXObserver));
    o->pid = application;
    CFRunLoopSourceContext ctx = {0};
    ctx.info = o;
    ctx.perform = observer_perform;
    o->source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    *outObserver = o;
    return kAXErrorSuccess;
}

AXError
AXObserverCreate(pid_t application, AXObserverCallback callback, AXObserverRef *outObserver)
{
    return observer_create(application, outObserver);
}

AXError
AXObserverCreateWithInfoCallback(pid_t application, AXObserverCallbackWithInfo callback, AXObserverRef *outObserver)
{
    return observer_create(application, outObserver);
}

AXError
AXObserverAddNotification(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon)
{
    return kAXErrorAPIDisabled;
}

AXError
AXObserverRemoveNotification(AXObserverRef observer, AXUIElementRef element, CFStringRef notification)
{
    return kAXErrorNotificationNotRegistered;
}

CFRunLoopSourceRef
AXObserverGetRunLoopSource(AXObserverRef observer)
{
    return observer->source;
}

/* --- Universal Access: zoom --- */

Boolean
UAZoomEnabled(void)
{
    return false;
}

OSStatus
UAZoomChangeFocus(const CGRect *inRect, const CGRect *inHighlightRect, UAZoomChangeFocusType inType)
{
    return noErr; /* with zoom off there's nothing to follow the focus */
}

/* --- Universal Access: interface settings --- */

static const CFStringRef kUniversalAccess = CFSTR("com.apple.universalaccess");

static Boolean
setting(CFStringRef key)
{
    Boolean valid = false;
    Boolean on = CFPreferencesGetAppBooleanValue(key, kUniversalAccess, &valid);
    return valid && on;
}

static void
set_setting(CFStringRef key, Boolean on, CFStringRef notification)
{
    CFPreferencesSetAppValue(key, on ? kCFBooleanTrue : kCFBooleanFalse, kUniversalAccess);
    CFPreferencesAppSynchronize(kUniversalAccess);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), notification, NULL, NULL, true);
}

extern CFStringRef kAXInterfaceReduceMotionKey, kAXInterfaceReduceMotionStatusDidChangeNotification;
extern CFStringRef kAXInterfaceIncreaseContrastKey, kAXInterfaceIncreaseContrastStatusDidChangeNotification;
extern CFStringRef kAXInterfaceReduceTransparencyKey, kAXInterfaceReduceTransparencyStatusDidChangeNotification;
extern CFStringRef kAXInterfaceDifferentiateWithoutColorKey,
    kAXInterfaceDifferentiateWithoutColorStatusDidChangeNotification;
extern CFStringRef kAXInterfaceClassicInvertColorKey, kAXInterfaceClassicInvertColorStatusDidChangeNotification;
extern CFStringRef kAXInterfaceShowToolbarButtonShapesKey,
    kAXInterfaceShowToolbarButtonShapesStatusDidChangeNotification;
extern CFStringRef kAXInterfaceShowWindowTitlebarIconsKey,
    kAXInterfaceShowWindowTitlebarIconsStatusDidChangeNotification;
extern CFStringRef kAXInterfaceReduceTextInsertionPointModulationKey,
    kAXInterfaceReduceTextInsertionPointModulationDidChangeNotification;
extern CFStringRef kAXInterfaceBristolKey;

#define INTERFACE_SETTING(Name, Key, Notification)                                                                \
    Boolean AXInterfaceGet##Name##Enabled(void);                                                                  \
    void AXInterfaceSet##Name##Enabled(Boolean on);                                                               \
    Boolean AXInterfaceGet##Name##Enabled(void) { return setting(Key); }                                          \
    void AXInterfaceSet##Name##Enabled(Boolean on) { set_setting(Key, on, Notification); }

INTERFACE_SETTING(ReduceMotion, kAXInterfaceReduceMotionKey, kAXInterfaceReduceMotionStatusDidChangeNotification)
INTERFACE_SETTING(IncreaseContrast, kAXInterfaceIncreaseContrastKey,
                  kAXInterfaceIncreaseContrastStatusDidChangeNotification)
INTERFACE_SETTING(ReduceTransparency, kAXInterfaceReduceTransparencyKey,
                  kAXInterfaceReduceTransparencyStatusDidChangeNotification)
INTERFACE_SETTING(DifferentiateWithoutColor, kAXInterfaceDifferentiateWithoutColorKey,
                  kAXInterfaceDifferentiateWithoutColorStatusDidChangeNotification)
INTERFACE_SETTING(ClassicInvertColor, kAXInterfaceClassicInvertColorKey,
                  kAXInterfaceClassicInvertColorStatusDidChangeNotification)
INTERFACE_SETTING(ShowToolbarButtonShapes, kAXInterfaceShowToolbarButtonShapesKey,
                  kAXInterfaceShowToolbarButtonShapesStatusDidChangeNotification)
INTERFACE_SETTING(ShowWindowTitlebarIcons, kAXInterfaceShowWindowTitlebarIconsKey,
                  kAXInterfaceShowWindowTitlebarIconsStatusDidChangeNotification)
INTERFACE_SETTING(ReduceTextInsertionPointModulation, kAXInterfaceReduceTextInsertionPointModulationKey,
                  kAXInterfaceReduceTextInsertionPointModulationDidChangeNotification)

Boolean AXInterfaceGetBristolEnabled(void);
Boolean
AXInterfaceGetBristolEnabled(void)
{
    return setting(kAXInterfaceBristolKey);
}
