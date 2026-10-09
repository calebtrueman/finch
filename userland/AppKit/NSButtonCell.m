/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSButtonCell: push buttons, toggles, checkboxes and radio buttons. The
 * button's value is its state (objectValue is the state as a number, as
 * Apple's); the title is separate. Button types set highlightsBy and
 * showsStateBy as Apple's do (measured by finch-appkit-controls-test).
 *
 * Nib flags (NSButtonFlags, NSButtonFlags2), from ibtool's output:
 *   NSButtonFlags: 0x80000000 push in, 0x40000000 change contents,
 *     0x20000000 change background, 0x10000000 change gray, 0x08000000
 *     light by contents, 0x04000000 light by background, 0x02000000 light
 *     by gray, 0x00800000 bordered, 0x00780000 image position (0x40 image
 *     only / overlaps, 0x08 image and title, 0x20 horizontal, 0x10 left or
 *     below, in the byte at bit 16), 0x00008000 transparent, 0x00006000
 *     inset, 0x00001000 image doesn't dim when disabled
 *   NSButtonFlags2: 0x27 bezel style (low three bits, 0x20 adds 8),
 *     0xc0 image scaling (archive value - 2, mod 4), bits 8 up the key
 *     equivalent's modifier mask shifted down 8
 *
 * Drawing is Finch's own: flat rounded bezels, the accent colour for the
 * default button and for "on" checkboxes and radio buttons.
 */
#import "NSControl_Finch.h"

/* The images a switch or radio button shows (Finch's drawings, named as Apple's). */
static NSImage *
standard_image(NSString *name)
{
    static NSMutableDictionary *images;
    if (!images)
        images = [[NSMutableDictionary alloc] init];
    NSImage *i = images[name];
    if (i)
        return i;
    BOOL radio = [name hasPrefix:@"NSRadio"];
    BOOL on = [name hasSuffix:@"Highlighted"] || [name isEqualToString:@"NSHighlightedRadioButton"];
    i = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect r) {
        if (radio)
            FinchDrawRadio(r, on ? NSControlStateValueOn : NSControlStateValueOff, NO, YES);
        else
            FinchDrawCheckbox(r, on ? NSControlStateValueOn : NSControlStateValueOff, NO, YES);
        return YES;
    }];
    [i setName:name];
    images[name] = i;
    return i;
}

/* A nib's reference to a standard button image ("NSSwitch", "NSRadioButton"). */
@interface NSButtonImageSource : NSObject <NSCoding>
@end

@implementation NSButtonImageSource

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *name = [coder decodeObjectForKey:@"NSImageName"];
    [self release];
    return (id)[standard_image([name isEqualToString:@"NSRadioButton"] ? @"NSRadioButton" : @"NSSwitch") retain];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

@end

enum {
    BF_PUSH_IN = 0x80000000u,
    BF_CHANGE_CONTENTS = 0x40000000u,
    BF_CHANGE_BACKGROUND = 0x20000000u,
    BF_CHANGE_GRAY = 0x10000000u,
    BF_LIGHT_BY_CONTENTS = 0x08000000u,
    BF_LIGHT_BY_BACKGROUND = 0x04000000u,
    BF_LIGHT_BY_GRAY = 0x02000000u,
    BF_BORDERED = 0x00800000u,
    BF_TRANSPARENT = 0x00008000u,
    BF_NO_DIM = 0x00001000u,
};

@implementation NSButtonCell {
    id _title; /* NSString or NSAttributedString */
    id _alternateTitle;
    NSImage *_image, *_alternateImage;
    NSString *_keyEquivalent;
    NSEventModifierFlags _keyMask;
    NSBezelStyle _bezelStyle;
    NSCellStyleMask _highlightsBy, _showsStateBy;
    NSCellImagePosition _imagePosition;
    NSImageScaling _imageScaling;
    NSButtonType _buttonType;
    NSColor *_backgroundColor;
    NSSound *_sound;
    float _delay, _interval;
    struct {
        unsigned transparent : 1;
        unsigned noDim : 1;
        unsigned borderOnlyInside : 1;
        unsigned mouseInside : 1;
        unsigned hugsTitle : 1;
    } _b;
}

static void
button_defaults(NSButtonCell *self)
{
    self->_keyEquivalent = @"";
    self->_highlightsBy = NSPushInCellMask | NSChangeGrayCellMask | NSChangeBackgroundCellMask;
    self->_buttonType = NSButtonTypeMomentaryPushIn;
    self->_imageScaling = NSImageScaleNone;
    self->_delay = 0.4f;
    self->_interval = 0.075f;
}

- (instancetype)init
{
    return [self initTextCell:@"Button"];
}

- (instancetype)initTextCell:(NSString *)string
{
    self = [super initTextCell:@""];
    if (!self)
        return nil;
    button_defaults(self);
    _title = [string copy] ?: @"";
    [self setBordered:YES];
    [self setAlignment:NSTextAlignmentCenter];
    return self;
}

- (instancetype)initImageCell:(NSImage *)image
{
    self = [super initTextCell:@""];
    if (!self)
        return nil;
    button_defaults(self);
    _title = @"";
    _image = [image retain];
    _imagePosition = image ? NSImageOnly : NSNoImage;
    [self setBordered:YES];
    [self setAlignment:NSTextAlignmentCenter];
    return self;
}

static NSCellImagePosition
position_from_flags(unsigned b)
{
    if (b & 0x40)
        return (b & 0x08) ? NSImageOverlaps : NSImageOnly;
    if (b & 0x08) {
        if (b & 0x20)
            return (b & 0x10) ? NSImageLeft : NSImageRight;
        return (b & 0x10) ? NSImageBelow : NSImageAbove;
    }
    return NSNoImage;
}

static unsigned
position_to_flags(NSCellImagePosition p)
{
    switch (p) {
    case NSImageOnly: return 0x40;
    case NSImageOverlaps: return 0x48;
    case NSImageLeft: case NSImageLeading: return 0x38;
    case NSImageRight: case NSImageTrailing: return 0x28;
    case NSImageBelow: return 0x18;
    case NSImageAbove: return 0x08;
    default: return 0;
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    button_defaults(self);
    id contents = [coder decodeObjectForKey:@"NSContents"];
    _title = [contents isKindOfClass:[NSString class]] || [contents isKindOfClass:[NSAttributedString class]]
                 ? [contents copy]
                 : @"";
    id alt = [coder decodeObjectForKey:@"NSAlternateContents"];
    _alternateTitle = [alt isKindOfClass:[NSString class]] || [alt isKindOfClass:[NSAttributedString class]] ? [alt copy]
                                                                                                             : @"";
    unsigned bf = (unsigned)[coder decodeIntForKey:@"NSButtonFlags"];
    unsigned bf2 = (unsigned)[coder decodeIntForKey:@"NSButtonFlags2"];
    _highlightsBy = ((bf & BF_PUSH_IN) ? NSPushInCellMask : 0) | ((bf & BF_LIGHT_BY_CONTENTS) ? NSContentsCellMask : 0) |
                    ((bf & BF_LIGHT_BY_GRAY) ? NSChangeGrayCellMask : 0) |
                    ((bf & BF_LIGHT_BY_BACKGROUND) ? NSChangeBackgroundCellMask : 0);
    _showsStateBy = ((bf & BF_CHANGE_CONTENTS) ? NSContentsCellMask : 0) | ((bf & BF_CHANGE_GRAY) ? NSChangeGrayCellMask : 0) |
                    ((bf & BF_CHANGE_BACKGROUND) ? NSChangeBackgroundCellMask : 0);
    [super setBordered:(bf & BF_BORDERED) != 0];
    _imagePosition = position_from_flags((bf >> 16) & 0x7f);
    _b.transparent = (bf & BF_TRANSPARENT) != 0;
    _b.noDim = (bf & BF_NO_DIM) != 0;
    _imageScaling = (NSImageScaling)((((bf2 >> 6) & 3) + 2) & 3);
    _keyMask = (bf2 >> 8) & 0xffffff;
    _bezelStyle = [coder containsValueForKey:@"NSBezelStyle"] ? (NSBezelStyle)[coder decodeIntegerForKey:@"NSBezelStyle"]
                                                              : (NSBezelStyle)((bf2 & 7) | ((bf2 & 0x20) >> 2));
    if ([coder containsValueForKey:@"NSAuxButtonType"])
        _buttonType = (NSButtonType)[coder decodeIntegerForKey:@"NSAuxButtonType"];
    NSString *key = [coder decodeObjectForKey:@"NSKeyEquivalent"];
    _keyEquivalent = [key isKindOfClass:[NSString class]] ? [key copy] : @"";
    id image = [coder decodeObjectForKey:@"NSNormalImage"];
    _image = [image isKindOfClass:[NSImage class]] ? [image retain] : nil;
    id altImage = [coder decodeObjectForKey:@"NSAlternateImage"];
    _alternateImage = [altImage isKindOfClass:[NSImage class]] ? [altImage retain] : nil;
    if ((_buttonType == NSButtonTypeSwitch || _buttonType == NSButtonTypeRadio) && !_image)
        _image = [standard_image(_buttonType == NSButtonTypeRadio ? @"NSRadioButton" : @"NSSwitch") retain];
    if ([coder containsValueForKey:@"NSPeriodicDelay"]) {
        _delay = [coder decodeIntForKey:@"NSPeriodicDelay"] / 1000.0f;
        _interval = [coder decodeIntForKey:@"NSPeriodicInterval"] / 1000.0f;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_title forKey:@"NSContents"];
    [coder encodeObject:_alternateTitle ?: @"" forKey:@"NSAlternateContents"];
    unsigned bf = ((_highlightsBy & NSPushInCellMask) ? BF_PUSH_IN : 0) |
                  ((_highlightsBy & NSContentsCellMask) ? BF_LIGHT_BY_CONTENTS : 0) |
                  ((_highlightsBy & NSChangeGrayCellMask) ? BF_LIGHT_BY_GRAY : 0) |
                  ((_highlightsBy & NSChangeBackgroundCellMask) ? BF_LIGHT_BY_BACKGROUND : 0) |
                  ((_showsStateBy & NSContentsCellMask) ? BF_CHANGE_CONTENTS : 0) |
                  ((_showsStateBy & NSChangeGrayCellMask) ? BF_CHANGE_GRAY : 0) |
                  ((_showsStateBy & NSChangeBackgroundCellMask) ? BF_CHANGE_BACKGROUND : 0) |
                  ([self isBordered] ? BF_BORDERED : 0) | (position_to_flags(_imagePosition) << 16) |
                  (_b.transparent ? BF_TRANSPARENT : 0) | (_b.noDim ? BF_NO_DIM : 0) | 0x4000;
    unsigned bf2 = (unsigned)(_bezelStyle & 7) | ((_bezelStyle & 8) << 2) | ((((unsigned)_imageScaling + 2) & 3) << 6) |
                   (unsigned)((_keyMask & 0xffffff) << 8);
    [coder encodeInt:(int)bf forKey:@"NSButtonFlags"];
    [coder encodeInt:(int)bf2 forKey:@"NSButtonFlags2"];
    [coder encodeInteger:_bezelStyle forKey:@"NSBezelStyle"];
    [coder encodeInteger:_buttonType forKey:@"NSAuxButtonType"];
    [coder encodeObject:_keyEquivalent forKey:@"NSKeyEquivalent"];
    if (_image)
        [coder encodeObject:_image forKey:@"NSNormalImage"];
    if (_alternateImage)
        [coder encodeObject:_alternateImage forKey:@"NSAlternateImage"];
    [coder encodeInt:(int)(_delay * 1000) forKey:@"NSPeriodicDelay"];
    [coder encodeInt:(int)(_interval * 1000) forKey:@"NSPeriodicInterval"];
}

- (void)dealloc
{
    [_title release];
    [_alternateTitle release];
    [_image release];
    [_alternateImage release];
    [_keyEquivalent release];
    [_backgroundColor release];
    [_sound release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSButtonCell *c = [super copyWithZone:zone];
    [c->_title retain];
    [c->_alternateTitle retain];
    [c->_image retain];
    [c->_alternateImage retain];
    [c->_keyEquivalent retain];
    [c->_backgroundColor retain];
    [c->_sound retain];
    return c;
}

#pragma mark Types

- (NSButtonType)_finchButtonType { return _buttonType; }

- (void)setButtonType:(NSButtonType)type
{
    _buttonType = type;
    switch (type) {
    case NSButtonTypeMomentaryLight:
        _highlightsBy = NSChangeGrayCellMask | NSChangeBackgroundCellMask;
        _showsStateBy = NSNoCellMask;
        break;
    case NSButtonTypePushOnPushOff:
        _highlightsBy = NSPushInCellMask | NSChangeGrayCellMask | NSChangeBackgroundCellMask;
        _showsStateBy = NSChangeGrayCellMask | NSChangeBackgroundCellMask;
        break;
    case NSButtonTypeToggle:
        _highlightsBy = NSPushInCellMask | NSContentsCellMask;
        _showsStateBy = NSContentsCellMask;
        break;
    case NSButtonTypeSwitch:
    case NSButtonTypeRadio:
        _highlightsBy = NSContentsCellMask;
        _showsStateBy = NSContentsCellMask;
        [self setImage:standard_image(type == NSButtonTypeRadio ? @"NSRadioButton" : @"NSSwitch")];
        [self setAlternateImage:standard_image(type == NSButtonTypeRadio ? @"NSRadioButton" : @"NSSwitch")];
        _imagePosition = NSImageLeading;
        _b.noDim = YES;
        [self setBordered:NO];
        break;
    case NSButtonTypeMomentaryChange:
        _highlightsBy = NSContentsCellMask;
        _showsStateBy = NSNoCellMask;
        break;
    case NSButtonTypeOnOff:
        _highlightsBy = NSChangeGrayCellMask | NSChangeBackgroundCellMask;
        _showsStateBy = NSChangeGrayCellMask | NSChangeBackgroundCellMask;
        break;
    case NSButtonTypeMomentaryPushIn:
        _highlightsBy = NSPushInCellMask | NSChangeGrayCellMask | NSChangeBackgroundCellMask;
        _showsStateBy = NSNoCellMask;
        break;
    default:
        _highlightsBy = NSChangeGrayCellMask | NSChangeBackgroundCellMask;
        _showsStateBy = NSNoCellMask;
        break;
    }
    [self _finchChanged];
}

- (NSInteger)cellAttribute:(NSCellAttribute)attribute
{
    switch (attribute) {
    case NSPushInCell: return (_highlightsBy & NSPushInCellMask) != 0;
    case NSChangeGrayCell: return (_showsStateBy & NSChangeGrayCellMask) != 0;
    case NSChangeBackgroundCell: return (_showsStateBy & NSChangeBackgroundCellMask) != 0;
    case NSCellChangesContents: return (_showsStateBy & NSContentsCellMask) != 0;
    case NSCellLightsByContents: return (_highlightsBy & NSContentsCellMask) != 0;
    case NSCellLightsByGray: return (_highlightsBy & NSChangeGrayCellMask) != 0;
    case NSCellLightsByBackground: return (_highlightsBy & NSChangeBackgroundCellMask) != 0;
    case NSCellIsBordered: return [self isBordered];
    case NSCellHasOverlappingImage: return _imagePosition == NSImageOverlaps;
    case NSCellHasImageHorizontal: return _imagePosition == NSImageLeft || _imagePosition == NSImageRight;
    case NSCellHasImageOnLeftOrBottom: return _imagePosition == NSImageLeft || _imagePosition == NSImageBelow;
    default: return [super cellAttribute:attribute];
    }
}

- (BOOL)_finchIsSwitch
{
    return _buttonType == NSButtonTypeSwitch || _buttonType == NSButtonTypeRadio ||
           (_image && (_image == standard_image(@"NSSwitch") || _image == standard_image(@"NSRadioButton")));
}

- (BOOL)_finchIsRadio
{
    return _buttonType == NSButtonTypeRadio || (_image && _image == standard_image(@"NSRadioButton"));
}

- (NSInteger)nextState
{
    if ([self _finchIsRadio] && [self state] == NSControlStateValueOn)
        return NSControlStateValueOn;
    return [super nextState];
}

- (void)setState:(NSControlStateValue)state
{
    [super setState:state];
    if ([self state] == NSControlStateValueOn && [self _finchIsRadio])
        [self _finchTurnOffRadioSiblings];
}

/* As macOS: radio buttons sharing a superview and an action work as a group. */
- (void)_finchTurnOffRadioSiblings
{
    NSView *v = [self controlView];
    SEL action = [self action];
    if (!v || !action || ![v isKindOfClass:[NSButton class]])
        return;
    for (NSView *s in [[v superview] subviews]) {
        if (s == v || ![s isKindOfClass:[NSButton class]])
            continue;
        NSButtonCell *c = [(NSButton *)s cell];
        if ([c isKindOfClass:[NSButtonCell class]] && [c _finchIsRadio] && [c action] == action &&
            [c state] != NSControlStateValueOff)
            [c setState:NSControlStateValueOff];
    }
}

#pragma mark Values: the state

- (id)objectValue { return @([self state]); }

- (void)setObjectValue:(id)value
{
    if ([value respondsToSelector:@selector(integerValue)])
        [self setState:[value integerValue]];
    else
        [self setState:NSControlStateValueOff];
}

- (NSString *)stringValue { return [NSString stringWithFormat:@"%ld", (long)[self state]]; }
- (void)setStringValue:(NSString *)string { [self setState:[string integerValue]]; }
- (int)intValue { return (int)[self state]; }
- (NSInteger)integerValue { return [self state]; }
- (float)floatValue { return (float)[self state]; }
- (double)doubleValue { return (double)[self state]; }
- (void)setIntValue:(int)v { [self setState:v]; }
- (void)setIntegerValue:(NSInteger)v { [self setState:v]; }
- (void)setFloatValue:(float)v { [self setState:(NSInteger)v]; }
- (void)setDoubleValue:(double)v { [self setState:(NSInteger)v]; }
- (NSAttributedString *)attributedStringValue { return [self attributedTitle]; }
- (void)setAttributedStringValue:(NSAttributedString *)s { [self setAttributedTitle:s]; }

#pragma mark Titles and images

- (NSString *)title
{
    return [_title isKindOfClass:[NSAttributedString class]] ? [_title string] : (_title ?: @"");
}

- (void)setTitle:(NSString *)title
{
    [_title release];
    _title = [title copy] ?: @"";
    [self _finchChanged];
}

- (NSDictionary *)_finchTitleAttributes
{
    NSMutableDictionary *a = [[[self _finchTextAttributes] mutableCopy] autorelease];
    NSMutableParagraphStyle *p = [[a[NSParagraphStyleAttributeName] mutableCopy] autorelease];
    [p setLineBreakMode:[self lineBreakMode]];
    a[NSParagraphStyleAttributeName] = p;
    return a;
}

- (NSAttributedString *)attributedTitle
{
    if ([_title isKindOfClass:[NSAttributedString class]])
        return _title;
    return [[[NSAttributedString alloc] initWithString:_title ?: @"" attributes:[self _finchTitleAttributes]]
        autorelease];
}

- (void)setAttributedTitle:(NSAttributedString *)title
{
    [_title release];
    _title = [title copy] ?: @"";
    [self _finchChanged];
}

- (NSString *)alternateTitle
{
    return [_alternateTitle isKindOfClass:[NSAttributedString class]] ? [_alternateTitle string]
                                                                      : (_alternateTitle ?: @"");
}

- (void)setAlternateTitle:(NSString *)title
{
    [_alternateTitle release];
    _alternateTitle = [title copy] ?: @"";
    [self _finchChanged];
}

- (NSAttributedString *)attributedAlternateTitle
{
    if ([_alternateTitle isKindOfClass:[NSAttributedString class]])
        return _alternateTitle;
    return [[[NSAttributedString alloc] initWithString:_alternateTitle ?: @""
                                            attributes:[self _finchTitleAttributes]] autorelease];
}

- (void)setAttributedAlternateTitle:(NSAttributedString *)title
{
    [_alternateTitle release];
    _alternateTitle = [title copy];
    [self _finchChanged];
}

- (NSImage *)image { return _image; }

- (void)setImage:(NSImage *)image
{
    if (image == _image)
        return;
    [_image release];
    _image = [image retain];
    [self _finchChanged];
}

- (NSImage *)alternateImage { return _alternateImage; }

- (void)setAlternateImage:(NSImage *)image
{
    [_alternateImage release];
    _alternateImage = [image retain];
    [self _finchChanged];
}

- (NSCellImagePosition)imagePosition { return _imagePosition; }

- (void)setImagePosition:(NSCellImagePosition)p
{
    _imagePosition = p;
    [self _finchChanged];
}

- (NSImageScaling)imageScaling { return _imageScaling; }

- (void)setImageScaling:(NSImageScaling)s
{
    _imageScaling = s;
    [self _finchChanged];
}

- (BOOL)_finchImageHugsTitle { return _b.hugsTitle; }
- (void)_finchSetImageHugsTitle:(BOOL)flag { _b.hugsTitle = flag; }

#pragma mark Appearance state

- (NSBezelStyle)bezelStyle { return _bezelStyle; }

- (void)setBezelStyle:(NSBezelStyle)style
{
    _bezelStyle = style;
    [self _finchChanged];
}

- (NSCellStyleMask)highlightsBy { return _highlightsBy; }
- (void)setHighlightsBy:(NSCellStyleMask)mask { _highlightsBy = mask; }
- (NSCellStyleMask)showsStateBy { return _showsStateBy; }
- (void)setShowsStateBy:(NSCellStyleMask)mask { _showsStateBy = mask; }
- (BOOL)isTransparent { return _b.transparent; }

- (void)setTransparent:(BOOL)flag
{
    _b.transparent = flag;
    [self _finchChanged];
}

- (BOOL)isOpaque { return !_b.transparent && [self isBordered] && _bezelStyle == NSBezelStyleSmallSquare; }
- (BOOL)imageDimsWhenDisabled { return !_b.noDim; }
- (void)setImageDimsWhenDisabled:(BOOL)flag { _b.noDim = !flag; }
- (BOOL)showsBorderOnlyWhileMouseInside { return _b.borderOnlyInside; }
- (void)setShowsBorderOnlyWhileMouseInside:(BOOL)flag { _b.borderOnlyInside = flag; }
- (NSSound *)sound { return _sound; }

- (void)setSound:(NSSound *)sound
{
    [_sound release];
    _sound = [sound retain];
}

- (NSColor *)backgroundColor { return _backgroundColor; }

- (void)setBackgroundColor:(NSColor *)color
{
    [_backgroundColor release];
    _backgroundColor = [color copy];
    [self _finchChanged];
}

- (NSString *)keyEquivalent { return _keyEquivalent ?: @""; }

- (void)setKeyEquivalent:(NSString *)key
{
    [_keyEquivalent release];
    _keyEquivalent = [key copy] ?: @"";
    [self _finchChanged];
}

- (NSEventModifierFlags)keyEquivalentModifierMask { return _keyMask; }
- (void)setKeyEquivalentModifierMask:(NSEventModifierFlags)mask { _keyMask = mask; }
- (NSFont *)keyEquivalentFont { return [self font]; }
- (void)setKeyEquivalentFont:(NSFont *)font {}
- (void)setKeyEquivalentFont:(NSString *)name size:(CGFloat)size {}

- (void)setPeriodicDelay:(float)delay interval:(float)interval
{
    _delay = delay;
    _interval = interval;
}

- (void)getPeriodicDelay:(float *)delay interval:(float *)interval
{
    if (delay)
        *delay = _delay;
    if (interval)
        *interval = _interval;
}

- (void)mouseEntered:(NSEvent *)event
{
    _b.mouseInside = YES;
    [self _finchChanged];
}

- (void)mouseExited:(NSEvent *)event
{
    _b.mouseInside = NO;
    [self _finchChanged];
}

- (void)performClick:(id)sender
{
    [super performClick:sender];
}

#pragma mark Geometry

- (BOOL)_finchIsDefault
{
    return [_keyEquivalent isEqualToString:@"\r"] && !(_keyMask & NSEventModifierFlagDeviceIndependentFlagsMask);
}

- (BOOL)_finchDrawsBezel
{
    return [self isBordered] && !_b.transparent && (!_b.borderOnlyInside || _b.mouseInside);
}

- (CGFloat)_finchBezelHeight
{
    switch ([self controlSize]) {
    case NSControlSizeSmall: return 19;
    case NSControlSizeMini: return 16;
    case NSControlSizeLarge: return 28;
    case NSControlSizeExtraLarge: return 32;
    default: return 24;
    }
}

/* Push-style bezels sit in a fixed height, centred; square ones fill the frame. */
- (BOOL)_finchFixedHeightBezel
{
    switch (_bezelStyle) {
    case NSBezelStyleAutomatic:
    case NSBezelStylePush:
    case NSBezelStyleToolbar:
    case NSBezelStyleAccessoryBarAction:
    case NSBezelStyleAccessoryBar:
    case NSBezelStylePushDisclosure:
    case NSBezelStyleBadge:
    case NSBezelStyleGlass:
        return YES;
    default:
        return NO;
    }
}

- (NSRect)_finchBezelRect:(NSRect)frame
{
    if (![self _finchFixedHeightBezel])
        return frame;
    CGFloat h = MIN(frame.size.height, [self _finchBezelHeight] - 2);
    NSRect r = NSInsetRect(frame, frame.size.width > 8 ? 1 : 0, 0);
    r.origin.y += floor((frame.size.height - h) / 2);
    r.size.height = h;
    return r;
}

- (NSRect)drawingRectForBounds:(NSRect)rect
{
    if (![self isBordered] || [self _finchIsSwitch])
        return rect;
    NSRect r = [self _finchBezelRect:rect];
    return NSInsetRect(r, 4, 1);
}

- (NSImage *)_finchShownImage
{
    BOOL alt = ([self state] != NSControlStateValueOff && (_showsStateBy & NSContentsCellMask)) ||
               ([self isHighlighted] && (_highlightsBy & NSContentsCellMask));
    return alt && _alternateImage && ![self _finchIsSwitch] ? _alternateImage : _image;
}

- (NSAttributedString *)_finchShownTitle
{
    BOOL alt = ([self state] != NSControlStateValueOff && (_showsStateBy & NSContentsCellMask)) ||
               ([self isHighlighted] && (_highlightsBy & NSContentsCellMask));
    NSAttributedString *t = alt && [[self alternateTitle] length] ? [self attributedAlternateTitle] : [self attributedTitle];
    return t;
}

- (NSCellImagePosition)_finchEffectivePosition
{
    NSCellImagePosition p = _imagePosition;
    if (p == NSImageLeading)
        p = NSImageLeft;
    else if (p == NSImageTrailing)
        p = NSImageRight;
    if (p == NSNoImage && _image && [self _finchIsSwitch])
        p = NSImageLeft;
    return p;
}

- (NSSize)_finchImageSize
{
    if ([self _finchIsSwitch])
        return NSMakeSize(16, 16);
    return _image ? [_image size] : NSZeroSize;
}

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    NSAttributedString *t = [self attributedTitle];
    NSSize ts = [t length] ? FinchCellTextSize(t, 0) : NSZeroSize;
    NSCellImagePosition p = [self _finchEffectivePosition];
    NSSize is = p == NSNoImage ? NSZeroSize : [self _finchImageSize];
    NSSize s;
    if ([self _finchIsSwitch]) {
        s = NSMakeSize(is.width + ([t length] ? 4 + ts.width : 0), MAX(16, ts.height));
        return s;
    }
    if (p == NSImageOnly || p == NSImageOverlaps || ![t length])
        s = p == NSNoImage ? ts : NSMakeSize(MAX(is.width, p == NSImageOverlaps ? ts.width : 0),
                                             MAX(is.height, p == NSImageOverlaps ? ts.height : 0));
    else if (p == NSImageLeft || p == NSImageRight)
        s = NSMakeSize(is.width + 4 + ts.width, MAX(is.height, ts.height));
    else if (p == NSImageAbove || p == NSImageBelow)
        s = NSMakeSize(MAX(is.width, ts.width), is.height + 2 + ts.height);
    else
        s = ts;
    if ([self isBordered]) {
        if ([self _finchFixedHeightBezel]) {
            s.width += [t length] ? 24 : 12;
            s.height = MAX(s.height + 4, [self _finchBezelHeight]);
        } else {
            s.width += 12;
            s.height += 8;
        }
    }
    return NSMakeSize(ceil(s.width), ceil(s.height));
}

- (NSRect)imageRectForBounds:(NSRect)rect
{
    NSRect r = [self drawingRectForBounds:rect];
    NSSize is = [self _finchImageSize];
    NSCellImagePosition p = [self _finchEffectivePosition];
    switch (p) {
    case NSImageLeft:
        return NSMakeRect(r.origin.x, NSMidY(r) - is.height / 2, is.width, is.height);
    case NSImageRight:
        return NSMakeRect(NSMaxX(r) - is.width, NSMidY(r) - is.height / 2, is.width, is.height);
    default:
        return r;
    }
}

- (NSRect)titleRectForBounds:(NSRect)rect
{
    NSRect r = [self drawingRectForBounds:rect];
    NSSize is = [self _finchImageSize];
    switch ([self _finchEffectivePosition]) {
    case NSImageLeft:
        r.origin.x += is.width + 4;
        r.size.width -= is.width + 4;
        break;
    case NSImageRight:
        r.size.width -= is.width + 4;
        break;
    case NSImageOnly:
        return NSZeroRect;
    default:
        break;
    }
    return r;
}

#pragma mark Drawing

- (void)drawBezelWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    BOOL enabled = [self isEnabled];
    BOOL pressed = [self isHighlighted] && (_highlightsBy & (NSPushInCellMask | NSChangeGrayCellMask | NSChangeBackgroundCellMask));
    BOOL on = [self state] != NSControlStateValueOff && (_showsStateBy & (NSChangeGrayCellMask | NSChangeBackgroundCellMask));
    BOOL accent = [self _finchIsDefault] || on || _bezelStyle == NSBezelStyleBadge;
    NSRect r = [self _finchBezelRect:frame];
    NSColor *fill = _backgroundColor ?: (accent ? FinchAccentColor() : FinchControlFill(NO));
    if (pressed)
        fill = [fill blendedColorWithFraction:accent ? 0.2 : 0.12 ofColor:[NSColor blackColor]];
    CGFloat radius = 6;
    if (_bezelStyle == NSBezelStyleCircular || _bezelStyle == NSBezelStyleHelpButton) {
        CGFloat d = MIN(r.size.width, r.size.height);
        r = NSMakeRect(NSMidX(r) - d / 2, NSMidY(r) - d / 2, d, d);
        radius = d / 2;
    } else if (_bezelStyle == NSBezelStyleSmallSquare || _bezelStyle == NSBezelStyleShadowlessSquare ||
               _bezelStyle == NSBezelStyleTexturedSquare || _bezelStyle == NSBezelStyleDisclosure) {
        radius = 2;
    } else if (_bezelStyle == NSBezelStyleBadge || _bezelStyle == NSBezelStyleAccessoryBar) {
        radius = r.size.height / 2;
    }
    FinchDrawBezel(r, radius, FinchDisabled(fill, enabled), accent ? nil : FinchDisabled(FinchControlStroke(), enabled));
}

- (void)drawImage:(NSImage *)image withFrame:(NSRect)frame inView:(NSView *)controlView
{
    BOOL enabled = [self isEnabled];
    if ([self _finchIsSwitch] && (image == standard_image(@"NSSwitch") || image == standard_image(@"NSRadioButton") || !image)) {
        BOOL pressed = [self isHighlighted];
        if ([self _finchIsRadio])
            FinchDrawRadio(frame, [self state], pressed, enabled);
        else
            FinchDrawCheckbox(frame, [self state], pressed, enabled);
        return;
    }
    FinchDrawImageInRect(image, frame, _imageScaling, NSImageAlignCenter, [controlView isFlipped],
                         enabled || !self.imageDimsWhenDisabled ? 1 : 0.5);
}

- (NSRect)drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)controlView
{
    NSMutableAttributedString *t = [[title mutableCopy] autorelease];
    NSRange all = NSMakeRange(0, [t length]);
    BOOL light = [self isBordered] && !_b.transparent && ![self _finchIsSwitch] &&
                 ([self _finchIsDefault] || ([self state] != NSControlStateValueOff &&
                                             (_showsStateBy & (NSChangeGrayCellMask | NSChangeBackgroundCellMask))) ||
                  _bezelStyle == NSBezelStyleBadge);
    if (light)
        [t addAttribute:NSForegroundColorAttributeName value:[NSColor whiteColor] range:all];
    if (![self isEnabled])
        [t addAttribute:NSForegroundColorAttributeName value:[NSColor disabledControlTextColor] range:all];
    FinchDrawCellText(t, frame, [controlView isFlipped]);
    return frame;
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    NSCellImagePosition p = [self _finchEffectivePosition];
    NSImage *image = [self _finchShownImage];
    NSAttributedString *title = [self _finchShownTitle];
    BOOL switchy = [self _finchIsSwitch];
    if (p != NSNoImage && (image || switchy)) {
        NSRect ir = [self imageRectForBounds:frame];
        if (switchy)
            ir = NSMakeRect(ir.origin.x, floor(NSMidY(frame) - 8), 16, 16);
        [self drawImage:image withFrame:ir inView:controlView];
    }
    if (p != NSImageOnly && [title length]) {
        NSRect tr = [self titleRectForBounds:frame];
        if (p == NSImageAbove || p == NSImageBelow) {
            NSSize is = [self _finchImageSize];
            BOOL flipped = [controlView isFlipped];
            BOOL titleLow = (p == NSImageAbove) != flipped;
            if (titleLow)
                tr.size.height -= is.height + 2;
            else {
                tr.origin.y += is.height + 2;
                tr.size.height -= is.height + 2;
            }
        }
        [self drawTitle:title withFrame:tr inView:controlView];
    }
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    if (_b.transparent)
        return;
    if ([self _finchDrawsBezel] && ![self _finchIsSwitch])
        [self drawBezelWithFrame:frame inView:controlView];
    [self drawInteriorWithFrame:frame inView:controlView];
    if ([self showsFirstResponder] && [[controlView window] firstResponder] == controlView &&
        [self focusRingType] != NSFocusRingTypeNone) {
        NSRect fr = [self _finchIsSwitch] ? [self imageRectForBounds:frame] : [self _finchBezelRect:frame];
        FinchDrawBezel(NSInsetRect(fr, -1, -1), 6, nil, [FinchAccentColor() colorWithAlphaComponent:0.5]);
    }
}

@end

#pragma mark - The default button

@implementation NSWindow (FinchDefaultButton)

static char default_button_key, default_disabled_key;

static NSButtonCell *
find_default(NSView *v)
{
    if ([v isKindOfClass:[NSButton class]]) {
        NSButtonCell *c = [(NSButton *)v cell];
        if ([c isKindOfClass:[NSButtonCell class]] && [[c keyEquivalent] isEqualToString:@"\r"] &&
            !([c keyEquivalentModifierMask] & NSEventModifierFlagDeviceIndependentFlagsMask))
            return c;
    }
    for (NSView *s in [v subviews]) {
        NSButtonCell *c = find_default(s);
        if (c)
            return c;
    }
    return nil;
}

/* As Apple's: the button whose key equivalent is Return, unless one was set. */
- (NSButtonCell *)defaultButtonCell
{
    NSButtonCell *c = objc_getAssociatedObject(self, &default_button_key);
    if (c)
        return c;
    return find_default([self contentView]);
}

- (void)setDefaultButtonCell:(NSButtonCell *)cell
{
    NSButtonCell *old = [self defaultButtonCell];
    if (old && old != cell && [[old keyEquivalent] isEqualToString:@"\r"])
        [old setKeyEquivalent:@""];
    [cell setKeyEquivalent:@"\r"];
    [cell setKeyEquivalentModifierMask:0];
    objc_setAssociatedObject(self, &default_button_key, cell, OBJC_ASSOCIATION_ASSIGN);
}

- (void)disableKeyEquivalentForDefaultButtonCell
{
    objc_setAssociatedObject(self, &default_disabled_key, @YES, OBJC_ASSOCIATION_RETAIN);
}

- (void)enableKeyEquivalentForDefaultButtonCell
{
    objc_setAssociatedObject(self, &default_disabled_key, nil, OBJC_ASSOCIATION_RETAIN);
}

@end
