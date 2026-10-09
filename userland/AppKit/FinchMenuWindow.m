/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The menu bar and the menus on screen. On macOS the menu bar is drawn by
 * the system; Finch has no system UI yet, so each app draws its own while
 * it is the active app: a borderless window at NSMainMenuWindowLevel across
 * the top 24 points of the screen (what NSScreen's visibleFrame leaves
 * out), with the app's name in bold and the main menu's titles. Menus open
 * as borderless windows at NSPopUpMenuWindowLevel, the same for the menu
 * bar's menus, context menus, -popUpMenuPositioningItem:... and pop-up
 * buttons. The look is Finch's own: flat, rounded, one accent colour.
 *
 * Tracking is a loop over the app's events in NSEventTrackingRunLoopMode:
 * press and drag through the menus and release on an item, or click a
 * title (or right-click) and the menu stays open for a second click; the
 * pointer highlights items and opens submenus; the arrow keys, Return and
 * Escape work in an open menu; a click outside cancels.
 */
#import "NSMenu_Finch.h"

#define BAR_HEIGHT 24
#define ITEM_HEIGHT 22
#define SEPARATOR_HEIGHT 11
#define HEADER_HEIGHT 20
#define V_PAD 5
#define STATE_WIDTH 22
#define NO_STATE_WIDTH 12
#define INDENT 10
#define RIGHT_PAD 14
#define KEY_GAP 24
#define ARROW_WIDTH 16
#define RADIUS 7
#define BAR_PAD 9
#define BAR_START 10

static NSColor *
accent(void)
{
    return [NSColor colorWithSRGBRed:0.16 green:0.44 blue:0.94 alpha:1];
}

static NSColor *
gray(CGFloat w)
{
    return [NSColor colorWithSRGBRed:w green:w blue:w alpha:1];
}

#pragma mark - Windows

@interface FinchMenuWindow : NSPanel
@end

@implementation FinchMenuWindow

- (instancetype)initWithFrame:(NSRect)frame level:(NSWindowLevel)level opaque:(BOOL)opaque
{
    self = [super initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered
                                defer:YES];
    if (!self)
        return nil;
    [self setLevel:level];
    [self setHidesOnDeactivate:NO];
    [self setExcludedFromWindowsMenu:YES];
    [self setOpaque:opaque];
    [self setHasShadow:!opaque];
    [self setBackgroundColor:opaque ? gray(0.96) : [NSColor clearColor]];
    return self;
}

- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (BOOL)worksWhenModal { return YES; }

@end

#pragma mark - A menu's rows

@interface FinchMenuView : NSView
- (instancetype)initWithMenu:(NSMenu *)menu font:(NSFont *)font minimumWidth:(CGFloat)width;
- (void)layoutRows;
- (NSSize)menuSize;
- (NSMenu *)menu;
- (NSInteger)rowCount;
- (NSMenuItem *)itemAtRow:(NSInteger)row;
- (NSRect)rectOfRow:(NSInteger)row;
- (NSInteger)rowAtPoint:(NSPoint)p;
- (NSInteger)rowOfItem:(NSMenuItem *)item;
- (NSInteger)highlightedRow;
- (void)setHighlightedRow:(NSInteger)row;
- (BOOL)isSelectableRow:(NSInteger)row;
@end

@implementation FinchMenuView {
    NSMenu *_menu;
    NSFont *_font;
    CGFloat _minimumWidth;
    NSMutableArray<NSMenuItem *> *_rows;
    NSMutableArray<NSValue *> *_rects;
    NSInteger _highlighted;
    NSSize _size;
    CGFloat _textX, _keyRight;
}

- (instancetype)initWithMenu:(NSMenu *)menu font:(NSFont *)font minimumWidth:(CGFloat)width
{
    self = [super initWithFrame:NSZeroRect];
    if (!self)
        return nil;
    _menu = [menu retain];
    _font = [font ?: [menu font] retain];
    _minimumWidth = width;
    _rows = [[NSMutableArray alloc] init];
    _rects = [[NSMutableArray alloc] init];
    _highlighted = -1;
    [self layoutRows];
    return self;
}

- (void)dealloc
{
    [_menu release];
    [_font release];
    [_rows release];
    [_rects release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSMenu *)menu { return _menu; }
- (NSSize)menuSize { return _size; }
- (NSInteger)rowCount { return (NSInteger)[_rows count]; }
- (NSMenuItem *)itemAtRow:(NSInteger)row { return row >= 0 && row < (NSInteger)[_rows count] ? _rows[row] : nil; }
- (NSRect)rectOfRow:(NSInteger)row { return [_rects[(NSUInteger)row] rectValue]; }
- (NSInteger)highlightedRow { return _highlighted; }

- (NSInteger)rowOfItem:(NSMenuItem *)item
{
    NSUInteger i = [_rows indexOfObjectIdenticalTo:item];
    return i == NSNotFound ? -1 : (NSInteger)i;
}

static NSDictionary *
text_attributes(NSFont *font, NSColor *color)
{
    return @{NSFontAttributeName : font, NSForegroundColorAttributeName : color};
}

static NSEventModifierFlags
current_modifiers(void)
{
    return [NSEvent modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                      NSEventModifierFlagControl | NSEventModifierFlagShift);
}

/* The rows: visible items, alternates in place of the item before them while their modifiers are down. */
- (void)layoutRows
{
    [_rows removeAllObjects];
    [_rects removeAllObjects];
    NSEventModifierFlags mods = current_modifiers();
    for (NSMenuItem *i in [_menu itemArray]) {
        if ([i isHidden])
            continue;
        if ([i isAlternate]) {
            NSEventModifierFlags m = [i keyEquivalentModifierMask] &
                                     (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                      NSEventModifierFlagControl | NSEventModifierFlagShift);
            if (m == mods && [_rows count] && ![[_rows lastObject] isAlternate])
                [_rows replaceObjectAtIndex:[_rows count] - 1 withObject:i];
            continue;
        }
        [_rows addObject:i];
    }
    BOOL images = NO;
    CGFloat maxTitle = 0, maxKey = 0, maxIndent = 0;
    BOOL submenus = NO;
    NSDictionary *attrs = text_attributes(_font, [NSColor blackColor]);
    for (NSMenuItem *i in _rows) {
        if ([i isSeparatorItem])
            continue;
        CGFloat w = [i attributedTitle] ? [[i attributedTitle] size].width : [[i title] sizeWithAttributes:attrs].width;
        maxTitle = MAX(maxTitle, w + [i indentationLevel] * INDENT);
        maxIndent = MAX(maxIndent, [i indentationLevel] * INDENT);
        maxKey = MAX(maxKey, [FinchMenuKeyEquivalentString(i) sizeWithAttributes:attrs].width);
        images |= [i image] != nil;
        submenus |= [i hasSubmenu];
    }
    _textX = ([_menu showsStateColumn] ? STATE_WIDTH : NO_STATE_WIDTH) + (images ? 22 : 0);
    CGFloat width = _textX + maxTitle + (maxKey > 0 ? KEY_GAP + maxKey : 0) + (submenus ? ARROW_WIDTH : 0) + RIGHT_PAD;
    width = ceil(MAX(MAX(width, 60), MAX(_minimumWidth, [_menu minimumWidth])));
    _keyRight = width - RIGHT_PAD - (submenus ? ARROW_WIDTH : 0);
    CGFloat y = V_PAD;
    for (NSMenuItem *i in _rows) {
        CGFloat h = [i isSeparatorItem] ? SEPARATOR_HEIGHT : [i isSectionHeader] ? HEADER_HEIGHT : ITEM_HEIGHT;
        if ([i view])
            h = NSHeight([[i view] frame]);
        [_rects addObject:[NSValue valueWithRect:NSMakeRect(0, y, width, h)]];
        y += h;
    }
    _size = NSMakeSize(width, y + V_PAD);
    if (_highlighted >= (NSInteger)[_rows count])
        _highlighted = -1;
    [self setFrameSize:_size];
    [self setNeedsDisplay:YES];
}

- (NSInteger)rowAtPoint:(NSPoint)p
{
    if (p.x < 0 || p.x >= _size.width)
        return -1;
    for (NSUInteger i = 0; i < [_rects count]; i++) {
        NSRect r = [_rects[i] rectValue];
        if (p.y >= NSMinY(r) && p.y < NSMaxY(r))
            return (NSInteger)i;
    }
    return -1;
}

- (BOOL)isSelectableRow:(NSInteger)row
{
    NSMenuItem *i = [self itemAtRow:row];
    return i && ![i isSeparatorItem] && ![i isSectionHeader] && [i isEnabled];
}

- (void)setHighlightedRow:(NSInteger)row
{
    if (![self isSelectableRow:row])
        row = -1;
    if (row == _highlighted)
        return;
    _highlighted = row;
    [_menu _finchSetHighlightedItem:[self itemAtRow:row]];
    [self setNeedsDisplay:YES];
}

static void
draw_check(NSRect r, NSColor *color)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    CGFloat x = NSMinX(r), y = NSMidY(r);
    [p moveToPoint:NSMakePoint(x + 7, y)];
    [p lineToPoint:NSMakePoint(x + 10, y + 3.5)];
    [p lineToPoint:NSMakePoint(x + 15.5, y - 4)];
    [p setLineWidth:1.8];
    [p setLineCapStyle:NSLineCapStyleRound];
    [p setLineJoinStyle:NSLineJoinStyleRound];
    [color setStroke];
    [p stroke];
}

static void
draw_arrow(CGFloat x, CGFloat midY, NSColor *color)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x, midY - 4)];
    [p lineToPoint:NSMakePoint(x + 4, midY)];
    [p lineToPoint:NSMakePoint(x, midY + 4)];
    [p setLineWidth:1.6];
    [p setLineCapStyle:NSLineCapStyleRound];
    [p setLineJoinStyle:NSLineJoinStyleRound];
    [color setStroke];
    [p stroke];
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = NSMakeRect(0, 0, _size.width, _size.height);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:RADIUS yRadius:RADIUS];
    [gray(0.97) setFill];
    [bg fill];
    [[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0.2] setStroke];
    [bg setLineWidth:1];
    [bg stroke];
    CGFloat lineHeight = ceil([_font ascender] - [_font descender]);
    for (NSInteger row = 0; row < (NSInteger)[_rows count]; row++) {
        NSMenuItem *item = _rows[(NSUInteger)row];
        NSRect r = [self rectOfRow:row];
        if ([item isSeparatorItem]) {
            [gray(0.84) setFill];
            NSRectFill(NSMakeRect(10, floor(NSMidY(r)), r.size.width - 20, 1));
            continue;
        }
        if ([item view])
            continue;
        BOOL enabled = [item isEnabled] && ![item isSectionHeader];
        BOOL lit = row == _highlighted && enabled;
        if (lit) {
            [accent() setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 5, 0) xRadius:4 yRadius:4] fill];
        }
        NSColor *color = lit ? [NSColor whiteColor] : enabled ? gray(0.1) : gray(0.62);
        NSFont *font = [item isSectionHeader] ? [NSFont boldSystemFontOfSize:[_font pointSize] - 2] : _font;
        CGFloat textY = NSMinY(r) + floor((r.size.height - lineHeight) / 2);
        /* the state column */
        NSImage *mark = [item state] == NSControlStateValueOn      ? [item onStateImage]
                        : [item state] == NSControlStateValueMixed ? [item mixedStateImage]
                                                                   : [item offStateImage];
        if (mark && [_menu showsStateColumn]) {
            NSRect col = NSMakeRect(2, NSMinY(r), STATE_WIDTH - 2, r.size.height);
            if (mark == [NSMenuItem _finchCheckmarkImage])
                draw_check(col, color);
            else if (mark == [NSMenuItem _finchMixedStateImage]) {
                [color setFill];
                NSRectFill(NSMakeRect(NSMinX(col) + 6, floor(NSMidY(col)) - 1, 9, 2));
            } else {
                NSSize s = [mark size];
                [mark drawInRect:NSMakeRect(NSMinX(col) + floor((col.size.width - MIN(s.width, 16)) / 2),
                                            floor(NSMidY(col) - MIN(s.height, 16) / 2), MIN(s.width, 16),
                                            MIN(s.height, 16))
                        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                  respectFlipped:YES hints:nil];
            }
        }
        CGFloat x = _textX + [item indentationLevel] * INDENT;
        if ([item image]) {
            NSSize s = [[item image] size];
            CGFloat w = MIN(s.width, 16), h = MIN(s.height, 16);
            [[item image] drawInRect:NSMakeRect(x - 22 + floor((16 - w) / 2), floor(NSMidY(r) - h / 2), w, h)
                            fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:enabled ? 1 : 0.5
                      respectFlipped:YES hints:nil];
        }
        if ([item attributedTitle] && !lit)
            [[item attributedTitle] drawAtPoint:NSMakePoint(x, textY)];
        else
            [[item title] drawAtPoint:NSMakePoint(x, textY) withAttributes:text_attributes(font, color)];
        NSString *key = FinchMenuKeyEquivalentString(item);
        if ([key length]) {
            NSDictionary *a = text_attributes(_font, lit ? color : enabled ? gray(0.45) : gray(0.68));
            CGFloat w = [key sizeWithAttributes:a].width;
            [key drawAtPoint:NSMakePoint(_keyRight - w, textY) withAttributes:a];
        }
        if ([item hasSubmenu])
            draw_arrow(r.size.width - RIGHT_PAD - 4, NSMidY(r), color);
    }
}

@end

NSSize
FinchMenuSize(NSMenu *menu)
{
    FinchMenuView *v = [[FinchMenuView alloc] initWithMenu:menu font:nil minimumWidth:0];
    NSSize s = [v menuSize];
    [v release];
    return s;
}

#pragma mark - The menu bar

@interface FinchMenuBarView : NSView
- (NSInteger)titleCount;
- (NSMenuItem *)itemAtTitle:(NSInteger)index;
- (NSRect)rectOfTitle:(NSInteger)index;
- (NSInteger)titleAtPoint:(NSPoint)p;  /* view coordinates */
- (NSInteger)titleOfItem:(NSMenuItem *)item;
- (void)setHighlightedTitle:(NSInteger)index;
@end

static FinchMenuWindow *bar_window;
static FinchMenuBarView *bar_view;
static NSMenu *bar_menu;  /* the menu observed */
static BOOL launched;

@interface FinchMenuTracker : NSObject
- (NSMenuItem *)trackBar:(FinchMenuBarView *)bar title:(NSInteger)title event:(NSEvent *)event;
- (NSMenuItem *)trackPopUp:(NSMenu *)menu item:(NSMenuItem *)item at:(NSPoint)p font:(NSFont *)font
              minimumWidth:(CGFloat)width event:(NSEvent *)event;
- (void)cancel;
@end

static FinchMenuTracker *tracking;

static NSString *
app_name(void)
{
    NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    return [name length] ? name : [[NSProcessInfo processInfo] processName];
}

@implementation FinchMenuBarView {
    NSMutableArray<NSMenuItem *> *_items;
    NSMutableArray<NSValue *> *_rects;
    NSInteger _highlighted;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _items = [[NSMutableArray alloc] init];
        _rects = [[NSMutableArray alloc] init];
        _highlighted = -1;
    }
    return self;
}

- (void)dealloc
{
    [_items release];
    [_rects release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSInteger)titleCount { return (NSInteger)[_items count]; }
- (NSMenuItem *)itemAtTitle:(NSInteger)i { return i >= 0 && i < (NSInteger)[_items count] ? _items[i] : nil; }
- (NSRect)rectOfTitle:(NSInteger)i { return [_rects[(NSUInteger)i] rectValue]; }

- (NSInteger)titleOfItem:(NSMenuItem *)item
{
    NSUInteger i = [_items indexOfObjectIdenticalTo:item];
    return i == NSNotFound ? -1 : (NSInteger)i;
}

static NSFont *
bar_font(BOOL bold)
{
    return bold ? [NSFont boldSystemFontOfSize:13] : [NSFont menuBarFontOfSize:0];
}

- (NSString *)titleFor:(NSInteger)i
{
    return i == 0 ? app_name() : [_items[(NSUInteger)i] title];
}

- (void)layoutTitles
{
    [_items removeAllObjects];
    [_rects removeAllObjects];
    CGFloat x = BAR_START;
    NSArray *all = [[NSApp mainMenu] itemArray];
    for (NSUInteger n = 0; n < [all count]; n++) {
        NSMenuItem *i = all[n];
        if ([i isHidden] || [i isSeparatorItem])
            continue;
        [_items addObject:i];
        NSInteger index = (NSInteger)[_items count] - 1;
        CGFloat w = [[self titleFor:index] sizeWithAttributes:@{NSFontAttributeName : bar_font(index == 0)}].width;
        w = ceil(w) + 2 * BAR_PAD;
        [_rects addObject:[NSValue valueWithRect:NSMakeRect(x, 0, w, BAR_HEIGHT)]];
        x += w;
    }
}

- (NSInteger)titleAtPoint:(NSPoint)p
{
    if (p.y < 0 || p.y >= BAR_HEIGHT)
        return -1;
    for (NSUInteger i = 0; i < [_rects count]; i++)
        if (p.x >= NSMinX([_rects[i] rectValue]) && p.x < NSMaxX([_rects[i] rectValue]))
            return (NSInteger)i;
    return -1;
}

- (void)setHighlightedTitle:(NSInteger)index
{
    if (index == _highlighted)
        return;
    _highlighted = index;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    [gray(0.96) setFill];
    NSRectFill(b);
    [gray(0.80) setFill];
    NSRectFill(NSMakeRect(0, NSMaxY(b) - 1, b.size.width, 1));
    NSFont *font = bar_font(NO);
    CGFloat lineHeight = ceil([font ascender] - [font descender]);
    for (NSInteger i = 0; i < (NSInteger)[_items count]; i++) {
        NSRect r = [self rectOfTitle:i];
        BOOL lit = i == _highlighted;
        if (lit) {
            [accent() setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 3) xRadius:5 yRadius:5] fill];
        }
        BOOL enabled = [_items[(NSUInteger)i] isEnabled];
        NSColor *color = lit ? [NSColor whiteColor] : enabled ? gray(0.1) : gray(0.62);
        [[self titleFor:i] drawAtPoint:NSMakePoint(NSMinX(r) + BAR_PAD, floor((BAR_HEIGHT - lineHeight) / 2))
                        withAttributes:text_attributes(bar_font(i == 0), color)];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger t = [self titleAtPoint:p];
    if (t < 0 || tracking)
        return;
    FinchMenuTracker *tracker = [[FinchMenuTracker alloc] init];
    [tracker trackBar:self title:t event:event];
    [tracker release];
}

@end

static void
bar_menu_changed(void)
{
    [bar_view layoutTitles];
    [bar_view setNeedsDisplay:YES];
}

static void
observe_bar_menu(NSMenu *menu)
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    static id observers[3];
    if (bar_menu == menu)
        return;
    for (int i = 0; i < 3; i++) {
        if (observers[i])
            [nc removeObserver:observers[i]];
        [observers[i] release];
        observers[i] = nil;
    }
    [bar_menu release];
    bar_menu = [menu retain];
    if (!menu)
        return;
    NSString *names[3] = {NSMenuDidAddItemNotification, NSMenuDidRemoveItemNotification, NSMenuDidChangeItemNotification};
    for (int i = 0; i < 3; i++)
        observers[i] = [[nc addObserverForName:names[i] object:menu queue:nil
                                    usingBlock:^(NSNotification *n) {
                                        bar_menu_changed();
                                    }] retain];
}

static void
activation_changed(void)
{
    static BOOL observing;
    if (observing)
        return;
    observing = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[ NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification ])
        [nc addObserverForName:name object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
                        FinchMenuBarUpdate();
                    }];
}

void
FinchMenuBarUpdate(void)
{
    if (!launched)
        return;
    NSMenu *menu = [NSApp mainMenu];
    BOOL show = menu && [NSMenu menuBarVisible] && [NSApp isActive] &&
                [NSApp activationPolicy] == NSApplicationActivationPolicyRegular && FWSConnect();
    observe_bar_menu(show ? menu : nil);
    if (!show) {
        [bar_window orderOut:nil];
        return;
    }
    NSRect screen = [[NSScreen mainScreen] frame];
    NSRect frame = NSMakeRect(NSMinX(screen), NSMaxY(screen) - BAR_HEIGHT, screen.size.width, BAR_HEIGHT);
    if (!bar_window) {
        bar_window = [[FinchMenuWindow alloc] initWithFrame:frame level:NSMainMenuWindowLevel opaque:YES];
        bar_view = [[FinchMenuBarView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        [bar_window setContentView:bar_view];
        [bar_view release];
    } else if (!NSEqualRects([bar_window frame], frame)) {
        [bar_window setFrame:frame display:NO];
    }
    bar_menu_changed();
    [bar_window orderFront:nil];
}

void
FinchMenuBarDidLaunch(void)
{
    launched = YES;
    activation_changed();
    FinchMenuBarUpdate();
}

#pragma mark - Tracking

@implementation FinchMenuTracker {
    NSMenu *_root;
    FinchMenuBarView *_bar;
    NSInteger _barTitle;
    NSMutableArray<FinchMenuWindow *> *_stack;
    NSFont *_font;
    NSMenuItem *_chosen;
    BOOL _done, _sticky, _moved, _keyboard;
    NSTimeInterval _start;
    NSPoint _startPoint;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _stack = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc
{
    [_stack release];
    [_font release];
    [super dealloc];
}

static FinchMenuView *
view_of(FinchMenuWindow *w)
{
    return (FinchMenuView *)[w contentView];
}

/* Opens a menu with its top left (or a row's top left) at a screen point. */
- (FinchMenuWindow *)open:(NSMenu *)menu at:(NSPoint)p row:(NSMenuItem *)item minimumWidth:(CGFloat)width
                   fromLeft:(CGFloat)leftEdge
{
    [menu _finchPrepareToOpen];
    id d = [menu delegate];
    if ([d respondsToSelector:@selector(menuWillOpen:)])
        [d menuWillOpen:menu];
    FinchMenuView *v = [[FinchMenuView alloc] initWithMenu:menu font:_font minimumWidth:width];
    NSSize s = [v menuSize];
    NSRect f = NSMakeRect(p.x, p.y - s.height, s.width, s.height);
    NSInteger row = item ? [v rowOfItem:item] : -1;
    if (row >= 0) {
        NSRect r = [v rectOfRow:row];
        f.origin.y += NSMinY(r);
    }
    NSRect screen = [[NSScreen mainScreen] frame];
    NSRect visible = [[NSScreen mainScreen] visibleFrame];
    if (NSMaxX(f) > NSMaxX(screen))
        f.origin.x = leftEdge >= 0 ? leftEdge - s.width : NSMaxX(screen) - s.width;
    f.origin.x = MAX(f.origin.x, NSMinX(screen));
    if (NSMaxY(f) > NSMaxY(visible))
        f.origin.y = NSMaxY(visible) - s.height;
    if (f.origin.y < NSMinY(screen))
        f.origin.y = NSMinY(screen);
    FinchMenuWindow *w = [[FinchMenuWindow alloc] initWithFrame:f level:NSPopUpMenuWindowLevel opaque:NO];
    [w setContentView:v];
    [v release];
    if (row >= 0)
        [v setHighlightedRow:row];
    [w orderFront:nil];
    [_stack addObject:w];
    [w release];
    return w;
}

- (void)closeFrom:(NSUInteger)level
{
    while ([_stack count] > level) {
        FinchMenuWindow *w = [[_stack lastObject] retain];
        [_stack removeLastObject];
        NSMenu *menu = [view_of(w) menu];
        [view_of(w) setHighlightedRow:-1];
        [w orderOut:nil];
        id d = [menu delegate];
        if ([d respondsToSelector:@selector(menuDidClose:)])
            [d menuDidClose:menu];
        [w release];
    }
    if (level > 0)
        [view_of(_stack[level - 1]) setNeedsDisplay:YES];
}

- (void)openBarTitle:(NSInteger)t
{
    [self closeFrom:0];
    _barTitle = t;
    [_bar setHighlightedTitle:t];
    NSMenu *sub = [[_bar itemAtTitle:t] submenu];
    if (!sub)
        return;
    NSRect r = [_bar rectOfTitle:t];
    NSRect inScreen = [[_bar window] convertRectToScreen:[_bar convertRect:r toView:nil]];
    [self open:sub at:NSMakePoint(NSMinX(inScreen), NSMinY(inScreen)) row:nil minimumWidth:0 fromLeft:-1];
}

/* The submenu of the highlighted row in a level, opened beside it. */
- (void)openSubmenuOfLevel:(NSUInteger)level selectFirst:(BOOL)first
{
    FinchMenuWindow *w = _stack[level];
    FinchMenuView *v = view_of(w);
    NSInteger row = [v highlightedRow];
    NSMenuItem *item = [v itemAtRow:row];
    if (![item hasSubmenu])
        return;
    if ([_stack count] > level + 1 && [view_of(_stack[level + 1]) menu] == [item submenu])
        return;
    [self closeFrom:level + 1];
    NSRect r = [v rectOfRow:row];
    NSRect inScreen = [w convertRectToScreen:[v convertRect:r toView:nil]];
    FinchMenuWindow *sub = [self open:[item submenu] at:NSMakePoint(NSMaxX([w frame]) - 4, NSMaxY(inScreen) + V_PAD)
                                  row:nil minimumWidth:0 fromLeft:NSMinX([w frame]) + 4];
    if (first)
        [self moveIn:view_of(sub) by:1];
}

- (void)moveIn:(FinchMenuView *)v by:(NSInteger)step
{
    NSInteger n = [v rowCount], row = [v highlightedRow];
    if (row < 0)
        row = step > 0 ? -1 : n;
    for (NSInteger r = row + step; r >= 0 && r < n; r += step)
        if ([v isSelectableRow:r]) {
            [v setHighlightedRow:r];
            return;
        }
}

/* Where a screen point is: a level and its row, or the bar's title. */
- (NSInteger)levelAt:(NSPoint)p row:(NSInteger *)row
{
    for (NSInteger k = (NSInteger)[_stack count] - 1; k >= 0; k--) {
        FinchMenuWindow *w = _stack[(NSUInteger)k];
        if (NSPointInRect(p, [w frame])) {
            FinchMenuView *v = view_of(w);
            *row = [v rowAtPoint:[v convertPoint:[w convertPointFromScreen:p] fromView:nil]];
            return k;
        }
    }
    *row = -1;
    return -1;
}

- (NSInteger)barTitleAt:(NSPoint)p
{
    if (!_bar || !NSPointInRect(p, [[_bar window] frame]))
        return -1;
    return [_bar titleAtPoint:[_bar convertPoint:[[_bar window] convertPointFromScreen:p] fromView:nil]];
}

- (void)choose:(NSMenuItem *)item
{
    _chosen = item;
    _done = YES;
}

- (void)pointerAt:(NSPoint)p
{
    NSInteger row, k = [self levelAt:p row:&row];
    if (k >= 0) {
        FinchMenuView *v = view_of(_stack[(NSUInteger)k]);
        NSMenuItem *item = [v itemAtRow:row];
        BOOL keepsChild = [_stack count] > (NSUInteger)k + 1 && [item submenu] &&
                          [view_of(_stack[(NSUInteger)k + 1]) menu] == [item submenu];
        if (!keepsChild)
            [self closeFrom:(NSUInteger)k + 1];
        [v setHighlightedRow:row];
        if ([v highlightedRow] == row && [item hasSubmenu])
            [self openSubmenuOfLevel:(NSUInteger)k selectFirst:NO];
        return;
    }
    NSInteger t = [self barTitleAt:p];
    if (t >= 0) {
        if (t != _barTitle)
            [self openBarTitle:t];
        return;
    }
    /* outside: no row lit in the deepest menu, unless it opened the menu after it */
    if ([_stack count])
        [view_of([_stack lastObject]) setHighlightedRow:-1];
}

- (void)mouseUpAt:(NSPoint)p
{
    NSInteger row, k = [self levelAt:p row:&row];
    NSMenuItem *item = k >= 0 ? [view_of(_stack[(NSUInteger)k]) itemAtRow:row] : nil;
    if (item && [view_of(_stack[(NSUInteger)k]) isSelectableRow:row] && ![item hasSubmenu]) {
        if (_sticky || _moved) {
            [self choose:item];
            return;
        }
    }
    if (_sticky)
        return;
    if ([self barTitleAt:p] >= 0 || item || !_moved) {
        _sticky = YES;  /* a click: the menu stays open */
        return;
    }
    _done = YES;
}

- (void)mouseDownAt:(NSPoint)p
{
    NSInteger row, k = [self levelAt:p row:&row];
    if (k >= 0) {
        [self pointerAt:p];
        return;
    }
    NSInteger t = [self barTitleAt:p];
    if (t >= 0) {
        if (t == _barTitle) {
            _done = YES;
            return;
        }
        [self openBarTitle:t];
        return;
    }
    _done = YES;
}

- (void)key:(NSEvent *)e
{
    NSString *chars = [e charactersIgnoringModifiers];
    if (![chars length])
        return;
    unichar c = [chars characterAtIndex:0];
    _keyboard = YES;
    _sticky = YES;
    FinchMenuView *top = [_stack count] ? view_of([_stack lastObject]) : nil;
    switch (c) {
    case 0x1b:
        _done = YES;
        break;
    case '\r':
    case 3:
    case ' ': {
        NSMenuItem *item = [top itemAtRow:[top highlightedRow]];
        if ([item hasSubmenu])
            [self openSubmenuOfLevel:[_stack count] - 1 selectFirst:YES];
        else if (item)
            [self choose:item];
        else if (c != ' ')
            _done = YES;
        break;
    }
    case NSDownArrowFunctionKey:
        [self moveIn:top by:1];
        break;
    case NSUpArrowFunctionKey:
        [self moveIn:top by:-1];
        break;
    case NSRightArrowFunctionKey:
        if ([[top itemAtRow:[top highlightedRow]] hasSubmenu])
            [self openSubmenuOfLevel:[_stack count] - 1 selectFirst:YES];
        else if (_bar && [_bar titleCount])
            [self openBarTitle:(_barTitle + 1) % [_bar titleCount]];
        break;
    case NSLeftArrowFunctionKey:
        if ([_stack count] > 1)
            [self closeFrom:[_stack count] - 1];
        else if (_bar && [_bar titleCount])
            [self openBarTitle:(_barTitle + [_bar titleCount] - 1) % [_bar titleCount]];
        break;
    }
}

- (void)relayout
{
    for (FinchMenuWindow *w in _stack) {
        FinchMenuView *v = view_of(w);
        NSRect f = [w frame];
        [v layoutRows];
        NSSize s = [v menuSize];
        [w setFrame:NSMakeRect(NSMinX(f), NSMaxY(f) - s.height, s.width, s.height) display:YES];
    }
}

- (void)run
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:NSMenuDidBeginTrackingNotification object:_root];
    tracking = self;
    [NSApp updateWindows];
    while (!_done) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantFuture]
                                           inMode:NSEventTrackingRunLoopMode dequeue:YES];
        if (e && !_done) {
            NSPoint p = FinchEventScreenLocation(e);
            switch ([e type]) {
            case NSEventTypeMouseMoved:
            case NSEventTypeLeftMouseDragged:
            case NSEventTypeRightMouseDragged:
            case NSEventTypeOtherMouseDragged:
                if (fabs(p.x - _startPoint.x) > 3 || fabs(p.y - _startPoint.y) > 3)
                    _moved = YES;
                [self pointerAt:p];
                break;
            case NSEventTypeLeftMouseDown:
            case NSEventTypeRightMouseDown:
            case NSEventTypeOtherMouseDown:
                _start = [NSDate timeIntervalSinceReferenceDate];
                _startPoint = p;
                _moved = NO;
                [self mouseDownAt:p];
                break;
            case NSEventTypeLeftMouseUp:
            case NSEventTypeRightMouseUp:
            case NSEventTypeOtherMouseUp:
                [self mouseUpAt:p];
                break;
            case NSEventTypeKeyDown:
                [self key:e];
                break;
            case NSEventTypeFlagsChanged:
                [self relayout];
                break;
            default:
                break;
            }
        }
        [NSApp updateWindows];
        [pool drain];
    }
    tracking = nil;
    [self closeFrom:0];
    [_bar setHighlightedTitle:-1];
    [NSApp updateWindows];
    [nc postNotificationName:NSMenuDidEndTrackingNotification object:_root];
}

- (NSMenuItem *)trackBar:(FinchMenuBarView *)bar title:(NSInteger)title event:(NSEvent *)event
{
    _bar = bar;
    _root = [NSApp mainMenu];
    _start = [NSDate timeIntervalSinceReferenceDate];
    _startPoint = FinchEventScreenLocation(event);
    [self openBarTitle:title];
    if (![[bar itemAtTitle:title] submenu]) {
        [bar setHighlightedTitle:-1];
        [_root _finchSendActionForItem:[bar itemAtTitle:title]];
        return nil;
    }
    [self run];
    NSMenuItem *chosen = _chosen;
    if (chosen)
        [[chosen menu] _finchSendActionForItem:chosen];
    return chosen;
}

- (NSMenuItem *)trackPopUp:(NSMenu *)menu item:(NSMenuItem *)item at:(NSPoint)p font:(NSFont *)font
              minimumWidth:(CGFloat)width event:(NSEvent *)event
{
    _root = menu;
    _font = [font retain];
    _start = [NSDate timeIntervalSinceReferenceDate];
    _startPoint = p;
    /* opened without a button down (from code or the keyboard): clicks choose */
    NSEventType type = [event type];
    _sticky = !event || !(type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown ||
                          type == NSEventTypeOtherMouseDown);
    [self open:menu at:p row:item minimumWidth:width fromLeft:-1];
    [self run];
    return _chosen;
}

- (void)cancel
{
    _done = YES;
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                       timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0]
             atStart:NO];
}

@end

NSMenuItem *
FinchMenuPopUp(NSMenu *menu, NSMenuItem *positioningItem, NSPoint screenPoint, NSView *view, NSEvent *event,
               CGFloat minimumWidth, NSFont *font, BOOL sendAction)
{
    if (tracking || !menu || !FWSConnect())
        return nil;
    FinchMenuTracker *t = [[FinchMenuTracker alloc] init];
    NSMenuItem *chosen = [[t trackPopUp:menu item:positioningItem at:screenPoint font:font minimumWidth:minimumWidth
                                  event:event] retain];
    [t release];
    if (chosen && sendAction)
        [[chosen menu] _finchSendActionForItem:chosen];
    return [chosen autorelease];
}

void
FinchMenuCancelTracking(BOOL animate)
{
    [tracking cancel];
}
