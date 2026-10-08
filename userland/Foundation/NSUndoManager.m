/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSUndoManager and NSNotificationQueue (docs/design/FOUNDATION.md), against
 * the SDK's headers.
 *
 * Undo: groups of actions on two stacks. An action is an invocation (from
 * -prepareWithInvocationTarget:'s proxy), a selector with one object, or a
 * block; targets are not retained, arguments are, as Apple's are. With
 * groupsByEvent (the default) the first registration opens a group that the
 * run loop closes at the end of its pass. Undoing opens a group whose
 * registrations go to the redo stack, under the same action name.
 *
 * Notification queues post ASAP notifications when the run loop next
 * finishes a pass and idle ones when it is about to wait, coalescing by
 * name and sender as asked.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include "Foundation_Finch.h"

NSNotificationName const NSUndoManagerCheckpointNotification = @"NSUndoManagerCheckpointNotification";
NSNotificationName const NSUndoManagerWillUndoChangeNotification = @"NSUndoManagerWillUndoChangeNotification";
NSNotificationName const NSUndoManagerWillRedoChangeNotification = @"NSUndoManagerWillRedoChangeNotification";
NSNotificationName const NSUndoManagerDidUndoChangeNotification = @"NSUndoManagerDidUndoChangeNotification";
NSNotificationName const NSUndoManagerDidRedoChangeNotification = @"NSUndoManagerDidRedoChangeNotification";
NSNotificationName const NSUndoManagerDidOpenUndoGroupNotification = @"NSUndoManagerDidOpenUndoGroupNotification";
NSNotificationName const NSUndoManagerWillCloseUndoGroupNotification = @"NSUndoManagerWillCloseUndoGroupNotification";
NSNotificationName const NSUndoManagerDidCloseUndoGroupNotification = @"NSUndoManagerDidCloseUndoGroupNotification";
NSString *const NSUndoManagerGroupIsDiscardableKey = @"NSUndoManagerGroupIsDiscardableKey";

/* MARK: - Actions and groups */

@interface _NSUndoAction : NSObject {
@public
    id _target;                 /* not retained */
    NSInvocation *_invocation;
    SEL _selector;
    id _object;
    void (^_block)(id);
}
- (void)perform;
- (BOOL)hasTarget:(id)target;
@end

@implementation _NSUndoAction
- (void)dealloc
{
    [_invocation release];
    [_object release];
    [_block release];
    [super dealloc];
}
- (void)perform
{
    if (_invocation) [_invocation invokeWithTarget:_target];
    else if (_block) _block(_target);
    else ((void (*)(id, SEL, id))(void *)objc_msgSend)(_target, _selector, _object);
}
- (BOOL)hasTarget:(id)target { return _target == target; }
@end

@interface _NSUndoGroup : NSObject {
@public
    NSMutableArray *_actions;   /* _NSUndoAction or nested _NSUndoGroup */
    NSString *_name;
    NSMutableDictionary *_userInfo;
    BOOL _discardable;
    _NSUndoGroup *_parent;      /* not retained */
}
- (void)perform;
- (BOOL)hasTarget:(id)target;
@end

@implementation _NSUndoGroup
- (instancetype)init
{
    if ((self = [super init])) _actions = [NSMutableArray new];
    return self;
}
- (void)dealloc
{
    [_actions release];
    [_name release];
    [_userInfo release];
    [super dealloc];
}
/* Last registered, first undone. */
- (void)perform
{
    for (id a in [_actions reverseObjectEnumerator]) [a perform];
}
- (BOOL)hasTarget:(id)target { return NO; }
- (void)removeActionsWithTarget:(id)target
{
    for (NSInteger i = (NSInteger)[_actions count] - 1; i >= 0; i--) {
        id a = [_actions objectAtIndex:(NSUInteger)i];
        if ([a isKindOfClass:[_NSUndoGroup class]]) {
            [a removeActionsWithTarget:target];
            if (![((_NSUndoGroup *)a)->_actions count]) [_actions removeObjectAtIndex:(NSUInteger)i];
        } else if ([a hasTarget:target]) {
            [_actions removeObjectAtIndex:(NSUInteger)i];
        }
    }
}
@end

/* What -prepareWithInvocationTarget: returns: records the next message. */
@interface _NSUndoManagerProxy : NSProxy {
@public
    NSUndoManager *_manager;
    id _target;
}
@end

@interface NSUndoManager (FinchPrivate)
- (void)_finchRegisterAction:(_NSUndoAction *)action;
@end

@implementation _NSUndoManagerProxy
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [_target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation
{
    [invocation retainArguments];
    _NSUndoAction *a = [[_NSUndoAction new] autorelease];
    a->_target = _target;
    a->_invocation = [invocation retain];
    [_manager _finchRegisterAction:a];
}
- (BOOL)respondsToSelector:(SEL)sel { return [_target respondsToSelector:sel]; }
@end

/* MARK: - NSUndoManager */

@implementation NSUndoManager {
    NSMutableArray *_undoStack, *_redoStack;
    _NSUndoGroup *_open;          /* innermost open group */
    NSInteger _level;
    NSInteger _disabled;
    BOOL _undoing, _redoing, _groupsByEvent, _autoGroup;
    NSUInteger _levels;
    NSArray *_modes;
    CFRunLoopObserverRef _observer;
    _NSUndoManagerProxy *_proxy;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _undoStack = [NSMutableArray new];
        _redoStack = [NSMutableArray new];
        _groupsByEvent = YES;
        _modes = [@[ NSDefaultRunLoopMode ] copy];
        _proxy = [_NSUndoManagerProxy alloc];
        _proxy->_manager = self;
    }
    return self;
}

- (void)dealloc
{
    if (_observer) {
        CFRunLoopObserverInvalidate(_observer);
        CFRelease(_observer);
    }
    while (_open) {
        _NSUndoGroup *g = _open;
        _open = g->_parent;
        [g release];
    }
    [_undoStack release];
    [_redoStack release];
    [_modes release];
    [_proxy release];
    [super dealloc];
}

- (void)post:(NSNotificationName)name userInfo:(NSDictionary *)info
{
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:self userInfo:info];
}

/* MARK: Groups */

- (NSInteger)groupingLevel { return _level; }

- (void)beginUndoGrouping
{
    if (!_undoing && !_redoing && _level == 0) [self post:NSUndoManagerCheckpointNotification userInfo:nil];
    _NSUndoGroup *g = [[_NSUndoGroup alloc] init];
    g->_parent = _open;
    _open = g;
    _level++;
    [self post:NSUndoManagerDidOpenUndoGroupNotification userInfo:nil];
}

- (void)endUndoGrouping
{
    if (_level <= 0)
        FinchRaise(NSInternalInconsistencyException, "-[NSUndoManager endUndoGrouping]: endUndoGrouping called with no matching begin");
    [self post:NSUndoManagerCheckpointNotification userInfo:nil];
    [self post:NSUndoManagerWillCloseUndoGroupNotification userInfo:nil];
    _NSUndoGroup *g = _open;
    _open = g->_parent;
    _level--;
    if (_level == 0) _autoGroup = NO;
    BOOL discardable = g->_discardable;
    if ([g->_actions count]) {
        if (_open) {
            [_open->_actions addObject:g];
            if (!_open->_name && g->_name) _open->_name = [g->_name copy];
        } else {
            NSMutableArray *stack = _undoing ? _redoStack : _undoStack;
            [stack addObject:g];
            if (_levels && [stack count] > _levels) [stack removeObjectAtIndex:0];
        }
    }
    [g release];
    [self post:NSUndoManagerDidCloseUndoGroupNotification userInfo:@{ NSUndoManagerGroupIsDiscardableKey: @(discardable) }];
}

- (BOOL)groupsByEvent { return _groupsByEvent; }
- (void)setGroupsByEvent:(BOOL)flag { _groupsByEvent = flag; }
- (NSUInteger)levelsOfUndo { return _levels; }
- (void)setLevelsOfUndo:(NSUInteger)levels
{
    _levels = levels;
    while (levels && [_undoStack count] > levels) [_undoStack removeObjectAtIndex:0];
    while (levels && [_redoStack count] > levels) [_redoStack removeObjectAtIndex:0];
}
- (NSArray *)runLoopModes { return _modes; }
- (void)setRunLoopModes:(NSArray *)modes { [_modes release]; _modes = [modes copy]; }

static void
close_event_group(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    NSUndoManager *self = info;
    if (self->_autoGroup && self->_level == 1) [self endUndoGrouping];
}

/* With groupsByEvent, the first registration opens a group the run loop
 * closes when this pass ends. */
- (void)openEventGroupIfNeeded
{
    if (!_groupsByEvent || _level > 0) return;
    [self beginUndoGrouping];
    _autoGroup = YES;
    if (!_observer) {
        CFRunLoopObserverContext ctx = { 0, self, NULL, NULL, NULL };
        _observer = CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 0, close_event_group, &ctx);
        for (NSString *mode in _modes) CFRunLoopAddObserver(CFRunLoopGetCurrent(), _observer, (CFStringRef)mode);
    }
}

/* MARK: Registration */

- (void)disableUndoRegistration { _disabled++; }
- (void)enableUndoRegistration
{
    if (_disabled <= 0)
        FinchRaise(NSInternalInconsistencyException, "-[NSUndoManager enableUndoRegistration]: undo registration is already enabled");
    _disabled--;
}
- (BOOL)isUndoRegistrationEnabled { return _disabled == 0; }

- (void)_finchRegisterAction:(_NSUndoAction *)action
{
    if (_disabled) return;
    if (!_undoing && !_redoing) [_redoStack removeAllObjects];
    if (_level == 0) {
        if (!_groupsByEvent)
            FinchRaise(NSInternalInconsistencyException, "-[NSUndoManager registerUndoWithTarget:selector:object:]: must begin a group before registering undo");
        [self openEventGroupIfNeeded];
    }
    [_open->_actions addObject:action];
}

- (void)registerUndoWithTarget:(id)target selector:(SEL)selector object:(id)object
{
    _NSUndoAction *a = [[_NSUndoAction new] autorelease];
    a->_target = target;
    a->_selector = selector;
    a->_object = [object retain];
    [self _finchRegisterAction:a];
}

- (void)registerUndoWithTarget:(id)target handler:(void (^)(id))undoHandler
{
    _NSUndoAction *a = [[_NSUndoAction new] autorelease];
    a->_target = target;
    a->_block = [undoHandler copy];
    [self _finchRegisterAction:a];
}

- (id)prepareWithInvocationTarget:(id)target
{
    _proxy->_target = target;
    return _proxy;
}

/* MARK: Undo and redo */

- (BOOL)isUndoing { return _undoing; }
- (BOOL)isRedoing { return _redoing; }

- (BOOL)canUndo
{
    if ([_undoStack count]) return YES;
    return _autoGroup && _level == 1 && [_open->_actions count] > 0;
}

- (BOOL)canRedo
{
    [self post:NSUndoManagerCheckpointNotification userInfo:nil];
    return [_redoStack count] > 0;
}

- (NSUInteger)undoCount { return [_undoStack count] + (_autoGroup && _level == 1 && [_open->_actions count] ? 1 : 0); }
- (NSUInteger)redoCount { return [_redoStack count]; }

- (void)closeEventGroup
{
    if (_autoGroup && _level == 1) [self endUndoGrouping];
}

- (void)undoNestedGroup
{
    if (_level > 0)
        FinchRaise(NSInternalInconsistencyException, "-[NSUndoManager undoNestedGroup]: undo was called with too many nested undo groups");
    _NSUndoGroup *g = [[[_undoStack lastObject] retain] autorelease];
    if (!g) return;
    [self post:NSUndoManagerWillUndoChangeNotification userInfo:nil];
    [_undoStack removeLastObject];
    _undoing = YES;
    [self beginUndoGrouping];
    [_open->_name release];
    _open->_name = [g->_name copy];
    @try {
        [g perform];
    } @finally {
        [self endUndoGrouping];
        _undoing = NO;
    }
    [self post:NSUndoManagerDidUndoChangeNotification userInfo:nil];
}

- (void)undo
{
    [self closeEventGroup];
    if (_level > 0) FinchRaise(NSInternalInconsistencyException, "-[NSUndoManager undo]: undo was called with too many nested undo groups");
    [self undoNestedGroup];
}

- (void)redo
{
    [self closeEventGroup];
    if (_level > 0) FinchRaise(NSInternalInconsistencyException, "-[NSUndoManager redo]: redo was called with too many nested undo groups");
    _NSUndoGroup *g = [[[_redoStack lastObject] retain] autorelease];
    if (!g) return;
    [self post:NSUndoManagerWillRedoChangeNotification userInfo:nil];
    [_redoStack removeLastObject];
    _redoing = YES;
    [self beginUndoGrouping];
    [_open->_name release];
    _open->_name = [g->_name copy];
    @try {
        [g perform];
    } @finally {
        [self endUndoGrouping];
        _redoing = NO;
    }
    [self post:NSUndoManagerDidRedoChangeNotification userInfo:nil];
}

- (void)removeAllActions
{
    [_undoStack removeAllObjects];
    [_redoStack removeAllObjects];
    while (_open) {
        _NSUndoGroup *g = _open;
        _open = g->_parent;
        [g release];
    }
    _level = 0;
    _autoGroup = NO;
    _disabled = 0;
}

- (void)removeAllActionsWithTarget:(id)target
{
    for (NSMutableArray *stack in @[ _undoStack, _redoStack ]) {
        for (NSInteger i = (NSInteger)[stack count] - 1; i >= 0; i--) {
            _NSUndoGroup *g = [stack objectAtIndex:(NSUInteger)i];
            [g removeActionsWithTarget:target];
            if (![g->_actions count]) [stack removeObjectAtIndex:(NSUInteger)i];
        }
    }
    for (_NSUndoGroup *g = _open; g; g = g->_parent) [g removeActionsWithTarget:target];
}

/* MARK: Names */

/* The group a name or flag applies to: the outermost open one, else the
 * last one on the stack being built. */
- (_NSUndoGroup *)namedGroup
{
    _NSUndoGroup *g = _open;
    while (g && g->_parent) g = g->_parent;
    if (g) return g;
    return [(_undoing ? _redoStack : _undoStack) lastObject];
}

- (void)setActionName:(NSString *)actionName
{
    _NSUndoGroup *g = [self namedGroup];
    if (!g || !actionName) return;
    [g->_name release];
    g->_name = [actionName copy];
}

- (void)setActionIsDiscardable:(BOOL)discardable
{
    _NSUndoGroup *g = [self namedGroup];
    if (g) g->_discardable = discardable;
}

- (_NSUndoGroup *)undoGroup
{
    if (_autoGroup && _level == 1 && [_open->_actions count]) return _open;
    return [_undoStack lastObject];
}

static NSString *
group_name(_NSUndoGroup *g)
{
    return g && g->_name ? g->_name : @"";
}

- (NSString *)undoActionName { return group_name([self undoGroup]); }
- (NSString *)redoActionName { return group_name([_redoStack lastObject]); }
- (BOOL)undoActionIsDiscardable { _NSUndoGroup *g = [self undoGroup]; return g && g->_discardable; }
- (BOOL)redoActionIsDiscardable { _NSUndoGroup *g = [_redoStack lastObject]; return g && g->_discardable; }

- (NSString *)undoMenuTitleForUndoActionName:(NSString *)actionName
{
    return [actionName length] ? [@"Undo " stringByAppendingString:actionName] : @"Undo";
}

- (NSString *)redoMenuTitleForUndoActionName:(NSString *)actionName
{
    return [actionName length] ? [@"Redo " stringByAppendingString:actionName] : @"Redo";
}

- (NSString *)undoMenuItemTitle { return [self undoMenuTitleForUndoActionName:[self undoActionName]]; }
- (NSString *)redoMenuItemTitle { return [self redoMenuTitleForUndoActionName:[self redoActionName]]; }

- (void)setActionUserInfoValue:(id)info forKey:(NSUndoManagerUserInfoKey)key
{
    _NSUndoGroup *g = [self namedGroup];
    if (!g) return;
    if (!g->_userInfo) g->_userInfo = [NSMutableDictionary new];
    if (info) [g->_userInfo setObject:info forKey:key];
    else [g->_userInfo removeObjectForKey:key];
}

- (id)undoActionUserInfoValueForKey:(NSUndoManagerUserInfoKey)key
{
    _NSUndoGroup *g = [self undoGroup];
    return g ? [g->_userInfo objectForKey:key] : nil;
}
- (id)redoActionUserInfoValueForKey:(NSUndoManagerUserInfoKey)key
{
    _NSUndoGroup *g = [_redoStack lastObject];
    return g ? [g->_userInfo objectForKey:key] : nil;
}

@end

/* MARK: - NSNotificationQueue */

@interface _NSQueuedNotification : NSObject {
@public
    NSNotification *_note;
    NSUInteger _coalesce;
    NSArray *_modes;
}
@end
@implementation _NSQueuedNotification
- (void)dealloc { [_note release]; [_modes release]; [super dealloc]; }
@end

@implementation NSNotificationQueue {
    NSNotificationCenter *_center;
    NSMutableArray *_asap, *_idle;
    CFRunLoopObserverRef _observer;
}

+ (NSNotificationQueue *)defaultQueue
{
    NSMutableDictionary *d = [[NSThread currentThread] threadDictionary];
    NSNotificationQueue *q = [d objectForKey:@"NSNotificationQueue"];
    if (!q) {
        q = [[[NSNotificationQueue alloc] initWithNotificationCenter:[NSNotificationCenter defaultCenter]] autorelease];
        [d setObject:q forKey:@"NSNotificationQueue"];
    }
    return q;
}

- (instancetype)init { return [self initWithNotificationCenter:[NSNotificationCenter defaultCenter]]; }

- (instancetype)initWithNotificationCenter:(NSNotificationCenter *)center
{
    if ((self = [super init])) {
        _center = [center retain];
        _asap = [NSMutableArray new];
        _idle = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc
{
    if (_observer) {
        CFRunLoopObserverInvalidate(_observer);
        CFRelease(_observer);
    }
    [_center release];
    [_asap release];
    [_idle release];
    [super dealloc];
}

static BOOL
matches(NSNotification *a, NSNotification *b, NSUInteger mask)
{
    if (mask == NSNotificationNoCoalescing) return NO;
    if ((mask & NSNotificationCoalescingOnName) && ![[a name] isEqualToString:[b name]]) return NO;
    if ((mask & NSNotificationCoalescingOnSender) && [a object] != [b object]) return NO;
    return YES;
}

/* Post the queued notifications whose modes include the current mode. */
- (void)post:(NSMutableArray *)queue
{
    NSString *mode = [[NSRunLoop currentRunLoop] currentMode];
    NSArray *now = [[queue copy] autorelease];
    for (_NSQueuedNotification *q in now) {
        if (mode && q->_modes && ![q->_modes containsObject:mode]) continue;
        [[q retain] autorelease];
        [queue removeObjectIdenticalTo:q];
        [_center postNotification:q->_note];
    }
}

static void
run_loop_pass(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    NSNotificationQueue *self = info;
    [self post:self->_asap];
    if (activity & kCFRunLoopBeforeWaiting) [self post:self->_idle];
}

- (void)watchRunLoop
{
    if (_observer) return;
    CFRunLoopObserverContext ctx = { 0, self, NULL, NULL, NULL };
    _observer = CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeTimers | kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 0, run_loop_pass, &ctx);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), _observer, kCFRunLoopCommonModes);
}

- (void)enqueueNotification:(NSNotification *)notification postingStyle:(NSPostingStyle)postingStyle
{
    [self enqueueNotification:notification postingStyle:postingStyle coalesceMask:NSNotificationCoalescingOnName | NSNotificationCoalescingOnSender forModes:nil];
}

- (void)enqueueNotification:(NSNotification *)notification postingStyle:(NSPostingStyle)postingStyle
               coalesceMask:(NSNotificationCoalescing)coalesceMask forModes:(NSArray<NSRunLoopMode> *)modes
{
    if (postingStyle == NSPostNow) {
        [self dequeueNotificationsMatching:notification coalesceMask:coalesceMask];
        [_center postNotification:notification];
        return;
    }
    NSMutableArray *queue = postingStyle == NSPostASAP ? _asap : _idle;
    for (_NSQueuedNotification *q in queue)
        if (matches(q->_note, notification, coalesceMask)) return;
    _NSQueuedNotification *q = [[_NSQueuedNotification new] autorelease];
    q->_note = [notification retain];
    q->_coalesce = coalesceMask;
    q->_modes = [(modes ? modes : @[ NSDefaultRunLoopMode ]) copy];
    [queue addObject:q];
    [self watchRunLoop];
}

- (void)dequeueNotificationsMatching:(NSNotification *)notification coalesceMask:(NSUInteger)coalesceMask
{
    for (NSMutableArray *queue in @[ _asap, _idle ])
        for (NSInteger i = (NSInteger)[queue count] - 1; i >= 0; i--)
            if (matches(((_NSQueuedNotification *)[queue objectAtIndex:(NSUInteger)i])->_note, notification, coalesceMask))
                [queue removeObjectAtIndex:(NSUInteger)i];
}

@end
