/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSegmentedCell: the segments of an NSSegmentedControl (labels, images,
 * widths, tags, selection) and how they track and draw. Its value is the
 * selected segment, as Apple's. In nibs the segments are NSSegmentItems
 * under NSSegmentImages. Drawing is Finch's own: a flat rounded bar with
 * the selected segments in the accent colour.
 */
#import "NSControl_Finch.h"

/* One segment (the nib's class name). */
@interface NSSegmentItem : NSObject <NSCoding, NSCopying>
@property (copy) NSString *label;
@property (retain) NSImage *image;
@property (retain) NSMenu *menu;
@property (copy) NSString *toolTip;
@property CGFloat width;
@property NSInteger tag;
@property BOOL selected, disabled, showsMenuIndicator;
@property NSImageScaling imageScaling;
@property NSTextAlignment alignment;
@end

@implementation NSSegmentItem
@synthesize label = _label, image = _image, menu = _menu, toolTip = _toolTip, width = _width, tag = _tag,
            selected = _selected, disabled = _disabled, showsMenuIndicator = _showsMenuIndicator,
            imageScaling = _imageScaling, alignment = _alignment;

- (instancetype)init
{
    self = [super init];
    if (self) {
        _imageScaling = NSImageScaleProportionallyDown;
        _alignment = NSTextAlignmentCenter;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self init];
    if (!self)
        return nil;
    id label = [coder decodeObjectForKey:@"NSSegmentItemLabel"];
    _label = [label isKindOfClass:[NSString class]] ? [label copy] : nil;
    id image = [coder decodeObjectForKey:@"NSSegmentItemImage"];
    _image = [image isKindOfClass:[NSImage class]] ? [image retain] : nil;
    id menu = [coder decodeObjectForKey:@"NSSegmentItemMenu"];
    _menu = FINCH_CLASS(NSMenu) && [menu isKindOfClass:FINCH_CLASS(NSMenu)] ? [menu retain] : nil;
    id tip = [coder decodeObjectForKey:@"NSSegmentItemTooltip"];
    _toolTip = [tip isKindOfClass:[NSString class]] ? [tip copy] : nil;
    _width = [coder decodeDoubleForKey:@"NSSegmentItemWidth"];
    _tag = [coder decodeIntegerForKey:@"NSSegmentItemTag"];
    _selected = [coder decodeBoolForKey:@"NSSegmentItemSelected"];
    _disabled = [coder decodeBoolForKey:@"NSSegmentItemDisabled"];
    _showsMenuIndicator = [coder decodeBoolForKey:@"NSSegmentItemShowsMenuIndicator"];
    if ([coder containsValueForKey:@"NSSegmentItemImageScaling"])
        _imageScaling = (NSImageScaling)[coder decodeIntegerForKey:@"NSSegmentItemImageScaling"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_label)
        [coder encodeObject:_label forKey:@"NSSegmentItemLabel"];
    if (_image)
        [coder encodeObject:_image forKey:@"NSSegmentItemImage"];
    if (_menu)
        [coder encodeObject:_menu forKey:@"NSSegmentItemMenu"];
    if (_toolTip)
        [coder encodeObject:_toolTip forKey:@"NSSegmentItemTooltip"];
    if (_width)
        [coder encodeDouble:_width forKey:@"NSSegmentItemWidth"];
    if (_tag)
        [coder encodeInteger:_tag forKey:@"NSSegmentItemTag"];
    if (_selected)
        [coder encodeBool:YES forKey:@"NSSegmentItemSelected"];
    if (_disabled)
        [coder encodeBool:YES forKey:@"NSSegmentItemDisabled"];
    [coder encodeInteger:_imageScaling forKey:@"NSSegmentItemImageScaling"];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSSegmentItem *i = [[NSSegmentItem allocWithZone:zone] init];
    i.label = _label;
    i.image = _image;
    i.menu = _menu;
    i.toolTip = _toolTip;
    i.width = _width;
    i.tag = _tag;
    i.selected = _selected;
    i.disabled = _disabled;
    i.showsMenuIndicator = _showsMenuIndicator;
    i.imageScaling = _imageScaling;
    i.alignment = _alignment;
    return i;
}

- (void)dealloc
{
    [_label release];
    [_image release];
    [_menu release];
    [_toolTip release];
    [super dealloc];
}

@end

@implementation NSSegmentedCell {
    NSMutableArray<NSSegmentItem *> *_items;
    NSInteger _selected; /* the segment selectedSegment reports */
    NSInteger _pressed;  /* the segment being tracked, or -1 */
    NSInteger _keySegment;
    NSSegmentSwitchTracking _trackingMode;
    NSSegmentStyle _segmentStyle;
    NSSegmentDistribution _distribution;
}

static void
segmented_defaults(NSSegmentedCell *self)
{
    self->_items = [[NSMutableArray alloc] init];
    self->_selected = -1;
    self->_pressed = -1;
}

- (instancetype)init
{
    return [self initTextCell:@""];
}

- (instancetype)initTextCell:(NSString *)string
{
    self = [super initTextCell:@""];
    if (!self)
        return nil;
    segmented_defaults(self);
    [self setBordered:YES];
    [self setAlignment:NSTextAlignmentCenter];
    return self;
}

- (instancetype)initImageCell:(NSImage *)image
{
    return [self initTextCell:@""];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    segmented_defaults(self);
    for (id item in [coder decodeObjectForKey:@"NSSegmentImages"])
        if ([item isKindOfClass:[NSSegmentItem class]])
            [_items addObject:item];
    _trackingMode = (NSSegmentSwitchTracking)[coder decodeIntegerForKey:@"NSTrackingMode"];
    _segmentStyle = (NSSegmentStyle)[coder decodeIntegerForKey:@"NSSegmentStyle"];
    _distribution = (NSSegmentDistribution)[coder decodeIntegerForKey:@"NSSegmentDistribution"];
    if ([coder containsValueForKey:@"NSSelectedSegment"])
        _selected = [coder decodeIntegerForKey:@"NSSelectedSegment"];
    else
        for (NSUInteger i = 0; i < [_items count]; i++)
            if ([_items[i] selected])
                _selected = (NSInteger)i;
    if (_selected >= (NSInteger)[_items count])
        _selected = -1;
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_items forKey:@"NSSegmentImages"];
    [coder encodeInteger:_selected forKey:@"NSSelectedSegment"];
    [coder encodeInteger:_trackingMode forKey:@"NSTrackingMode"];
    [coder encodeInteger:_segmentStyle forKey:@"NSSegmentStyle"];
    [coder encodeInteger:_distribution forKey:@"NSSegmentDistribution"];
}

- (void)dealloc
{
    [_items release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSSegmentedCell *c = [super copyWithZone:zone];
    c->_items = [[NSMutableArray alloc] init];
    for (NSSegmentItem *i in _items)
        [c->_items addObject:[[i copy] autorelease]];
    return c;
}

- (NSSegmentItem *)_item:(NSInteger)i
{
    return i >= 0 && i < (NSInteger)[_items count] ? _items[i] : nil;
}

#pragma mark Segments

- (NSInteger)segmentCount { return (NSInteger)[_items count]; }

- (void)setSegmentCount:(NSInteger)count
{
    if (count < 0)
        count = 0;
    while ((NSInteger)[_items count] > count)
        [_items removeLastObject];
    while ((NSInteger)[_items count] < count) {
        NSSegmentItem *i = [[NSSegmentItem alloc] init];
        [_items addObject:i];
        [i release];
    }
    if (_selected >= count)
        _selected = -1;
    [self _finchChanged];
}

- (NSInteger)selectedSegment { return _selected; }

- (void)setSelectedSegment:(NSInteger)segment
{
    if (segment < 0 || segment >= (NSInteger)[_items count]) {
        for (NSSegmentItem *i in _items)
            i.selected = NO;
        _selected = -1;
        [self _finchChanged];
        return;
    }
    [self setSelected:YES forSegment:segment];
}

- (BOOL)selectSegmentWithTag:(NSInteger)tag
{
    for (NSUInteger i = 0; i < [_items count]; i++)
        if ([_items[i] tag] == tag) {
            [self setSelected:YES forSegment:(NSInteger)i];
            return YES;
        }
    return NO;
}

- (void)makeNextSegmentKey
{
    if ([_items count])
        _keySegment = (_keySegment + 1) % (NSInteger)[_items count];
}

- (void)makePreviousSegmentKey
{
    if ([_items count])
        _keySegment = (_keySegment + (NSInteger)[_items count] - 1) % (NSInteger)[_items count];
}

- (NSSegmentSwitchTracking)trackingMode { return _trackingMode; }

- (void)setTrackingMode:(NSSegmentSwitchTracking)mode
{
    _trackingMode = mode;
    if (mode == NSSegmentSwitchTrackingSelectOne && _selected >= 0)
        for (NSUInteger i = 0; i < [_items count]; i++)
            [_items[i] setSelected:(NSInteger)i == _selected];
}

- (void)setWidth:(CGFloat)width forSegment:(NSInteger)s { [self _item:s].width = width; [self _finchChanged]; }
- (CGFloat)widthForSegment:(NSInteger)s { return [self _item:s].width; }
- (void)setImage:(NSImage *)image forSegment:(NSInteger)s { [self _item:s].image = image; [self _finchChanged]; }
- (NSImage *)imageForSegment:(NSInteger)s { return [self _item:s].image; }
- (void)setImageScaling:(NSImageScaling)v forSegment:(NSInteger)s { [self _item:s].imageScaling = v; }
- (NSImageScaling)imageScalingForSegment:(NSInteger)s { return [self _item:s] ? [self _item:s].imageScaling : 0; }
- (void)setLabel:(NSString *)label forSegment:(NSInteger)s { [self _item:s].label = label; [self _finchChanged]; }
- (NSString *)labelForSegment:(NSInteger)s { return [self _item:s].label; }
- (void)setMenu:(NSMenu *)menu forSegment:(NSInteger)s { [self _item:s].menu = menu; }
- (NSMenu *)menuForSegment:(NSInteger)s { return [self _item:s].menu; }
- (void)setToolTip:(NSString *)tip forSegment:(NSInteger)s { [self _item:s].toolTip = tip; }
- (NSString *)toolTipForSegment:(NSInteger)s { return [self _item:s].toolTip; }
- (void)setTag:(NSInteger)tag forSegment:(NSInteger)s { [self _item:s].tag = tag; }
- (NSInteger)tagForSegment:(NSInteger)s { return [self _item:s].tag; }
- (void)setShowsMenuIndicator:(BOOL)f forSegment:(NSInteger)s { [self _item:s].showsMenuIndicator = f; }
- (BOOL)showsMenuIndicatorForSegment:(NSInteger)s { return [self _item:s].showsMenuIndicator; }
- (void)setAlignment:(NSTextAlignment)a forSegment:(NSInteger)s { [self _item:s].alignment = a; }
- (NSTextAlignment)alignmentForSegment:(NSInteger)s { return [self _item:s] ? [self _item:s].alignment : NSTextAlignmentCenter; }

- (void)setSelected:(BOOL)selected forSegment:(NSInteger)s
{
    NSSegmentItem *item = [self _item:s];
    if (!item)
        return;
    if (_trackingMode == NSSegmentSwitchTrackingMomentary || _trackingMode == NSSegmentSwitchTrackingMomentaryAccelerator) {
        /* nothing stays selected */
        [self _finchChanged];
        return;
    }
    if (_trackingMode == NSSegmentSwitchTrackingSelectOne) {
        if (selected) {
            for (NSSegmentItem *i in _items)
                i.selected = i == item;
            _selected = s;
        } else {
            item.selected = NO;
            if (_selected == s)
                _selected = -1;
        }
    } else {
        /* select any: the selected segment is the last one changed */
        item.selected = selected;
        _selected = s;
    }
    [self _finchChanged];
}

- (BOOL)isSelectedForSegment:(NSInteger)s { return [self _item:s].selected; }

- (void)setEnabled:(BOOL)enabled forSegment:(NSInteger)s
{
    [self _item:s].disabled = !enabled;
    [self _finchChanged];
}

- (BOOL)isEnabledForSegment:(NSInteger)s
{
    NSSegmentItem *i = [self _item:s];
    return i ? !i.disabled : NO;
}

- (NSSegmentStyle)segmentStyle { return _segmentStyle; }

- (void)setSegmentStyle:(NSSegmentStyle)style
{
    _segmentStyle = style;
    [self _finchChanged];
}

- (NSSegmentDistribution)_finchDistribution { return _distribution; }
- (void)_finchSetDistribution:(NSSegmentDistribution)d { _distribution = d; [self _finchChanged]; }
- (NSBackgroundStyle)interiorBackgroundStyleForSegment:(NSInteger)s
{
    return [self isSelectedForSegment:s] ? NSBackgroundStyleEmphasized : NSBackgroundStyleNormal;
}

#pragma mark Value: the selected segment

- (id)objectValue { return @(_selected); }

- (void)setObjectValue:(id)value
{
    if ([value respondsToSelector:@selector(integerValue)])
        [self setSelectedSegment:[value integerValue]];
}

- (NSString *)stringValue { return @""; }
- (void)setStringValue:(NSString *)string {}
- (BOOL)_finchClickChangesState { return NO; }
- (BOOL)acceptsFirstResponder { return [_items count] > 0 && [super acceptsFirstResponder]; }

#pragma mark Geometry

- (CGFloat)_finchHeight
{
    switch ([self controlSize]) {
    case NSControlSizeSmall: return 20;
    case NSControlSizeMini: return 16;
    case NSControlSizeLarge: return 28;
    default: return 24;
    }
}

- (NSDictionary *)_finchLabelAttributes:(NSInteger)s selected:(BOOL)selected
{
    NSMutableParagraphStyle *p = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [p setAlignment:[self alignmentForSegment:s]];
    [p setLineBreakMode:NSLineBreakByTruncatingTail];
    BOOL enabled = [self isEnabled] && [self isEnabledForSegment:s];
    NSColor *c = selected && _trackingMode == NSSegmentSwitchTrackingSelectOne ? [NSColor whiteColor]
                                                                               : [NSColor controlTextColor];
    return @{
        NSFontAttributeName : [self font] ?: [NSFont systemFontOfSize:0],
        NSForegroundColorAttributeName : FinchDisabled(c, enabled),
        NSParagraphStyleAttributeName : p,
    };
}

/* A segment's natural width: its set width, or its contents plus padding. */
- (CGFloat)_finchNaturalWidth:(NSInteger)s
{
    NSSegmentItem *i = [self _item:s];
    if (i.width > 0)
        return i.width;
    CGFloat w = 0;
    if (i.image)
        w += [i.image size].width;
    if ([i.label length]) {
        NSSize ts = [i.label sizeWithAttributes:[self _finchLabelAttributes:s selected:NO]];
        w += (w > 0 ? 4 : 0) + ceil(ts.width);
    }
    return MAX(w + 16, 24);
}

- (NSArray<NSValue *> *)_finchSegmentRects:(NSRect)frame
{
    NSInteger n = (NSInteger)[_items count];
    NSMutableArray *rects = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    if (!n)
        return rects;
    CGFloat total = 0;
    NSInteger autos = 0;
    CGFloat widths[n];
    for (NSInteger s = 0; s < n; s++) {
        widths[s] = [self _finchNaturalWidth:s];
        total += widths[s];
        if (_items[s].width <= 0)
            autos++;
    }
    CGFloat extra = frame.size.width - total;
    if (extra > 0 && autos)
        for (NSInteger s = 0; s < n; s++)
            if (_items[s].width <= 0)
                widths[s] += extra / autos;
    CGFloat x = frame.origin.x;
    for (NSInteger s = 0; s < n; s++) {
        CGFloat w = s == n - 1 && extra > 0 && autos ? NSMaxX(frame) - x : widths[s];
        [rects addObject:[NSValue valueWithRect:NSMakeRect(round(x), frame.origin.y, round(w), frame.size.height)]];
        x += widths[s];
    }
    return rects;
}

- (NSInteger)_finchSegmentAtPoint:(NSPoint)p inFrame:(NSRect)frame
{
    NSArray *rects = [self _finchSegmentRects:frame];
    for (NSUInteger i = 0; i < [rects count]; i++) {
        NSRect r = [rects[i] rectValue];
        if (p.x >= NSMinX(r) && p.x < NSMaxX(r))
            return (NSInteger)i;
    }
    return -1;
}

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    CGFloat w = 0;
    for (NSInteger s = 0; s < (NSInteger)[_items count]; s++)
        w += [self _finchNaturalWidth:s];
    return NSMakeSize(ceil(w) + 2, [self _finchHeight]);
}

#pragma mark Tracking

- (void)_finchSetPressed:(NSInteger)s
{
    _pressed = s;
    [self _finchChanged];
}

/* A click on segment s: select (or toggle) it as the tracking mode says. */
- (void)_finchClickSegment:(NSInteger)s
{
    NSSegmentItem *item = [self _item:s];
    if (!item || item.disabled)
        return;
    switch (_trackingMode) {
    case NSSegmentSwitchTrackingSelectOne:
        [self setSelected:YES forSegment:s];
        break;
    case NSSegmentSwitchTrackingSelectAny:
        [self setSelected:!item.selected forSegment:s];
        break;
    default:
        _selected = s; /* for the action; cleared after it */
        break;
    }
}

- (void)_finchEndMomentary
{
    if (_trackingMode == NSSegmentSwitchTrackingMomentary || _trackingMode == NSSegmentSwitchTrackingMomentaryAccelerator)
        _selected = -1;
}

#pragma mark Drawing

- (void)drawSegment:(NSInteger)s inFrame:(NSRect)frame withView:(NSView *)controlView
{
    NSSegmentItem *item = [self _item:s];
    if (!item)
        return;
    BOOL selected = item.selected || s == _pressed;
    NSRect r = NSInsetRect(frame, 6, 0);
    NSImage *image = item.image;
    NSString *label = item.label;
    CGFloat iw = image ? MIN([image size].width, r.size.width) : 0;
    NSDictionary *attrs = [self _finchLabelAttributes:s selected:selected];
    CGFloat tw = [label length] ? ceil([label sizeWithAttributes:attrs].width) : 0;
    CGFloat content = iw + (iw && tw ? 4 : 0) + tw;
    CGFloat x = r.origin.x + MAX(0, (r.size.width - content) / 2);
    if (image) {
        NSRect ir = NSMakeRect(x, r.origin.y + 2, iw, r.size.height - 4);
        FinchDrawImageInRect(image, ir, item.imageScaling, NSImageAlignCenter, [controlView isFlipped],
                             [self isEnabled] && !item.disabled ? 1 : 0.4);
        x += iw + 4;
    }
    if ([label length]) {
        NSAttributedString *t = [[[NSAttributedString alloc] initWithString:label attributes:attrs] autorelease];
        NSRect tr = NSMakeRect(x, r.origin.y, MIN(tw, NSMaxX(r) - x), r.size.height);
        FinchDrawCellText(t, tr, [controlView isFlipped]);
    }
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    NSRect body = frame;
    CGFloat h = MIN(frame.size.height, [self _finchHeight] - 2);
    body.origin.y += floor((frame.size.height - h) / 2);
    body.size.height = h;
    body = NSInsetRect(body, 1, 0);
    BOOL enabled = [self isEnabled];
    CGFloat radius = _segmentStyle == NSSegmentStyleCapsule ? h / 2 : 6;
    if (_segmentStyle == NSSegmentStyleSmallSquare || _segmentStyle == NSSegmentStyleTexturedSquare)
        radius = 2;
    FinchDrawBezel(body, radius, FinchDisabled(FinchControlFill(NO), enabled), FinchDisabled(FinchControlStroke(), enabled));
    NSArray *rects = [self _finchSegmentRects:body];
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 0.5, 0.5) xRadius:radius yRadius:radius];
    for (NSUInteger s = 0; s < [rects count]; s++) {
        NSRect r = [rects[s] rectValue];
        NSSegmentItem *item = _items[s];
        BOOL pressed = (NSInteger)s == _pressed;
        if (item.selected || pressed) {
            NSColor *fill = item.selected && _trackingMode == NSSegmentSwitchTrackingSelectOne
                                ? FinchAccentColor()
                                : [NSColor colorWithSRGBRed:0.80 green:0.82 blue:0.86 alpha:1];
            if (pressed && item.selected)
                fill = [fill blendedColorWithFraction:0.15 ofColor:[NSColor blackColor]];
            else if (pressed)
                fill = FinchControlFill(YES);
            [NSGraphicsContext saveGraphicsState];
            [clip addClip];
            [FinchDisabled(fill, enabled) setFill];
            NSRectFill(r);
            [NSGraphicsContext restoreGraphicsState];
        }
        if (s > 0) {
            [FinchDisabled(FinchControlStroke(), enabled) setFill];
            NSRectFill(NSMakeRect(NSMinX(r), NSMinY(body) + 4, 1, body.size.height - 8));
        }
    }
    for (NSUInteger s = 0; s < [rects count]; s++)
        [self drawSegment:(NSInteger)s inFrame:[rects[s] rectValue] withView:controlView];
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    NSArray *rects = [self _finchSegmentRects:frame];
    for (NSUInteger s = 0; s < [rects count]; s++)
        [self drawSegment:(NSInteger)s inFrame:[rects[s] rectValue] withView:controlView];
}

@end
