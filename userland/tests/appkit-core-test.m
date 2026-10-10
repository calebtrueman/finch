/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-core-test: AppKit's core classes without a screen: responder
 * chains, events, view geometry and autoresizing, the key bindings, window
 * frames and first responders, action routing, appearances. Prints
 * everything; run it against Apple's AppKit and Finch's
 * (DYLD_FRAMEWORK_PATH) and diff. The first line is where NSView came from.
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void
out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", [s UTF8String]);
}

static NSString *
R(NSRect r)
{
    return NSStringFromRect(r);
}

static void
try_get(NSString *label, id (^get)(void))
{
    @try {
        out(@"  %@: %@", label, get());
    } @catch (NSException *e) {
        out(@"  %@: %@ %@", label, e.name, e.reason);
    }
}

#pragma mark - Responders

static NSMutableArray<NSString *> *log_;

@interface Logger : NSResponder
@property (copy) NSString *name;
@property BOOL handles;
@end

@implementation Logger
- (void)mouseDown:(NSEvent *)e
{
    [log_ addObject:[NSString stringWithFormat:@"%@ mouseDown", self.name]];
    if (!self.handles)
        [super mouseDown:e];
}
- (void)keyDown:(NSEvent *)e
{
    [log_ addObject:[NSString stringWithFormat:@"%@ keyDown", self.name]];
    if (!self.handles)
        [super keyDown:e];
}
- (void)noResponderFor:(SEL)sel
{
    [log_ addObject:[NSString stringWithFormat:@"%@ noResponderFor %@", self.name, NSStringFromSelector(sel)]];
}
- (void)doSomething:(id)sender
{
    [log_ addObject:[NSString stringWithFormat:@"%@ doSomething", self.name]];
}
- (void)doCommandBySelector:(SEL)sel
{
    [log_ addObject:NSStringFromSelector(sel)];
}
- (void)insertText:(id)text
{
    [log_ addObject:[NSString stringWithFormat:@"insertText '%@'", text]];
}
@end

static void
responders(void)
{
    out(@"== responders");
    log_ = [NSMutableArray array];
    Logger *a = [Logger new], *b = [Logger new], *c = [Logger new];
    a.name = @"a", b.name = @"b", c.name = @"c";
    a.nextResponder = b;
    b.nextResponder = c;
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:0
                                      timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
    NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                windowNumber:0 context:nil characters:@"x" charactersIgnoringModifiers:@"x"
                                   isARepeat:NO keyCode:7];
    [a mouseDown:down];
    [a keyDown:key];
    out(@"unhandled: %@", [log_ componentsJoinedByString:@", "]);
    [log_ removeAllObjects];
    b.handles = YES;
    [a mouseDown:down];
    [a keyDown:key];
    out(@"b handles: %@", [log_ componentsJoinedByString:@", "]);
    [log_ removeAllObjects];
    out(@"tryToPerform: %d %d", [a tryToPerform:@selector(doSomething:) with:nil],
        [a tryToPerform:@selector(nothingHere:) with:nil]);
    out(@"log: %@", [log_ componentsJoinedByString:@", "]);
    NSResponder *plain = [NSResponder new];
    out(@"plain: accepts %d become %d resign %d next %@", plain.acceptsFirstResponder, [plain becomeFirstResponder],
        [plain resignFirstResponder], plain.nextResponder);
    try_get(@"plain menu", ^id { return plain.menu; });
}

#pragma mark - Events

static void
events(void)
{
    out(@"== events");
    NSEvent *m = [NSEvent mouseEventWithType:NSEventTypeRightMouseDragged location:NSMakePoint(10.5, 20)
                               modifierFlags:NSEventModifierFlagShift | NSEventModifierFlagCommand timestamp:5.25
                                windowNumber:0 context:nil eventNumber:7 clickCount:2 pressure:0.5];
    out(@"%@", m);
    out(@"type %lu flags %lx btn %ld clicks %ld evnum %ld pressure %g loc %@ time %g", (unsigned long)m.type,
        (unsigned long)m.modifierFlags, (long)m.buttonNumber, (long)m.clickCount, (long)m.eventNumber, m.pressure,
        NSStringFromPoint(m.locationInWindow), m.timestamp);
    try_get(@"characters", ^id { return m.characters; });
    try_get(@"keyCode", ^id { return @(m.keyCode); });
    try_get(@"data1", ^id { return @(m.data1); });
    try_get(@"trackingNumber", ^id { return @(m.trackingNumber); });
    try_get(@"scrollingDeltaX", ^id { return @(m.scrollingDeltaX); });
    try_get(@"subtype", ^id { return @(m.subtype); });
    NSEvent *k = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSMakePoint(1, 2) modifierFlags:0x100
                                 timestamp:1 windowNumber:0 context:nil characters:@"é"
               charactersIgnoringModifiers:@"e" isARepeat:YES keyCode:14];
    out(@"%@", k);
    try_get(@"characters", ^id { return k.characters; });
    try_get(@"unmodified", ^id { return k.charactersIgnoringModifiers; });
    try_get(@"repeat", ^id { return @(k.isARepeat); });
    try_get(@"clickCount", ^id { return @(k.clickCount); });
    try_get(@"pressure", ^id { return @(k.pressure); });
    try_get(@"eventNumber", ^id { return @(k.eventNumber); });
    try_get(@"buttonNumber", ^id { return @(k.buttonNumber); });
    NSEvent *f = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint
                             modifierFlags:NSEventModifierFlagOption timestamp:2 windowNumber:0 context:nil
                                characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:58];
    try_get(@"flags keyCode", ^id { return @(f.keyCode); });
    try_get(@"flags characters", ^id { return f.characters; });
    NSEvent *ee = [NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:NSMakePoint(3, 4) modifierFlags:0
                                        timestamp:3 windowNumber:0 context:nil eventNumber:9 trackingNumber:11
                                         userData:NULL];
    out(@"entered: tracking %ld evnum %ld", (long)ee.trackingNumber, (long)ee.eventNumber);
    try_get(@"entered clickCount", ^id { return @(ee.clickCount); });
    NSEvent *o = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSMakePoint(1, 1)
                               modifierFlags:0 timestamp:4 windowNumber:0 context:nil subtype:3 data1:-4 data2:5];
    out(@"%@ / %d %ld %ld", o, o.subtype, (long)o.data1, (long)o.data2);
    try_get(@"other clickCount", ^id { return @(o.clickCount); });
    @try {
        [NSEvent mouseEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                       windowNumber:0 context:nil eventNumber:0 clickCount:0 pressure:0];
        out(@"mouse event of key type: made");
    } @catch (NSException *e) {
        out(@"mouse event of key type: %@", e.name);
    }
    out(@"masks: %llx %llx %llx", NSEventMaskFromType(NSEventTypeKeyDown), NSEventMaskFromType(NSEventTypeScrollWheel),
        (unsigned long long)NSEventMaskAny);
    out(@"intervals: %g %g", NSEvent.doubleClickInterval, NSEvent.keyRepeatDelay);
    out(@"copy is same: %d", [m copy] == m);
}

#pragma mark - Key bindings

static void
bindings(void)
{
    out(@"== key bindings");
    log_ = [NSMutableArray array];
    Logger *r = [Logger new];
    struct {
        unichar c;
        NSEventModifierFlags m;
        unsigned short code;
    } keys[] = {
        /* Apple's AppKit spins in its input machinery for arrows, Escape and the like with no window, so
         * the comparison sticks to keys it handles headless; the rest are in Finch's table. */
        {'a', 0, 0}, {'A', NSEventModifierFlagShift, 0}, {'\r', 0, 36}, {'\r', NSEventModifierFlagShift, 36},
        {'\r', NSEventModifierFlagOption, 36}, {'\r', NSEventModifierFlagControl, 36}, {'\t', 0, 48},
        {'\t', NSEventModifierFlagControl, 48}, {0x19, NSEventModifierFlagShift, 48}, {0x7f, 0, 51},
        {0x7f, NSEventModifierFlagOption, 51}, {0x7f, NSEventModifierFlagCommand, 51},
        {0x7f, NSEventModifierFlagControl, 51}, {NSDeleteFunctionKey, NSEventModifierFlagFunction, 117},
        {'a', NSEventModifierFlagControl, 0}, {'A', NSEventModifierFlagControl | NSEventModifierFlagShift, 0},
        {'e', NSEventModifierFlagControl, 14}, {'k', NSEventModifierFlagControl, 40}, {'o', NSEventModifierFlagControl, 31},
        {'t', NSEventModifierFlagControl, 17}, {'f', NSEventModifierFlagControl, 3}, {'z', NSEventModifierFlagControl, 6},
        {'b', NSEventModifierFlagControl | NSEventModifierFlagOption, 11}, {'.', NSEventModifierFlagCommand, 47},
        {'q', NSEventModifierFlagCommand, 12}, {0xe9, NSEventModifierFlagOption, 14},
    };
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        NSString *s = [NSString stringWithCharacters:&keys[i].c length:1];
        NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:keys[i].m
                                     timestamp:0 windowNumber:0 context:nil characters:s
                   charactersIgnoringModifiers:s isARepeat:NO keyCode:keys[i].code];
        [log_ removeAllObjects];
        [r interpretKeyEvents:@[ e ]];
        out(@"%04x %06lx -> %@", keys[i].c, (unsigned long)keys[i].m, [log_ componentsJoinedByString:@", "]);
    }
}

#pragma mark - Views

@interface Flipped : NSView
@end
@implementation Flipped
- (BOOL)isFlipped
{
    return YES;
}
@end

@interface Watch : NSView
@property (readwrite) NSInteger tag;
@end
@implementation Watch
@synthesize tag = _tag;
- (void)viewWillMoveToSuperview:(NSView *)s
{
    [log_ addObject:[NSString stringWithFormat:@"%ld willMoveToSuperview %ld", (long)self.tag, (long)s.tag]];
}
- (void)viewDidMoveToSuperview
{
    [log_ addObject:[NSString stringWithFormat:@"%ld didMoveToSuperview %ld", (long)self.tag, (long)self.superview.tag]];
}
- (void)didAddSubview:(NSView *)v
{
    [log_ addObject:[NSString stringWithFormat:@"%ld didAddSubview %ld", (long)self.tag, (long)v.tag]];
}
- (void)willRemoveSubview:(NSView *)v
{
    [log_ addObject:[NSString stringWithFormat:@"%ld willRemoveSubview %ld", (long)self.tag, (long)v.tag]];
}
@end

static NSString *
tags(NSView *v)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSView *s in v.subviews)
        [a addObject:@(s.tag)];
    return [a componentsJoinedByString:@" "];
}

static void
geometry(void)
{
    out(@"== view geometry");
    NSRect r = NSMakeRect(10, 20, 30, 40);
    double pts[][2] = {{10, 20}, {40, 20}, {10, 60}, {40, 60}, {9.99, 30}, {39.99, 59.99}, {10, 20.001}};
    for (int f = 0; f < 2; f++) {
        NSMutableString *s = [NSMutableString string];
        for (int i = 0; i < 7; i++)
            [s appendFormat:@" %d", NSMouseInRect(NSMakePoint(pts[i][0], pts[i][1]), r, f)];
        out(@"mouseInRect flipped %d:%@", f, s);
    }
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    Flipped *a = [[Flipped alloc] initWithFrame:NSMakeRect(20, 30, 100, 80)];
    [root addSubview:a];
    NSView *b = [[NSView alloc] initWithFrame:NSMakeRect(5, 10, 40, 20)];
    [a addSubview:b];
    [a setBoundsOrigin:NSMakePoint(-3, 4)];
    [b setBoundsSize:NSMakeSize(80, 10)];
    out(@"b->nil %@", NSStringFromPoint([b convertPoint:NSMakePoint(1, 2) toView:nil]));
    out(@"b->root %@", NSStringFromPoint([b convertPoint:NSMakePoint(1, 2) toView:root]));
    out(@"root->b %@", NSStringFromPoint([root convertPoint:NSMakePoint(50, 60) toView:b]));
    out(@"b->a %@ a->b %@", NSStringFromPoint([b convertPoint:NSMakePoint(7, 3) toView:a]),
        NSStringFromPoint([a convertPoint:NSMakePoint(7, 3) toView:b]));
    out(@"rect %@ from %@", R([b convertRect:NSMakeRect(1, 2, 3, 4) toView:nil]),
        R([b convertRect:NSMakeRect(1, 2, 3, 4) fromView:nil]));
    out(@"size %@ from %@", NSStringFromSize([b convertSize:NSMakeSize(3, 4) toView:nil]),
        NSStringFromSize([b convertSize:NSMakeSize(3, 4) fromView:nil]));
    NSMutableString *grid = [NSMutableString string];
    for (int y = 0; y < 200; y += 10)
        for (int x = 0; x < 200; x += 10) {
            NSView *h = [root hitTest:NSMakePoint(x, y)];
            [grid appendString:h == b ? @"b" : h == a ? @"a" : h == root ? @"r" : @"."];
        }
    out(@"hits %@", grid);
    out(@"hit outside %@; hidden a: %@", [root hitTest:NSMakePoint(300, 0)],
        ({
            a.hidden = YES;
            NSView *h = [root hitTest:NSMakePoint(50, 50)];
            a.hidden = NO;
            h == root ? @"root" : @"other";
        }));
    out(@"visible (no window) %@", R([b visibleRect]));
    out(@"bounds b %@ frame %@", R(b.bounds), R(b.frame));
    [b setFrameSize:NSMakeSize(20, 40)];
    out(@"after frame size: bounds %@", R(b.bounds));
    [b scaleUnitSquareToSize:NSMakeSize(2, 0.5)];
    out(@"after scale: bounds %@", R(b.bounds));
    [b translateOriginToPoint:NSMakePoint(1, 1)];
    out(@"after translate: bounds %@", R(b.bounds));
    [b setFrame:NSMakeRect(1, 2, 50, 60)];
    out(@"after setFrame: frame %@ bounds %@", R(b.frame), R(b.bounds));
    out(@"defaults: tag %ld opaque %d autoresizes %d mask %lu posts %d %d hidden %d flipped %d", (long)root.tag,
        root.isOpaque, root.autoresizesSubviews, (unsigned long)root.autoresizingMask, root.postsFrameChangedNotifications,
        root.postsBoundsChangedNotifications, root.isHidden, root.isFlipped);
    out(@"next responders: b->a %d a->root %d root %@", b.nextResponder == a, a.nextResponder == root,
        root.nextResponder);
    out(@"ancestor %d %d desc %d %d", [b ancestorSharedWithView:root] == root, [b ancestorSharedWithView:a] == a,
        [b isDescendantOf:root], [root isDescendantOf:b]);
    out(@"intrinsic %@ noMetric %g", NSStringFromSize(root.intrinsicContentSize), NSViewNoIntrinsicMetric);
    NSView *c = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    out(@"align %@", R([c backingAlignedRect:NSMakeRect(1.3, 2.6, 3.3, 4.4) options:NSAlignAllEdgesNearest]));
    out(@"align outward %@", R([c backingAlignedRect:NSMakeRect(1.3, 2.6, 3.3, 4.4) options:NSAlignAllEdgesOutward]));
    out(@"center %@", R([c centerScanRect:NSMakeRect(1.3, 2.6, 3.3, 4.4)]));
    out(@"backing %@ %@", R([c convertRectToBacking:NSMakeRect(1, 2, 3, 4)]),
        R([c convertRectFromBacking:NSMakeRect(1, 2, 3, 4)]));
    out(@"mouse:inRect: %d %d", [a mouse:NSMakePoint(0, 0) inRect:NSMakeRect(0, 0, 5, 5)],
        [root mouse:NSMakePoint(0, 0) inRect:NSMakeRect(0, 0, 5, 5)]);
    out(@"needsDisplay before %d", c.needsDisplay);
    c.needsDisplay = YES;
    out(@"needsDisplay after %d", c.needsDisplay);
}

static void
tree(void)
{
    out(@"== view tree");
    log_ = [NSMutableArray array];
    Watch *p = [[Watch alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    p.tag = 1;
    Watch *v[5];
    for (int i = 0; i < 5; i++) {
        v[i] = [[Watch alloc] initWithFrame:NSMakeRect(i, i, 10, 10)];
        v[i].tag = 10 + i;
    }
    [p addSubview:v[0]];
    [p addSubview:v[1]];
    [p addSubview:v[2] positioned:NSWindowBelow relativeTo:nil];
    [p addSubview:v[3] positioned:NSWindowAbove relativeTo:v[2]];
    [p addSubview:v[4] positioned:NSWindowBelow relativeTo:v[1]];
    out(@"order %@", tags(p));
    out(@"log %@", [log_ componentsJoinedByString:@"; "]);
    [log_ removeAllObjects];
    [p addSubview:v[2]];
    out(@"re-add moves to top: %@ log %@", tags(p), [log_ componentsJoinedByString:@"; "]);
    [log_ removeAllObjects];
    [v[1] removeFromSuperview];
    out(@"removed: %@ log %@ superview %@ next %@", tags(p), [log_ componentsJoinedByString:@"; "], v[1].superview,
        v[1].nextResponder);
    [log_ removeAllObjects];
    Watch *n = [[Watch alloc] initWithFrame:NSZeroRect];
    n.tag = 99;
    [p replaceSubview:v[0] with:n];
    out(@"replaced: %@ log %@", tags(p), [log_ componentsJoinedByString:@"; "]);
    [log_ removeAllObjects];
    p.subviews = @[ v[3], n, v[1] ];
    out(@"setSubviews: %@ log %@", tags(p), [log_ componentsJoinedByString:@"; "]);
    out(@"viewWithTag 99 %d, 1 %d, 7 %@", [p viewWithTag:99] == n, [p viewWithTag:1] == p, [p viewWithTag:7]);
    /* key view loop */
    NSView *k1 = [NSView new], *k2 = [NSView new], *k3 = [NSView new];
    k1.nextKeyView = k2;
    k2.nextKeyView = k3;
    k3.nextKeyView = k1;
    out(@"key loop: %d %d %d prev %d", k1.nextKeyView == k2, k3.nextKeyView == k1, k2.previousKeyView == k1,
        k1.previousKeyView == k3);
    out(@"nextValid (none accept) %@ canBecomeKeyView %d", k1.nextValidKeyView, k1.canBecomeKeyView);
    /* notifications */
    __block int frames = 0, boundses = 0;
    id o1 = [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification object:k1
                                                               queue:nil usingBlock:^(NSNotification *note) { frames++; }];
    id o2 = [[NSNotificationCenter defaultCenter] addObserverForName:NSViewBoundsDidChangeNotification object:k1
                                                               queue:nil usingBlock:^(NSNotification *note) { boundses++; }];
    k1.frame = NSMakeRect(1, 2, 3, 4);
    k1.frame = NSMakeRect(1, 2, 3, 4);
    k1.frameOrigin = NSMakePoint(5, 5);
    k1.frameSize = NSMakeSize(9, 9);
    k1.boundsOrigin = NSMakePoint(1, 1);
    k1.bounds = NSMakeRect(1, 1, 2, 2);
    out(@"notifications: frame %d bounds %d", frames, boundses);
    [[NSNotificationCenter defaultCenter] removeObserver:o1];
    [[NSNotificationCenter defaultCenter] removeObserver:o2];
}

static void
autoresizing(void)
{
    out(@"== autoresizing");
    for (int fl = 0; fl < 2; fl++)
        for (int m = 0; m < 64; m++) {
            NSView *s = [[(fl ? [Flipped class] : [NSView class]) alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
            NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(10, 20, 30, 40)];
            v.autoresizingMask = m;
            [s addSubview:v];
            [s setFrameSize:NSMakeSize(200, 150)];
            NSRect a = v.frame;
            [s setFrameSize:NSMakeSize(37, 9)];
            out(@"%d %2d: %@ | %@", fl, m, R(a), R(v.frame));
        }
    double ws[] = {100, 73, 60, 45, 40, 33, 30, 20, 5, 0, -10};
    for (int m = 1; m < 8; m++) {
        NSMutableString *line = [NSMutableString string];
        for (int i = 0; i < 11; i++) {
            NSView *s = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
            NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(10, 20, 30, 40)];
            v.autoresizingMask = m;
            [s addSubview:v];
            [s setFrameSize:NSMakeSize(ws[i], 100)];
            [line appendFormat:@" [%g: %g %g]", ws[i], v.frame.origin.x, v.frame.size.width];
        }
        out(@"m=%d:%@", m, line);
    }
    NSView *s = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(10.3, 20, 30.3, 40)];
    [s addSubview:v];
    out(@"unaligned kept: %@", R(v.frame));
    v.autoresizingMask = NSViewMinXMargin;
    [s setFrameSize:NSMakeSize(101.1, 100)];
    out(@"after: %@", R(v.frame));
    v.autoresizingMask = NSViewWidthSizable;
    [s setFrameSize:NSMakeSize(102.2, 100)];
    out(@"after w: %@", R(v.frame));
    s.autoresizesSubviews = NO;
    [s setFrameSize:NSMakeSize(300, 300)];
    out(@"autoresizes off: %@", R(v.frame));
}

#pragma mark - Windows

@interface Taker : NSView
@property BOOL accepts, refusesResign;
@property (readwrite) NSInteger tag;
@end
@implementation Taker
@synthesize tag = _tag;
- (BOOL)acceptsFirstResponder
{
    return self.accepts;
}
- (BOOL)becomeFirstResponder
{
    [log_ addObject:[NSString stringWithFormat:@"%ld become", (long)self.tag]];
    return YES;
}
- (BOOL)resignFirstResponder
{
    [log_ addObject:[NSString stringWithFormat:@"%ld resign", (long)self.tag]];
    return !self.refusesResign;
}
@end

static NSString *
fr(NSWindow *w)
{
    id r = w.firstResponder;
    return r == w ? @"window" : [r isKindOfClass:[NSView class]] ? [NSString stringWithFormat:@"%ld", (long)[r tag]]
                                                                  : NSStringFromClass([r class]);
}

static void
windows(void)
{
    out(@"== windows");
    NSUInteger styles[] = {0, NSWindowStyleMaskTitled,
                           NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                               NSWindowStyleMaskResizable,
                           NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView,
                           NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable,
                           NSWindowStyleMaskTitled | NSWindowStyleMaskUtilityWindow};
    for (int i = 0; i < 6; i++)
        out(@"style %lx frame %@ content %@", (unsigned long)styles[i],
            R([NSWindow frameRectForContentRect:NSMakeRect(100, 100, 300, 200) styleMask:styles[i]]),
            R([NSWindow contentRectForFrameRect:NSMakeRect(100, 100, 300, 200) styleMask:styles[i]]));
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 300, 200) styleMask:styles[2]
                                                backing:NSBackingStoreBuffered defer:YES];
    w.releasedWhenClosed = NO;
    out(@"frame %@ visible %d released %d level %ld opaque %d shadow %d alpha %g", R(w.frame), w.isVisible,
        [[[NSWindow alloc] initWithContentRect:NSZeroRect styleMask:0 backing:NSBackingStoreBuffered defer:YES]
            isReleasedWhenClosed],
        (long)w.level, w.isOpaque, w.hasShadow, w.alphaValue);
    out(@"content %@ %@ mask %lu superview %@ %@", [w.contentView className], R([w.contentView frame]),
        (unsigned long)[w.contentView autoresizingMask], [[w.contentView superview] className],
        R([[w.contentView superview] frame]));
    out(@"content next responder is window %d; window next %@", [w.contentView nextResponder] == w, w.nextResponder);
    out(@"first responder %@ title '%@' minSize %@ maxSize %@", fr(w), w.title, NSStringFromSize(w.minSize),
        NSStringFromSize(w.maxSize));
    out(@"mouseMoved %d autodisplay %d canBecomeKey %d", w.acceptsMouseMovedEvents, w.isAutodisplay,
        w.canBecomeKeyWindow);
    NSWindow *b = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 50, 50) styleMask:0
                                                backing:NSBackingStoreBuffered defer:YES];
    out(@"borderless canBecomeKey %d main %d", b.canBecomeKeyWindow, b.canBecomeMainWindow);
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(3, 4, 10, 10)];
    w.contentView = v;
    out(@"new content frame %@ mask %lu window %d", R(v.frame), (unsigned long)v.autoresizingMask, v.window == w);
    [w setContentSize:NSMakeSize(400, 300)];
    out(@"after setContentSize: %@ content %@", R(w.frame), R(v.frame));
    [w setFrame:NSMakeRect(10, 20, 250, 150) display:NO];
    out(@"after setFrame: %@ content %@", R(w.frame), R(v.frame));
    w.title = @"Hello";
    out(@"title %@ representedFilename '%@'", w.title, w.representedFilename);
    w.contentMinSize = NSMakeSize(100, 50);
    out(@"contentMinSize %@ minSize %@", NSStringFromSize(w.contentMinSize), NSStringFromSize(w.minSize));
    out(@"convert to screen %@ from %@", R([w convertRectToScreen:NSMakeRect(1, 2, 3, 4)]),
        R([w convertRectFromScreen:NSMakeRect(1, 2, 3, 4)]));
    /* first responders */
    log_ = [NSMutableArray array];
    Taker *t1 = [[Taker alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)], *t2 = [[Taker alloc] initWithFrame:NSZeroRect];
    t1.tag = 1, t2.tag = 2;
    t1.accepts = YES;
    [v addSubview:t1];
    [v addSubview:t2];
    out(@"make t1: %d -> %@ (%@)", [w makeFirstResponder:t1], fr(w), [log_ componentsJoinedByString:@", "]);
    [log_ removeAllObjects];
    out(@"make t2 (refuses): %d -> %@ (%@)", [w makeFirstResponder:t2], fr(w), [log_ componentsJoinedByString:@", "]);
    [log_ removeAllObjects];
    [w makeFirstResponder:t1];
    [log_ removeAllObjects];
    t1.refusesResign = YES;
    t2.accepts = YES;
    out(@"t1 refuses to resign: %d -> %@ (%@)", [w makeFirstResponder:t2], fr(w), [log_ componentsJoinedByString:@", "]);
    t1.refusesResign = NO;
    [log_ removeAllObjects];
    out(@"make nil: %d -> %@ (%@)", [w makeFirstResponder:nil], fr(w), [log_ componentsJoinedByString:@", "]);
    [w makeFirstResponder:t2];
    [log_ removeAllObjects];
    [t2 removeFromSuperview];
    out(@"removed first responder -> %@ (%@)", fr(w), [log_ componentsJoinedByString:@", "]);
    NSView *other = [[NSView alloc] initWithFrame:NSZeroRect];
    out(@"view of no window: %d -> %@", [w makeFirstResponder:other], fr(w));
    [w close];
}

#pragma mark - Actions

@interface Target : NSObject
@end
@implementation Target
- (void)appAction:(id)sender
{
    [log_ addObject:@"delegate appAction"];
}
@end

static void
actions(void)
{
    out(@"== actions");
    log_ = [NSMutableArray array];
    Target *t = [Target new];
    NSApp.delegate = (id)t;
    out(@"targetForAction appAction is delegate %d", [NSApp targetForAction:@selector(appAction:)] == t);
    out(@"sendAction nil target: %d", [NSApp sendAction:@selector(appAction:) to:nil from:nil]);
    out(@"sendAction missing: %d", [NSApp sendAction:@selector(nowhere:) to:nil from:nil]);
    out(@"sendAction to t: %d", [NSApp sendAction:@selector(appAction:) to:t from:nil]);
    out(@"targetForAction terminate: is app %d", [NSApp targetForAction:@selector(terminate:)] == NSApp);
    out(@"log %@", [log_ componentsJoinedByString:@", "]);
    NSApp.delegate = nil;
}

static void
appearances(void)
{
    out(@"== appearances");
    for (NSString *n in @[
             NSAppearanceNameAqua, NSAppearanceNameDarkAqua, NSAppearanceNameVibrantDark, NSAppearanceNameVibrantLight,
             NSAppearanceNameAccessibilityHighContrastAqua, NSAppearanceNameAccessibilityHighContrastDarkAqua
         ]) {
        NSAppearance *a = [NSAppearance appearanceNamed:n];
        out(@"%@ -> %@ vibrancy %d match %@", n, a.name, a.allowsVibrancy,
            [a bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]);
    }
    out(@"same object: %d", [NSAppearance appearanceNamed:NSAppearanceNameAqua] ==
                                [NSAppearance appearanceNamed:NSAppearanceNameAqua]);
}

/* Input contexts, Dock tiles, window tabs' objects and other calls apps make */
static void
app_calls(void)
{
    NSView *plain = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    NSTextInputContext *c = tv.inputContext;
    printf("input context: plain %d text view %d same %d client %d\n", plain.inputContext != nil, c != nil,
           c == tv.inputContext, c.client == (id)tv);
    printf("US layout name: %s\n", [NSTextInputContext localizedNameForInputSource:@"com.apple.keylayout.US"].UTF8String);
    NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                windowNumber:0 context:nil characters:@"q" charactersIgnoringModifiers:@"q"
                                   isARepeat:NO keyCode:12];
    NSEvent *flags = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint
                                 modifierFlags:NSEventModifierFlagShift timestamp:0 windowNumber:0 context:nil
                                    characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:56];
    printf("handle key: %d text '%s'; flags changed handled %d\n", [c handleEvent:key], tv.string.UTF8String,
           [c handleEvent:flags]);

    NSDockTile *tile = NSApp.dockTile;
    printf("dock tile: %gx%g badge '%s' shows badge %d owner app %d\n", tile.size.width, tile.size.height,
           tile.badgeLabel.UTF8String, tile.showsApplicationBadge, tile.owner == NSApp);
    tile.badgeLabel = @"3";
    printf("badge now '%s'\n", tile.badgeLabel.UTF8String);
    tile.badgeLabel = @"";
    printf("badge emptied %d\n", tile.badgeLabel == nil);

    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    w.title = @"Tabbed";
    printf("window tab: title '%s' tooltip '%s'; tabbed windows %lu; identifier %s\n", w.tab.title.UTF8String,
           w.tab.toolTip.UTF8String, (unsigned long)w.tabbedWindows.count, w.tabbingIdentifier.UTF8String);
    w.tabbingIdentifier = @"group";
    printf("tab group: has %lu, selected is window %d, bar visible %d, identifier %s\n",
           (unsigned long)w.tabGroup.windows.count, w.tabGroup.selectedWindow == w, w.tabGroup.isTabBarVisible,
           w.tabbingIdentifier.UTF8String);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    printf("bottom corner rounded %d\n", (int)(long)[w performSelector:@selector(bottomCornerRounded)]);
#pragma clang diagnostic pop
    [[NSUserDefaults standardUserDefaults] setObject:@"0 0 10 10 0 0 100 100 " forKey:@"NSWindow Frame finch-test-frame"];
    [NSWindow removeFrameUsingName:@"finch-test-frame"];
    printf("frame removed %d\n", [[NSUserDefaults standardUserDefaults] objectForKey:@"NSWindow Frame finch-test-frame"] == nil);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSView class]));
        [NSApplication sharedApplication];
        responders();
        events();
        bindings();
        geometry();
        tree();
        autoresizing();
        windows();
        actions();
        appearances();
        app_calls();
    }
    return 0;
}
