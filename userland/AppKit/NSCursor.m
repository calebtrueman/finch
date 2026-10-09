/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSCursor: the pointer's shape. The standard cursors are the window
 * server's shapes (it draws them, in Finch's look); custom ones carry an
 * image. Archived as Apple's are: a type code (NSCursorType) and hot spot.
 */
#import "NSView_Finch.h"

/* Apple's archive type codes, and the hot spots its standard cursors report. */
typedef struct {
    int type;
    int32_t shape;
    CGFloat hx, hy;
} Standard;

enum {
    ARROW = 0, IBEAM = 1, DRAG_LINK = 2, NOT_ALLOWED = 3, DRAG_COPY = 5, CLOSED_HAND = 11, OPEN_HAND = 12,
    POINTING_HAND = 13, RESIZE_LEFT = 17, RESIZE_RIGHT = 18, RESIZE_LEFT_RIGHT = 19, CROSSHAIR = 20,
    RESIZE_UP = 21, RESIZE_DOWN = 22, RESIZE_UP_DOWN = 23, CONTEXTUAL_MENU = 24, DISAPPEARING = 25,
    IBEAM_VERTICAL = 26, CUSTOM = -1,
};

static const Standard standards[] = {
    {ARROW, FWS_CURSOR_ARROW, 5, 5},
    {IBEAM, FWS_CURSOR_IBEAM, 12, 11},
    {DRAG_LINK, FWS_CURSOR_ARROW, 11, 3},
    {NOT_ALLOWED, FWS_CURSOR_ARROW, 5, 5},
    {DRAG_COPY, FWS_CURSOR_ARROW, 5, 5},
    {CLOSED_HAND, FWS_CURSOR_CLOSED_HAND, 16, 17},
    {OPEN_HAND, FWS_CURSOR_OPEN_HAND, 16, 17},
    {POINTING_HAND, FWS_CURSOR_POINTING_HAND, 13, 8},
    {RESIZE_LEFT, FWS_CURSOR_RESIZE_LEFT_RIGHT, 12, 12},
    {RESIZE_RIGHT, FWS_CURSOR_RESIZE_LEFT_RIGHT, 12, 12},
    {RESIZE_LEFT_RIGHT, FWS_CURSOR_RESIZE_LEFT_RIGHT, 15, 12},
    {CROSSHAIR, FWS_CURSOR_CROSSHAIR, 11, 11},
    {RESIZE_UP, FWS_CURSOR_RESIZE_UP_DOWN, 12, 13},
    {RESIZE_DOWN, FWS_CURSOR_RESIZE_UP_DOWN, 12, 11},
    {RESIZE_UP_DOWN, FWS_CURSOR_RESIZE_UP_DOWN, 12, 14},
    {CONTEXTUAL_MENU, FWS_CURSOR_ARROW, 5, 5},
    {DISAPPEARING, FWS_CURSOR_ARROW, 5, 5},
    {IBEAM_VERTICAL, FWS_CURSOR_IBEAM, 11, 10},
};

@implementation NSCursor {
    int _type;
    NSImage *_image;
    NSPoint _hotSpot;
}

static NSMutableArray<NSCursor *> *stack;
static NSCursor *current;
static NSInteger hide_count;

static NSCursor *
standard(int type)
{
    static NSMutableDictionary *made;
    if (!made)
        made = [[NSMutableDictionary alloc] init];
    NSCursor *c = made[@(type)];
    if (!c) {
        c = [[[NSCursor alloc] init] autorelease];
        c->_type = type;
        for (size_t i = 0; i < sizeof standards / sizeof *standards; i++)
            if (standards[i].type == type)
                c->_hotSpot = NSMakePoint(standards[i].hx, standards[i].hy);
        made[@(type)] = c;
    }
    return c;
}

+ (NSCursor *)arrowCursor { return standard(ARROW); }
+ (NSCursor *)IBeamCursor { return standard(IBEAM); }
+ (NSCursor *)dragLinkCursor { return standard(DRAG_LINK); }
+ (NSCursor *)operationNotAllowedCursor { return standard(NOT_ALLOWED); }
+ (NSCursor *)dragCopyCursor { return standard(DRAG_COPY); }
+ (NSCursor *)closedHandCursor { return standard(CLOSED_HAND); }
+ (NSCursor *)openHandCursor { return standard(OPEN_HAND); }
+ (NSCursor *)pointingHandCursor { return standard(POINTING_HAND); }
+ (NSCursor *)resizeLeftCursor { return standard(RESIZE_LEFT); }
+ (NSCursor *)resizeRightCursor { return standard(RESIZE_RIGHT); }
+ (NSCursor *)resizeLeftRightCursor { return standard(RESIZE_LEFT_RIGHT); }
+ (NSCursor *)crosshairCursor { return standard(CROSSHAIR); }
+ (NSCursor *)resizeUpCursor { return standard(RESIZE_UP); }
+ (NSCursor *)resizeDownCursor { return standard(RESIZE_DOWN); }
+ (NSCursor *)resizeUpDownCursor { return standard(RESIZE_UP_DOWN); }
+ (NSCursor *)contextualMenuCursor { return standard(CONTEXTUAL_MENU); }
+ (NSCursor *)disappearingItemCursor { return standard(DISAPPEARING); }
+ (NSCursor *)IBeamCursorForVerticalLayout { return standard(IBEAM_VERTICAL); }

+ (NSCursor *)currentCursor { return current ?: [self arrowCursor]; }
+ (NSCursor *)currentSystemCursor { return [self currentCursor]; }

- (instancetype)init
{
    self = [super init];
    if (self)
        _type = CUSTOM;
    return self;
}

- (instancetype)initWithImage:(NSImage *)image hotSpot:(NSPoint)hotSpot
{
    self = [super init];
    if (self) {
        _type = CUSTOM;
        _image = [image retain];
        _hotSpot = hotSpot;
    }
    return self;
}

- (instancetype)initWithImage:(NSImage *)image foregroundColorHint:(NSColor *)fg backgroundColorHint:(NSColor *)bg
                      hotSpot:(NSPoint)hotSpot
{
    return [self initWithImage:image hotSpot:hotSpot];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    int type = [coder containsValueForKey:@"NSCursorType"] ? [coder decodeIntForKey:@"NSCursorType"] : CUSTOM;
    for (size_t i = 0; i < sizeof standards / sizeof *standards; i++)
        if (standards[i].type == type) {
            [self release];
            return [standard(type) retain];
        }
    NSImage *image = [coder decodeObjectForKey:@"NSImage"];
    NSPoint hot = [coder decodeObjectForKey:@"NSHotSpot"] ? [[coder decodeObjectForKey:@"NSHotSpot"] pointValue]
                                                           : NSZeroPoint;
    return [self initWithImage:image hotSpot:hot];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:_type forKey:@"NSCursorType"];
    [coder encodeObject:[NSValue valueWithPoint:_hotSpot] forKey:@"NSHotSpot"];
    if (_image)
        [coder encodeObject:_image forKey:@"NSImage"];
}

- (void)dealloc
{
    [_image release];
    [super dealloc];
}

- (NSImage *)image { return _image; }
- (NSPoint)hotSpot { return _hotSpot; }

/* Tell the window server: standard cursors by shape; custom ones show as the arrow for now. */
- (void)set
{
    [current autorelease];
    current = [self retain];
    int32_t shape = FWS_CURSOR_ARROW;
    for (size_t i = 0; i < sizeof standards / sizeof *standards; i++)
        if (standards[i].type == _type)
            shape = standards[i].shape;
    FWSSetCursorShape(shape);
}

- (void)push
{
    if (!stack)
        stack = [[NSMutableArray alloc] init];
    [stack addObject:[NSCursor currentCursor]];
    [self set];
}

- (void)pop
{
    [NSCursor pop];
}

+ (void)pop
{
    NSCursor *c = [stack lastObject];
    if (!c)
        return;
    [[c retain] autorelease];
    [stack removeLastObject];
    [c set];
}

+ (void)hide
{
    if (hide_count++ == 0)
        FWSSetCursorVisible(false);
}

+ (void)unhide
{
    if (hide_count > 0 && --hide_count == 0)
        FWSSetCursorVisible(true);
}

+ (void)setHiddenUntilMouseMoves:(BOOL)flag
{
    if (flag)
        FWSSetCursorVisible(false);
}

- (void)setOnMouseEntered:(BOOL)flag {}
- (void)setOnMouseExited:(BOOL)flag {}
- (BOOL)isSetOnMouseEntered { return NO; }
- (BOOL)isSetOnMouseExited { return NO; }
- (void)mouseEntered:(NSEvent *)event { [self set]; }
- (void)mouseExited:(NSEvent *)event { [[NSCursor arrowCursor] set]; }

@end
