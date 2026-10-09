/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSBox: a titled group around a content view, a separator line, or a
 * custom box (fill, border colour, width and corner radius). The content
 * view's frame follows Apple's: the title takes a 12-point strip at the top
 * (or bottom), the margins inset the rest; a custom box insets by its
 * border width and has no title. Nib keys: NSOffsets (the margins),
 * NSTitleCell, NSContentView, NSBorderType, NSBoxType, NSTitlePosition,
 * NSTransparent, NSBorderWidth2, NSCornerRadius2, NSBorderColor2,
 * NSFillColor2. Drawn in Finch's own flat look.
 */
#import "NSControl_Finch.h"

/* A custom box's background, behind the content view (Apple's custom boxes have one too). */
@interface FinchBoxCustomView : NSView
@end

@implementation FinchBoxCustomView

- (void)drawRect:(NSRect)dirty
{
    NSBox *box = (NSBox *)[self superview];
    if (![box isKindOfClass:[NSBox class]] || [box boxType] != NSBoxCustom || [box isTransparent])
        return;
    NSRect r = [self bounds];
    CGFloat w = [box borderWidth], radius = [box cornerRadius];
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, w / 2, w / 2) xRadius:radius yRadius:radius];
    [[box fillColor] setFill];
    [p fill];
    if (w > 0) {
        [p setLineWidth:w];
        [[box borderColor] setStroke];
        [p stroke];
    }
}

@end

static const CGFloat TITLE_STRIP = 12;

@implementation NSBox {
    NSCell *_titleCell;
    NSView *_contentView;
    FinchBoxCustomView *_background;
    NSSize _margins;
    NSBoxType _boxType;
    NSBorderType _borderType;
    NSTitlePosition _titlePosition;
    CGFloat _borderWidth, _cornerRadius;
    NSColor *_borderColor, *_fillColor;
    BOOL _transparent;
}

static NSCell *
make_title_cell(NSString *title)
{
    Class c = FINCH_CLASS(NSTextFieldCell) ?: [NSCell class];
    NSCell *cell = [[c alloc] initTextCell:title ?: @"Title"];
    [cell setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [cell setAlignment:NSTextAlignmentCenter];
    if ([cell respondsToSelector:@selector(setTextColor:)])
        [(id)cell setTextColor:[NSColor labelColor]];
    return cell;
}

static void
box_defaults(NSBox *self)
{
    self->_margins = NSMakeSize(5, 5);
    self->_borderType = NSGrooveBorder;
    self->_titlePosition = NSAtTop;
    self->_borderWidth = 1;
    self->_borderColor = [[NSColor secondaryLabelColor] retain];
    self->_fillColor = [[NSColor clearColor] retain];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    box_defaults(self);
    _titleCell = make_title_cell(@"Title");
    NSView *content = [[NSView alloc] initWithFrame:[self _finchContentRect]];
    [content setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _contentView = content;
    [self addSubview:content];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    box_defaults(self);
    if ([coder containsValueForKey:@"NSOffsets"])
        _margins = [coder decodeSizeForKey:@"NSOffsets"];
    id cell = [coder decodeObjectForKey:@"NSTitleCell"];
    _titleCell = [cell isKindOfClass:[NSCell class]] ? [cell retain] : make_title_cell(@"Title");
    id content = [coder decodeObjectForKey:@"NSContentView"];
    _contentView = [content isKindOfClass:[NSView class]] ? [content retain] : nil;
    if (_contentView && [_contentView superview] != self)
        [self addSubview:_contentView];
    _borderType = (NSBorderType)[coder decodeIntegerForKey:@"NSBorderType"];
    _boxType = (NSBoxType)[coder decodeIntegerForKey:@"NSBoxType"];
    _titlePosition = (NSTitlePosition)[coder decodeIntegerForKey:@"NSTitlePosition"];
    _transparent = [coder decodeBoolForKey:@"NSTransparent"];
    if ([coder containsValueForKey:@"NSBorderWidth2"])
        _borderWidth = [[coder decodeObjectForKey:@"NSBorderWidth2"] doubleValue];
    if ([coder containsValueForKey:@"NSCornerRadius2"])
        _cornerRadius = [coder decodeDoubleForKey:@"NSCornerRadius2"];
    NSColor *c = [coder decodeObjectForKey:@"NSBorderColor2"];
    if ([c isKindOfClass:[NSColor class]]) {
        [_borderColor release];
        _borderColor = [c retain];
    }
    c = [coder decodeObjectForKey:@"NSFillColor2"];
    if ([c isKindOfClass:[NSColor class]]) {
        [_fillColor release];
        _fillColor = [c retain];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeSize:_margins forKey:@"NSOffsets"];
    [coder encodeObject:_titleCell forKey:@"NSTitleCell"];
    if (_contentView)
        [coder encodeObject:_contentView forKey:@"NSContentView"];
    [coder encodeInteger:_borderType forKey:@"NSBorderType"];
    [coder encodeInteger:_boxType forKey:@"NSBoxType"];
    [coder encodeInteger:_titlePosition forKey:@"NSTitlePosition"];
    [coder encodeBool:_transparent forKey:@"NSTransparent"];
    [coder encodeObject:@(_borderWidth) forKey:@"NSBorderWidth2"];
    [coder encodeDouble:_cornerRadius forKey:@"NSCornerRadius2"];
    [coder encodeObject:_borderColor forKey:@"NSBorderColor2"];
    [coder encodeObject:_fillColor forKey:@"NSFillColor2"];
}

- (void)dealloc
{
    [_titleCell release];
    [_contentView release];
    [_background release];
    [_borderColor release];
    [_fillColor release];
    [super dealloc];
}

#pragma mark Geometry

- (BOOL)_finchTitleAtTop
{
    return _titlePosition == NSAboveTop || _titlePosition == NSAtTop;
}

- (BOOL)_finchTitleAtBottom
{
    return _titlePosition == NSAtBottom || _titlePosition == NSBelowBottom;
}

- (NSRect)borderRect
{
    NSRect b = [self bounds];
    if (_boxType != NSBoxPrimary)
        return b;
    if ([self _finchTitleAtTop])
        b.size.height -= TITLE_STRIP;
    else if ([self _finchTitleAtBottom]) {
        b.origin.y += TITLE_STRIP;
        b.size.height -= TITLE_STRIP;
    }
    return b;
}

- (NSRect)titleRect
{
    if (_titlePosition == NSNoTitle || _boxType != NSBoxPrimary)
        return NSZeroRect;
    NSString *t = [_titleCell stringValue];
    NSFont *f = [_titleCell font] ?: [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    CGFloat w = [t length] ? [t sizeWithAttributes:@{NSFontAttributeName : f}].width : 0;
    NSRect b = [self bounds];
    CGFloat h = 14, y;
    switch (_titlePosition) {
    case NSAboveTop:
    case NSAtTop: y = NSMaxY(b) - h; break;
    case NSBelowTop: y = NSMaxY(b) - h - 2; break;
    case NSAboveBottom: y = NSMinY(b) + 2; break;
    default: y = NSMinY(b); break;
    }
    return NSMakeRect(NSMinX(b) + 7, y, w, h);
}

- (NSRect)_finchContentRect
{
    if (_boxType == NSBoxSeparator)
        return NSZeroRect;
    NSRect r;
    if (_boxType == NSBoxCustom) {
        r = NSInsetRect([self bounds], _borderWidth, _borderWidth);
    } else {
        r = [self borderRect];
        if (_titlePosition == NSBelowTop)
            r.size.height -= 5;
        else if (_titlePosition == NSAboveBottom) {
            r.origin.y += 5;
            r.size.height -= 5;
        }
    }
    r = NSInsetRect(r, _margins.width, _margins.height);
    if (r.size.width < 0)
        r.size.width = 0;
    if (r.size.height < 0)
        r.size.height = 0;
    return r;
}

- (void)_finchLayoutContent
{
    if (_contentView)
        [_contentView setFrame:[self _finchContentRect]];
    [self setNeedsDisplay:YES];
}

#pragma mark Properties

- (NSBoxType)boxType { return _boxType; }

- (void)setBoxType:(NSBoxType)type
{
    _boxType = type;
    [self setNeedsDisplay:YES];
}

- (NSBorderType)borderType { return _borderType; }

- (void)setBorderType:(NSBorderType)type
{
    _borderType = type;
    [self _finchLayoutContent];
}

- (NSTitlePosition)titlePosition { return _titlePosition; }

- (void)setTitlePosition:(NSTitlePosition)p
{
    _titlePosition = p;
    [self _finchLayoutContent];
}

- (NSString *)title { return [_titleCell stringValue]; }

- (void)setTitle:(NSString *)title
{
    [_titleCell setStringValue:title ?: @""];
    [self setNeedsDisplay:YES];
}

- (NSFont *)titleFont { return [_titleCell font]; }

- (void)setTitleFont:(NSFont *)font
{
    [_titleCell setFont:font];
    [self setNeedsDisplay:YES];
}

- (id)titleCell { return _titleCell; }
- (NSSize)contentViewMargins { return _margins; }

- (void)setContentViewMargins:(NSSize)m
{
    _margins = m;
    [self _finchLayoutContent];
}

- (BOOL)isTransparent { return _transparent; }

- (void)setTransparent:(BOOL)flag
{
    _transparent = flag;
    [self setNeedsDisplay:YES];
}

- (CGFloat)borderWidth { return _borderWidth; }

- (void)setBorderWidth:(CGFloat)w
{
    _borderWidth = w;
    [self setNeedsDisplay:YES];
}

- (CGFloat)cornerRadius { return _cornerRadius; }

- (void)setCornerRadius:(CGFloat)r
{
    _cornerRadius = r;
    [self setNeedsDisplay:YES];
}

- (NSColor *)borderColor { return _borderColor; }

- (void)setBorderColor:(NSColor *)c
{
    [_borderColor release];
    _borderColor = [c copy];
    [self setNeedsDisplay:YES];
    [_background setNeedsDisplay:YES];
}

- (NSColor *)fillColor { return _fillColor; }

- (void)setFillColor:(NSColor *)c
{
    [_fillColor release];
    _fillColor = [c copy];
    [self setNeedsDisplay:YES];
    [_background setNeedsDisplay:YES];
}

- (__kindof NSView *)contentView { return _contentView; }

- (void)setContentView:(NSView *)view
{
    if (view == _contentView)
        return;
    if (_boxType == NSBoxCustom && !_background) {
        _background = [[FinchBoxCustomView alloc] initWithFrame:[self bounds]];
        [_background setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [self addSubview:_background positioned:NSWindowBelow relativeTo:nil];
    }
    [_contentView removeFromSuperview];
    [_contentView release];
    _contentView = [view retain];
    if (view) {
        [view setFrame:[self _finchContentRect]];
        [self addSubview:view];
    }
    [self setNeedsDisplay:YES];
}

- (void)setFrameFromContentFrame:(NSRect)content
{
    NSRect f = NSInsetRect(content, -_margins.width, -_margins.height);
    if (_boxType == NSBoxCustom)
        f = NSInsetRect(f, -_borderWidth, -_borderWidth);
    else if (_boxType == NSBoxPrimary) {
        if ([self _finchTitleAtTop])
            f.size.height += TITLE_STRIP;
        else if ([self _finchTitleAtBottom]) {
            f.origin.y -= TITLE_STRIP;
            f.size.height += TITLE_STRIP;
        }
    }
    [self setFrame:f];
}

- (void)sizeToFit
{
    NSRect u = NSZeroRect;
    for (NSView *v in [_contentView subviews])
        u = NSIsEmptyRect(u) ? [v frame] : NSUnionRect(u, [v frame]);
    if (_contentView) {
        for (NSView *v in [_contentView subviews])
            [v setFrameOrigin:NSMakePoint(NSMinX([v frame]) - NSMinX(u), NSMinY([v frame]) - NSMinY(u))];
    }
    NSRect cf = [_contentView frame];
    NSPoint o = [self convertPoint:cf.origin toView:[self superview]];
    o.x += NSMinX(u);
    o.y += NSMinY(u);
    NSSize s = u.size;
    NSRect tr = [self titleRect];
    if (s.width < NSWidth(tr) + 4)
        s.width = NSWidth(tr) + 4;
    [self setFrameFromContentFrame:NSMakeRect(o.x, o.y, s.width, s.height)];
    [_contentView setFrame:[self _finchContentRect]];
}

- (BOOL)isOpaque { return NO; }

#pragma mark Drawing

- (void)drawRect:(NSRect)dirty
{
    if (_transparent)
        return;
    NSRect b = [self bounds];
    switch (_boxType) {
    case NSBoxSeparator: {
        [[NSColor separatorColor] setFill];
        if (b.size.width >= b.size.height)
            NSRectFill(NSMakeRect(NSMinX(b), floor(NSMidY(b)), b.size.width, 1));
        else
            NSRectFill(NSMakeRect(floor(NSMidX(b)), NSMinY(b), 1, b.size.height));
        return;
    }
    case NSBoxCustom: {
        if (_background)
            return; /* the background view draws it */
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, _borderWidth / 2, _borderWidth / 2)
                                                          xRadius:_cornerRadius
                                                          yRadius:_cornerRadius];
        [_fillColor setFill];
        [p fill];
        if (_borderWidth > 0) {
            [p setLineWidth:_borderWidth];
            [_borderColor setStroke];
            [p stroke];
        }
        return;
    }
    default:
        break;
    }
    if (_borderType != NSNoBorder)
        FinchDrawBezel([self borderRect], 5, [NSColor colorWithWhite:0 alpha:0.035],
                       [NSColor colorWithWhite:0 alpha:0.12]);
    if (_titlePosition != NSNoTitle) {
        NSString *t = [_titleCell stringValue];
        if ([t length]) {
            NSFont *f = [_titleCell font] ?: [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
            NSRect tr = [self titleRect];
            [t drawAtPoint:NSMakePoint(NSMinX(tr), NSMinY(tr) + 1)
                withAttributes:@{NSFontAttributeName : f, NSForegroundColorAttributeName : [NSColor secondaryLabelColor]}];
        }
    }
}

@end
