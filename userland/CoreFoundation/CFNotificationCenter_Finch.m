/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CFNotificationCenter, which swift-corelibs doesn't have (only the header).
 *
 * As on macOS, there are three centers:
 * - The local center shares its observers with Foundation's default
 *   NSNotificationCenter: a notification posted through either reaches the
 *   observers of both, in the order they were added. Observers are kept as
 *   NSNotificationCenter observers when Foundation is loaded (looked up at
 *   run time; CF sits below it), and in CF's own list when it isn't.
 * - The Darwin center rides on notify(3): names only, delivered on the main
 *   queue; the object and user info are dropped, as macOS's are.
 * - The distributed center delivers on the main queue, with the object and
 *   user info, within the process: Finch has no distnoted yet to carry
 *   notifications between processes.
 */
#include "CFInternal.h"
#include "CFRuntime_Internal.h"

#include <CoreFoundation/CFNotificationCenter.h>
#import <objc/NSObject.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <pthread.h>

enum { LOCAL, DARWIN, DISTRIBUTED };

typedef struct {
    const void *observer;
    CFNotificationCallback callback;
    CFStringRef name;     /* NULL: any */
    const void *object;   /* NULL: any */
    id proxy;             /* the NSNotificationCenter observer (local center, with Foundation) */
    int token;            /* notify(3) registration (Darwin center) */
} Observer;

struct __CFNotificationCenter {
    CFRuntimeBase base;
    int kind;
    os_unfair_lock lock;
    Observer *observers;
    CFIndex count, capacity;
};

static CFStringRef
copy_description(CFTypeRef cf)
{
    return CFStringCreateWithFormat(kCFAllocatorSystemDefault, NULL, CFSTR("<CFNotificationCenter %p [%p]>"), cf,
                                    CFGetAllocator(cf));
}

static const CFRuntimeClass __CFNotificationCenterClass = {
    .version = 0,
    .className = "CFNotificationCenter",
    .copyDebugDesc = copy_description,
};

static CFTypeID type_id;
static struct __CFNotificationCenter *centers[3];

static void
make_centers(void)
{
    type_id = _CFRuntimeRegisterClass(&__CFNotificationCenterClass);
    for (int i = 0; i < 3; i++) {
        centers[i] = (struct __CFNotificationCenter *)_CFRuntimeCreateInstance(
            kCFAllocatorSystemDefault, type_id, sizeof(struct __CFNotificationCenter) - sizeof(CFRuntimeBase), NULL);
        centers[i]->kind = i;
        centers[i]->lock = OS_UNFAIR_LOCK_INIT;
    }
}

static struct __CFNotificationCenter *
center(int kind)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, make_centers);
    return centers[kind];
}

CFTypeID
CFNotificationCenterGetTypeID(void)
{
    center(LOCAL);
    return type_id;
}

CFNotificationCenterRef CFNotificationCenterGetLocalCenter(void) { return center(LOCAL); }
CFNotificationCenterRef CFNotificationCenterGetDarwinNotifyCenter(void) { return center(DARWIN); }
CFNotificationCenterRef CFNotificationCenterGetDistributedCenter(void) { return center(DISTRIBUTED); }

#pragma mark Foundation's default center

static id
ns_default_center(void)
{
    Class c = objc_getClass("NSNotificationCenter");
    return c ? ((id(*)(id, SEL))objc_msgSend)((id)c, sel_registerName("defaultCenter")) : nil;
}

/* An NSNotificationCenter observer that calls a CF callback. */
@interface __CFNotificationObserver : NSObject {
@public
    CFNotificationCallback callback;
    const void *observer;
}
@end

@implementation __CFNotificationObserver
- (void)_cfNotify:(id)note
{
    CFStringRef name = (CFStringRef)((id(*)(id, SEL))objc_msgSend)(note, sel_registerName("name"));
    id object = ((id(*)(id, SEL))objc_msgSend)(note, sel_registerName("object"));
    CFDictionaryRef info = (CFDictionaryRef)((id(*)(id, SEL))objc_msgSend)(note, sel_registerName("userInfo"));
    callback((CFNotificationCenterRef)center(LOCAL), (void *)observer, name, object, info);
}
@end

#pragma mark Observers

static void
append(struct __CFNotificationCenter *c, Observer o)
{
    if (c->count == c->capacity) {
        c->capacity = c->capacity ? c->capacity * 2 : 8;
        c->observers = realloc(c->observers, (size_t)c->capacity * sizeof(Observer));
    }
    c->observers[c->count++] = o;
}

static void
deliver_darwin(CFStringRef name)
{
    struct __CFNotificationCenter *c = center(DARWIN);
    os_unfair_lock_lock(&c->lock);
    CFIndex n = 0;
    Observer *hits = malloc(sizeof(Observer) * (size_t)(c->count ? c->count : 1));
    for (CFIndex i = 0; i < c->count; i++)
        if (c->observers[i].name && CFEqual(c->observers[i].name, name))
            hits[n++] = c->observers[i];
    os_unfair_lock_unlock(&c->lock);
    /* macOS hands Darwin observers this placeholder in place of an object */
    for (CFIndex i = 0; i < n; i++)
        hits[i].callback(c, (void *)hits[i].observer, name, CFSTR("kCFNotificationAnyObject"), NULL);
    free(hits);
}

void
CFNotificationCenterAddObserver(CFNotificationCenterRef cref, const void *observer, CFNotificationCallback callBack,
                                CFStringRef name, const void *object,
                                CFNotificationSuspensionBehavior suspensionBehavior)
{
    struct __CFNotificationCenter *c = (struct __CFNotificationCenter *)cref;
    if (!c || !callBack)
        return;
    Observer o = {observer, callBack, name ? CFStringCreateCopy(kCFAllocatorSystemDefault, name) : NULL, object, nil, 0};
    if (c->kind == DARWIN) {
        if (!name)
            return;  /* macOS requires a name here */
        char buf[512];
        if (!CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8))
            return;
        CFStringRef held = o.name;
        CFRetain(held);
        notify_register_dispatch(buf, &o.token, dispatch_get_main_queue(), ^(int token) {
            deliver_darwin(held);
        });
    } else if (c->kind == LOCAL) {
        id ns = ns_default_center();
        if (ns) {
            __CFNotificationObserver *p = [[__CFNotificationObserver alloc] init];
            p->callback = callBack;
            p->observer = observer;
            o.proxy = p;
            ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(ns, sel_registerName("addObserver:selector:name:object:"),
                                                              p, @selector(_cfNotify:), (id)name, (id)object);
        }
    }
    os_unfair_lock_lock(&c->lock);
    append(c, o);
    os_unfair_lock_unlock(&c->lock);
}

static void
remove_matching(struct __CFNotificationCenter *c, const void *observer, CFStringRef name, const void *object, bool every)
{
    os_unfair_lock_lock(&c->lock);
    CFIndex n = 0;
    Observer *gone = malloc(sizeof(Observer) * (size_t)(c->count ? c->count : 1));
    CFIndex k = 0;
    for (CFIndex i = 0; i < c->count; i++) {
        Observer *o = &c->observers[i];
        bool match = o->observer == observer &&
                     (every || ((!name || (o->name && CFEqual(o->name, name))) && (!object || o->object == object)));
        if (match)
            gone[n++] = *o;
        else
            c->observers[k++] = *o;
    }
    c->count = k;
    os_unfair_lock_unlock(&c->lock);
    id ns = n && c->kind == LOCAL ? ns_default_center() : nil;
    for (CFIndex i = 0; i < n; i++) {
        if (gone[i].proxy) {
            ((void (*)(id, SEL, id))objc_msgSend)(ns, sel_registerName("removeObserver:"), gone[i].proxy);
            [gone[i].proxy release];
        }
        if (c->kind == DARWIN)
            notify_cancel(gone[i].token);
        if (gone[i].name)
            CFRelease(gone[i].name);
    }
    free(gone);
}

void
CFNotificationCenterRemoveObserver(CFNotificationCenterRef c, const void *observer, CFNotificationName name,
                                   const void *object)
{
    if (c)
        remove_matching((struct __CFNotificationCenter *)c, observer, name, object, false);
}

void
CFNotificationCenterRemoveEveryObserver(CFNotificationCenterRef c, const void *observer)
{
    if (c)
        remove_matching((struct __CFNotificationCenter *)c, observer, NULL, NULL, true);
}

#pragma mark Posting

/* The observers of a CF-only list that match, copied out so callbacks can add or remove. */
static Observer *
matches(struct __CFNotificationCenter *c, CFStringRef name, const void *object, CFIndex *count)
{
    os_unfair_lock_lock(&c->lock);
    Observer *hits = malloc(sizeof(Observer) * (size_t)(c->count ? c->count : 1));
    CFIndex n = 0;
    for (CFIndex i = 0; i < c->count; i++) {
        Observer *o = &c->observers[i];
        if ((!o->name || CFEqual(o->name, name)) && (!o->object || o->object == object))
            hits[n++] = *o;
    }
    os_unfair_lock_unlock(&c->lock);
    *count = n;
    return hits;
}

void
CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterRef cref, CFNotificationName name,
                                                const void *object, CFDictionaryRef userInfo, CFOptionFlags options)
{
    struct __CFNotificationCenter *c = (struct __CFNotificationCenter *)cref;
    if (!c || !name)
        return;
    if (c->kind == DARWIN) {
        char buf[512];
        if (CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8))
            notify_post(buf);
        return;
    }
    if (c->kind == LOCAL) {
        id ns = ns_default_center();
        if (ns) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(ns, sel_registerName("postNotificationName:object:userInfo:"),
                                                          (id)name, (id)object, (id)userInfo);
            return;
        }
        CFIndex n;
        Observer *hits = matches(c, name, object, &n);
        for (CFIndex i = 0; i < n; i++)
            hits[i].callback(c, (void *)hits[i].observer, name, object, userInfo);
        free(hits);
        return;
    }
    /* distributed: later on the main queue, as it would come back from distnoted */
    CFStringRef n = CFStringCreateCopy(kCFAllocatorSystemDefault, name);
    CFTypeRef obj = object ? CFRetain(object) : NULL;
    CFDictionaryRef info = userInfo ? CFDictionaryCreateCopy(kCFAllocatorSystemDefault, userInfo) : NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        CFIndex count;
        Observer *hits = matches(c, n, obj, &count);
        for (CFIndex i = 0; i < count; i++)
            hits[i].callback(c, (void *)hits[i].observer, n, obj, info);
        free(hits);
        CFRelease(n);
        if (obj)
            CFRelease(obj);
        if (info)
            CFRelease(info);
    });
}

void
CFNotificationCenterPostNotification(CFNotificationCenterRef c, CFNotificationName name, const void *object,
                                     CFDictionaryRef userInfo, Boolean deliverImmediately)
{
    CFNotificationCenterPostNotificationWithOptions(c, name, object, userInfo,
                                                    deliverImmediately ? kCFNotificationDeliverImmediately : 0);
}
