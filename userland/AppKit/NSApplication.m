/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSApplication: the app's connection to the window server, its event
 * queue and main loop, and the routing of actions.
 *
 * Events arrive on the main run loop (CoreGraphics' window-server client
 * reads them in a CFFileDescriptor source in the common modes) and are
 * queued as NSEvents. -nextEventMatchingMask:... runs the run loop in the
 * mode asked for until a matching event is queued; windows that need it
 * are redrawn before the run loop waits, as on macOS.
 */
#import "NSMenu_Finch.h"
#import "NSStoryboard_Finch.h"

id NSApp = nil;

NSNotificationName NSApplicationDidBecomeActiveNotification = @"NSApplicationDidBecomeActiveNotification";
NSNotificationName NSApplicationDidHideNotification = @"NSApplicationDidHideNotification";
NSNotificationName NSApplicationDidFinishLaunchingNotification = @"NSApplicationDidFinishLaunchingNotification";
NSNotificationName NSApplicationDidResignActiveNotification = @"NSApplicationDidResignActiveNotification";
NSNotificationName NSApplicationDidUnhideNotification = @"NSApplicationDidUnhideNotification";
NSNotificationName NSApplicationDidUpdateNotification = @"NSApplicationDidUpdateNotification";
NSNotificationName NSApplicationWillBecomeActiveNotification = @"NSApplicationWillBecomeActiveNotification";
NSNotificationName NSApplicationWillHideNotification = @"NSApplicationWillHideNotification";
NSNotificationName NSApplicationWillFinishLaunchingNotification = @"NSApplicationWillFinishLaunchingNotification";
NSNotificationName NSApplicationWillResignActiveNotification = @"NSApplicationWillResignActiveNotification";
NSNotificationName NSApplicationWillUnhideNotification = @"NSApplicationWillUnhideNotification";
NSNotificationName NSApplicationWillUpdateNotification = @"NSApplicationWillUpdateNotification";
NSNotificationName NSApplicationWillTerminateNotification = @"NSApplicationWillTerminateNotification";
NSNotificationName NSApplicationDidChangeScreenParametersNotification =
    @"NSApplicationDidChangeScreenParametersNotification";
NSNotificationName NSApplicationProtectedDataWillBecomeUnavailableNotification =
    @"NSApplicationProtectedDataWillBecomeUnavailableNotification";
NSNotificationName NSApplicationProtectedDataDidBecomeAvailableNotification =
    @"NSApplicationProtectedDataDidBecomeAvailableNotification";
NSNotificationName const NSApplicationDidChangeOcclusionStateNotification =
    @"NSApplicationDidChangeOcclusionStateNotification";
NSString *const NSApplicationLaunchIsDefaultLaunchKey = @"NSApplicationLaunchIsDefaultLaunchKey";
NSString *const NSApplicationLaunchUserNotificationKey = @"NSApplicationLaunchUserNotificationKey";
NSString *const NSApplicationLaunchRemoteNotificationKey = @"NSApplicationLaunchRemoteNotificationKey";
NSRunLoopMode NSModalPanelRunLoopMode = @"NSModalPanelRunLoopMode";
NSRunLoopMode NSEventTrackingRunLoopMode = @"NSEventTrackingRunLoopMode";
NSAboutPanelOptionKey const NSAboutPanelOptionCredits = @"Credits";
NSAboutPanelOptionKey const NSAboutPanelOptionApplicationName = @"ApplicationName";
NSAboutPanelOptionKey const NSAboutPanelOptionApplicationIcon = @"ApplicationIcon";
NSAboutPanelOptionKey const NSAboutPanelOptionVersion = @"Version";
NSAboutPanelOptionKey const NSAboutPanelOptionApplicationVersion = @"ApplicationVersion";

static NSMutableArray<NSEvent *> *queue;
static CFRunLoopSourceRef post_source;
static CFRunLoopObserverRef display_observer;
static BOOL needs_display;
static NSWindow *key_window, *main_window;  /* not retained */

@interface NSApplication (FinchModal)
- (void)_finchServerEvent:(const FWSEvent *)e;
@end

@implementation NSApplication {
    id<NSApplicationDelegate> _delegate;  /* not retained */
    NSEvent *_currentEvent;
    NSMenu *_mainMenu, *_windowsMenu, *_servicesMenu, *_helpMenu;
    NSImage *_icon;
    NSApplicationActivationPolicy _policy;
    NSApplicationPresentationOptions _presentation;
    NSMutableArray *_modalWindows;   /* the modal session stack */
    NSInteger _modalResponse;
    NSAppearance *_appearance;
    struct {
        unsigned running : 1;
        unsigned active : 1;
        unsigned hidden : 1;
        unsigned launched : 1;
        unsigned stopModal : 1;
        unsigned terminating : 1;
    } _a;
}

#pragma mark - Creating

+ (NSApplication *)sharedApplication
{
    if (!NSApp) {
        NSApp = [[self alloc] init];
    }
    return NSApp;
}

static void
server_event(const FWSEvent *e, void *info)
{
    [(NSApplication *)NSApp _finchServerEvent:e];
}

static void
post_perform(void *info)
{
    /* Nothing to do: being signalled makes the run loop return to -nextEventMatchingMask:. */
}

static void
before_waiting(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    if (needs_display)
        [(NSApplication *)NSApp updateWindows];
}

- (instancetype)init
{
    if (NSApp && NSApp != self) {
        [self release];
        return [NSApp retain];
    }
    self = [super init];
    if (!self)
        return nil;
    NSApp = self;
    if (!queue)
        queue = [[NSMutableArray alloc] init];
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopAddCommonMode(main, (CFStringRef)NSEventTrackingRunLoopMode);
    CFRunLoopAddCommonMode(main, (CFStringRef)NSModalPanelRunLoopMode);
    CFRunLoopSourceContext ctx = {0};
    ctx.perform = post_perform;
    post_source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    CFRunLoopAddSource(main, post_source, kCFRunLoopCommonModes);
    display_observer = CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeWaiting, true, 2000000, before_waiting, NULL);
    CFRunLoopAddObserver(main, display_observer, kCFRunLoopCommonModes);
    FWSSetEventHandler(server_event, NULL);
    _policy = NSApplicationActivationPolicyRegular;
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>", [self class], self];
}

#pragma mark - Delegate

- (id<NSApplicationDelegate>)delegate { return _delegate; }

- (void)setDelegate:(id<NSApplicationDelegate>)delegate
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_delegate)
        [nc removeObserver:_delegate name:nil object:self];
    _delegate = delegate;
    if (!delegate)
        return;
    static const struct {
        const char *selector;
        NSNotificationName const *name;
    } hooks[] = {
        {"applicationWillFinishLaunching:", &NSApplicationWillFinishLaunchingNotification},
        {"applicationDidFinishLaunching:", &NSApplicationDidFinishLaunchingNotification},
        {"applicationWillBecomeActive:", &NSApplicationWillBecomeActiveNotification},
        {"applicationDidBecomeActive:", &NSApplicationDidBecomeActiveNotification},
        {"applicationWillResignActive:", &NSApplicationWillResignActiveNotification},
        {"applicationDidResignActive:", &NSApplicationDidResignActiveNotification},
        {"applicationWillHide:", &NSApplicationWillHideNotification},
        {"applicationDidHide:", &NSApplicationDidHideNotification},
        {"applicationWillUnhide:", &NSApplicationWillUnhideNotification},
        {"applicationDidUnhide:", &NSApplicationDidUnhideNotification},
        {"applicationWillUpdate:", &NSApplicationWillUpdateNotification},
        {"applicationDidUpdate:", &NSApplicationDidUpdateNotification},
        {"applicationWillTerminate:", &NSApplicationWillTerminateNotification},
        {"applicationDidChangeScreenParameters:", &NSApplicationDidChangeScreenParametersNotification},
        {"applicationDidChangeOcclusionState:", &NSApplicationDidChangeOcclusionStateNotification},
    };
    for (size_t i = 0; i < sizeof hooks / sizeof *hooks; i++) {
        SEL sel = sel_registerName(hooks[i].selector);
        if ([(id)delegate respondsToSelector:sel])
            [nc addObserver:delegate selector:sel name:*hooks[i].name object:self];
    }
}

#pragma mark - Windows

- (NSArray<NSWindow *> *)windows { return FinchAllWindows(); }
- (NSWindow *)keyWindow { return key_window; }
- (NSWindow *)mainWindow { return main_window; }
- (NSWindow *)modalWindow { return [_modalWindows lastObject]; }

void
FinchApplicationSetKeyWindow(NSWindow *window)
{
    key_window = window;
}

void
FinchApplicationSetMainWindow(NSWindow *window)
{
    main_window = window;
}

void
FinchApplicationNeedsDisplay(void)
{
    if (needs_display)
        return;
    needs_display = YES;
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void
FinchApplicationWindowOrderedOut(NSWindow *window)
{
    NSApplication *app = NSApp;
    if (!app || app->_a.terminating || ![app->_delegate respondsToSelector:
                                                            @selector(applicationShouldTerminateAfterLastWindowClosed:)])
        return;
    for (NSWindow *w in FinchAllWindows())
        if (w != window && [w isVisible] && ![w isKindOfClass:[NSPanel class]])
            return;
    if ([app->_delegate applicationShouldTerminateAfterLastWindowClosed:app])
        [app performSelector:@selector(terminate:) withObject:app afterDelay:0];
}

- (NSWindow *)windowWithWindowNumber:(NSInteger)number
{
    return FinchWindowForNumber(number);
}

- (void)enumerateWindowsWithOptions:(NSWindowListOptions)options
                         usingBlock:(void (NS_NOESCAPE ^)(NSWindow *, BOOL *))block
{
    BOOL stop = NO;
    for (NSWindow *w in FinchAllWindows()) {
        block(w, &stop);
        if (stop)
            break;
    }
}

- (NSArray *)orderedWindows
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible])
            [a addObject:w];
    return a;
}

- (void)updateWindows
{
    needs_display = NO;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSApplicationWillUpdateNotification object:self];
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible] && [w isAutodisplay])
            [w displayIfNeeded];
    [nc postNotificationName:NSApplicationDidUpdateNotification object:self];
}

- (void)setWindowsNeedUpdate:(BOOL)flag
{
    if (flag)
        FinchApplicationNeedsDisplay();
}

- (NSWindow *)makeWindowsPerform:(SEL)selector inOrder:(BOOL)inOrder
{
    for (NSWindow *w in FinchAllWindows())
        if (((BOOL(*)(id, SEL))objc_msgSend)(w, selector))
            return w;
    return nil;
}

- (void)miniaturizeAll:(id)sender
{
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible])
            [w miniaturize:sender];
}

- (void)arrangeInFront:(id)sender
{
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible])
            [w orderFront:sender];
}

#pragma mark - Events

- (NSEvent *)currentEvent { return _currentEvent; }

static void
set_current(NSApplication *app, NSEvent *e)
{
    [e retain];
    [app->_currentEvent release];
    app->_currentEvent = e;
}

/* A window-server event: activation is handled here; input is queued. */
- (void)_finchServerEvent:(const FWSEvent *)e
{
    if (e->type == FWS_EVENT_APP_ACTIVATED || e->type == FWS_EVENT_APP_DEACTIVATED) {
        [self _finchSetActive:e->type == FWS_EVENT_APP_ACTIVATED];
        return;
    }
    if (e->type == FWS_EVENT_WINDOW_MOVED) {
        FinchWindowServerEvent(e);
        return;
    }
    NSWindow *window = FinchWindowForNumber(e->window);
    if ((e->type == FWS_EVENT_KEY_DOWN || e->type == FWS_EVENT_KEY_UP || e->type == FWS_EVENT_FLAGS_CHANGED) &&
        !window)
        window = key_window;
    NSEvent *event = FinchEventFromServer(e, window);
    if (!event)
        return;
    NSRect screen = [[NSScreen mainScreen] frame];
    NSUInteger buttons = [NSEvent pressedMouseButtons];
    switch (e->type) {
    case FWS_EVENT_LEFT_DOWN: buttons |= 1; break;
    case FWS_EVENT_LEFT_UP: buttons &= ~1u; break;
    case FWS_EVENT_RIGHT_DOWN: buttons |= 2; break;
    case FWS_EVENT_RIGHT_UP: buttons &= ~2u; break;
    case FWS_EVENT_OTHER_DOWN: buttons |= 1u << e->button; break;
    case FWS_EVENT_OTHER_UP: buttons &= ~(1u << e->button); break;
    }
    FinchEventNoteModifiers([event modifierFlags], NSMakePoint(e->screen_x, NSMaxY(screen) - e->screen_y), buttons);
    /* Coalesce moves and drags, as macOS does. */
    NSEventType type = [event type];
    if ((type == NSEventTypeMouseMoved || type == NSEventTypeLeftMouseDragged) && [queue count] &&
        [[queue lastObject] type] == type && [[queue lastObject] window] == window)
        [queue removeLastObject];
    [queue addObject:event];
}

- (void)_finchSetActive:(BOOL)active
{
    if (_a.active == (unsigned)active)
        return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:active ? NSApplicationWillBecomeActiveNotification : NSApplicationWillResignActiveNotification
                      object:self];
    _a.active = active;
    if (!active)
        for (NSWindow *w in FinchAllWindows())
            if ([w hidesOnDeactivate] && [w isVisible])
                [w orderOut:self];
    [nc postNotificationName:active ? NSApplicationDidBecomeActiveNotification : NSApplicationDidResignActiveNotification
                      object:self];
}

static NSEvent *
take_matching(NSEventMask mask, BOOL dequeue)
{
    for (NSUInteger i = 0; i < [queue count]; i++) {
        NSEvent *e = queue[i];
        if (mask & NSEventMaskFromType([e type])) {
            [[e retain] autorelease];
            if (dequeue)
                [queue removeObjectAtIndex:i];
            return e;
        }
    }
    return nil;
}

- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask untilDate:(NSDate *)expiration inMode:(NSRunLoopMode)mode
                           dequeue:(BOOL)deqFlag
{
    if (!mode)
        mode = NSDefaultRunLoopMode;
    for (;;) {
        NSEvent *e = take_matching(mask, deqFlag);
        if (e && deqFlag) {
            e = FinchEventApplyLocalMonitors(e);
            if (!e)
                continue;
        }
        if (e) {
            if (deqFlag)
                set_current(self, e);
            return e;
        }
        NSTimeInterval wait = expiration ? [expiration timeIntervalSinceNow] : 0;
        if (wait <= 0) {
            /* one pass, to pick up what is pending */
            CFRunLoopRunInMode((CFStringRef)mode, 0, true);
            e = take_matching(mask, deqFlag);
            if (e && deqFlag)
                e = FinchEventApplyLocalMonitors(e);
            if (e && deqFlag)
                set_current(self, e);
            return e;
        }
        if (needs_display)
            [self updateWindows];
        CFRunLoopRunResult r = CFRunLoopRunInMode((CFStringRef)mode, MIN(wait, 1e10), true);
        if (r == kCFRunLoopRunFinished)
            [NSThread sleepForTimeInterval:MIN(wait, 0.01)];  /* nothing to wait on in this mode */
    }
}

- (void)discardEventsMatchingMask:(NSEventMask)mask beforeEvent:(NSEvent *)lastEvent
{
    NSUInteger end = lastEvent ? [queue indexOfObjectIdenticalTo:lastEvent] : [queue count];
    if (end == NSNotFound)
        end = [queue count];
    for (NSInteger i = (NSInteger)end - 1; i >= 0; i--)
        if (mask & NSEventMaskFromType([queue[(NSUInteger)i] type]))
            [queue removeObjectAtIndex:(NSUInteger)i];
}

- (void)postEvent:(NSEvent *)event atStart:(BOOL)flag
{
    if (!event)
        return;
    if (flag)
        [queue insertObject:event atIndex:0];
    else
        [queue addObject:event];
    CFRunLoopSourceSignal(post_source);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)sendEvent:(NSEvent *)event
{
    NSEventType type = [event type];
    switch (type) {
    case NSEventTypeKeyDown:
        if (([event modifierFlags] & NSEventModifierFlagCommand)) {
            if ([[self keyWindow] performKeyEquivalent:event])
                return;
            if ([_mainMenu performKeyEquivalent:event])
                return;
        }
        [[self keyWindow] sendEvent:event];
        break;
    case NSEventTypeKeyUp:
    case NSEventTypeFlagsChanged:
        [[self keyWindow] sendEvent:event];
        break;
    case NSEventTypeAppKitDefined:
    case NSEventTypeSystemDefined:
    case NSEventTypeApplicationDefined:
    case NSEventTypePeriodic:
        break;
    default: {
        NSWindow *w = [event window];
        if (_modalWindows.count && w && w != [_modalWindows lastObject] && ![w worksWhenModal]) {
            if (type == NSEventTypeLeftMouseDown)
                NSBeep();
            return;
        }
        [w sendEvent:event];
        break;
    }
    }
}

- (void)preventWindowOrdering {}

#pragma mark - Running

- (BOOL)isRunning { return _a.running; }
- (BOOL)isActive { return _a.active; }

- (void)finishLaunching
{
    if (_a.launched)
        return;
    _a.launched = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSApplicationWillFinishLaunchingNotification object:self];
    if (_policy == NSApplicationActivationPolicyRegular)
        [self activateIgnoringOtherApps:YES];
    FinchMenuBarDidLaunch();  /* the menu bar shows from now on (FinchMenuWindow.m) */
    [nc postNotificationName:NSApplicationDidFinishLaunchingNotification
                      object:self
                    userInfo:@{NSApplicationLaunchIsDefaultLaunchKey : @YES}];
}

- (void)run
{
    [self finishLaunching];
    _a.running = YES;
    while (_a.running) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSEvent *e = [self nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantFuture]
                                          inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e)
            [self sendEvent:e];
        [pool drain];
    }
}

static NSEvent *
wake_event(void)
{
    return [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                             timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
}

- (void)stop:(id)sender
{
    if (_modalWindows.count) {
        [self stopModal];
        return;
    }
    _a.running = NO;
    [self postEvent:wake_event() atStart:NO];
}

- (void)terminate:(id)sender
{
    NSApplicationTerminateReply reply = NSTerminateNow;
    if ([(id)_delegate respondsToSelector:@selector(applicationShouldTerminate:)])
        reply = [_delegate applicationShouldTerminate:self];
    if (reply == NSTerminateNow)
        [self _finchTerminateNow];
}

- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate
{
    if (shouldTerminate)
        [self _finchTerminateNow];
}

- (void)_finchTerminateNow
{
    _a.terminating = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationWillTerminateNotification object:self];
    [[NSUserDefaults standardUserDefaults] synchronize];
    exit(0);
}

- (void)replyToOpenOrPrint:(NSApplicationDelegateReply)reply {}

- (void)activateIgnoringOtherApps:(BOOL)flag
{
    [self _finchSetActive:YES];
}

- (void)activate
{
    [self activateIgnoringOtherApps:YES];
}

- (void)yieldActivationToApplication:(NSRunningApplication *)application {}
- (void)yieldActivationToApplicationWithBundleIdentifier:(NSString *)bundleIdentifier {}

- (void)deactivate
{
    [self _finchSetActive:NO];
}

- (void)hide:(id)sender
{
    if (_a.hidden)
        return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSApplicationWillHideNotification object:self];
    for (NSWindow *w in FinchAllWindows())
        if ([w isVisible] && [w canHide])
            [w orderOut:sender];
    _a.hidden = YES;
    [nc postNotificationName:NSApplicationDidHideNotification object:self];
}

- (void)unhide:(id)sender
{
    [self unhideWithoutActivation];
    [self activateIgnoringOtherApps:YES];
}

- (void)unhideWithoutActivation
{
    if (!_a.hidden)
        return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSApplicationWillUnhideNotification object:self];
    _a.hidden = NO;
    [nc postNotificationName:NSApplicationDidUnhideNotification object:self];
}

- (BOOL)isHidden { return _a.hidden; }
- (void)hideOtherApplications:(id)sender {}
- (void)unhideAllApplications:(id)sender {}

- (NSApplicationActivationPolicy)activationPolicy { return _policy; }

- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy
{
    _policy = policy;
    return YES;
}

- (NSApplicationPresentationOptions)presentationOptions { return _presentation; }
- (void)setPresentationOptions:(NSApplicationPresentationOptions)options { _presentation = options; }
- (NSApplicationPresentationOptions)currentSystemPresentationOptions { return _presentation; }
- (NSApplicationOcclusionState)occlusionState { return NSApplicationOcclusionStateVisible; }
- (NSInteger)requestUserAttention:(NSRequestUserAttentionType)type { return 0; }
- (void)cancelUserAttentionRequest:(NSInteger)request {}
- (BOOL)isProtectedDataAvailable { return YES; }
- (NSUserInterfaceLayoutDirection)userInterfaceLayoutDirection { return NSUserInterfaceLayoutDirectionLeftToRight; }
- (void)registerForRemoteNotifications {}
- (void)unregisterForRemoteNotifications {}
- (BOOL)isRegisteredForRemoteNotifications { return NO; }
- (void)registerServicesMenuSendTypes:(NSArray *)send returnTypes:(NSArray *)ret {}
- (void)disableRelaunchOnLogin {}
- (void)enableRelaunchOnLogin {}
- (BOOL)isAutomaticCustomizeTouchBarMenuItemEnabled { return NO; }
- (void)setAutomaticCustomizeTouchBarMenuItemEnabled:(BOOL)flag {}

- (NSAppearance *)appearance { return _appearance; }
- (void)setAppearance:(NSAppearance *)appearance { [_appearance autorelease]; _appearance = [appearance retain]; }
- (NSAppearance *)effectiveAppearance
{
    return _appearance ?: [NSAppearance appearanceNamed:NSAppearanceNameAqua];
}

#pragma mark - Modal sessions

struct _NSModalSession {
    NSWindow *window;
    NSInteger response;
    BOOL done;
};

- (NSModalSession)beginModalSessionForWindow:(NSWindow *)window
{
    if (!_modalWindows)
        _modalWindows = [[NSMutableArray alloc] init];
    [_modalWindows addObject:window];
    NSModalSession s = calloc(1, sizeof *s);
    s->window = window;
    s->response = NSModalResponseContinue;
    if (![window isVisible])
        [window center];
    [window makeKeyAndOrderFront:self];
    _a.stopModal = NO;
    return s;
}

- (NSModalResponse)runModalSession:(NSModalSession)session
{
    NSEvent *e;
    while (!_a.stopModal &&
           (e = [self nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSModalPanelRunLoopMode
                                    dequeue:YES]))
        [self sendEvent:e];
    if (_a.stopModal) {
        _a.stopModal = NO;
        return _modalResponse;
    }
    return NSModalResponseContinue;
}

- (void)endModalSession:(NSModalSession)session
{
    [_modalWindows removeObjectIdenticalTo:session->window];
    free(session);
}

- (NSModalResponse)runModalForWindow:(NSWindow *)window
{
    NSModalSession s = [self beginModalSessionForWindow:window];
    NSModalResponse r;
    for (;;) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSEvent *e = [self nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantFuture]
                                          inMode:NSModalPanelRunLoopMode dequeue:YES];
        if (e && !_a.stopModal)
            [self sendEvent:e];
        [pool drain];
        if (_a.stopModal) {
            _a.stopModal = NO;
            r = _modalResponse;
            break;
        }
    }
    [self endModalSession:s];
    return r;
}

- (void)stopModal
{
    [self stopModalWithCode:NSModalResponseStop];
}

- (void)stopModalWithCode:(NSModalResponse)code
{
    _modalResponse = code;
    _a.stopModal = YES;
    [self postEvent:wake_event() atStart:NO];
}

- (void)abortModal
{
    [self stopModalWithCode:NSModalResponseAbort];
}

- (NSInteger)runModalForWindow:(NSWindow *)window relativeToWindow:(NSWindow *)docWindow
{
    return [self runModalForWindow:window];
}

- (void)beginSheet:(NSWindow *)sheet modalForWindow:(NSWindow *)docWindow modalDelegate:(id)modalDelegate
    didEndSelector:(SEL)didEndSelector contextInfo:(void *)contextInfo
{
    [docWindow beginSheet:sheet completionHandler:nil];
}

- (void)endSheet:(NSWindow *)sheet
{
    [[sheet sheetParent] endSheet:sheet];
}

- (void)endSheet:(NSWindow *)sheet returnCode:(NSInteger)returnCode
{
    [[sheet sheetParent] endSheet:sheet returnCode:returnCode];
}

#pragma mark - Actions

/* Where an action with no target goes: the key window's responder chain, the key window and its delegate,
 * the same for the main window, then the app and its delegate. */
- (id)targetForAction:(SEL)action
{
    return [self targetForAction:action to:nil from:nil];
}

static id
responds(id object, SEL action)
{
    return object && [object respondsToSelector:action] ? object : nil;
}

static id
search_window(NSWindow *w, SEL action)
{
    if (!w)
        return nil;
    for (NSResponder *r = [w firstResponder]; r; r = [r nextResponder])
        if ([r respondsToSelector:action])
            return r;
    id t = responds(w, action) ?: responds([w delegate], action);
    if (!t && [[w windowController] document])
        t = responds([[w windowController] document], action);
    return t;
}

/* As Apple's, an explicit target is returned as it is; -sendAction:to:from: resolves without calling the
 * (overridable) -targetForAction:to:from:. */
static id
resolve_target(NSApplication *self, SEL action, id target)
{
    if (!action)
        return nil;
    if (target)
        return target;
    id t = search_window([self keyWindow], action);
    if (!t && [self mainWindow] != [self keyWindow])
        t = search_window([self mainWindow], action);
    if (!t)
        t = responds(self, action) ?: responds(self->_delegate, action);
    if (!t) {
        Class dc = FINCH_CLASS(NSDocumentController);
        id shared = dc ? [dc sharedDocumentController] : nil;
        t = responds(shared, action);
    }
    return t;
}

- (id)targetForAction:(SEL)action to:(id)target from:(id)sender
{
    return resolve_target(self, action, target);
}

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender
{
    id t = resolve_target(self, action, target);
    if (!t || ![t respondsToSelector:action])
        return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(t, action, sender);
    return YES;
}

- (BOOL)tryToPerform:(SEL)action with:(id)object
{
    if ([super tryToPerform:action with:object])
        return YES;
    if (_delegate && [(id)_delegate respondsToSelector:action]) {
        ((void (*)(id, SEL, id))objc_msgSend)(_delegate, action, object);
        return YES;
    }
    return NO;
}

- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType
{
    return nil;
}

#pragma mark - Menus and the icon

- (NSMenu *)mainMenu { return _mainMenu; }
- (void)setMainMenu:(NSMenu *)menu
{
    [_mainMenu autorelease];
    _mainMenu = [menu retain];
    FinchMenuBarUpdate();  /* redraws the menu bar, once launched (FinchMenuWindow.m) */
}
- (NSMenu *)windowsMenu { return _windowsMenu; }
- (void)setWindowsMenu:(NSMenu *)menu { [_windowsMenu autorelease]; _windowsMenu = [menu retain]; }
- (NSMenu *)servicesMenu { return _servicesMenu; }
- (void)setServicesMenu:(NSMenu *)menu { [_servicesMenu autorelease]; _servicesMenu = [menu retain]; }
- (NSMenu *)helpMenu { return _helpMenu; }
- (void)setHelpMenu:(NSMenu *)menu { [_helpMenu autorelease]; _helpMenu = [menu retain]; }
- (void)addWindowsItem:(NSWindow *)win title:(NSString *)string filename:(BOOL)isFilename {}
- (void)changeWindowsItem:(NSWindow *)win title:(NSString *)string filename:(BOOL)isFilename {}
- (void)removeWindowsItem:(NSWindow *)win {}
- (void)updateWindowsItem:(NSWindow *)win {}
- (NSImage *)applicationIconImage { return _icon; }
- (void)setApplicationIconImage:(NSImage *)image { [_icon autorelease]; _icon = [image retain]; }
- (NSDockTile *)dockTile { return nil; }
- (void)orderFrontStandardAboutPanel:(id)sender {}
- (void)orderFrontStandardAboutPanelWithOptions:(NSDictionary *)options {}
- (void)orderFrontCharacterPalette:(id)sender {}
- (void)orderFrontColorPanel:(id)sender {}
- (void)runPageLayout:(id)sender {}
- (void)showHelp:(id)sender {}
- (void)activateContextHelpMode:(id)sender {}

#pragma mark - Errors

- (BOOL)presentError:(NSError *)error
{
    if ([(id)_delegate respondsToSelector:@selector(application:willPresentError:)])
        error = [_delegate application:self willPresentError:error];
    NSLog(@"%@", [error localizedDescription]);
    return NO;
}

- (void)presentError:(NSError *)error modalForWindow:(NSWindow *)window delegate:(id)delegate
    didPresentSelector:(SEL)didPresentSelector contextInfo:(void *)contextInfo
{
    BOOL recovered = [self presentError:error];
    if (delegate && didPresentSelector)
        ((void (*)(id, SEL, BOOL, void *))objc_msgSend)(delegate, didPresentSelector, recovered, contextInfo);
}

@end

#pragma mark - NSApplicationMain

int
NSApplicationMain(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = [bundle infoDictionary];
    Class principal = NSClassFromString(info[@"NSPrincipalClass"]);
    if (!principal || ![principal isSubclassOfClass:[NSApplication class]])
        principal = [NSApplication class];
    NSApplication *app = [principal sharedApplication];
    NSString *nib = info[@"NSMainNibFile"];
    if ([nib length]) {
        Class nibClass = FINCH_CLASS(NSNib);
        id loaded = nibClass ? [[[nibClass alloc] initWithNibNamed:nib bundle:bundle] autorelease] : nil;
        if (![loaded instantiateWithOwner:app topLevelObjects:NULL])
            NSLog(@"Unable to load nib file: %@, exiting", nib);
    } else if ([info[@"NSMainStoryboardFile"] length]) {
        FinchStoryboardLaunch(app, bundle);  /* NSStoryboard.m */
    }
    [pool drain];
    [app run];
    return 0;
}

BOOL
NSShowsServicesMenuItem(NSString *itemName)
{
    return YES;
}

NSInteger
NSSetShowsServicesMenuItem(NSString *itemName, BOOL enabled)
{
    return 0;
}

BOOL
NSPerformService(NSString *itemName, NSPasteboard *pboard)
{
    return NO;
}

void
NSUpdateDynamicServices(void)
{
}
