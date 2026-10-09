/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSRulerView and NSRulerMarker. A ruler belongs to a scroll view, which
 * floats it over the content's top or leading edge (NSScrollView.m). From
 * the content outwards it holds the rule (hash marks and labels,
 * ruleThickness), the markers (reservedThicknessForMarkers) and an
 * accessory view; the baseline is where the rule meets the markers. Hash
 * marks follow the client view's coordinates, offset by originOffset, in
 * the registered units. Markers are dragged with -trackMouse:adding:,
 * which asks the client view (the NSRulerView client methods) at each step.
 */
#import "NSView_Finch.h"

@interface NSRulerView (FinchPrivate)
- (CGFloat)_finchRulerLocation:(CGFloat)location;
- (CGFloat)_finchClientLocation:(CGFloat)location;
- (void)_finchRetile;
- (void)_finchPlaceAccessory;
@end

static NSMutableDictionary<NSString *, NSDictionary *> *units;

static void
register_builtin_units(void)
{
    if (units)
        return;
    units = [NSMutableDictionary new];
    units[@"Inches"] = @{@"abbr" : @"in", @"points" : @72.0, @"up" : @[ @2.0 ], @"down" : @[ @0.5 ]};
    units[@"Centimeters"] = @{@"abbr" : @"cm", @"points" : @(72.0 / 2.54), @"up" : @[ @2.0 ], @"down" : @[ @0.5, @0.2 ]};
    units[@"Points"] = @{@"abbr" : @"pt", @"points" : @1.0, @"up" : @[ @10.0 ], @"down" : @[ @0.5 ]};
    units[@"Picas"] = @{@"abbr" : @"pc", @"points" : @12.0, @"up" : @[ @10.0 ], @"down" : @[ @0.5 ]};
}

static NSString *
default_units(void)
{
    NSString *pref = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleMeasurementUnits"];
    if ([pref isEqualToString:@"Inches"] || [pref isEqualToString:@"Centimeters"])
        return pref;
    return [[NSLocale currentLocale] usesMetricSystem] ? @"Centimeters" : @"Inches";
}

@implementation NSRulerView {
    NSScrollView *_scrollView; /* weak: the scroll view owns its rulers */
    NSView *_clientView;       /* weak */
    NSView *_accessoryView;
    NSMutableArray<NSRulerMarker *> *_markers;
    NSRulerOrientation _orientation;
    NSString *_units;
    CGFloat _origin, _rule, _markerSpace, _accessorySpace;
}

+ (void)registerUnitWithName:(NSString *)name
                abbreviation:(NSString *)abbreviation
unitToPointsConversionFactor:(CGFloat)factor
                 stepUpCycle:(NSArray<NSNumber *> *)up
               stepDownCycle:(NSArray<NSNumber *> *)down
{
    register_builtin_units();
    units[name] = @{@"abbr" : abbreviation ?: @"", @"points" : @(factor), @"up" : up ?: @[], @"down" : down ?: @[]};
}

- (instancetype)initWithScrollView:(NSScrollView *)scrollView orientation:(NSRulerOrientation)orientation
{
    self = [super initWithFrame:NSMakeRect(0, 0, 10, 10)];
    if (self) {
        register_builtin_units();
        _scrollView = scrollView;
        _orientation = orientation;
        _units = [default_units() copy];
        _rule = 17;
        _markerSpace = orientation == NSHorizontalRuler ? 15 : 0;
        _markers = [NSMutableArray new];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [self initWithScrollView:nil orientation:NSHorizontalRuler];
    if (self)
        [self setFrame:frame];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        register_builtin_units();
        _units = [default_units() copy];
        _rule = 17;
        _markerSpace = 15;
        _markers = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc
{
    [_markers release];
    [_accessoryView release];
    [_units release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

#pragma mark Properties

- (NSScrollView *)scrollView { return _scrollView; }
- (void)setScrollView:(NSScrollView *)sv { _scrollView = sv; }
- (NSRulerOrientation)orientation { return _orientation; }
- (void)setOrientation:(NSRulerOrientation)o
{
    _orientation = o;
    [self _finchRetile];
}
- (NSString *)measurementUnits { return _units; }
- (void)setMeasurementUnits:(NSString *)name
{
    [_units autorelease];
    _units = [name copy];
    [self setNeedsDisplay:YES];
}
- (CGFloat)originOffset { return _origin; }
- (void)setOriginOffset:(CGFloat)o
{
    _origin = o;
    [self setNeedsDisplay:YES];
}
- (CGFloat)ruleThickness { return _rule; }
- (void)setRuleThickness:(CGFloat)t
{
    _rule = t;
    [self _finchRetile];
}
- (CGFloat)reservedThicknessForMarkers { return _markerSpace; }
- (void)setReservedThicknessForMarkers:(CGFloat)t
{
    _markerSpace = t;
    [self _finchRetile];
}
- (CGFloat)reservedThicknessForAccessoryView { return _accessorySpace; }
- (void)setReservedThicknessForAccessoryView:(CGFloat)t
{
    _accessorySpace = t;
    [self _finchRetile];
}

- (CGFloat)_finchMarkerThickness
{
    CGFloat t = _markerSpace;
    for (NSRulerMarker *m in _markers)
        t = MAX(t, [m thicknessRequiredInRuler]);
    return t;
}

- (CGFloat)requiredThickness { return _rule + [self _finchMarkerThickness] + _accessorySpace; }

/* As Apple's: how far the rule lies from the outer edge, whatever the ruler's size now. */
- (CGFloat)baselineLocation
{
    CGFloat size = _orientation == NSHorizontalRuler ? NSHeight([self frame]) : NSWidth([self frame]);
    return MAX(0, size - _rule);
}

- (void)_finchRetile
{
    if ([self superview] && [self superview] == _scrollView)
        [_scrollView tile];
    [self _finchPlaceAccessory];
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self _finchPlaceAccessory];
}

#pragma mark The accessory view and client

- (NSView *)accessoryView { return _accessoryView; }
- (void)setAccessoryView:(NSView *)view
{
    if (view == _accessoryView)
        return;
    [_accessoryView removeFromSuperview];
    [_accessoryView release];
    _accessoryView = [view retain];
    if (view)
        [self addSubview:view];
    [self _finchPlaceAccessory];
}

- (void)_finchPlaceAccessory
{
    if (!_accessoryView)
        return;
    NSRect b = [self bounds];
    if (_orientation == NSHorizontalRuler)
        [_accessoryView setFrame:NSMakeRect(0, 0, NSWidth(b), _accessorySpace)];
    else
        [_accessoryView setFrame:NSMakeRect(0, 0, _accessorySpace, NSHeight(b))];
}

- (NSView *)clientView { return _clientView; }
- (void)setClientView:(NSView *)client
{
    if (client == _clientView)
        return;
    if ([_clientView respondsToSelector:@selector(rulerView:willSetClientView:)])
        [(id)_clientView rulerView:self willSetClientView:client];
    _clientView = client;
    [_markers removeAllObjects];
    [self setAccessoryView:nil];
    [self _finchRetile];
}

#pragma mark Markers

- (NSArray<NSRulerMarker *> *)markers { return [[_markers copy] autorelease]; }

- (void)setMarkers:(NSArray<NSRulerMarker *> *)markers
{
    if ([markers count] && !_clientView)
        [NSException raise:NSInternalInconsistencyException
                    format:@"*** -[NSRulerView setMarkers:]: you must set the client view of the ruler before you can add ruler markers."];
    [_markers setArray:markers ?: @[]];
    [self _finchRetile];
}

- (void)addMarker:(NSRulerMarker *)marker
{
    if (!_clientView)
        [NSException raise:NSInternalInconsistencyException
                    format:@"*** -[NSRulerView addMarker:]: you must set the client view of the ruler before you can add ruler markers."];
    [_markers addObject:marker];
    [self _finchRetile];
}

- (void)removeMarker:(NSRulerMarker *)marker
{
    [_markers removeObjectIdenticalTo:marker];
    [self setNeedsDisplay:YES];
}

- (BOOL)trackMarker:(NSRulerMarker *)marker withMouseEvent:(NSEvent *)event
{
    return [marker trackMouse:event adding:YES];
}

#pragma mark Coordinates

/* A location along the client view, in the ruler's own coordinates, and back. */
- (CGFloat)_finchRulerLocation:(CGFloat)location
{
    NSView *client = _clientView ?: [_scrollView documentView];
    if (!client || ![self superview])
        return location;
    NSPoint p = _orientation == NSHorizontalRuler ? NSMakePoint(location, 0) : NSMakePoint(0, location);
    p = [self convertPoint:p fromView:client];
    return _orientation == NSHorizontalRuler ? p.x : p.y;
}

- (CGFloat)_finchClientLocation:(CGFloat)location
{
    NSView *client = _clientView ?: [_scrollView documentView];
    if (!client || ![self superview])
        return location;
    NSPoint p = _orientation == NSHorizontalRuler ? NSMakePoint(location, 0) : NSMakePoint(0, location);
    p = [self convertPoint:p toView:client];
    return _orientation == NSHorizontalRuler ? p.x : p.y;
}

#pragma mark Drawing

- (void)invalidateHashMarks { [self setNeedsDisplay:YES]; }

- (void)moveRulerlineFromLocation:(CGFloat)old toLocation:(CGFloat)new
{
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(dirty);
    [self drawHashMarksAndLabelsInRect:dirty];
    [self drawMarkersInRect:dirty];
    NSRect b = [self bounds];
    [[NSColor separatorColor] setFill];
    if (_orientation == NSHorizontalRuler)
        NSRectFill(NSMakeRect(NSMinX(b), NSMaxY(b) - 1, NSWidth(b), 1));
    else
        NSRectFill(NSMakeRect(NSMaxX(b) - 1, NSMinY(b), 1, NSHeight(b)));
}

- (void)drawHashMarksAndLabelsInRect:(NSRect)rect
{
    NSDictionary *unit = units[_units] ?: units[@"Inches"];
    CGFloat step = [unit[@"points"] doubleValue];
    if (step <= 0)
        return;
    BOOL h = _orientation == NSHorizontalRuler;
    NSRect b = [self bounds];
    CGFloat base = [self baselineLocation], extent = h ? NSWidth(b) : NSHeight(b);
    /* the unit's zero, and the visible span in client units */
    CGFloat zero = [self _finchRulerLocation:_origin];
    /* Labels every unit, or every few units as the step-up cycle says when units are close together. */
    CGFloat labelStep = step;
    NSArray *up = unit[@"up"];
    for (NSUInteger i = 0; labelStep < 36 && [up count] && i < 8; i++)
        labelStep *= [up[i % [up count]] doubleValue];
    /* Finer marks while they stay at least five points apart. */
    NSMutableArray *finer = [NSMutableArray array];
    CGFloat f = labelStep;
    NSArray *down = unit[@"down"];
    for (NSUInteger i = 0; [down count] && i < 8; i++) {
        CGFloat next = f * [down[i % [down count]] doubleValue];
        if (next < 5)
            break;
        [finer addObject:@(next)];
        f = next;
    }
    NSColor *ink = [NSColor secondaryLabelColor];
    [ink setFill];
    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:9],
        NSForegroundColorAttributeName : [NSColor secondaryLabelColor]
    };
    long first = (long)floor((0 - zero) / labelStep) - 1, last = (long)ceil((extent - zero) / labelStep) + 1;
    for (long i = first; i <= last; i++) {
        CGFloat at = zero + i * labelStep;
        CGFloat len = _rule * 0.6;
        NSRect mark = h ? NSMakeRect(round(at), base + _rule - len, 1, len) : NSMakeRect(base + _rule - len, round(at), len, 1);
        NSRectFill(mark);
        if (i >= 0 || zero > 0) {
            NSString *label = [NSString stringWithFormat:@"%ld", (long)llround(i * labelStep / step)];
            if (h)
                [label drawAtPoint:NSMakePoint(round(at) + 3, base) withAttributes:attrs];
            else
                [label drawAtPoint:NSMakePoint(base + 1, round(at) + 1) withAttributes:attrs];
        }
        /* the finer marks after this one, shorter at each level */
        CGFloat level = 0.35;
        for (NSNumber *n in finer) {
            CGFloat d = [n doubleValue];
            for (CGFloat x = at + d; x < at + labelStep - 0.5; x += d) {
                CGFloat l = _rule * level;
                NSRectFill(h ? NSMakeRect(round(x), base + _rule - l, 1, l) : NSMakeRect(base + _rule - l, round(x), l, 1));
            }
            level *= 0.7;
        }
    }
}

- (void)drawMarkersInRect:(NSRect)rect
{
    for (NSRulerMarker *m in _markers)
        if (NSIntersectsRect([m imageRectInRuler], rect))
            [m drawRect:rect];
}

#pragma mark Events

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    for (NSRulerMarker *m in [_markers reverseObjectEnumerator]) {
        if (NSPointInRect(p, NSInsetRect([m imageRectInRuler], -2, -2))) {
            [m trackMouse:event adding:NO];
            return;
        }
    }
    if ([_clientView respondsToSelector:@selector(rulerView:handleMouseDown:)])
        [(id)_clientView rulerView:self handleMouseDown:event];
}

@end

#pragma mark - NSRulerMarker

@implementation NSRulerMarker {
    NSRulerView *_ruler; /* weak */
    CGFloat _location;
    NSImage *_image;
    NSPoint _imageOrigin;
    BOOL _movable, _removable, _dragging;
    id _represented;
}

- (instancetype)initWithRulerView:(NSRulerView *)ruler
                   markerLocation:(CGFloat)location
                            image:(NSImage *)image
                      imageOrigin:(NSPoint)origin
{
    self = [super init];
    if (self) {
        _ruler = ruler;
        _location = location;
        _image = [image retain];
        _imageOrigin = origin;
        _movable = YES;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self)
        _movable = YES;
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {}

- (id)copyWithZone:(NSZone *)zone
{
    NSRulerMarker *m = [[NSRulerMarker allocWithZone:zone] initWithRulerView:_ruler markerLocation:_location
                                                                       image:_image imageOrigin:_imageOrigin];
    m->_movable = _movable;
    m->_removable = _removable;
    m->_represented = [_represented copyWithZone:zone];
    return m;
}

- (void)dealloc
{
    [_image release];
    [_represented release];
    [super dealloc];
}

- (NSRulerView *)ruler { return _ruler; }
- (CGFloat)markerLocation { return _location; }
- (void)setMarkerLocation:(CGFloat)l
{
    _location = l;
    [_ruler setNeedsDisplay:YES];
}
- (NSImage *)image { return _image; }
- (void)setImage:(NSImage *)image
{
    [_image autorelease];
    _image = [image retain];
    [_ruler setNeedsDisplay:YES];
}
- (NSPoint)imageOrigin { return _imageOrigin; }
- (void)setImageOrigin:(NSPoint)o { _imageOrigin = o; }
- (BOOL)isMovable { return _movable; }
- (void)setMovable:(BOOL)f { _movable = f; }
- (BOOL)isRemovable { return _removable; }
- (void)setRemovable:(BOOL)f { _removable = f; }
- (BOOL)isDragging { return _dragging; }
- (id<NSCopying>)representedObject { return _represented; }
- (void)setRepresentedObject:(id<NSCopying>)o
{
    [_represented autorelease];
    _represented = [(id)o retain];
}

- (CGFloat)thicknessRequiredInRuler
{
    NSSize s = [_image size];
    return [_ruler orientation] == NSVerticalRuler ? s.width : s.height;
}

/* The image's origin sits on the marker's location, at the ruler's baseline. */
- (NSRect)imageRectInRuler
{
    NSSize s = [_image size];
    CGFloat at = [_ruler _finchRulerLocation:_location], base = [_ruler baselineLocation];
    if ([_ruler orientation] == NSVerticalRuler)
        return NSMakeRect(base - s.width + _imageOrigin.x, at - _imageOrigin.y, s.width, s.height);
    return NSMakeRect(at - _imageOrigin.x, base - s.height + _imageOrigin.y, s.width, s.height);
}

- (void)drawRect:(NSRect)rect
{
    NSRect r = [self imageRectInRuler];
    [_image drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:_dragging ? 0.7 : 1
        respectFlipped:YES hints:nil];
}

/*
 * Follows the mouse until it goes up, asking the client at each step. A removable marker
 * dragged well away from the ruler goes; a marker being added that ends outside it isn't added.
 */
- (BOOL)trackMouse:(NSEvent *)event adding:(BOOL)adding
{
    NSRulerView *r = _ruler;
    id client = [r clientView];
    if (!adding && !_movable && !_removable)
        return NO;
    if (!adding && [client respondsToSelector:@selector(rulerView:shouldMoveMarker:)] &&
        ![client rulerView:r shouldMoveMarker:self])
        return NO;
    if (adding && [client respondsToSelector:@selector(rulerView:shouldAddMarker:)] &&
        ![client rulerView:r shouldAddMarker:self])
        return NO;
    BOOL h = [r orientation] == NSHorizontalRuler;
    NSPoint start = [r convertPoint:[event locationInWindow] fromView:nil];
    CGFloat grab = (h ? start.x : start.y) - [r _finchRulerLocation:_location];
    if (adding) {
        grab = 0;
        [r addMarker:self];
    }
    _dragging = YES;
    BOOL away = NO;
    NSWindow *w = [r window];
    for (;;) {
        NSEvent *e = [w nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
        if (!e)
            break;
        NSPoint p = [r convertPoint:[e locationInWindow] fromView:nil];
        CGFloat across = h ? p.y : p.x, size = h ? NSHeight([r bounds]) : NSWidth([r bounds]);
        away = (adding || _removable) && (across < -16 || across > size + 16);
        if (_movable || adding) {
            CGFloat loc = [r _finchClientLocation:(h ? p.x : p.y) - grab];
            if (!adding && [client respondsToSelector:@selector(rulerView:willMoveMarker:toLocation:)])
                loc = [client rulerView:r willMoveMarker:self toLocation:loc];
            else if (adding && [client respondsToSelector:@selector(rulerView:willAddMarker:atLocation:)])
                loc = [client rulerView:r willAddMarker:self atLocation:loc];
            _location = loc;
        }
        [r setNeedsDisplay:YES];
        [r displayIfNeeded];
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
    }
    _dragging = NO;
    [[self retain] autorelease];
    if (away) {
        BOOL remove = adding || ![client respondsToSelector:@selector(rulerView:shouldRemoveMarker:)] ||
                      [client rulerView:r shouldRemoveMarker:self];
        if (remove) {
            [r removeMarker:self];
            if (!adding && [client respondsToSelector:@selector(rulerView:didRemoveMarker:)])
                [client rulerView:r didRemoveMarker:self];
            return !adding;
        }
    }
    if (adding) {
        if ([client respondsToSelector:@selector(rulerView:didAddMarker:)])
            [client rulerView:r didAddMarker:self];
    } else if ([client respondsToSelector:@selector(rulerView:didMoveMarker:)]) {
        [client rulerView:r didMoveMarker:self];
    }
    [r setNeedsDisplay:YES];
    return YES;
}

@end
