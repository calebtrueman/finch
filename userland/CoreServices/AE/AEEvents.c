/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Event handlers and sending (AppleEvents.h, AEMach.h).
 *
 * An event addressed to this process (kCurrentProcess, its pid or its
 * bundle identifier) is dispatched at once, as macOS does: the pre-dispatch
 * handler if one is installed, then the most specific event handler
 * (class/ID, class/any, any/ID, any/any; application table before
 * system). AESendMessage returns the handler's result, or
 * errAEEventNotHandled; the reply is an 'aevt'/'ansr' event with the
 * request's return ID. Finch has no Apple event transport between
 * processes yet: an event for another process fails with procNotFound when
 * no such process runs, and connectionInvalid when it does.
 */
#include "AE_Finch.h"
#include <errno.h>
#include <libproc.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>

struct handler {
    AEEventClass cls;
    AEEventID eid;
    AEEventHandlerUPP proc;
    SRefCon refcon;
};

static struct {
    struct handler *v;
    long count;
} tables[2];

struct special {
    AEKeyword cls;
    AEEventHandlerUPP proc;
};

static struct {
    struct special *v;
    long count;
} specials[2];

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

SInt32
ae_next_return_id(void)
{
    /* AEReturnID is 16 bits: count through the positive ones, starting somewhere per process */
    static _Atomic SInt32 next;
    SInt32 unset = 0;
    atomic_compare_exchange_strong(&next, &unset, getpid() % 30000 + 1);
    return (SInt32)(atomic_fetch_add(&next, 1) % 32767) + 1;
}

AEEventHandlerUPP (NewAEEventHandlerUPP)(AEEventHandlerProcPtr userRoutine) { return userRoutine; }
void (DisposeAEEventHandlerUPP)(AEEventHandlerUPP userUPP) {}
OSErr (InvokeAEEventHandlerUPP)(const AppleEvent *theAppleEvent, AppleEvent *reply, SRefCon handlerRefcon,
                              AEEventHandlerUPP userUPP)
{
    return userUPP(theAppleEvent, reply, handlerRefcon);
}
AEDisposeExternalUPP (NewAEDisposeExternalUPP)(AEDisposeExternalProcPtr userRoutine) { return userRoutine; }
void (DisposeAEDisposeExternalUPP)(AEDisposeExternalUPP userUPP) {}
void (InvokeAEDisposeExternalUPP)(const void *dataPtr, Size dataLength, SRefCon refcon, AEDisposeExternalUPP userUPP)
{
    userUPP(dataPtr, dataLength, refcon);
}

static struct handler *
find_exact(int sys, AEEventClass cls, AEEventID eid)
{
    for (long i = 0; i < tables[sys].count; i++)
        if (tables[sys].v[i].cls == cls && tables[sys].v[i].eid == eid)
            return &tables[sys].v[i];
    return NULL;
}

OSErr
AEInstallEventHandler(AEEventClass theAEEventClass, AEEventID theAEEventID, AEEventHandlerUPP handler,
                      SRefCon handlerRefcon, Boolean isSysHandler)
{
    if (!handler)
        return paramErr;
    int sys = isSysHandler ? 1 : 0;
    pthread_mutex_lock(&lock);
    struct handler *h = find_exact(sys, theAEEventClass, theAEEventID);
    if (!h) {
        struct handler *v = realloc(tables[sys].v, (tables[sys].count + 1) * sizeof *v);
        if (!v) {
            pthread_mutex_unlock(&lock);
            return memFullErr;
        }
        tables[sys].v = v;
        h = &v[tables[sys].count++];
    }
    *h = (struct handler){theAEEventClass, theAEEventID, handler, handlerRefcon};
    pthread_mutex_unlock(&lock);
    return noErr;
}

OSErr
AERemoveEventHandler(AEEventClass theAEEventClass, AEEventID theAEEventID, AEEventHandlerUPP handler,
                     Boolean isSysHandler)
{
    int sys = isSysHandler ? 1 : 0;
    pthread_mutex_lock(&lock);
    struct handler *h = find_exact(sys, theAEEventClass, theAEEventID);
    OSErr e = errAEHandlerNotFound;
    if (h && (!handler || h->proc == handler)) {
        long i = h - tables[sys].v;
        memmove(h, h + 1, (tables[sys].count - i - 1) * sizeof *h);
        tables[sys].count--;
        e = noErr;
    }
    pthread_mutex_unlock(&lock);
    return e;
}

OSErr
AEGetEventHandler(AEEventClass theAEEventClass, AEEventID theAEEventID, AEEventHandlerUPP *handler,
                  SRefCon *handlerRefcon, Boolean isSysHandler)
{
    pthread_mutex_lock(&lock);
    struct handler *h = find_exact(isSysHandler ? 1 : 0, theAEEventClass, theAEEventID);
    if (h) {
        if (handler)
            *handler = h->proc;
        if (handlerRefcon)
            *handlerRefcon = h->refcon;
    }
    pthread_mutex_unlock(&lock);
    return h ? noErr : errAEHandlerNotFound;
}

static bool
lookup(AEEventClass cls, AEEventID eid, struct handler *out)
{
    AEEventClass c[] = {cls, cls, typeWildCard, typeWildCard};
    AEEventID e[] = {eid, typeWildCard, eid, typeWildCard};
    bool found = false;
    pthread_mutex_lock(&lock);
    for (int sys = 0; sys < 2 && !found; sys++)
        for (int i = 0; i < 4 && !found; i++) {
            struct handler *h = find_exact(sys, c[i], e[i]);
            if (h) {
                *out = *h;
                found = true;
            }
        }
    pthread_mutex_unlock(&lock);
    return found;
}

static struct special *
find_special(int sys, AEKeyword cls)
{
    for (long i = 0; i < specials[sys].count; i++)
        if (specials[sys].v[i].cls == cls)
            return &specials[sys].v[i];
    return NULL;
}

OSErr
AEInstallSpecialHandler(AEKeyword functionClass, AEEventHandlerUPP handler, Boolean isSysHandler)
{
    int sys = isSysHandler ? 1 : 0;
    pthread_mutex_lock(&lock);
    struct special *s = find_special(sys, functionClass);
    if (!s) {
        struct special *v = realloc(specials[sys].v, (specials[sys].count + 1) * sizeof *v);
        if (!v) {
            pthread_mutex_unlock(&lock);
            return memFullErr;
        }
        specials[sys].v = v;
        s = &v[specials[sys].count++];
    }
    *s = (struct special){functionClass, handler};
    pthread_mutex_unlock(&lock);
    return noErr;
}

OSErr
AERemoveSpecialHandler(AEKeyword functionClass, AEEventHandlerUPP handler, Boolean isSysHandler)
{
    int sys = isSysHandler ? 1 : 0;
    pthread_mutex_lock(&lock);
    struct special *s = find_special(sys, functionClass);
    OSErr e = errAEHandlerNotFound;
    if (s && (!handler || s->proc == handler)) {
        long i = s - specials[sys].v;
        memmove(s, s + 1, (specials[sys].count - i - 1) * sizeof *s);
        specials[sys].count--;
        e = noErr;
    }
    pthread_mutex_unlock(&lock);
    return e;
}

OSErr
AEGetSpecialHandler(AEKeyword functionClass, AEEventHandlerUPP *handler, Boolean isSysHandler)
{
    pthread_mutex_lock(&lock);
    struct special *s = find_special(isSysHandler ? 1 : 0, functionClass);
    if (s && handler)
        *handler = s->proc;
    pthread_mutex_unlock(&lock);
    return s ? noErr : errAEHandlerNotFound;
}

OSErr
AEManagerInfo(AEKeyword keyWord, long *result)
{
    if (!result)
        return paramErr;
    switch (keyWord) {
    case keyAEVersion: *result = 0x01518000; return noErr;  /* 1.5.1: the Apple Event Manager's "version" */
    case keyAERecorderCount: *result = 0; return noErr;
    }
    *result = 0;
    return errAEUnknownSendMode;
}

#pragma mark - Dispatch

static __thread const AppleEvent *current_event;
static __thread AppleEvent *current_reply;

/* Dispatches an event to this process's handlers (AEProcessAppleEvent's core). */
static OSErr
dispatch(const AppleEvent *event, AppleEvent *reply)
{
    OSType cls = 0, eid = 0;
    DescType t;
    Size n;
    AEGetAttributePtr(event, keyEventClassAttr, typeType, &t, &cls, 4, &n);
    AEGetAttributePtr(event, keyEventIDAttr, typeType, &t, &eid, 4, &n);
    const AppleEvent *saved = current_event;
    AppleEvent *saved_reply = current_reply;
    current_event = event;
    current_reply = reply;
    OSErr e = errAEEventNotHandled;
    AEEventHandlerUPP pre = NULL;
    if (AEGetSpecialHandler(keyPreDispatch, &pre, false) && AEGetSpecialHandler(keyPreDispatch, &pre, true))
        pre = NULL;
    if (pre)
        e = pre(event, reply, 0);
    if (e == errAEEventNotHandled) {
        struct handler h;
        if (lookup(cls, eid, &h))
            e = h.proc(event, reply, h.refcon);
    }
    current_event = saved;
    current_reply = saved_reply;
    return e;
}

FINCH_EXPORT pid_t _FinchLSPIDForBundleIdentifier(CFStringRef bundleID);

/* 1: this process; 0: another one, which exists; -1: none. */
static int
target_of(const AppleEvent *event)
{
    AEDesc addr;
    if (AEGetAttributeDesc(event, keyAddressAttr, typeWildCard, &addr))
        return -1;
    Size n;
    const unsigned char *p = ae_bytes(&addr, &n);
    int r = -1;
    switch (addr.descriptorType) {
    case typeProcessSerialNumber:
        if (n >= 8) {
            const ProcessSerialNumber *psn = (const ProcessSerialNumber *)p;
            if (psn->highLongOfPSN == 0 && psn->lowLongOfPSN == kCurrentProcess)
                r = 1;
        }
        break;
    case typeKernelProcessID:
        if (n >= 4) {
            pid_t pid = *(const pid_t *)p;
            r = pid == getpid() ? 1 : (kill(pid, 0) == 0 || errno == EPERM) ? 0 : -1;
        }
        break;
    case typeApplicationBundleID: {
        CFStringRef bid = CFStringCreateWithBytes(NULL, p, n, kCFStringEncodingUTF8, false);
        CFStringRef mine = CFBundleGetIdentifier(CFBundleGetMainBundle());
        if (bid && mine && CFStringCompare(bid, mine, kCFCompareCaseInsensitive) == kCFCompareEqualTo)
            r = 1;
        else if (bid && _FinchLSPIDForBundleIdentifier(bid) > 0)
            r = 0;
        if (bid)
            CFRelease(bid);
        break;
    }
    }
    AEDisposeDesc(&addr);
    return r;
}

OSStatus
AESendMessage(const AppleEvent *event, AppleEvent *reply, AESendMode sendMode, long timeOutInTicks)
{
    if (!event)
        return paramErr;
    if (reply)
        AEInitializeDesc(reply);
    int target = target_of(event);
    if (target < 0)
        return procNotFound;
    if (target == 0)
        return connectionInvalid;
    SInt32 rid = 0, tid = 0;
    DescType t;
    Size n;
    AEGetAttributePtr(event, keyReturnIDAttr, typeSInt32, &t, &rid, 4, &n);
    AEGetAttributePtr(event, keyTransactionIDAttr, typeSInt32, &t, &tid, 4, &n);
    AppleEvent r;
    ProcessSerialNumber self = {0, kCurrentProcess};
    AEAddressDesc back;
    ae_make_data(typeProcessSerialNumber, &self, sizeof self, &back);
    OSErr e = AECreateAppleEvent(kCoreEventClass, kAEAnswer, &back, rid, tid, &r);
    AEDisposeDesc(&back);
    if (e)
        return e;
    e = dispatch(event, &r);
    if (reply)
        *reply = r;
    else
        AEDisposeDesc(&r);
    return e;
}

/* For NSAppleEventManager: the event being handled on this thread. */
FINCH_EXPORT const AppleEvent *
_FinchAECurrentEvent(AppleEvent **reply)
{
    if (reply)
        *reply = current_reply;
    return current_event;
}

OSStatus
AEDeterminePermissionToAutomateTarget(const AEAddressDesc *target, AEEventClass theAEEventClass, AEEventID theAEEventID,
                                      Boolean askUserIfNeeded)
{
    return noErr;  /* no automation consent on Finch yet */
}
