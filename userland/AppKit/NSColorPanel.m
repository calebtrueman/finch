/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A shared color panel with Finch's own wheel, channel sliders and palette.
 * Programmatic color changes use the same action/notification path as clicks. */
#import "NSControl_Finch.h"
#include <math.h>
#import <objc/message.h>

NSNotificationName NSColorPanelColorDidChangeNotification = @"NSColorPanelColorDidChangeNotification";
@interface NSColorWell (FinchPanel)
+ (void)_finchPanelChanged:(NSColorPanel *)panel;
+ (void)_finchPanelClosed:(NSColorPanel *)panel;
@end
@interface NSColorPanel (FinchPicker)
- (void)_finchPickColor:(NSColor *)color final:(BOOL)final;
- (NSArray *)_finchPalette;
@end
@interface FinchColorChooser : NSView {
  @public
    NSColorPanel *_panel;
    NSSlider *_channels[4];
    NSSegmentedControl *_modes;
}
- (void)syncColor;
@end
@implementation FinchColorChooser
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _modes = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(12, 280, 226, 26)];
        _modes.segmentCount = 3;
        [_modes setLabel:@"Wheel" forSegment:0];
        [_modes setLabel:@"RGB" forSegment:1];
        [_modes setLabel:@"Palette" forSegment:2];
        for (NSInteger i = 0; i < 3; i++)
            [_modes setWidth:74 forSegment:i];
        _modes.target = self;
        _modes.action = @selector(changeMode:);
        [self addSubview:_modes];
        for (NSInteger i = 0; i < 4; i++) {
            NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(40, 16 + (3 - i) * 30, 195, 20)];
            slider.minValue = 0;
            slider.maxValue = 1;
            slider.continuous = YES;
            slider.target = self;
            slider.action = @selector(changeChannel:);
            slider.tag = i;
            _channels[i] = slider;
            [self addSubview:slider];
        }
    }
    return self;
}
- (void)dealloc
{
    for (NSUInteger i = 0; i < 4; i++)
        [_channels[i] release];
    [_modes release];
    [super dealloc];
}
- (void)changeMode:(id)sender
{
    _panel.mode = _modes.selectedSegment == 0   ? NSColorPanelModeWheel
                  : _modes.selectedSegment == 1 ? NSColorPanelModeRGB
                                                : NSColorPanelModeColorList;
}
- (void)syncColor
{
    NSColor *rgb = [_panel.color colorUsingColorSpace:[NSColorSpace extendedSRGBColorSpace]];
    if (rgb) {
        _channels[0].doubleValue = rgb.redComponent;
        _channels[1].doubleValue = rgb.greenComponent;
        _channels[2].doubleValue = rgb.blueComponent;
        _channels[3].doubleValue = rgb.alphaComponent;
    }
    _channels[3].hidden = !_panel.showsAlpha;
    _modes.selectedSegment = _panel.mode == NSColorPanelModeWheel       ? 0
                             : _panel.mode == NSColorPanelModeColorList ? 2
                                                                        : 1;
    [self setNeedsDisplay:YES];
}
- (void)changeChannel:(NSSlider *)sender
{
    NSColor *color = [NSColor colorWithSRGBRed:_channels[0].doubleValue
                                         green:_channels[1].doubleValue
                                          blue:_channels[2].doubleValue
                                         alpha:_panel.showsAlpha ? _channels[3].doubleValue : _panel.alpha];
    [_panel _finchPickColor:color final:YES];
}
- (NSRect)pickerRect
{
    return NSMakeRect(12, 140, MAX(1, self.bounds.size.width - 24), MAX(1, self.bounds.size.height - 190));
}
- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    _modes.frame = NSMakeRect(12, size.height - 34, size.width - 24, 26);
    for (NSUInteger i = 0; i < 4; i++)
        _channels[i].frame = NSMakeRect(40, 16 + (3 - i) * 30, MAX(1, size.width - 55), 20);
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirty
{
    [FinchControlFill(NO) setFill];
    NSRectFill(self.bounds);
    NSRect rect = [self pickerRect];
    if (_panel.mode == NSColorPanelModeColorList) {
        NSArray *colors = [_panel _finchPalette];
        CGFloat size = MIN(28, MIN(rect.size.width / 8, rect.size.height / MAX(1, ceil(colors.count / 8.0))));
        for (NSUInteger i = 0; i < colors.count; i++) {
            NSRect swatch =
                NSMakeRect(rect.origin.x + (i % 8) * size, NSMaxY(rect) - (i / 8 + 1) * size, size - 3, size - 3);
            if (NSMinY(swatch) < NSMinY(rect))
                break;
            [colors[i] setFill];
            NSRectFill(swatch);
        }
    } else if (_panel.mode == NSColorPanelModeWheel) {
        NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
        CGFloat radius = MIN(rect.size.width, rect.size.height) / 2;
        /* Each small tile samples hue and distance from the center. */
        for (CGFloat y = -radius; y < radius; y += 1) {
            for (CGFloat x = -radius; x < radius; x += 1) {
                CGFloat saturation = hypot(x + 0.5, y + 0.5) / radius;
                if (saturation > 1)
                    continue;
                CGFloat hue = atan2(y + 0.5, x + 0.5) / (2 * M_PI);
                if (hue < 0)
                    hue += 1;
                [[NSColor colorWithCalibratedHue:hue saturation:saturation brightness:1 alpha:1] setFill];
                NSRectFill(NSMakeRect(center.x + x, center.y + y, 1, 1));
            }
        }
    } else {
        [_panel.color setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 6, 6) xRadius:8 yRadius:8] fill];
    }
    NSArray *labels = @[ @"R", @"G", @"B", @"A" ];
    NSDictionary *attrs =
        @{NSFontAttributeName : [NSFont systemFontOfSize:12], NSForegroundColorAttributeName : [NSColor labelColor]};
    for (NSUInteger i = 0; i < 4; i++)
        if (i != 3 || _panel.showsAlpha)
            [labels[i] drawAtPoint:NSMakePoint(18, 18 + (3 - i) * 30) withAttributes:attrs];
}
- (NSColor *)colorAtPoint:(NSPoint)point
{
    NSRect rect = [self pickerRect];
    if (!NSPointInRect(point, rect))
        return nil;
    if (_panel.mode == NSColorPanelModeColorList) {
        NSArray *colors = [_panel _finchPalette];
        CGFloat size = MIN(28, MIN(rect.size.width / 8, rect.size.height / MAX(1, ceil(colors.count / 8.0))));
        NSInteger col = (point.x - rect.origin.x) / size, row = (NSMaxY(rect) - point.y) / size;
        NSUInteger index = row * 8 + col;
        return col >= 0 && col < 8 && row >= 0 && index < colors.count ? colors[index] : nil;
    }
    if (_panel.mode != NSColorPanelModeWheel)
        return nil;
    CGFloat x = point.x - NSMidX(rect), y = point.y - NSMidY(rect);
    CGFloat radius = MIN(rect.size.width, rect.size.height) / 2;
    CGFloat saturation = MIN(1, hypot(x, y) / radius);
    CGFloat hue = atan2(y, x) / (2 * M_PI);
    if (hue < 0)
        hue += 1;
    return [NSColor colorWithCalibratedHue:hue saturation:saturation brightness:1 alpha:_panel.alpha];
}
- (void)mouseDown:(NSEvent *)event
{
    NSColor *color = [self colorAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (!color)
        return;
    [_panel _finchPickColor:color final:NO];
    if (!self.window) {
        [_panel _finchPickColor:color final:YES];
        return;
    }
    NSEvent *next;
    while ((next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp])) {
        color = [self colorAtPoint:[self convertPoint:next.locationInWindow fromView:nil]] ?: _panel.color;
        [_panel _finchPickColor:color final:next.type == NSEventTypeLeftMouseUp];
        if (next.type == NSEventTypeLeftMouseUp)
            break;
    }
}
@end

static NSColorPanel *sharedPanel;
static NSColorPanelOptions pickerMask = NSColorPanelAllModesMask;
static NSColorPanelMode pickerMode = NSColorPanelModeRGB;
@implementation NSColorPanel {
    NSColor *_color;
    NSView *_accessory;
    FinchColorChooser *_chooser;
    NSMutableArray *_colorLists;
    __weak id _colorTarget;
    SEL _colorAction;
    NSColorPanelMode _mode;
    BOOL _continuous, _showsAlpha, _pendingChange;
    CGFloat _maximumExposure;
}
+ (NSColorPanel *)sharedColorPanel
{
    if (!sharedPanel)
        sharedPanel = [[self alloc] initWithContentRect:NSMakeRect(0, 90, 250, 323)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                                                backing:NSBackingStoreBuffered
                                                  defer:YES];
    return sharedPanel;
}
+ (BOOL)sharedColorPanelExists
{
    return sharedPanel != nil;
}
+ (void)setPickerMask:(NSColorPanelOptions)mask
{
    if (!sharedPanel)
        pickerMask = mask;
}
+ (void)setPickerMode:(NSColorPanelMode)mode
{
    pickerMode = mode;
    if (sharedPanel)
        sharedPanel.mode = mode;
}
+ (BOOL)dragColor:(NSColor *)color withEvent:(NSEvent *)event fromView:(NSView *)view
{
    return NO;
}
- (instancetype)initWithContentRect:(NSRect)rect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing
                              defer:(BOOL)defer
{
    if ((self = [super initWithContentRect:rect styleMask:style backing:backing defer:defer])) {
        _color = [[NSColor whiteColor] retain];
        _continuous = YES;
        _showsAlpha = YES;
        _maximumExposure = 0;
        _mode = pickerMode >= 0 && pickerMode <= 7 ? pickerMode : NSColorPanelModeRGB;
        if (!(pickerMask & (1UL << _mode))) {
            for (NSInteger i = 0; i <= 7; i++)
                if (pickerMask & (1UL << i)) {
                    _mode = i;
                    break;
                }
        }
        _colorLists = [[NSMutableArray alloc] init];
        self.title = @"Colors";
        self.floatingPanel = YES;
        self.worksWhenModal = YES;
        self.becomesKeyOnlyIfNeeded = YES;
        self.hidesOnDeactivate = YES;
        self.releasedWhenClosed = NO;
        self.minSize = NSMakeSize(250, 320);
        _chooser = [[FinchColorChooser alloc] initWithFrame:self.contentView.bounds];
        _chooser->_panel = self;
        _chooser.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.contentView addSubview:_chooser];
        [_chooser syncColor];
    }
    return self;
}
- (void)dealloc
{
    [_color release];
    [_accessory release];
    [_chooser release];
    [_colorLists release];
    [super dealloc];
}
- (NSColor *)color
{
    return _color;
}
- (void)_finchSendPanelAction
{
    if (_colorAction)
        [NSApp sendAction:_colorAction to:_colorTarget from:self];
}
- (BOOL)worksWhenModal
{
    return YES;
}
- (BOOL)becomesKeyOnlyIfNeeded
{
    return YES;
}
- (void)_finchNotifyColorChange
{
    _pendingChange = NO;
    if (_colorAction)
        [NSApp sendAction:_colorAction to:_colorTarget from:self];
    [NSColorWell _finchPanelChanged:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSColorPanelColorDidChangeNotification object:self];
}
- (void)setColor:(NSColor *)color
{
    if (!color || [_color isEqual:color])
        return;
    [_color release];
    _color = [color copy];
    [_chooser syncColor];
    [self _finchNotifyColorChange];
}
- (void)_finchPickColor:(NSColor *)color final:(BOOL)final
{
    if (!color)
        return;
    if (_continuous) {
        self.color = color;
        return;
    }
    if (![_color isEqual:color]) {
        [_color release];
        _color = [color copy];
        _pendingChange = YES;
        [_chooser syncColor];
    }
    if (final && _pendingChange)
        [self _finchNotifyColorChange];
}
- (CGFloat)alpha
{
    return _color.alphaComponent;
}
- (BOOL)isContinuous
{
    return _continuous;
}
- (void)setContinuous:(BOOL)flag
{
    _continuous = flag;
    for (NSUInteger i = 0; i < 4; i++)
        _chooser->_channels[i].continuous = flag;
}
- (BOOL)showsAlpha
{
    return _showsAlpha;
}
- (void)setShowsAlpha:(BOOL)flag
{
    _showsAlpha = flag;
    [_chooser syncColor];
}
- (NSColorPanelMode)mode
{
    return _mode;
}
- (void)setMode:(NSColorPanelMode)mode
{
    if (mode < 0 || mode > 7 || !(pickerMask & (1UL << mode)))
        return;
    _mode = mode;
    [_chooser syncColor];
}
- (id)target
{
    return _colorTarget;
}
- (void)setTarget:(id)target
{
    _colorTarget = target;
}
- (SEL)action
{
    return _colorAction;
}
- (void)setAction:(SEL)action
{
    _colorAction = action;
}
- (CGFloat)maximumLinearExposure
{
    return _maximumExposure;
}
- (void)setMaximumLinearExposure:(CGFloat)value
{
    _maximumExposure = MAX(0, value);
}
- (NSView *)accessoryView
{
    return _accessory;
}
- (void)setAccessoryView:(NSView *)view
{
    if (view == _accessory)
        return;
    CGFloat before = _accessory ? _accessory.frame.size.height + 8 : 0;
    [_accessory removeFromSuperview];
    [_accessory release];
    _accessory = [view retain];
    CGFloat after = view ? view.frame.size.height + 8 : 0;
    NSRect frame = self.frame;
    frame.size.height += after - before;
    frame.origin.y -= after - before;
    [self setFrame:frame display:NO];
    NSRect content = self.contentView.bounds;
    _chooser.frame = NSMakeRect(0, after, content.size.width, MAX(1, content.size.height - after));
    if (view) {
        view.frame = NSMakeRect(0, 0, content.size.width, after - 8);
        view.autoresizingMask = NSViewWidthSizable;
        [self.contentView addSubview:view];
    }
}
- (void)attachColorList:(NSColorList *)list
{
    if (list && ![_colorLists containsObject:list])
        [_colorLists addObject:list];
    [_chooser setNeedsDisplay:YES];
}
- (void)detachColorList:(NSColorList *)list
{
    [_colorLists removeObjectIdenticalTo:list];
    [_chooser setNeedsDisplay:YES];
}
- (NSArray *)_finchPalette
{
    NSMutableArray *colors = [NSMutableArray array];
    for (NSColorList *list in _colorLists)
        for (NSString *key in list.allKeys) {
            NSColor *c = [list colorWithKey:key];
            if (c)
                [colors addObject:c];
        }
    if (!colors.count) {
        [colors addObjectsFromArray:@[
            [NSColor blackColor], [NSColor darkGrayColor], [NSColor grayColor], [NSColor lightGrayColor],
            [NSColor whiteColor], [NSColor redColor], [NSColor greenColor], [NSColor blueColor]
        ]];
        for (NSUInteger i = 0; i < 32; i++)
            [colors addObject:[NSColor colorWithCalibratedHue:(i % 8) / 8.0
                                                   saturation:0.4 + (i / 8) * 0.2
                                                   brightness:1
                                                        alpha:1]];
    }
    return colors;
}
- (void)close
{
    [NSColorWell _finchPanelClosed:self];
    [super close];
}
@end

@implementation NSApplication (FinchColorPanel)
- (void)orderFrontColorPanel:(id)sender
{
    [[NSColorPanel sharedColorPanel] orderFront:sender];
}
@end
