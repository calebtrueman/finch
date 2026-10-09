/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAppleEventManager: where apps register handlers for Apple events
 * (open documents, quit, get URL, ...). Finch has no Apple Event transport
 * yet, so handlers are recorded and nothing arrives; AppKit opens documents
 * and quits through its own paths. The registration API behaves as Apple's,
 * so apps that install handlers at launch run unchanged.
 */
#import <Foundation/Foundation.h>

NSNotificationName const NSAppleEventManagerWillProcessFirstEventNotification =
    @"NSAppleEventManagerWillProcessFirstEventNotification";
const double NSAppleEventTimeOutDefault = -1.0;
const double NSAppleEventTimeOutNone = -2.0;

@implementation NSAppleEventManager {
    NSMutableDictionary<NSString *, NSArray *> *_handlers;  /* "class/id" -> [handler, selector name] */
    NSAppleEventDescriptor *_current, *_currentReply;
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

- (void)setEventHandler:(id)handler andSelector:(SEL)handleEventSelector forEventClass:(AEEventClass)eventClass
             andEventID:(AEEventID)eventID
{
    @synchronized(self) {
        _handlers[key_for(eventClass, eventID)] = @[ handler ?: [NSNull null], NSStringFromSelector(handleEventSelector) ];
    }
}

- (void)removeEventHandlerForEventClass:(AEEventClass)eventClass andEventID:(AEEventID)eventID
{
    @synchronized(self) {
        [_handlers removeObjectForKey:key_for(eventClass, eventID)];
    }
}

- (OSErr)dispatchRawAppleEvent:(const AppleEvent *)theAppleEvent withRawReply:(AppleEvent *)theReply
                  handlerRefCon:(SRefCon)handlerRefCon
{
    return -1708;  /* errAEEventNotHandled */
}

- (NSAppleEventDescriptor *)currentAppleEvent { return _current; }
- (NSAppleEventDescriptor *)currentReplyAppleEvent { return _currentReply; }
- (NSAppleEventManagerSuspensionID)suspendCurrentAppleEvent { return NULL; }
- (NSAppleEventDescriptor *)appleEventForSuspensionID:(NSAppleEventManagerSuspensionID)suspensionID { return nil; }
- (NSAppleEventDescriptor *)replyAppleEventForSuspensionID:(NSAppleEventManagerSuspensionID)suspensionID { return nil; }
- (void)setCurrentAppleEventAndReplyEventWithSuspensionID:(NSAppleEventManagerSuspensionID)suspensionID {}
- (void)resumeWithSuspensionID:(NSAppleEventManagerSuspensionID)suspensionID {}

@end
