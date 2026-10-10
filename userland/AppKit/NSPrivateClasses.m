/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit's private classes and functions that apps use directly (Terminal among them),
 * with Apple's interfaces, read from its binary:
 *   - NSFindIndicator: the yellow highlight that bounces over found text, drawn as
 *     borderless windows over the view's rects, then faded;
 *   - NSScrollerImpPair: a scroll view's scroller pair, its style and delegate;
 *   - NSImmediateActionGestureRecognizer: force-click actions (Finch has no
 *     force-click input, so it never begins);
 *   - NSFunctionRow: the Touch Bar's, which Finch's Macs don't have;
 *   - NSInputManager: the pre-10.6 input manager, of which there's no current one, as
 *     on macOS today;
 *   - NSSolariumEnabled() (whether AppKit draws macOS 26's design: Finch draws its own
 *     theme) and NSShowSystemInfoPanel().
 */
#import "AppKit_Finch.h"
#include <objc/message.h>
#include <objc/runtime.h>

BOOL NSSolariumEnabled(void);
void NSShowSystemInfoPanel(NSDictionary *options);

BOOL
NSSolariumEnabled(void)
{
    return NO;
}

void
NSShowSystemInfoPanel(NSDictionary *options)
{
    NSMutableDictionary *d = [[NSMutableDictionary alloc] initWithDictionary:options ?: @{}];
    [d setObject:@"YES" forKey:@"AppleInternal"];
    [NSApp orderFrontStandardAboutPanelWithOptions:d];
    [d release];
}

#pragma mark - NSFindIndicator

@protocol NSFindIndicatorDelegate;

@interface NSFindIndicator : NSObject
@property (copy) NSArray *rects;
@property (assign) NSView *view;
@property (assign) NSWindow *parentWindow;
@property (assign) id delegate;
@property (assign) NSTextFinder *textFinder;
@property (copy) id contentDrawer;
@property (copy) id imageProvider;
@property (copy) id completionHandler;
@property BOOL usesThreadedAnimation;
@property (getter=isVisible) BOOL visible;
@end

/* One highlight: a yellow rounded rectangle with the view's content drawn inside. */
@interface _FinchFindIndicatorView : NSView {
  @public
    NSImage *_content;
}
@end

@implementation _FinchFindIndicatorView
- (void)dealloc
{
    [_content release];
    [super dealloc];
}
- (void)drawRect:(NSRect)dirty
{
    NSRect b = NSInsetRect([self bounds], 1, 1);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:4 yRadius:4];
    [[NSColor colorWithSRGBRed:1 green:0.92 blue:0.2 alpha:1] setFill];
    [p fill];
    [_content drawInRect:NSInsetRect([self bounds], 4, 2) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                fraction:1];
    [[NSColor colorWithSRGBRed:0.85 green:0.65 blue:0 alpha:1] setStroke];
    [p stroke];
}
@end

static int find_indicator_drawing;

@implementation NSFindIndicator {
    NSMutableArray<NSWindow *> *_windows;
}

+ (void)beginDrawing { find_indicator_drawing++; }
+ (void)endDrawing { find_indicator_drawing--; }
+ (BOOL)isDrawing { return find_indicator_drawing > 0; }

- (void)dealloc
{
    [self _cancel];
    [_rects release];
    [_contentDrawer release];
    [_imageProvider release];
    [_completionHandler release];
    [super dealloc];
}

- (NSWindow *)_effectiveParentWindow { return _parentWindow ?: [_view window]; }

- (void)_cancel
{
    for (NSWindow *w in _windows) {
        [[w parentWindow] removeChildWindow:w];
        [w orderOut:nil];
    }
    [_windows release];
    _windows = nil;
    _visible = NO;
}

- (NSArray *)_buildFindIndicatorWindows
{
    [self _cancel];
    NSWindow *parent = [self _effectiveParentWindow];
    if (!_view || !parent)
        return @[];
    _windows = [[NSMutableArray alloc] init];
    for (NSValue *v in _rects) {
        NSRect r = NSInsetRect([v rectValue], -4, -2);
        NSRect inWindow = [_view convertRect:r toView:nil];
        NSRect onScreen = [parent convertRectToScreen:inWindow];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:onScreen styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered defer:NO];
        [w setOpaque:NO];
        [w setBackgroundColor:[NSColor clearColor]];
        [w setIgnoresMouseEvents:YES];
        [w setReleasedWhenClosed:NO];
        _FinchFindIndicatorView *iv = [[_FinchFindIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(r), NSHeight(r))];
        NSRect content = [v rectValue];
        NSBitmapImageRep *rep = [_view bitmapImageRepForCachingDisplayInRect:content];
        if (rep) {
            [NSFindIndicator beginDrawing];
            [_view cacheDisplayInRect:content toBitmapImageRep:rep];
            [NSFindIndicator endDrawing];
            NSImage *img = [[NSImage alloc] initWithSize:content.size];
            [img addRepresentation:rep];
            iv->_content = img;
        }
        [w setContentView:iv];
        [iv release];
        [parent addChildWindow:w ordered:NSWindowAbove];
        [_windows addObject:w];
        [w release];
    }
    return _windows;
}

- (void)setVisible:(BOOL)visible
{
    if (visible == _visible)
        return;
    if (visible) {
        for (NSWindow *w in [self _buildFindIndicatorWindows])
            [w orderFront:nil];
        _visible = YES;
    } else {
        [self _cancel];
    }
}

- (void)updateWithRects:(NSArray *)rects
{
    [self setRects:rects];
    if (_visible) {
        _visible = NO;
        [self setVisible:YES];
    }
}

- (void)_redrawReusingWindows { [self updateWithRects:_rects]; }

- (void)_finish
{
    [self _cancel];
    void (^done)(void) = [[_completionHandler retain] autorelease];
    if (done)
        done();
}

/* Shows the highlight; with fade, it goes after a moment, as Apple's does. */
- (void)pulseWithFade:(BOOL)fade andDissolve:(BOOL)dissolve
{
    [self setVisible:YES];
    if (fade || dissolve)
        [self performSelector:@selector(_finish) withObject:nil afterDelay:fade ? 1.0 : 0.5];
}

- (void)pulseAndFade:(BOOL)fade { [self pulseWithFade:fade andDissolve:NO]; }
- (void)dissolve { [self _finish]; }
- (void)_fade:(double)duration { [self performSelector:@selector(_finish) withObject:nil afterDelay:duration]; }
- (void)_pulse:(double)duration { [self setVisible:YES]; }
- (void)focusUAZoom {}

@end

#pragma mark - NSScrollerImpPair

@interface NSScrollerImpPair : NSObject
@property (assign) id delegate;
@property (assign) NSScrollView *scrollView;
@property (retain) id verticalScrollerImp, horizontalScrollerImp;
@property (getter=isFlipped) BOOL flipped;
@property NSScrollerStyle scrollerStyle;
@property NSScrollerKnobStyle scrollerKnobStyle;
@property (copy) NSColor *scrollerKnobColor, *scrollerTrackColor;
@property (readonly) BOOL overlayScrollersShown;
@property (readonly, getter=isInScrollGesture) BOOL inScrollGesture;
@end

@implementation NSScrollerImpPair

static NSHashTable *all_pairs;

+ (NSInteger)scrollerLayoutDirection { return 0; }
+ (void)setSuppressScrollerFlash:(BOOL)suppress forDescendantsOfView:(NSView *)view {}
+ (void)setSuppressScrollerFlash:(BOOL)suppress forDecendantsOfView:(NSView *)view {}

/* A change of the recommended style (a mouse plugged in, the preference changed) goes
   to every pair's delegate. */
+ (void)_updateAllScrollerImpPairsForNewRecommendedScrollerStyle:(NSScrollerStyle)style
{
    for (NSScrollerImpPair *p in [all_pairs allObjects]) {
        id d = [p delegate];
        if ([d respondsToSelector:@selector(scrollerImpPair:updateScrollerStyleForNewRecommendedScrollerStyle:)])
            ((void (*)(id, SEL, id, NSScrollerStyle))objc_msgSend)(
                d, @selector(scrollerImpPair:updateScrollerStyleForNewRecommendedScrollerStyle:), p, style);
        else
            [p setScrollerStyle:style];
    }
}

- (instancetype)init
{
    if ((self = [super init])) {
        @synchronized([NSScrollerImpPair class]) {
            if (!all_pairs)
                all_pairs = [[NSHashTable weakObjectsHashTable] retain];
            [all_pairs addObject:self];
        }
        _scrollerStyle = [NSScroller preferredScrollerStyle];
    }
    return self;
}

- (void)dealloc
{
    @synchronized([NSScrollerImpPair class]) {
        [all_pairs removeObject:self];
    }
    [_verticalScrollerImp release];
    [_horizontalScrollerImp release];
    [_scrollerKnobColor release];
    [_scrollerTrackColor release];
    [super dealloc];
}

- (BOOL)overlayScrollersShown { return _scrollerStyle == NSScrollerStyleOverlay; }
- (BOOL)isInScrollGesture { return NO; }
- (void)flashScrollers {}
- (void)hideOverlayScrollers {}
- (void)lockOverlayScrollerState:(NSUInteger)state {}
- (void)unlockOverlayScrollerState {}
- (BOOL)overlayScrollerStateIsLocked { return NO; }
- (void)beginScrollGesture {}
- (void)endScrollGesture {}
- (void)cancelScrollGesture {}
- (void)contentAreaScrolled {}
- (void)contentAreaScrolledInDirection:(NSPoint)direction {}
- (void)contentAreaWillDraw {}
- (void)contentAreaDidResize {}
- (void)contentAreaDidHide {}
- (void)contentAreaDidUnhide {}
- (void)mouseEnteredContentArea {}
- (void)mouseExitedContentArea {}
- (void)mouseMovedInContentArea {}
- (void)startLiveResize {}
- (void)endLiveResize {}
- (void)windowOrderedIn {}
- (void)windowOrderedOut {}
- (void)movedToNewWindow {}
- (void)removedFromSuperview {}
- (void)updateTrackingAreas {}
- (void)endTrackingInScrollerImp:(id)imp {}

@end

#pragma mark - NSImmediateActionGestureRecognizer

@interface NSImmediateActionGestureRecognizer : NSGestureRecognizer
@property (retain) id animationController;
@property (retain) NSViewController *viewController;
@end

@implementation NSImmediateActionGestureRecognizer
- (void)dealloc
{
    [_animationController release];
    [_viewController release];
    [super dealloc];
}
@end

#pragma mark - NSFunctionRow

@interface NSFunctionRow : NSObject
@end

@implementation NSFunctionRow
+ (BOOL)isDynamicFunctionRowAvailable { return NO; }
+ (NSArray *)activeFunctionRows { return @[]; }
+ (void)markActiveFunctionRowsAsDimmed:(BOOL)dimmed {}
+ (int)associatedDisplay { return 0; }
@end

#pragma mark - NSInputManager

@implementation NSInputManager
+ (NSInputManager *)currentInputManager { return nil; }
+ (void)cycleToNextInputLanguage:(id)sender {}
+ (void)cycleToNextInputServerInLanguage:(id)sender {}
- (NSInputManager *)initWithName:(NSString *)inputServerName host:(NSString *)hostName
{
    [self release];
    return nil;
}
- (NSString *)localizedInputManagerName { return nil; }
- (void)markedTextAbandoned:(id)cli {}
- (void)markedTextSelectionChanged:(NSRange)newSel client:(id)cli {}
- (BOOL)wantsToInterpretAllKeystrokes { return NO; }
- (NSString *)language { return nil; }
- (NSImage *)image { return nil; }
- (NSInputServer *)server { return nil; }
- (BOOL)wantsToHandleMouseEvents { return NO; }
- (BOOL)handleMouseEvent:(NSEvent *)mouseEvent { return NO; }
- (BOOL)wantsToDelayTextChangeNotifications { return NO; }
@end
