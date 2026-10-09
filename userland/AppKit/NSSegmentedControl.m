/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSegmentedControl: an NSControl over an NSSegmentedCell. A click selects
 * (or, selecting any, toggles) the segment under the mouse and sends the
 * action; momentary segments are selected only while the action is sent.
 */
#import "NSControl_Finch.h"

@interface NSSegmentedCell (FinchSegments)
- (NSInteger)_finchSegmentAtPoint:(NSPoint)p inFrame:(NSRect)frame;
- (void)_finchSetPressed:(NSInteger)s;
- (void)_finchClickSegment:(NSInteger)s;
- (void)_finchEndMomentary;
- (NSSegmentDistribution)_finchDistribution;
- (void)_finchSetDistribution:(NSSegmentDistribution)d;
- (void)setShowsMenuIndicator:(BOOL)f forSegment:(NSInteger)s;
- (BOOL)showsMenuIndicatorForSegment:(NSInteger)s;
- (void)setAlignment:(NSTextAlignment)a forSegment:(NSInteger)s;
- (NSTextAlignment)alignmentForSegment:(NSInteger)s;
@end

@implementation NSSegmentedControl {
    NSColor *_selectedSegmentBezelColor;
    NSControlBorderShape _borderShape;
    BOOL _springLoaded;
}

+ (Class)cellClass
{
    return [super cellClass] ?: [NSSegmentedCell class];
}

- (void)dealloc
{
    [_selectedSegmentBezelColor release];
    [super dealloc];
}

static NSSegmentedCell *
seg(NSSegmentedControl *c)
{
    id cell = [c cell];
    return [cell isKindOfClass:[NSSegmentedCell class]] ? cell : nil;
}

+ (instancetype)segmentedControlWithLabels:(NSArray<NSString *> *)labels trackingMode:(NSSegmentSwitchTracking)mode
                                    target:(id)target action:(SEL)action
{
    NSSegmentedControl *c = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [c setSegmentCount:(NSInteger)[labels count]];
    for (NSUInteger i = 0; i < [labels count]; i++) {
        [c setLabel:labels[i] forSegment:(NSInteger)i];
        [c setTag:(NSInteger)i forSegment:(NSInteger)i];
    }
    [c setTrackingMode:mode];
    [c setTarget:target];
    [c setAction:action];
    [c sizeToFit];
    return c;
}

+ (instancetype)segmentedControlWithImages:(NSArray<NSImage *> *)images trackingMode:(NSSegmentSwitchTracking)mode
                                    target:(id)target action:(SEL)action
{
    NSSegmentedControl *c = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [c setSegmentCount:(NSInteger)[images count]];
    for (NSUInteger i = 0; i < [images count]; i++) {
        [c setImage:images[i] forSegment:(NSInteger)i];
        [c setTag:(NSInteger)i forSegment:(NSInteger)i];
    }
    [c setTrackingMode:mode];
    [c setTarget:target];
    [c setAction:action];
    [c sizeToFit];
    return c;
}

#pragma mark Forwarding

- (NSInteger)segmentCount { return [seg(self) segmentCount]; }
- (void)setSegmentCount:(NSInteger)n { [seg(self) setSegmentCount:n]; [self setNeedsDisplay:YES]; }
- (NSInteger)selectedSegment { return [seg(self) selectedSegment]; }
- (void)setSelectedSegment:(NSInteger)s { [seg(self) setSelectedSegment:s]; [self setNeedsDisplay:YES]; }
- (NSInteger)indexOfSelectedItem { return [self selectedSegment]; }
- (BOOL)selectSegmentWithTag:(NSInteger)tag { return [seg(self) selectSegmentWithTag:tag]; }
- (void)setWidth:(CGFloat)w forSegment:(NSInteger)s { [seg(self) setWidth:w forSegment:s]; }
- (CGFloat)widthForSegment:(NSInteger)s { return [seg(self) widthForSegment:s]; }
- (void)setImage:(NSImage *)i forSegment:(NSInteger)s { [seg(self) setImage:i forSegment:s]; }
- (NSImage *)imageForSegment:(NSInteger)s { return [seg(self) imageForSegment:s]; }
- (void)setImageScaling:(NSImageScaling)v forSegment:(NSInteger)s { [seg(self) setImageScaling:v forSegment:s]; }
- (NSImageScaling)imageScalingForSegment:(NSInteger)s { return [seg(self) imageScalingForSegment:s]; }
- (void)setLabel:(NSString *)l forSegment:(NSInteger)s { [seg(self) setLabel:l forSegment:s]; }
- (NSString *)labelForSegment:(NSInteger)s { return [seg(self) labelForSegment:s]; }
- (void)setMenu:(NSMenu *)m forSegment:(NSInteger)s { [seg(self) setMenu:m forSegment:s]; }
- (NSMenu *)menuForSegment:(NSInteger)s { return [seg(self) menuForSegment:s]; }
- (void)setSelected:(BOOL)f forSegment:(NSInteger)s { [seg(self) setSelected:f forSegment:s]; [self setNeedsDisplay:YES]; }
- (BOOL)isSelectedForSegment:(NSInteger)s { return [seg(self) isSelectedForSegment:s]; }
- (void)setEnabled:(BOOL)f forSegment:(NSInteger)s { [seg(self) setEnabled:f forSegment:s]; }
- (BOOL)isEnabledForSegment:(NSInteger)s { return [seg(self) isEnabledForSegment:s]; }
- (void)setToolTip:(NSString *)t forSegment:(NSInteger)s { [seg(self) setToolTip:t forSegment:s]; }
- (NSString *)toolTipForSegment:(NSInteger)s { return [seg(self) toolTipForSegment:s]; }
- (void)setTag:(NSInteger)t forSegment:(NSInteger)s { [seg(self) setTag:t forSegment:s]; }
- (NSInteger)tagForSegment:(NSInteger)s { return [seg(self) tagForSegment:s]; }
- (void)setShowsMenuIndicator:(BOOL)f forSegment:(NSInteger)s { [seg(self) setShowsMenuIndicator:f forSegment:s]; }
- (BOOL)showsMenuIndicatorForSegment:(NSInteger)s { return [seg(self) showsMenuIndicatorForSegment:s]; }
- (void)setAlignment:(NSTextAlignment)a forSegment:(NSInteger)s { [seg(self) setAlignment:a forSegment:s]; }
- (NSTextAlignment)alignmentForSegment:(NSInteger)s { return [seg(self) alignmentForSegment:s]; }
- (NSSegmentStyle)segmentStyle { return [seg(self) segmentStyle]; }
- (void)setSegmentStyle:(NSSegmentStyle)s { [seg(self) setSegmentStyle:s]; }
- (NSSegmentSwitchTracking)trackingMode { return [seg(self) trackingMode]; }
- (void)setTrackingMode:(NSSegmentSwitchTracking)m { [seg(self) setTrackingMode:m]; }
- (NSSegmentDistribution)segmentDistribution { return [seg(self) _finchDistribution]; }
- (void)setSegmentDistribution:(NSSegmentDistribution)d { [seg(self) _finchSetDistribution:d]; }
- (BOOL)isSpringLoaded { return _springLoaded; }
- (void)setSpringLoaded:(BOOL)f { _springLoaded = f; }
- (NSControlBorderShape)borderShape { return _borderShape; }
- (void)setBorderShape:(NSControlBorderShape)s { _borderShape = s; }
- (NSColor *)selectedSegmentBezelColor { return _selectedSegmentBezelColor; }

- (void)setSelectedSegmentBezelColor:(NSColor *)c
{
    [_selectedSegmentBezelColor release];
    _selectedSegmentBezelColor = [c copy];
    [self setNeedsDisplay:YES];
}

- (double)doubleValueForSelectedSegment
{
    return 0;
}

- (BOOL)acceptsFirstResponder
{
    return [self segmentCount] > 0 && [super acceptsFirstResponder];
}

#pragma mark Clicks

- (void)mouseDown:(NSEvent *)event
{
    NSSegmentedCell *c = seg(self);
    if (!c || ![self isEnabled])
        return;
    NSRect bounds = [self bounds];
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger s = [c _finchSegmentAtPoint:p inFrame:bounds];
    if (s < 0 || ![c isEnabledForSegment:s])
        return;
    [c _finchSetPressed:s];
    [[self window] displayIfNeeded];
    BOOL inside = YES;
    for (;;) {
        NSEvent *e = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        if (!e)
            break;
        p = [self convertPoint:[e locationInWindow] fromView:nil];
        inside = NSMouseInRect(p, bounds, [self isFlipped]) && [c _finchSegmentAtPoint:p inFrame:bounds] == s;
        [c _finchSetPressed:inside ? s : -1];
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
    }
    [c _finchSetPressed:-1];
    if (!inside)
        return;
    [c _finchClickSegment:s];
    [self sendAction:[self action] to:[self target]];
    [c _finchEndMomentary];
    [self setNeedsDisplay:YES];
}

#pragma mark Compression

- (void)compressWithPrioritizedCompressionOptions:(NSArray<NSUserInterfaceCompressionOptions *> *)options {}

- (NSSize)minimumSizeWithPrioritizedCompressionOptions:(NSArray<NSUserInterfaceCompressionOptions *> *)options
{
    return [self intrinsicContentSize];
}

- (NSUserInterfaceCompressionOptions *)activeCompressionOptions
{
    return [[[(id)FINCH_CLASS(NSUserInterfaceCompressionOptions) alloc] init] autorelease];
}

@end
