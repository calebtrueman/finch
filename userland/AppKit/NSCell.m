/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSCell: the state, value and drawing of a control's content, shared by
 * every control. Behaviour follows Apple's as measured by
 * finch-appkit-controls-test (values and their conversions, the state
 * cycle, which setters imply which); the archive flags are in
 * NSControl_Finch.h. Drawing is Finch's own flat look (NSControlDrawing in
 * this file), never Apple's artwork.
 */
#import "NSControl_Finch.h"

#pragma mark - Finch's look

NSColor *
FinchAccentColor(void)
{
    return [NSColor colorWithSRGBRed:0.16 green:0.47 blue:0.96 alpha:1];
}

NSColor *
FinchControlFill(BOOL pressed)
{
    return pressed ? [NSColor colorWithSRGBRed:0.84 green:0.85 blue:0.87 alpha:1]
                   : [NSColor colorWithSRGBRed:0.985 green:0.985 blue:0.99 alpha:1];
}

NSColor *
FinchControlStroke(void)
{
    return [NSColor colorWithSRGBRed:0.70 green:0.71 blue:0.74 alpha:1];
}

NSColor *
FinchDisabled(NSColor *color, BOOL enabled)
{
    return enabled ? color : [color colorWithAlphaComponent:[color alphaComponent] * 0.45];
}

void
FinchDrawBezel(NSRect rect, CGFloat radius, NSColor *fill, NSColor *stroke)
{
    NSRect r = NSInsetRect(rect, 0.5, 0.5);
    if (r.size.width <= 0 || r.size.height <= 0)
        return;
    radius = MIN(radius, MIN(r.size.width, r.size.height) / 2);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
    if (fill) {
        [fill setFill];
        [p fill];
    }
    if (stroke) {
        [stroke setStroke];
        [p setLineWidth:1];
        [p stroke];
    }
}

/* The 14-point glyph box centred in box. */
static NSRect
glyph_box(NSRect box)
{
    CGFloat s = MIN(14, MIN(box.size.width, box.size.height));
    return NSMakeRect(floor(NSMidX(box) - s / 2), floor(NSMidY(box) - s / 2), s, s);
}

void
FinchDrawCheckbox(NSRect box, NSControlStateValue state, BOOL pressed, BOOL enabled)
{
    NSRect g = glyph_box(box);
    BOOL on = state != NSControlStateValueOff;
    NSColor *fill = on ? FinchAccentColor() : FinchControlFill(pressed);
    if (on && pressed)
        fill = [fill blendedColorWithFraction:0.2 ofColor:[NSColor blackColor]];
    FinchDrawBezel(g, 3.5, FinchDisabled(fill, enabled), on ? nil : FinchDisabled(FinchControlStroke(), enabled));
    if (!on)
        return;
    NSBezierPath *mark = [NSBezierPath bezierPath];
    [mark setLineWidth:2];
    [mark setLineCapStyle:NSLineCapStyleRound];
    [mark setLineJoinStyle:NSLineJoinStyleRound];
    CGFloat x = g.origin.x, y = g.origin.y, s = g.size.width;
    BOOL flipped = [[NSGraphicsContext currentContext] isFlipped];
    if (state == NSControlStateValueMixed) {
        [mark moveToPoint:NSMakePoint(x + s * 0.27, y + s / 2)];
        [mark lineToPoint:NSMakePoint(x + s * 0.73, y + s / 2)];
    } else {
        CGFloat (^Y)(CGFloat) = ^CGFloat(CGFloat f) { return flipped ? y + s * (1 - f) : y + s * f; };
        [mark moveToPoint:NSMakePoint(x + s * 0.25, Y(0.52))];
        [mark lineToPoint:NSMakePoint(x + s * 0.43, Y(0.33))];
        [mark lineToPoint:NSMakePoint(x + s * 0.76, Y(0.70))];
    }
    [FinchDisabled([NSColor whiteColor], enabled) setStroke];
    [mark stroke];
}

void
FinchDrawRadio(NSRect box, NSControlStateValue state, BOOL pressed, BOOL enabled)
{
    NSRect g = glyph_box(box);
    BOOL on = state != NSControlStateValueOff;
    NSColor *fill = on ? FinchAccentColor() : FinchControlFill(pressed);
    if (on && pressed)
        fill = [fill blendedColorWithFraction:0.2 ofColor:[NSColor blackColor]];
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(g, 0.5, 0.5)];
    [FinchDisabled(fill, enabled) setFill];
    [circle fill];
    if (!on) {
        [FinchDisabled(FinchControlStroke(), enabled) setStroke];
        [circle setLineWidth:1];
        [circle stroke];
        return;
    }
    [FinchDisabled([NSColor whiteColor], enabled) setFill];
    CGFloat d = g.size.width * 0.38;
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(g) - d / 2, NSMidY(g) - d / 2, d, d)] fill];
}

NSSize
FinchCellTextSize(NSAttributedString *text, CGFloat width)
{
    if (![text length]) {
        NSFont *f = nil;
        NSDictionary *a = nil;
        (void)a;
        f = [NSFont systemFontOfSize:0];
        NSAttributedString *probe = [[NSAttributedString alloc] initWithString:@" "
                                                                    attributes:@{NSFontAttributeName : f}];
        NSSize s = [probe size];
        [probe release];
        return NSMakeSize(0, ceil(s.height));
    }
    NSRect r = [text boundingRectWithSize:NSMakeSize(width > 0 ? width : 1e7, 1e7)
                                  options:width > 0 ? NSStringDrawingUsesLineFragmentOrigin : 0];
    if (width <= 0) {
        NSSize s = [text size];
        return NSMakeSize(ceil(s.width), ceil(s.height));
    }
    return NSMakeSize(ceil(r.size.width), ceil(r.size.height));
}

void
FinchDrawCellText(NSAttributedString *text, NSRect rect, BOOL flipped)
{
    if (![text length])
        return;
    NSSize s = [text boundingRectWithSize:NSMakeSize(rect.size.width, 1e7)
                                  options:NSStringDrawingUsesLineFragmentOrigin].size;
    CGFloat h = MIN(ceil(s.height), rect.size.height + 1);
    NSRect r = rect;
    r.origin.y += floor((rect.size.height - h) / 2);
    r.size.height = h;
    [text drawWithRect:r options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
}

void
FinchDrawImageInRect(NSImage *image, NSRect rect, NSImageScaling scaling, NSImageAlignment align, BOOL flipped,
                     CGFloat alpha)
{
    if (!image || NSIsEmptyRect(rect))
        return;
    NSSize is = [image size];
    if (is.width <= 0 || is.height <= 0)
        return;
    NSSize d = is;
    switch (scaling) {
    case NSImageScaleAxesIndependently:
        d = rect.size;
        break;
    case NSImageScaleProportionallyDown:
    case NSImageScaleProportionallyUpOrDown: {
        CGFloat k = MIN(rect.size.width / is.width, rect.size.height / is.height);
        if (scaling == NSImageScaleProportionallyDown)
            k = MIN(k, 1);
        d = NSMakeSize(is.width * k, is.height * k);
        break;
    }
    default:
        break;
    }
    /* horizontal: left, centre, right; vertical: top, centre, bottom (in the view's sense of up) */
    int hx = 1, vy = 1;
    switch (align) {
    case NSImageAlignTop: vy = 0; break;
    case NSImageAlignTopLeft: hx = 0; vy = 0; break;
    case NSImageAlignTopRight: hx = 2; vy = 0; break;
    case NSImageAlignLeft: hx = 0; break;
    case NSImageAlignBottom: vy = 2; break;
    case NSImageAlignBottomLeft: hx = 0; vy = 2; break;
    case NSImageAlignBottomRight: hx = 2; vy = 2; break;
    case NSImageAlignRight: hx = 2; break;
    default: break;
    }
    CGFloat x = rect.origin.x + (rect.size.width - d.width) * hx / 2;
    CGFloat top = flipped ? rect.origin.y : NSMaxY(rect) - d.height;
    CGFloat bottom = flipped ? NSMaxY(rect) - d.height : rect.origin.y;
    CGFloat y = vy == 0 ? top : vy == 2 ? bottom : rect.origin.y + (rect.size.height - d.height) / 2;
    [image drawInRect:NSMakeRect(round(x), round(y), d.width, d.height) fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:alpha respectFlipped:YES hints:nil];
}

/* Apple's three- and nine-part image functions (NSCell.h). */
void
NSDrawThreePartImage(NSRect frame, NSImage *startCap, NSImage *centerFill, NSImage *endCap, BOOL vertical,
                     NSCompositingOperation op, CGFloat alphaFraction, BOOL flipped)
{
    NSSize a = [startCap size], b = [endCap size];
    NSRect r1, r2, r3;
    if (vertical) {
        r1 = NSMakeRect(frame.origin.x, flipped ? frame.origin.y : NSMaxY(frame) - a.height, frame.size.width, a.height);
        r3 = NSMakeRect(frame.origin.x, flipped ? NSMaxY(frame) - b.height : frame.origin.y, frame.size.width, b.height);
        r2 = NSMakeRect(frame.origin.x, MIN(NSMaxY(r1), NSMaxY(r3)) == NSMaxY(r1) ? NSMaxY(r1) : NSMaxY(r3),
                        frame.size.width, frame.size.height - a.height - b.height);
    } else {
        r1 = NSMakeRect(frame.origin.x, frame.origin.y, a.width, frame.size.height);
        r3 = NSMakeRect(NSMaxX(frame) - b.width, frame.origin.y, b.width, frame.size.height);
        r2 = NSMakeRect(NSMaxX(r1), frame.origin.y, frame.size.width - a.width - b.width, frame.size.height);
    }
    [startCap drawInRect:r1 fromRect:NSZeroRect operation:op fraction:alphaFraction respectFlipped:YES hints:nil];
    if (r2.size.width > 0 && r2.size.height > 0)
        [centerFill drawInRect:r2 fromRect:NSZeroRect operation:op fraction:alphaFraction respectFlipped:YES hints:nil];
    [endCap drawInRect:r3 fromRect:NSZeroRect operation:op fraction:alphaFraction respectFlipped:YES hints:nil];
}

void
NSDrawNinePartImage(NSRect frame, NSImage *topLeft, NSImage *topEdge, NSImage *topRight, NSImage *leftEdge,
                    NSImage *centerFill, NSImage *rightEdge, NSImage *bottomLeft, NSImage *bottomEdge,
                    NSImage *bottomRight, NSCompositingOperation op, CGFloat alphaFraction, BOOL flipped)
{
    NSSize tl = [topLeft size], br = [bottomRight size];
    CGFloat x0 = frame.origin.x, x1 = x0 + tl.width, x3 = NSMaxX(frame), x2 = x3 - br.width;
    CGFloat yb0 = frame.origin.y, yb1 = yb0 + br.height, yt1 = NSMaxY(frame), yt0 = yt1 - tl.height;
    if (flipped) {
        /* top is at the small y */
        yt0 = frame.origin.y;
        yt1 = yt0 + tl.height;
        yb1 = NSMaxY(frame);
        yb0 = yb1 - br.height;
    }
    CGFloat midLo = flipped ? yt1 : yb1, midHi = flipped ? yb0 : yt0;
    NSImage *im[9] = {topLeft, topEdge, topRight, leftEdge, centerFill, rightEdge, bottomLeft, bottomEdge, bottomRight};
    CGFloat xs[4] = {x0, x1, x2, x3};
    CGFloat ys[3][2] = {{MIN(yt0, yt1), MAX(yt0, yt1)}, {midLo, midHi}, {MIN(yb0, yb1), MAX(yb0, yb1)}};
    for (int row = 0; row < 3; row++)
        for (int col = 0; col < 3; col++) {
            NSRect r = NSMakeRect(xs[col], ys[row][0], xs[col + 1] - xs[col], ys[row][1] - ys[row][0]);
            if (r.size.width > 0 && r.size.height > 0)
                [im[row * 3 + col] drawInRect:r fromRect:NSZeroRect operation:op fraction:alphaFraction
                               respectFlipped:YES hints:nil];
        }
}

#pragma mark - Archive helpers

NSTextAlignment
FinchAlignmentFromArchive(unsigned v)
{
    switch (v) {
    case 0: return NSTextAlignmentLeft;
    case 1: return NSTextAlignmentRight;
    case 2: return NSTextAlignmentCenter;
    case 3: return NSTextAlignmentJustified;
    default: return NSTextAlignmentNatural;
    }
}

unsigned
FinchAlignmentToArchive(NSTextAlignment a)
{
    switch (a) {
    case NSTextAlignmentLeft: return 0;
    case NSTextAlignmentRight: return 1;
    case NSTextAlignmentCenter: return 2;
    case NSTextAlignmentJustified: return 3;
    default: return 4;
    }
}

#pragma mark - NSCell

@implementation NSCell {
    id _contents;       /* the value: a string, number, attributed string or other object; the image for image cells */
    NSFont *_font;
    NSFormatter *_formatter;
    id _representedObject;
    NSMenu *_menu;
    NSView *_controlView; /* not retained */
    NSString *_identifier;
    NSControlStateValue _state;
    NSCellType _type;
    NSTextAlignment _alignment;
    NSLineBreakMode _lineBreakMode;
    NSControlSize _controlSize;
    NSFocusRingType _focusRingType;
    NSWritingDirection _writingDirection;
    NSUserInterfaceLayoutDirection _layoutDirection;
    NSBackgroundStyle _backgroundStyle;
    NSEventMask _actionMask;
    struct {
        unsigned enabled : 1;
        unsigned bordered : 1;
        unsigned bezeled : 1;
        unsigned editable : 1;
        unsigned selectable : 1;
        unsigned scrollable : 1;
        unsigned highlighted : 1;
        unsigned allowsMixed : 1;
        unsigned refusesFirstResponder : 1;
        unsigned showsFirstResponder : 1;
        unsigned actionOnEndEditing : 1;
        unsigned allowsUndo : 1;
        unsigned importsGraphics : 1;
        unsigned editsAttributes : 1;
        unsigned singleLine : 1;
        unsigned truncatesLastLine : 1;
        unsigned invalid : 1;
        unsigned editing : 1;
    } _c;
}

+ (BOOL)prefersTrackingUntilMouseUp { return NO; }
+ (NSFocusRingType)defaultFocusRingType { return NSFocusRingTypeExterior; }
+ (NSMenu *)defaultMenu { return nil; }

static void
cell_defaults(NSCell *self)
{
    self->_c.enabled = YES;
    self->_c.allowsUndo = YES;
    self->_writingDirection = NSWritingDirectionNatural;
    self->_actionMask = NSEventMaskLeftMouseUp;
    self->_lineBreakMode = NSLineBreakByWordWrapping;
}

- (instancetype)init
{
    return [self initImageCell:nil];
}

- (instancetype)initTextCell:(NSString *)string
{
    self = [super init];
    if (!self)
        return nil;
    cell_defaults(self);
    _type = NSTextCellType;
    _contents = [string copy] ?: @"";
    _font = [[NSFont systemFontOfSize:0] retain];
    return self;
}

- (instancetype)initImageCell:(NSImage *)image
{
    self = [super init];
    if (!self)
        return nil;
    cell_defaults(self);
    _type = image ? NSImageCellType : NSNullCellType;
    _contents = [image retain];
    return self;
}

- (void)dealloc
{
    [_contents release];
    [_font release];
    [_formatter release];
    [_representedObject release];
    [_menu release];
    [_identifier release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSCell *c = NSCopyObject(self, 0, zone);
    [c->_contents retain];
    [c->_font retain];
    [c->_formatter retain];
    [c->_representedObject retain];
    [c->_menu retain];
    [c->_identifier retain];
    return c;
}

#pragma mark Coding

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self)
        return nil;
    cell_defaults(self);
    unsigned f1 = (unsigned)[coder decodeIntForKey:@"NSCellFlags"];
    unsigned f2 = (unsigned)[coder decodeIntForKey:@"NSCellFlags2"];
    _type = (f1 >> CF1_TYPE_SHIFT) & 3;
    _state = (f1 & CF1_STATE) ? ((f2 & CF2_MIXED) && (f2 & CF2_ALLOWS_MIXED) ? NSControlStateValueMixed : NSControlStateValueOn)
                              : NSControlStateValueOff;
    _c.highlighted = (f1 & CF1_HIGHLIGHTED) != 0;
    _c.enabled = !(f1 & CF1_DISABLED);
    _c.editable = (f1 & CF1_EDITABLE) != 0;
    _c.bordered = (f1 & CF1_BORDERED) != 0;
    _c.bezeled = (f1 & CF1_BEZELED) != 0;
    _c.selectable = (f1 & CF1_SELECTABLE) != 0;
    _c.scrollable = (f1 & CF1_SCROLLABLE) != 0;
    if (f1 & CF1_CONTINUOUS)
        _actionMask |= NSEventMaskPeriodic;
    _c.editsAttributes = (f2 & CF2_EDITS_ATTRIBUTES) != 0;
    _c.importsGraphics = (f2 & CF2_IMPORTS_GRAPHICS) != 0;
    _alignment = FinchAlignmentFromArchive((f2 >> CF2_ALIGNMENT_SHIFT) & 7);
    _c.refusesFirstResponder = (f2 & CF2_REFUSES_FIRST_RESPONDER) != 0;
    _c.allowsMixed = (f2 & CF2_ALLOWS_MIXED) != 0;
    _c.actionOnEndEditing = (f2 & CF2_ACTION_ON_END_EDITING) != 0;
    _controlSize = (f2 >> CF2_CONTROL_SIZE_SHIFT) & 7;
    if ([coder containsValueForKey:@"NSControlSize2"])
        _controlSize = [coder decodeIntegerForKey:@"NSControlSize2"];
    _focusRingType = (f2 >> CF2_FOCUS_RING_SHIFT) & 3;
    _writingDirection = (NSWritingDirection)((f2 >> CF2_WRITING_DIRECTION_SHIFT) & 3) - 1;
    _c.allowsUndo = !(f2 & CF2_NO_UNDO);
    _lineBreakMode = (f2 >> CF2_LINE_BREAK_SHIFT) & 7;
    _c.truncatesLastLine = (f2 & CF2_TRUNCATES_LAST_LINE) != 0;
    _c.singleLine = (f2 & CF2_SINGLE_LINE) != 0;
    id contents = [coder decodeObjectForKey:@"NSContents"];
    id support = [coder decodeObjectForKey:@"NSSupport"];
    if ([support isKindOfClass:[NSFont class]])
        _font = [support retain];
    else if (_type == NSTextCellType)
        _font = [[NSFont systemFontOfSize:0] retain];
    if ([contents isKindOfClass:[NSImage class]]) {
        _contents = [contents retain];
        if (_type == NSTextCellType || _type == NSNullCellType)
            _type = NSImageCellType;
    } else if ([support isKindOfClass:[NSImage class]] && _type == NSImageCellType) {
        _contents = [support retain];
    } else {
        _contents = [contents copy];
        if (!_contents && _type == NSTextCellType)
            _contents = @"";
    }
    _formatter = [[coder decodeObjectForKey:@"NSFormatter"] retain];
    if (_formatter && [_contents isKindOfClass:[NSString class]] && [_contents length]) {
        id obj = nil;
        if ([_formatter getObjectValue:&obj forString:_contents errorDescription:NULL] && obj) {
            [_contents release];
            _contents = [obj retain];
        }
    }
    _controlView = [coder decodeObjectForKey:@"NSControlView"];
    _identifier = [[coder decodeObjectForKey:@"NSCellIdentifier"] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    unsigned f1 = (unsigned)_type << CF1_TYPE_SHIFT;
    if (_state != NSControlStateValueOff)
        f1 |= CF1_STATE;
    if (_c.highlighted) f1 |= CF1_HIGHLIGHTED;
    if (!_c.enabled) f1 |= CF1_DISABLED;
    if (_c.editable) f1 |= CF1_EDITABLE;
    if (_c.bordered) f1 |= CF1_BORDERED;
    if (_c.bezeled) f1 |= CF1_BEZELED;
    if (_c.selectable) f1 |= CF1_SELECTABLE;
    if (_c.scrollable) f1 |= CF1_SCROLLABLE;
    if (_actionMask & NSEventMaskPeriodic) f1 |= CF1_CONTINUOUS;
    unsigned f2 = FinchAlignmentToArchive(_alignment) << CF2_ALIGNMENT_SHIFT;
    if (_c.editsAttributes) f2 |= CF2_EDITS_ATTRIBUTES;
    if (_c.importsGraphics) f2 |= CF2_IMPORTS_GRAPHICS;
    if (_c.refusesFirstResponder) f2 |= CF2_REFUSES_FIRST_RESPONDER;
    if (_c.allowsMixed) f2 |= CF2_ALLOWS_MIXED;
    if (_state == NSControlStateValueMixed) f2 |= CF2_MIXED;
    if (_c.actionOnEndEditing) f2 |= CF2_ACTION_ON_END_EDITING;
    f2 |= (unsigned)(MIN(_controlSize, 2) & 7) << CF2_CONTROL_SIZE_SHIFT;
    f2 |= (unsigned)(_focusRingType & 3) << CF2_FOCUS_RING_SHIFT;
    f2 |= (unsigned)((_writingDirection + 1) & 3) << CF2_WRITING_DIRECTION_SHIFT;
    if (!_c.allowsUndo) f2 |= CF2_NO_UNDO;
    f2 |= (unsigned)(_lineBreakMode & 7) << CF2_LINE_BREAK_SHIFT;
    if (_c.truncatesLastLine) f2 |= CF2_TRUNCATES_LAST_LINE;
    if (_c.singleLine) f2 |= CF2_SINGLE_LINE;
    [coder encodeInt:(int)f1 forKey:@"NSCellFlags"];
    [coder encodeInt:(int)f2 forKey:@"NSCellFlags2"];
    if (_controlSize > 2)
        [coder encodeInteger:_controlSize forKey:@"NSControlSize2"];
    if (_contents)
        [coder encodeObject:_contents forKey:@"NSContents"];
    if (_font)
        [coder encodeObject:_font forKey:@"NSSupport"];
    if (_formatter)
        [coder encodeObject:_formatter forKey:@"NSFormatter"];
    if (_controlView)
        [coder encodeConditionalObject:_controlView forKey:@"NSControlView"];
}

#pragma mark Private hooks

- (NSEventMask)_finchActionMask { return _actionMask; }
- (BOOL)_finchIsEditing { return _c.editing; }
- (BOOL)_finchClickChangesState { return YES; }

- (void)_finchChanged
{
    NSView *v = _controlView;
    if (!v)
        return;
    if ([v isKindOfClass:[NSControl class]])
        [(NSControl *)v updateCell:self];
    else
        [v setNeedsDisplay:YES];
}

- (BOOL)_finchDrawsEnabled
{
    return _c.enabled;
}

- (NSDictionary *)_finchTextAttributes
{
    NSMutableParagraphStyle *p = [[[NSParagraphStyle defaultParagraphStyle] mutableCopy] autorelease];
    [p setAlignment:_alignment];
    [p setLineBreakMode:[self wraps] ? _lineBreakMode : (_lineBreakMode == NSLineBreakByWordWrapping ||
                                                                 _lineBreakMode == NSLineBreakByCharWrapping
                                                             ? NSLineBreakByClipping
                                                             : _lineBreakMode)];
    [p setBaseWritingDirection:_writingDirection];
    NSColor *color = _c.enabled ? [NSColor controlTextColor] : [NSColor disabledControlTextColor];
    return @{
        NSFontAttributeName : _font ?: [NSFont systemFontOfSize:0],
        NSForegroundColorAttributeName : color,
        NSParagraphStyleAttributeName : p,
    };
}

- (BOOL)_finchSendAction
{
    SEL action = [self action];
    /* As Apple's: a cell without a control sends nothing. The control is asked even without an
       action, so its bindings get its value (NSKeyValueBinding.m). */
    if ([_controlView isKindOfClass:[NSControl class]])
        return [(NSControl *)_controlView sendAction:action to:[self target]];
    return NO;
}

#pragma mark Basic state

- (NSView *)controlView { return _controlView; }
- (void)setControlView:(NSView *)view { _controlView = view; }
- (NSCellType)type { return _type; }

- (void)setType:(NSCellType)type
{
    if (type == _type)
        return;
    if (type == NSImageCellType && ![_contents isKindOfClass:[NSImage class]])
        return; /* an image cell needs an image (setImage: makes one) */
    if (type == NSTextCellType) {
        [_contents release];
        _contents = [@"Cell" copy];
        if (!_font)
            _font = [[NSFont systemFontOfSize:0] retain];
    }
    _type = type;
    [self _finchChanged];
}

- (NSControlStateValue)state { return _state; }

- (void)setState:(NSControlStateValue)state
{
    if (state < 0)
        state = _c.allowsMixed ? NSControlStateValueMixed : NSControlStateValueOn;
    else if (state > 0)
        state = NSControlStateValueOn;
    if (state == _state)
        return;
    _state = state;
    [self _finchChanged];
}

- (BOOL)allowsMixedState { return _c.allowsMixed; }

- (void)setAllowsMixedState:(BOOL)flag
{
    _c.allowsMixed = flag;
    if (!flag && _state == NSControlStateValueMixed)
        [self setState:NSControlStateValueOn];
}

- (NSInteger)nextState
{
    if (_state == NSControlStateValueOff)
        return _c.allowsMixed ? NSControlStateValueMixed : NSControlStateValueOn;
    if (_state == NSControlStateValueMixed)
        return NSControlStateValueOn;
    return NSControlStateValueOff;
}

- (void)setNextState
{
    [self setState:[self nextState]];
}

- (id)target { return nil; }

- (void)setTarget:(id)target
{
    [NSException raise:NSInternalInconsistencyException format:@"Must use setTarget: on an NSActionCell subclass"];
}

- (SEL)action { return NULL; }

- (void)setAction:(SEL)action
{
    [NSException raise:NSInternalInconsistencyException format:@"Must use setAction: on an NSActionCell subclass"];
}

- (NSInteger)tag { return -1; }

- (void)setTag:(NSInteger)tag
{
    [NSException raise:NSInternalInconsistencyException format:@"Must use setTag: on an NSActionCell subclass"];
}

- (NSString *)title { return [self stringValue]; }
- (void)setTitle:(NSString *)title { [self setStringValue:title ?: @""]; }
- (BOOL)isOpaque { return _c.bezeled; }
- (BOOL)isEnabled { return _c.enabled; }

- (void)setEnabled:(BOOL)flag
{
    if (_c.enabled == !!flag)
        return;
    _c.enabled = flag;
    [self _finchChanged];
}

- (NSInteger)sendActionOn:(NSEventMask)mask
{
    NSInteger old = (NSInteger)_actionMask;
    _actionMask = mask;
    return old;
}

- (BOOL)isContinuous { return (_actionMask & NSEventMaskPeriodic) != 0; }

- (void)setContinuous:(BOOL)flag
{
    if (flag)
        _actionMask |= NSEventMaskPeriodic;
    else
        _actionMask &= ~NSEventMaskPeriodic;
}

- (BOOL)isEditable { return _c.editable; }

- (void)setEditable:(BOOL)flag
{
    _c.editable = flag;
}

- (BOOL)isSelectable { return _c.selectable || _c.editable; }

- (void)setSelectable:(BOOL)flag
{
    _c.selectable = flag;
    if (!flag)
        _c.editable = NO;
}

- (BOOL)isBordered { return _c.bordered; }

- (void)setBordered:(BOOL)flag
{
    _c.bordered = flag;
    if (flag)
        _c.bezeled = NO;
    [self _finchChanged];
}

- (BOOL)isBezeled { return _c.bezeled; }

- (void)setBezeled:(BOOL)flag
{
    _c.bezeled = flag;
    if (flag)
        _c.bordered = NO;
    [self _finchChanged];
}

- (BOOL)isScrollable { return _c.scrollable; }

- (void)setScrollable:(BOOL)flag
{
    _c.scrollable = flag;
}

- (BOOL)isHighlighted { return _c.highlighted; }

- (void)setHighlighted:(BOOL)flag
{
    if (_c.highlighted == !!flag)
        return;
    _c.highlighted = flag;
    [self _finchChanged];
}

- (NSTextAlignment)alignment { return _alignment; }

- (void)setAlignment:(NSTextAlignment)alignment
{
    _alignment = alignment;
    [self _finchChanged];
}

- (BOOL)wraps
{
    return !_c.scrollable && (_lineBreakMode == NSLineBreakByWordWrapping || _lineBreakMode == NSLineBreakByCharWrapping);
}

- (void)setWraps:(BOOL)flag
{
    if (flag) {
        _c.scrollable = NO;
        if (_lineBreakMode != NSLineBreakByWordWrapping && _lineBreakMode != NSLineBreakByCharWrapping)
            _lineBreakMode = NSLineBreakByWordWrapping;
    } else if (_lineBreakMode == NSLineBreakByWordWrapping || _lineBreakMode == NSLineBreakByCharWrapping) {
        _lineBreakMode = NSLineBreakByClipping;
    }
    [self _finchChanged];
}

- (NSLineBreakMode)lineBreakMode { return _lineBreakMode; }

- (void)setLineBreakMode:(NSLineBreakMode)mode
{
    _lineBreakMode = mode;
    [self _finchChanged];
}

- (BOOL)truncatesLastVisibleLine { return _c.truncatesLastLine; }
- (void)setTruncatesLastVisibleLine:(BOOL)flag { _c.truncatesLastLine = flag; }
- (NSFont *)font { return _font; }

- (void)setFont:(NSFont *)font
{
    if (font == _font)
        return;
    [_font release];
    _font = [font retain];
    [self _finchChanged];
}

- (NSString *)keyEquivalent { return @""; }
- (NSFormatter *)formatter { return _formatter; }

- (void)setFormatter:(NSFormatter *)formatter
{
    if (formatter == _formatter)
        return;
    [_formatter release];
    _formatter = [formatter retain];
    [self _finchChanged];
}

- (NSControlSize)controlSize { return _controlSize; }

- (void)setControlSize:(NSControlSize)size
{
    _controlSize = size;
    [self _finchChanged];
}

- (id)representedObject { return _representedObject; }

- (void)setRepresentedObject:(id)object
{
    [object retain];
    [_representedObject release];
    _representedObject = object;
}

- (NSMenu *)menu { return _menu; }

- (void)setMenu:(NSMenu *)menu
{
    [menu retain];
    [_menu release];
    _menu = menu;
}

- (NSMenu *)menuForEvent:(NSEvent *)event inRect:(NSRect)cellFrame ofView:(NSView *)view
{
    return [self menu];
}

- (NSUserInterfaceItemIdentifier)identifier { return _identifier; }

- (void)setIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    [_identifier autorelease];
    _identifier = [identifier copy];
}

- (BOOL)sendsActionOnEndEditing { return _c.actionOnEndEditing; }
- (void)setSendsActionOnEndEditing:(BOOL)flag { _c.actionOnEndEditing = flag; }
- (NSWritingDirection)baseWritingDirection { return _writingDirection; }
- (void)setBaseWritingDirection:(NSWritingDirection)d { _writingDirection = d; }
- (BOOL)allowsUndo { return _c.allowsUndo; }
- (void)setAllowsUndo:(BOOL)flag { _c.allowsUndo = flag; }
- (NSUserInterfaceLayoutDirection)userInterfaceLayoutDirection { return _layoutDirection; }
- (void)setUserInterfaceLayoutDirection:(NSUserInterfaceLayoutDirection)d { _layoutDirection = d; }
- (BOOL)usesSingleLineMode { return _c.singleLine; }
- (void)setUsesSingleLineMode:(BOOL)flag { _c.singleLine = flag; }
- (NSBackgroundStyle)backgroundStyle { return _backgroundStyle; }
- (void)setBackgroundStyle:(NSBackgroundStyle)style { _backgroundStyle = style; }
- (NSBackgroundStyle)interiorBackgroundStyle { return _backgroundStyle; }
- (BOOL)allowsEditingTextAttributes { return _c.editsAttributes; }

- (void)setAllowsEditingTextAttributes:(BOOL)flag
{
    _c.editsAttributes = flag;
    if (!flag)
        _c.importsGraphics = NO;
}

- (BOOL)importsGraphics { return _c.importsGraphics; }

- (void)setImportsGraphics:(BOOL)flag
{
    _c.importsGraphics = flag;
    if (flag)
        _c.editsAttributes = YES;
}

- (BOOL)refusesFirstResponder { return _c.refusesFirstResponder; }
- (void)setRefusesFirstResponder:(BOOL)flag { _c.refusesFirstResponder = flag; }
- (BOOL)acceptsFirstResponder { return _c.enabled && !_c.refusesFirstResponder; }
- (BOOL)showsFirstResponder { return _c.showsFirstResponder; }

- (void)setShowsFirstResponder:(BOOL)flag
{
    if (_c.showsFirstResponder == !!flag)
        return;
    _c.showsFirstResponder = flag;
    [self _finchChanged];
}

- (NSFocusRingType)focusRingType { return _focusRingType; }
- (void)setFocusRingType:(NSFocusRingType)type { _focusRingType = type; }
- (BOOL)wantsNotificationForMarkedText { return NO; }
- (NSUInteger)mnemonicLocation { return NSNotFound; }
- (void)setMnemonicLocation:(NSUInteger)location {}
- (NSString *)mnemonic { return @""; }

- (void)setTitleWithMnemonic:(NSString *)string
{
    NSMutableString *s = [[string mutableCopy] autorelease];
    NSRange r = [s rangeOfString:@"&"];
    if (r.location != NSNotFound)
        [s deleteCharactersInRange:r];
    [self setTitle:s];
}

- (NSInteger)mouseDownFlags { return 0; }

- (void)getPeriodicDelay:(float *)delay interval:(float *)interval
{
    if (delay)
        *delay = 0.2f;
    if (interval)
        *interval = 0.025f;
}

- (NSInteger)cellAttribute:(NSCellAttribute)attribute
{
    switch (attribute) {
    case NSCellDisabled: return !_c.enabled;
    case NSCellState: return _state != NSControlStateValueOff;
    case NSCellEditable: return _c.editable;
    case NSCellHighlighted: return _c.highlighted;
    case NSCellIsBordered: return _c.bordered;
    case NSCellAllowsMixedState: return _c.allowsMixed;
    default: return 0;
    }
}

- (void)setCellAttribute:(NSCellAttribute)attribute to:(NSInteger)value
{
    switch (attribute) {
    case NSCellDisabled: [self setEnabled:!value]; break;
    case NSCellState: [self setState:value]; break;
    case NSCellEditable: [self setEditable:value != 0]; break;
    case NSCellHighlighted: [self setHighlighted:value != 0]; break;
    case NSCellIsBordered: [self setBordered:value != 0]; break;
    case NSCellAllowsMixedState: [self setAllowsMixedState:value != 0]; break;
    default: break;
    }
}

#pragma mark Values

- (BOOL)hasValidObjectValue { return !_c.invalid; }

- (id)objectValue
{
    if (_c.invalid)
        return nil;
    if (_type == NSImageCellType)
        return _contents;
    return _contents;
}

/* Store a value; image cells keep their image. */
- (void)_finchSetContents:(id)value
{
    if (_type == NSNullCellType)
        return;
    id old = _contents;
    if (_type == NSImageCellType && ![value isKindOfClass:[NSImage class]]) {
        _type = NSTextCellType;
        if (!_font)
            _font = [[NSFont systemFontOfSize:0] retain];
    }
    _contents = [value respondsToSelector:@selector(copyWithZone:)] ? [value copy] : [value retain];
    [old release];
    [self _finchChanged];
}

- (void)setObjectValue:(id)value
{
    if (_type == NSNullCellType)
        return;
    _c.invalid = NO;
    if (_formatter && [value isKindOfClass:[NSString class]]) {
        [self setStringValue:value];
        return;
    }
    [self _finchSetContents:value];
}

static NSString *
number_string(NSNumber *n)
{
    const char *t = [n objCType];
    if (*t == 'f' || *t == 'd')
        return [NSString stringWithFormat:@"%.16g", [n doubleValue]];
    static NSNumberFormatter *f;
    if (!f) {
        f = [[NSNumberFormatter alloc] init];
        [f setNumberStyle:NSNumberFormatterDecimalStyle];
        [f setMaximumFractionDigits:0];
    }
    NSString *s = nil;
    @synchronized(f) {
        [f setLocale:[NSLocale currentLocale]];
        s = [f stringFromNumber:n];
    }
    return s ?: [n stringValue];
}

- (NSString *)stringValue
{
    id v = _contents;
    if (!v)
        return @"";
    if (_c.invalid && [v isKindOfClass:[NSString class]])
        return v;
    if (_formatter && !_c.invalid) {
        NSString *s = [_formatter stringForObjectValue:v];
        if (s)
            return s;
    }
    if ([v isKindOfClass:[NSString class]])
        return v;
    if ([v isKindOfClass:[NSAttributedString class]])
        return [v string];
    if ([v isKindOfClass:[NSNumber class]])
        return number_string(v);
    return [v description] ?: @"";
}

- (void)setStringValue:(NSString *)string
{
    if (!string)
        [NSException raise:NSInternalInconsistencyException format:@"Attempt to set a cell's string value to nil"];
    if (_type == NSNullCellType)
        return;
    if (_formatter) {
        id obj = nil;
        if ([_formatter getObjectValue:&obj forString:string errorDescription:NULL]) {
            _c.invalid = NO;
            [self _finchSetContents:obj];
        } else {
            [self _finchSetContents:string];
            _c.invalid = YES;
        }
        return;
    }
    _c.invalid = NO;
    [self _finchSetContents:string];
}

- (NSComparisonResult)compare:(id)other
{
    return [[self stringValue] compare:[other stringValue]];
}

static double
value_double(id v)
{
    if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]])
        return [v doubleValue];
    if ([v isKindOfClass:[NSAttributedString class]])
        return [[v string] doubleValue];
    return 0;
}

static long long
value_integer(id v)
{
    if ([v isKindOfClass:[NSNumber class]])
        return [v longLongValue];
    if ([v isKindOfClass:[NSString class]])
        return [v longLongValue];
    if ([v isKindOfClass:[NSAttributedString class]])
        return [[v string] longLongValue];
    return 0;
}

- (int)intValue { return (int)value_integer([self objectValue] ?: [self stringValue]); }
- (NSInteger)integerValue { return (NSInteger)value_integer([self objectValue] ?: [self stringValue]); }
- (float)floatValue { return (float)value_double([self objectValue] ?: [self stringValue]); }
- (double)doubleValue { return value_double([self objectValue] ?: [self stringValue]); }
- (void)setIntValue:(int)v { [self setObjectValue:@(v)]; }
- (void)setIntegerValue:(NSInteger)v { [self setObjectValue:@(v)]; }
- (void)setFloatValue:(float)v { [self setObjectValue:@(v)]; }
- (void)setDoubleValue:(double)v { [self setObjectValue:@(v)]; }
- (void)takeIntValueFrom:(id)sender { [self setIntValue:[sender intValue]]; }
- (void)takeIntegerValueFrom:(id)sender { [self setIntegerValue:[sender integerValue]]; }
- (void)takeFloatValueFrom:(id)sender { [self setFloatValue:[sender floatValue]]; }
- (void)takeDoubleValueFrom:(id)sender { [self setDoubleValue:[sender doubleValue]]; }
- (void)takeStringValueFrom:(id)sender { [self setStringValue:[sender stringValue] ?: @""]; }
- (void)takeObjectValueFrom:(id)sender { [self setObjectValue:[sender objectValue]]; }

- (NSAttributedString *)attributedStringValue
{
    id v = [self objectValue];
    if ([v isKindOfClass:[NSAttributedString class]] && !_formatter)
        return v;
    if (_formatter && [_formatter respondsToSelector:@selector(attributedStringForObjectValue:withDefaultAttributes:)]) {
        NSAttributedString *a = [_formatter attributedStringForObjectValue:v
                                                     withDefaultAttributes:[self _finchTextAttributes]];
        if (a)
            return a;
    }
    return [[[NSAttributedString alloc] initWithString:[self stringValue] attributes:[self _finchTextAttributes]]
        autorelease];
}

- (void)setAttributedStringValue:(NSAttributedString *)value
{
    if (_formatter) {
        [self setStringValue:[value string] ?: @""];
        return;
    }
    [self setObjectValue:value];
}

- (NSImage *)image
{
    return _type == NSImageCellType && [_contents isKindOfClass:[NSImage class]] ? _contents : nil;
}

- (void)setImage:(NSImage *)image
{
    if (!image) {
        if (_type == NSImageCellType) {
            [_contents release];
            _contents = nil;
        }
        [self _finchChanged];
        return;
    }
    [image retain];
    [_contents release];
    _contents = image;
    _type = NSImageCellType;
    _c.invalid = NO;
    [self _finchChanged];
}

#pragma mark Geometry

/* The inset the border or bezel takes. */
- (CGFloat)_finchBorderInset
{
    return _c.bezeled ? 3 : _c.bordered ? 2 : 0;
}

- (NSRect)drawingRectForBounds:(NSRect)rect
{
    CGFloat i = [self _finchBorderInset];
    return NSInsetRect(rect, i, i);
}

- (NSRect)titleRectForBounds:(NSRect)rect
{
    return [self drawingRectForBounds:rect];
}

- (NSRect)imageRectForBounds:(NSRect)rect
{
    return [self drawingRectForBounds:rect];
}

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    CGFloat i = 2 * [self _finchBorderInset];
    if (_type == NSImageCellType) {
        NSSize s = [[self image] size];
        return NSMakeSize(s.width + i, s.height + i);
    }
    if (_type == NSTextCellType) {
        CGFloat width = [self wraps] && rect.size.width > 0 && rect.size.width < 1e6 ? rect.size.width - 4 - i : 0;
        NSSize s = FinchCellTextSize([self attributedStringValue], width);
        return NSMakeSize(s.width + 4 + i, s.height + i);
    }
    return NSMakeSize(40000, 40000);
}

- (NSSize)cellSize
{
    return [self cellSizeForBounds:NSMakeRect(0, 0, 1e7, 1e7)];
}

- (NSColor *)highlightColorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    return [NSColor selectedControlColor];
}

- (void)calcDrawInfo:(NSRect)rect {}

- (NSCellHitResult)hitTestForEvent:(NSEvent *)event inRect:(NSRect)cellFrame ofView:(NSView *)controlView
{
    NSPoint p = [controlView convertPoint:[event locationInWindow] fromView:nil];
    if (!NSMouseInRect(p, cellFrame, [controlView isFlipped]))
        return NSCellHitNone;
    NSCellHitResult r = NSCellHitContentArea;
    if (_type == NSTextCellType && [self isEditable])
        r |= NSCellHitEditableTextArea;
    if (_c.enabled)
        r |= NSCellHitTrackableArea;
    return r;
}

- (NSRect)expansionFrameWithFrame:(NSRect)cellFrame inView:(NSView *)view { return NSZeroRect; }
- (void)drawWithExpansionFrame:(NSRect)cellFrame inView:(NSView *)view { [self drawWithFrame:cellFrame inView:view]; }
- (NSRect)focusRingMaskBoundsForFrame:(NSRect)cellFrame inView:(NSView *)controlView { return cellFrame; }

- (void)drawFocusRingMaskWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    NSRectFill(cellFrame);
}

- (NSArray<NSDraggingImageComponent *> *)draggingImageComponentsWithFrame:(NSRect)frame inView:(NSView *)view
{
    return @[];
}

- (void)resetCursorRect:(NSRect)cellFrame inView:(NSView *)controlView {}

#pragma mark Drawing

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    NSRect r = [self drawingRectForBounds:cellFrame];
    BOOL flipped = [controlView isFlipped];
    if (_type == NSImageCellType) {
        FinchDrawImageInRect([self image], r, NSImageScaleProportionallyDown, NSImageAlignCenter, flipped,
                             _c.enabled ? 1 : 0.5);
    } else if (_type == NSTextCellType && !_c.editing) {
        FinchDrawCellText([self attributedStringValue], NSInsetRect([self titleRectForBounds:cellFrame], 2, 0), flipped);
    }
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    if (_c.bezeled)
        FinchDrawBezel(cellFrame, 3, [NSColor textBackgroundColor], FinchControlStroke());
    else if (_c.bordered)
        FinchDrawBezel(cellFrame, 0, nil, FinchControlStroke());
    [self drawInteriorWithFrame:cellFrame inView:controlView];
    if (_c.showsFirstResponder && _focusRingType != NSFocusRingTypeNone)
        FinchDrawBezel(NSInsetRect(cellFrame, -1, -1), 4, nil, [FinchAccentColor() colorWithAlphaComponent:0.6]);
}

- (void)highlight:(BOOL)flag withFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    if (_c.highlighted == !!flag)
        return;
    _c.highlighted = flag;
    [controlView setNeedsDisplayInRect:cellFrame];
}

#pragma mark Tracking

- (BOOL)startTrackingAt:(NSPoint)startPoint inView:(NSView *)controlView
{
    return [self isContinuous] || (_actionMask & NSEventMaskLeftMouseDragged);
}

- (BOOL)continueTracking:(NSPoint)lastPoint at:(NSPoint)currentPoint inView:(NSView *)controlView
{
    return [self isContinuous] || (_actionMask & NSEventMaskLeftMouseDragged);
}

- (void)stopTracking:(NSPoint)lastPoint at:(NSPoint)stopPoint inView:(NSView *)controlView mouseIsUp:(BOOL)flag
{
}

/*
 * As Apple's: follow the mouse until it goes up (or, without untilMouseUp,
 * leaves the cell), sending the action on the events -sendActionOn: asked
 * for. A mouse up in the cell advances the state; YES if the mouse went up.
 */
- (BOOL)trackMouse:(NSEvent *)event inRect:(NSRect)cellFrame ofView:(NSView *)controlView untilMouseUp:(BOOL)untilUp
{
    NSWindow *w = [controlView window];
    BOOL flipped = [controlView isFlipped];
    NSPoint p = [controlView convertPoint:[event locationInWindow] fromView:nil];
    NSPoint last = p;
    BOOL tracking = [self startTrackingAt:p inView:controlView];
    if (_actionMask & NSEventMaskLeftMouseDown)
        [self _finchSendAction];
    NSEventMask mask = NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged;
    if ([event type] == NSEventTypeLeftMouseUp)
        goto up;
    for (;;) {
        NSEvent *e = [w nextEventMatchingMask:mask];
        if (!e)
            return NO;
        event = e;
        p = [controlView convertPoint:[e locationInWindow] fromView:nil];
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
        if (!untilUp && !NSMouseInRect(p, cellFrame, flipped)) {
            [self stopTracking:last at:p inView:controlView mouseIsUp:NO];
            return NO;
        }
        if (tracking) {
            tracking = [self continueTracking:last at:p inView:controlView];
            if (tracking && ((_actionMask & NSEventMaskLeftMouseDragged) || [self isContinuous]))
                [self _finchSendAction];
        }
        last = p;
    }
up:
    [self stopTracking:last at:p inView:controlView mouseIsUp:YES];
    if (!untilUp && !NSMouseInRect(p, cellFrame, flipped))
        return NO;
    if (_c.enabled && [self _finchClickChangesState] && NSMouseInRect(p, cellFrame, flipped))
        [self setNextState];
    if (_actionMask & NSEventMaskLeftMouseUp)
        [self _finchSendAction];
    return YES;
}

- (void)performClick:(id)sender
{
    if (!_c.enabled)
        return;
    NSView *v = _controlView;
    if (v && [v respondsToSelector:@selector(performClick:)] && [v isKindOfClass:[NSControl class]] &&
        [(NSControl *)v cell] == self) {
        [(NSControl *)v performClick:sender];
        return;
    }
    if ([self _finchClickChangesState])
        [self setNextState];
    [self _finchSendAction];
}

#pragma mark Editing

- (NSText *)setUpFieldEditorAttributes:(NSText *)text
{
    [text setFont:_font ?: [NSFont systemFontOfSize:0]];
    [text setAlignment:_alignment];
    [text setTextColor:[NSColor controlTextColor]];
    [text setEditable:[self isEditable]];
    [text setSelectable:[self isSelectable]];
    [text setRichText:_c.editsAttributes];
    [text setImportsGraphics:_c.importsGraphics];
    [text setDrawsBackground:NO];
    return text;
}

- (NSTextView *)fieldEditorForView:(NSView *)controlView
{
    return nil;
}

/* Put the field editor over the cell's text and give it the cell's string. */
- (void)_finchSetUpEditor:(NSText *)editor rect:(NSRect)rect inView:(NSView *)view delegate:(id)delegate
{
    _c.editing = YES;
    [self setUpFieldEditorAttributes:editor];
    NSRect r = NSInsetRect([self titleRectForBounds:rect], 2, 0);
    NSFont *f = _font ?: [NSFont systemFontOfSize:0];
    if (![self wraps]) {
        /* one line, centred as the cell draws it */
        CGFloat h = ceil([f ascender] - [f descender] + [f leading]);
        if (h < r.size.height) {
            r.origin.y += floor((r.size.height - h) / 2);
            r.size.height = h;
        }
    }
    [editor setFrame:r];
    if (_c.editsAttributes && [[self objectValue] isKindOfClass:[NSAttributedString class]] &&
        [editor respondsToSelector:@selector(textStorage)])
        [[(NSTextView *)editor textStorage] setAttributedString:[self objectValue]];
    else
        [editor setString:[self stringValue]];
    if ([editor isKindOfClass:[NSTextView class]] && !_c.singleLine && [self wraps])
        [[(NSTextView *)editor textContainer] setWidthTracksTextView:YES];
    [editor setDelegate:delegate];
    if ([editor superview] != view)
        [view addSubview:editor];
    [[view window] makeFirstResponder:editor];
    [view setNeedsDisplay:YES];
}

- (void)editWithFrame:(NSRect)rect inView:(NSView *)controlView editor:(NSText *)textObj delegate:(id)delegate
                event:(NSEvent *)event
{
    if (!textObj || !controlView || _type != NSTextCellType)
        return;
    [self _finchSetUpEditor:textObj rect:rect inView:controlView delegate:delegate];
    if (event && [event type] == NSEventTypeLeftMouseDown)
        [textObj mouseDown:event];
}

- (void)selectWithFrame:(NSRect)rect inView:(NSView *)controlView editor:(NSText *)textObj delegate:(id)delegate
                  start:(NSInteger)start length:(NSInteger)length
{
    if (!textObj || !controlView || _type != NSTextCellType)
        return;
    [self _finchSetUpEditor:textObj rect:rect inView:controlView delegate:delegate];
    NSUInteger n = [[textObj string] length];
    NSUInteger s = MIN((NSUInteger)MAX(start, 0), n);
    [textObj setSelectedRange:NSMakeRange(s, MIN((NSUInteger)MAX(length, 0), n - s))];
}

- (void)endEditing:(NSText *)textObj
{
    _c.editing = NO;
    if ([textObj delegate] && [textObj respondsToSelector:@selector(setDelegate:)])
        [textObj setDelegate:nil];
    if ([textObj superview])
        [textObj removeFromSuperview];
    [textObj setString:@""];
    [self _finchChanged];
}

+ (NSString *)_bulletStringForString:(NSString *)string bulletCharacter:(unichar)bullet
{
    NSUInteger n = [string length];
    unichar *b = malloc(sizeof(unichar) * (n ?: 1));
    for (NSUInteger i = 0; i < n; i++)
        b[i] = bullet;
    NSString *s = [NSString stringWithCharacters:b length:n];
    free(b);
    return s;
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityLabel { return _type == NSTextCellType ? [self stringValue] : nil; }

@end
