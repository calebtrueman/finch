/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAppleEventManager: where apps register handlers for Apple events
 * (open documents, quit, get URL, ...). A handler is installed with
 * CoreServices' AE (AEInstallEventHandler), as Apple's is, so an event AE
 * dispatches in this process (one sent to the process itself, the only
 * kind Finch delivers until it has an Apple event server; see
 * docs/design/CORESERVICES.md) reaches it, with currentAppleEvent and
 * currentReplyAppleEvent set while it runs. AppKit opens documents and
 * quits through its own paths meanwhile.
 */
#import <Foundation/Foundation.h>
#include <objc/message.h>

NSNotificationName const NSAppleEventManagerWillProcessFirstEventNotification =
    @"NSAppleEventManagerWillProcessFirstEventNotification";
const double NSAppleEventTimeOutDefault = -1.0;
const double NSAppleEventTimeOutNone = -2.0;

/* NSAppleEventDescriptor.m: CoreServices, found at run time. */
void *_NSFinchCoreServicesSymbol(const char *name);
#define CS(fn) ((__typeof__(&fn))_NSFinchCoreServicesSymbol(#fn))

@interface NSAppleEventDescriptor (FinchBorrowed)
- (void)_finchRelinquishDesc;
@end

@implementation NSAppleEventManager {
    NSMutableDictionary<NSString *, NSArray *> *_handlers;  /* "class/id" -> [handler, selector name] */
    NSAppleEventDescriptor *_current, *_currentReply;
    BOOL _sawFirst;
}

static NSAppleEventManager *shared;

+ (NSAppleEventManager *)sharedAppleEventManager
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[NSAppleEventManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _handlers = [[NSMutableDictionary alloc] init];
    return self;
}

static NSString *
key_for(AEEventClass cls, AEEventID ident)
{
    return [NSString stringWithFormat:@"%08x/%08x", (unsigned)cls, (unsigned)ident];
}

static OSErr
generic_handler(const AppleEvent *event, AppleEvent *reply, SRefCon refcon)
{
    return [[NSAppleEventManager sharedAppleEventManager] dispatchRawAppleEvent:event withRawReply:reply handlerRefCon:refcon];
}

- (void)setEventHandler:(id)handler andSelector:(SEL)handleEventSelector forEventClass:(AEEventClass)eventClass
             andEventID:(AEEventID)eventID
{
    @synchronized(self) {
        _handlers[key_for(eventClass, eventID)] = @[ handler ?: [NSNull null], NSStringFromSelector(handleEventSelector) ];
    }
    CS(AEInstallEventHandler)(eventClass, eventID, generic_handler, NULL, false);
}

- (void)removeEventHandlerForEventClass:(AEEventClass)eventClass andEventID:(AEEventID)eventID
{
    @synchronized(self) {
        [_handlers removeObjectForKey:key_for(eventClass, eventID)];
    }
    CS(AERemoveEventHandler)(eventClass, eventID, generic_handler, false);
}

- (NSArray *)_finchHandlerFor:(AEEventClass)cls id:(AEEventID)eid
{
    @synchronized(self) {
        AEEventClass c[] = {cls, cls, typeWildCard, typeWildCard};
        AEEventID e[] = {eid, typeWildCard, eid, typeWildCard};
        for (int i = 0; i < 4; i++) {
            NSArray *h = _handlers[key_for(c[i], e[i])];
            if (h)
                return [[h retain] autorelease];
        }
    }
    return nil;
}

- (OSErr)dispatchRawAppleEvent:(const AppleEvent *)theAppleEvent withRawReply:(AppleEvent *)theReply
                  handlerRefCon:(SRefCon)handlerRefCon
{
    if (!theAppleEvent)
        return paramErr;
    OSType cls = 0, eid = 0;
    DescType t;
    Size n;
    CS(AEGetAttributePtr)(theAppleEvent, keyEventClassAttr, typeType, &t, &cls, 4, &n);
    CS(AEGetAttributePtr)(theAppleEvent, keyEventIDAttr, typeType, &t, &eid, 4, &n);
    NSArray *h = [self _finchHandlerFor:cls id:eid];
    if (!h || h[0] == [NSNull null])
        return errAEEventNotHandled;
    if (!_sawFirst) {
        _sawFirst = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:NSAppleEventManagerWillProcessFirstEventNotification object:self];
    }
    /* the descriptors borrow the event and reply: AE owns them */
    NSAppleEventDescriptor *event = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:theAppleEvent];
    NSAppleEventDescriptor *reply = theReply ? [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:theReply]
                                             : [[NSAppleEventDescriptor nullDescriptor] retain];
    NSAppleEventDescriptor *savedEvent = _current, *savedReply = _currentReply;
    _current = event;
    _currentReply = reply;
    SEL sel = NSSelectorFromString(h[1]);
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(h[0], sel, event, reply);
    } @finally {
        _current = savedEvent;
        _currentReply = savedReply;
        if (theReply)
            *theReply = *reply.aeDesc;
        /* hand the descriptors back without disposing of what they borrowed */
        [event _finchRelinquishDesc];
        if (theReply)
            [reply _finchRelinquishDesc];
        [event release];
        [reply release];
    }
    return noErr;
}

- (NSAppleEventDescriptor *)currentAppleEvent { return [[_current retain] autorelease]; }
- (NSAppleEventDescriptor *)currentReplyAppleEvent { return [[_currentReply retain] autorelease]; }
- (NSAppleEventManagerSuspensionID)suspendCurrentAppleEvent { return NULL; }
- (NSAppleEventDescriptor *)appleEventForSuspensionID:(NSAppleEventManagerSuspensionID)suspensionID { return nil; }
- (NSAppleEventDescriptor *)replyAppleEventForSuspensionID:(NSAppleEventManagerSuspensionID)suspensionID { return nil; }
- (void)setCurrentAppleEventAndReplyEventWithSuspensionID:(NSAppleEventManagerSuspensionID)suspensionID {}
- (void)resumeWithSuspensionID:(NSAppleEventManagerSuspensionID)suspensionID {}

@end
