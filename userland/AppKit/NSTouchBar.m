/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Touch Bar classes. Finch runs on Macs without a Touch Bar (as Apple's
 * Mac lineup now is), so nothing is shown: bars and items keep the state
 * apps give them and answer as Apple's do (item lookup through template
 * items and the delegate, responders' lazily made bars, the standard space
 * items), and are never visible.
 */
#import "NSView_Finch.h"
#import <objc/runtime.h>

NSTouchBarItemIdentifier const NSTouchBarItemIdentifierFixedSpaceSmall = @"NSTouchBarItemIdentifierFixedSpaceSmall";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierFixedSpaceLarge = @"NSTouchBarItemIdentifierFixedSpaceLarge";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierFlexibleSpace = @"NSTouchBarItemIdentifierFlexibleSpace";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierOtherItemsProxy = @"NSTouchBarItemIdentifierOtherItemsProxy";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierCandidateList = @"NSTouchBarItemIdentifierCandidateList";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierCharacterPicker = @"NSTouchBarItemIdentifierCharacterPicker";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierTextColorPicker = @"NSTouchBarItemIdentifierTextColorPicker";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierTextStyle = @"NSTouchBarItemIdentifierTextStyle";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierTextAlignment = @"NSTouchBarItemIdentifierTextAlignment";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierTextList = @"NSTouchBarItemIdentifierTextList";
NSTouchBarItemIdentifier const NSTouchBarItemIdentifierTextFormat = @"NSTouchBarItemIdentifierTextFormat";

#pragma mark NSTouchBarItem

@implementation NSTouchBarItem {
@protected
    NSTouchBarItemIdentifier _identifier;
    NSTouchBarItemPriority _priority;
    NSString *_label;
}

- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super init];
    if (self)
        _identifier = [identifier copy];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self initWithIdentifier:[coder decodeObjectForKey:@"NSTouchBarItemIdentifier"] ?: @""];
    if (self)
        _priority = [coder decodeFloatForKey:@"NSTouchBarItemVisibilityPriority"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"NSTouchBarItemIdentifier"];
    [coder encodeFloat:_priority forKey:@"NSTouchBarItemVisibilityPriority"];
}

- (void)dealloc
{
    [_identifier release];
    [_label release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> identifier = \"%@\"", [self class], self, _identifier];
}

- (NSTouchBarItemIdentifier)identifier { return _identifier; }
- (NSTouchBarItemPriority)visibilityPriority { return _priority; }
- (void)setVisibilityPriority:(NSTouchBarItemPriority)p { _priority = p; }
- (NSView *)view { return nil; }
- (NSViewController *)viewController { return nil; }
- (NSString *)customizationLabel { return _label ?: @""; }
- (void)setCustomizationLabel:(NSString *)l { [_label autorelease]; _label = [l copy]; }
- (BOOL)isVisible { return NO; }

@end

/* The standard spaces, as Apple's private class. */
@interface NSSpaceTouchBarItem : NSTouchBarItem
@end
@implementation NSSpaceTouchBarItem
@end

#pragma mark NSTouchBar

@implementation NSTouchBar {
    NSString *_customizationIdentifier, *_principal, *_escape;
    NSArray *_allowed, *_required, *_defaults;
    NSSet *_templates;
    NSMutableDictionary *_made;
    __weak id<NSTouchBarDelegate> _delegate;
}

static BOOL automatic_customize;

+ (BOOL)isAutomaticCustomizeTouchBarMenuItemEnabled { return automatic_customize; }
+ (void)setAutomaticCustomizeTouchBarMenuItemEnabled:(BOOL)f { automatic_customize = f; }

- (instancetype)init
{
    self = [super init];
    if (self) {
        _allowed = [[NSArray alloc] init];
        _required = [[NSArray alloc] init];
        _defaults = [[NSArray alloc] init];
        _templates = [[NSSet alloc] init];
        _made = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self init];
    if (self) {
        id items = [coder decodeObjectForKey:@"NSTouchBarTemplateItems"];
        if ([items isKindOfClass:[NSSet class]])
            [self setTemplateItems:items];
        else if ([items isKindOfClass:[NSArray class]])
            [self setTemplateItems:[NSSet setWithArray:items]];
        NSArray *defaults = [coder decodeObjectForKey:@"NSTouchBarDefaultItemIdentifiers"];
        if ([defaults isKindOfClass:[NSArray class]])
            [self setDefaultItemIdentifiers:defaults];
        [self setPrincipalItemIdentifier:[coder decodeObjectForKey:@"NSTouchBarPrincipalItemIdentifier"]];
        [self setCustomizationIdentifier:[coder decodeObjectForKey:@"NSTouchBarCustomizationIdentifier"]];
        _delegate = [coder decodeObjectForKey:@"NSTouchBarDelegate"];
        if ([coder containsValueForKey:@"NSTouchBarCustomizationAllowedItemIdentifiers"])
            [self setCustomizationAllowedItemIdentifiers:[coder decodeObjectForKey:@"NSTouchBarCustomizationAllowedItemIdentifiers"]];
        if ([coder containsValueForKey:@"NSTouchBarCustomizationRequiredItemIdentifiers"])
            [self setCustomizationRequiredItemIdentifiers:[coder decodeObjectForKey:@"NSTouchBarCustomizationRequiredItemIdentifiers"]];
        [self setEscapeKeyReplacementItemIdentifier:[coder decodeObjectForKey:@"NSTouchBarEscapeKeyReplacementItemIdentifier"]];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_templates forKey:@"NSTouchBarTemplateItems"];
    [coder encodeObject:_defaults forKey:@"NSTouchBarDefaultItemIdentifiers"];
    [coder encodeObject:_principal forKey:@"NSTouchBarPrincipalItemIdentifier"];
    [coder encodeObject:_customizationIdentifier forKey:@"NSTouchBarCustomizationIdentifier"];
    [coder encodeObject:_allowed forKey:@"NSTouchBarCustomizationAllowedItemIdentifiers"];
    [coder encodeObject:_required forKey:@"NSTouchBarCustomizationRequiredItemIdentifiers"];
    [coder encodeObject:_escape forKey:@"NSTouchBarEscapeKeyReplacementItemIdentifier"];
    [coder encodeConditionalObject:_delegate forKey:@"NSTouchBarDelegate"];
}

- (void)dealloc
{
    [_customizationIdentifier release];
    [_principal release];
    [_escape release];
    [_allowed release];
    [_required release];
    [_defaults release];
    [_templates release];
    [_made release];
    [super dealloc];
}

#define COPY_ACCESSORS(type, get, set, ivar) \
    -(type)get { return ivar; }              \
    -(void)set:(type)v { [ivar autorelease]; ivar = [v copy]; }

COPY_ACCESSORS(NSTouchBarCustomizationIdentifier, customizationIdentifier, setCustomizationIdentifier, _customizationIdentifier)
COPY_ACCESSORS(NSArray *, customizationAllowedItemIdentifiers, setCustomizationAllowedItemIdentifiers, _allowed)
COPY_ACCESSORS(NSArray *, customizationRequiredItemIdentifiers, setCustomizationRequiredItemIdentifiers, _required)
COPY_ACCESSORS(NSArray *, defaultItemIdentifiers, setDefaultItemIdentifiers, _defaults)
COPY_ACCESSORS(NSTouchBarItemIdentifier, principalItemIdentifier, setPrincipalItemIdentifier, _principal)
COPY_ACCESSORS(NSTouchBarItemIdentifier, escapeKeyReplacementItemIdentifier, setEscapeKeyReplacementItemIdentifier, _escape)
COPY_ACCESSORS(NSSet *, templateItems, setTemplateItems, _templates)

- (NSArray<NSTouchBarItemIdentifier> *)itemIdentifiers { return [[_defaults copy] autorelease]; }
- (id<NSTouchBarDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSTouchBarDelegate>)d { _delegate = d; }
- (BOOL)isVisible { return NO; }

/* A template item, else the standard spaces, else the delegate's (kept once made). */
- (NSTouchBarItem *)itemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
    for (NSTouchBarItem *i in _templates)
        if ([[i identifier] isEqualToString:identifier])
            return i;
    NSTouchBarItem *made = _made[identifier];
    if (made)
        return made;
    if ([identifier isEqualToString:NSTouchBarItemIdentifierFlexibleSpace] ||
        [identifier isEqualToString:NSTouchBarItemIdentifierFixedSpaceSmall] ||
        [identifier isEqualToString:NSTouchBarItemIdentifierFixedSpaceLarge])
        made = [[[NSSpaceTouchBarItem alloc] initWithIdentifier:identifier] autorelease];
    else if ([(id)_delegate respondsToSelector:@selector(touchBar:makeItemForIdentifier:)])
        made = [_delegate touchBar:self makeItemForIdentifier:identifier];
    if (made)
        _made[identifier] = made;
    return made;
}

@end

#pragma mark Responders and the application

@implementation NSResponder (NSTouchBarProvider)

static const void *kTouchBar = &kTouchBar;

/* Made once, by -makeTouchBar, the first time it's asked for (as Apple's). */
- (NSTouchBar *)touchBar
{
    NSTouchBar *t = objc_getAssociatedObject(self, kTouchBar);
    if (!t) {
        t = [self makeTouchBar];
        if (t)
            objc_setAssociatedObject(self, kTouchBar, t, OBJC_ASSOCIATION_RETAIN);
    }
    return t;
}

- (void)setTouchBar:(NSTouchBar *)t { objc_setAssociatedObject(self, kTouchBar, t, OBJC_ASSOCIATION_RETAIN); }
- (NSTouchBar *)makeTouchBar { return nil; }

@end

@implementation NSApplication (NSTouchBarCustomization)
- (BOOL)isAutomaticCustomizeTouchBarMenuItemEnabled { return automatic_customize; }
- (void)setAutomaticCustomizeTouchBarMenuItemEnabled:(BOOL)f { automatic_customize = f; }
- (IBAction)toggleTouchBarCustomizationPalette:(id)sender {}
@end

#pragma mark The item kinds

@implementation NSCustomTouchBarItem {
    NSView *_view;
    NSViewController *_viewController;
}

- (void)dealloc
{
    [_view release];
    [_viewController release];
    [super dealloc];
}

/* Apple's makes an empty view to begin with. */
- (NSView *)view
{
    if (!_view && !_viewController)
        _view = [[NSView alloc] initWithFrame:NSZeroRect];
    return _viewController ? [_viewController view] : _view;
}
- (void)setView:(NSView *)v { [_view autorelease]; _view = [v retain]; }
- (NSViewController *)viewController { return _viewController; }
- (void)setViewController:(NSViewController *)vc { [_viewController autorelease]; _viewController = [vc retain]; }

@end

@implementation NSGroupTouchBarItem {
    NSTouchBar *_group;
    NSUserInterfaceLayoutDirection _direction;
    BOOL _equal;
    CGFloat _preferredWidth;
    NSArray *_compression;
}

+ (instancetype)groupItemWithIdentifier:(NSTouchBarItemIdentifier)identifier items:(NSArray<NSTouchBarItem *> *)items
{
    NSGroupTouchBarItem *g = [[[self alloc] initWithIdentifier:identifier] autorelease];
    NSTouchBar *bar = [[[NSTouchBar alloc] init] autorelease];
    [bar setTemplateItems:[NSSet setWithArray:items]];
    [bar setDefaultItemIdentifiers:[items valueForKey:@"identifier"]];
    [g setGroupTouchBar:bar];
    return g;
}

+ (instancetype)groupItemWithIdentifier:(NSTouchBarItemIdentifier)identifier items:(NSArray<NSTouchBarItem *> *)items
              allowedCompressionOptions:(NSUserInterfaceCompressionOptions *)options
{
    return [self groupItemWithIdentifier:identifier items:items];
}

+ (instancetype)alertStyleGroupItemWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    NSGroupTouchBarItem *g = [self groupItemWithIdentifier:identifier items:@[]];
    [g setPrefersEqualWidths:YES];
    return g;
}

- (void)dealloc
{
    [_group release];
    [_compression release];
    [super dealloc];
}

- (NSTouchBar *)groupTouchBar
{
    if (!_group)
        _group = [[NSTouchBar alloc] init];
    return _group;
}
- (void)setGroupTouchBar:(NSTouchBar *)t { [_group autorelease]; _group = [t retain]; }
- (NSUserInterfaceLayoutDirection)groupUserInterfaceLayoutDirection { return _direction; }
- (void)setGroupUserInterfaceLayoutDirection:(NSUserInterfaceLayoutDirection)d { _direction = d; }
- (BOOL)prefersEqualWidths { return _equal; }
- (void)setPrefersEqualWidths:(BOOL)f { _equal = f; }
- (CGFloat)preferredItemWidth { return _preferredWidth; }
- (void)setPreferredItemWidth:(CGFloat)w { _preferredWidth = w; }
- (NSArray *)prioritizedCompressionOptions { return _compression ?: @[]; }
- (void)setPrioritizedCompressionOptions:(NSArray *)a { [_compression autorelease]; _compression = [a copy]; }
- (NSUserInterfaceCompressionOptions *)effectiveCompressionOptions { return nil; }

@end

@implementation NSPopoverTouchBarItem {
    NSTouchBar *_popover, *_pressAndHold;
    NSView *_collapsed;
    NSImage *_collapsedImage;
    NSString *_collapsedLabel;
    BOOL _showsClose;
}

- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super initWithIdentifier:identifier];
    if (self) {
        _popover = [[NSTouchBar alloc] init];
        _showsClose = YES;
    }
    return self;
}

- (void)dealloc
{
    [_popover release];
    [_pressAndHold release];
    [_collapsed release];
    [_collapsedImage release];
    [_collapsedLabel release];
    [super dealloc];
}

- (NSTouchBar *)popoverTouchBar { return _popover; }
- (void)setPopoverTouchBar:(NSTouchBar *)t { [_popover autorelease]; _popover = [t retain]; }
- (NSTouchBar *)pressAndHoldTouchBar { return _pressAndHold; }
- (void)setPressAndHoldTouchBar:(NSTouchBar *)t { [_pressAndHold autorelease]; _pressAndHold = [t retain]; }
- (NSView *)collapsedRepresentation { return _collapsed; }
- (void)setCollapsedRepresentation:(NSView *)v { [_collapsed autorelease]; _collapsed = [v retain]; }
- (NSImage *)collapsedRepresentationImage { return _collapsedImage; }
- (void)setCollapsedRepresentationImage:(NSImage *)i { [_collapsedImage autorelease]; _collapsedImage = [i retain]; }
- (NSString *)collapsedRepresentationLabel { return _collapsedLabel; }
- (void)setCollapsedRepresentationLabel:(NSString *)l { [_collapsedLabel autorelease]; _collapsedLabel = [l copy]; }
- (BOOL)showsCloseButton { return _showsClose; }
- (void)setShowsCloseButton:(BOOL)f { _showsClose = f; }
- (void)showPopover:(id)sender {}
- (void)dismissPopover:(id)sender {}
- (NSGestureRecognizer *)makeStandardActivatePopoverGestureRecognizer
{
    return [[[NSPressGestureRecognizer alloc] initWithTarget:self action:@selector(showPopover:)] autorelease];
}

@end

@implementation NSButtonTouchBarItem {
    NSString *_title;
    NSImage *_image;
    NSColor *_bezel;
    __weak id _target;
    SEL _action;
    BOOL _enabled;
}

+ (instancetype)buttonTouchBarItemWithIdentifier:(NSTouchBarItemIdentifier)identifier title:(NSString *)title
                                           image:(NSImage *)image target:(id)target action:(SEL)action
{
    NSButtonTouchBarItem *b = [[[self alloc] initWithIdentifier:identifier] autorelease];
    [b setTitle:title ?: @""];
    [b setImage:image];
    [b setTarget:target];
    [b setAction:action];
    return b;
}

+ (instancetype)buttonTouchBarItemWithIdentifier:(NSTouchBarItemIdentifier)identifier title:(NSString *)title
                                          target:(id)target action:(SEL)action
{
    NSButtonTouchBarItem *b = [[[self alloc] initWithIdentifier:identifier] autorelease];
    [b setTitle:title ?: @""];
    [b setTarget:target];
    [b setAction:action];
    return b;
}

+ (instancetype)buttonTouchBarItemWithIdentifier:(NSTouchBarItemIdentifier)identifier image:(NSImage *)image
                                          target:(id)target action:(SEL)action
{
    return [self buttonTouchBarItemWithIdentifier:identifier title:@"" image:image target:target action:action];
}

- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super initWithIdentifier:identifier];
    if (self) {
        _title = @"";
        _enabled = YES;
    }
    return self;
}

- (void)dealloc
{
    [_title release];
    [_image release];
    [_bezel release];
    [super dealloc];
}

- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)t { [_title autorelease]; _title = [t copy]; }
- (NSImage *)image { return _image; }
- (void)setImage:(NSImage *)i { [_image autorelease]; _image = [i retain]; }
- (NSColor *)bezelColor { return _bezel; }
- (void)setBezelColor:(NSColor *)c { [_bezel autorelease]; _bezel = [c copy]; }
- (id)target { return _target; }
- (void)setTarget:(id)t { _target = t; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)a { _action = a; }
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)f { _enabled = f; }

@end

@implementation NSSliderTouchBarItem {
    NSSlider *_slider;
    CGFloat _minWidth, _maxWidth;
    NSString *_label;
    NSSliderAccessory *_minAccessory, *_maxAccessory;
    NSSliderAccessoryWidth _accessoryWidth;
}

- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super initWithIdentifier:identifier];
    if (self) {
        _slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 100, 30)];
        _minWidth = 64;
        _maxWidth = FLT_MAX;
        _accessoryWidth = 36;  /* NSSliderAccessoryWidthDefault */
    }
    return self;
}

- (void)dealloc
{
    [_slider release];
    [_label release];
    [_minAccessory release];
    [_maxAccessory release];
    [super dealloc];
}

- (NSView *)view { return _slider; }
- (NSSlider *)slider { return _slider; }
- (void)setSlider:(NSSlider *)s { [_slider autorelease]; _slider = [s retain]; }
- (double)doubleValue { return [_slider doubleValue]; }
- (void)setDoubleValue:(double)v { [_slider setDoubleValue:v]; }
- (CGFloat)minimumSliderWidth { return _minWidth; }
- (void)setMinimumSliderWidth:(CGFloat)w { _minWidth = w; }
- (CGFloat)maximumSliderWidth { return _maxWidth; }
- (void)setMaximumSliderWidth:(CGFloat)w { _maxWidth = w; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label autorelease]; _label = [l copy]; }
- (NSSliderAccessory *)minimumValueAccessory { return _minAccessory; }
- (void)setMinimumValueAccessory:(NSSliderAccessory *)a { [_minAccessory autorelease]; _minAccessory = [a retain]; }
- (NSSliderAccessory *)maximumValueAccessory { return _maxAccessory; }
- (void)setMaximumValueAccessory:(NSSliderAccessory *)a { [_maxAccessory autorelease]; _maxAccessory = [a retain]; }
- (NSSliderAccessoryWidth)valueAccessoryWidth { return _accessoryWidth; }
- (void)setValueAccessoryWidth:(NSSliderAccessoryWidth)w { _accessoryWidth = w; }
- (id)target { return [_slider target]; }
- (void)setTarget:(id)t { [_slider setTarget:t]; }
- (SEL)action { return [_slider action]; }
- (void)setAction:(SEL)a { [_slider setAction:a]; }

@end

@implementation NSColorPickerTouchBarItem {
    NSColor *_color;
    BOOL _showsAlpha, _enabled;
    NSArray *_spaces;
    NSColorList *_list;
    __weak id _target;
    SEL _action;
}

+ (instancetype)colorPickerWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    return [[[self alloc] initWithIdentifier:identifier] autorelease];
}
+ (instancetype)textColorPickerWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    NSColorPickerTouchBarItem *c = [self colorPickerWithIdentifier:identifier];
    [c setShowsAlpha:NO];
    return c;
}
+ (instancetype)strokeColorPickerWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    return [self colorPickerWithIdentifier:identifier];
}
+ (instancetype)colorPickerWithIdentifier:(NSTouchBarItemIdentifier)identifier buttonImage:(NSImage *)image
{
    return [self colorPickerWithIdentifier:identifier];
}

- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super initWithIdentifier:identifier];
    if (self) {
        _color = [[NSColor colorWithGenericGamma22White:0 alpha:1] retain];
        _showsAlpha = YES;
        _enabled = YES;
    }
    return self;
}

- (void)dealloc
{
    [_color release];
    [_spaces release];
    [_list release];
    [super dealloc];
}

- (NSColor *)color { return _color; }
- (void)setColor:(NSColor *)c { [_color autorelease]; _color = [c copy]; }
- (BOOL)showsAlpha { return _showsAlpha; }
- (void)setShowsAlpha:(BOOL)f { _showsAlpha = f; }
- (NSArray *)allowedColorSpaces { return _spaces; }
- (void)setAllowedColorSpaces:(NSArray *)a { [_spaces autorelease]; _spaces = [a copy]; }
- (NSColorList *)colorList { return _list; }
- (void)setColorList:(NSColorList *)l { [_list autorelease]; _list = [l retain]; }
- (id)target { return _target; }
- (void)setTarget:(id)t { _target = t; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)a { _action = a; }
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)f { _enabled = f; }

@end

@implementation NSStepperTouchBarItem {
    double _max, _min, _increment, _value;
    __weak id _target;
    SEL _action;
}

+ (instancetype)stepperTouchBarItemWithIdentifier:(NSTouchBarItemIdentifier)identifier formatter:(NSFormatter *)formatter
{
    return [[[self alloc] initWithIdentifier:identifier] autorelease];
}

+ (instancetype)stepperTouchBarItemWithIdentifier:(NSTouchBarItemIdentifier)identifier
                                   drawingHandler:(void (^)(NSRect, double))drawingHandler
{
    return [[[self alloc] initWithIdentifier:identifier] autorelease];
}

/* As Apple's: 0 to 59 in steps of 1. */
- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super initWithIdentifier:identifier];
    if (self) {
        _max = 59;
        _increment = 1;
    }
    return self;
}

- (double)maxValue { return _max; }
- (void)setMaxValue:(double)v { _max = v; }
- (double)minValue { return _min; }
- (void)setMinValue:(double)v { _min = v; }
- (double)increment { return _increment; }
- (void)setIncrement:(double)v { _increment = v; }
- (double)value { return _value; }
- (void)setValue:(double)v { _value = MIN(MAX(v, _min), _max); }
- (id)target { return _target; }
- (void)setTarget:(id)t { _target = t; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)a { _action = a; }

@end

@implementation NSPickerTouchBarItem {
    NSMutableArray *_labels, *_images, *_enabledAt;
    NSPickerTouchBarItemSelectionMode _mode;
    NSPickerTouchBarItemControlRepresentation _representation;
    NSString *_collapsedLabel;
    NSImage *_collapsedImage;
    NSColor *_selectionColor;
    NSInteger _selected;
    __weak id _target;
    SEL _action;
    BOOL _enabled;
}

+ (instancetype)pickerTouchBarItemWithIdentifier:(NSTouchBarItemIdentifier)identifier labels:(NSArray<NSString *> *)labels
                                   selectionMode:(NSPickerTouchBarItemSelectionMode)mode target:(id)target action:(SEL)action
{
    NSPickerTouchBarItem *p = [[[self alloc] initWithIdentifier:identifier] autorelease];
    [p setNumberOfOptions:(NSInteger)[labels count]];
    for (NSUInteger i = 0; i < [labels count]; i++)
        [p setLabel:labels[i] atIndex:(NSInteger)i];
    [p setSelectionMode:mode];
    [p setTarget:target];
    [p setAction:action];
    return p;
}

+ (instancetype)pickerTouchBarItemWithIdentifier:(NSTouchBarItemIdentifier)identifier images:(NSArray<NSImage *> *)images
                                   selectionMode:(NSPickerTouchBarItemSelectionMode)mode target:(id)target action:(SEL)action
{
    NSPickerTouchBarItem *p = [[[self alloc] initWithIdentifier:identifier] autorelease];
    [p setNumberOfOptions:(NSInteger)[images count]];
    for (NSUInteger i = 0; i < [images count]; i++)
        [p setImage:images[i] atIndex:(NSInteger)i];
    [p setSelectionMode:mode];
    [p setTarget:target];
    [p setAction:action];
    return p;
}

- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super initWithIdentifier:identifier];
    if (self) {
        _labels = [[NSMutableArray alloc] init];
        _images = [[NSMutableArray alloc] init];
        _enabledAt = [[NSMutableArray alloc] init];
        _collapsedLabel = @"";
        _selected = -1;
        _enabled = YES;
    }
    return self;
}

- (void)dealloc
{
    [_labels release];
    [_images release];
    [_enabledAt release];
    [_collapsedLabel release];
    [_collapsedImage release];
    [_selectionColor release];
    [super dealloc];
}

- (NSInteger)numberOfOptions { return (NSInteger)[_labels count]; }
- (void)setNumberOfOptions:(NSInteger)n
{
    while ((NSInteger)[_labels count] < n) {
        [_labels addObject:@""];
        [_images addObject:[NSNull null]];
        [_enabledAt addObject:@YES];
    }
    while ((NSInteger)[_labels count] > MAX(n, 0)) {
        [_labels removeLastObject];
        [_images removeLastObject];
        [_enabledAt removeLastObject];
    }
}

static BOOL
in_range(NSArray *a, NSInteger i)
{
    return i >= 0 && i < (NSInteger)[a count];
}

- (void)setLabel:(NSString *)l atIndex:(NSInteger)i { if (in_range(_labels, i)) _labels[(NSUInteger)i] = l ?: @""; }
- (NSString *)labelAtIndex:(NSInteger)i { return in_range(_labels, i) ? _labels[(NSUInteger)i] : nil; }
- (void)setImage:(NSImage *)img atIndex:(NSInteger)i { if (in_range(_images, i)) _images[(NSUInteger)i] = img ?: (id)[NSNull null]; }
- (NSImage *)imageAtIndex:(NSInteger)i
{
    id img = in_range(_images, i) ? _images[(NSUInteger)i] : nil;
    return img == [NSNull null] ? nil : img;
}
- (void)setEnabled:(BOOL)f atIndex:(NSInteger)i { if (in_range(_enabledAt, i)) _enabledAt[(NSUInteger)i] = @(f); }
- (BOOL)isEnabledAtIndex:(NSInteger)i { return in_range(_enabledAt, i) && [_enabledAt[(NSUInteger)i] boolValue]; }
- (NSPickerTouchBarItemControlRepresentation)controlRepresentation { return _representation; }
- (void)setControlRepresentation:(NSPickerTouchBarItemControlRepresentation)r { _representation = r; }
- (NSString *)collapsedRepresentationLabel { return _collapsedLabel; }
- (void)setCollapsedRepresentationLabel:(NSString *)l { [_collapsedLabel autorelease]; _collapsedLabel = [l copy]; }
- (NSImage *)collapsedRepresentationImage { return _collapsedImage; }
- (void)setCollapsedRepresentationImage:(NSImage *)i { [_collapsedImage autorelease]; _collapsedImage = [i retain]; }
- (NSColor *)selectionColor { return _selectionColor; }
- (void)setSelectionColor:(NSColor *)c { [_selectionColor autorelease]; _selectionColor = [c copy]; }
- (NSPickerTouchBarItemSelectionMode)selectionMode { return _mode; }
- (void)setSelectionMode:(NSPickerTouchBarItemSelectionMode)m { _mode = m; }
- (NSInteger)selectedIndex { return _selected; }
- (void)setSelectedIndex:(NSInteger)i { _selected = i; }
- (id)target { return _target; }
- (void)setTarget:(id)t { _target = t; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)a { _action = a; }
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)f { _enabled = f; }

@end

@implementation NSSharingServicePickerTouchBarItem {
    id _delegate;  /* weak */
    BOOL _enabled;
    NSImage *_buttonImage;
    NSString *_buttonTitle;
}

- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super initWithIdentifier:identifier];
    if (self)
        _enabled = YES;
    return self;
}

- (void)dealloc
{
    [_buttonImage release];
    [_buttonTitle release];
    [super dealloc];
}

- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)f { _enabled = f; }
- (NSImage *)buttonImage { return _buttonImage; }
- (void)setButtonImage:(NSImage *)i { [_buttonImage autorelease]; _buttonImage = [i retain]; }
- (NSString *)buttonTitle { return _buttonTitle; }
- (void)setButtonTitle:(NSString *)t { [_buttonTitle autorelease]; _buttonTitle = [t copy]; }

@end

@implementation NSCandidateListTouchBarItem {
    NSView *_client;
    id _delegate;  /* weak */
    BOOL _collapsed, _allowsCollapsing, _textInputCandidates;
    NSArray *_candidates;
    id _attributedStringForCandidate;
}

- (instancetype)initWithIdentifier:(NSTouchBarItemIdentifier)identifier
{
    self = [super initWithIdentifier:identifier];
    if (self) {
        _allowsCollapsing = YES;
        _textInputCandidates = YES;
    }
    return self;
}

- (void)dealloc
{
    [_candidates release];
    [_attributedStringForCandidate release];
    [super dealloc];
}

- (NSView *)client { return _client; }
- (void)setClient:(NSView *)c { _client = c; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (BOOL)isCollapsed { return _collapsed; }
- (void)setCollapsed:(BOOL)f { _collapsed = f; }
- (BOOL)allowsCollapsing { return _allowsCollapsing; }
- (void)setAllowsCollapsing:(BOOL)f { _allowsCollapsing = f; }
- (BOOL)isCandidateListVisible { return NO; }
- (void)updateWithInsertionPointVisibility:(BOOL)isVisible {}
- (BOOL)allowsTextInputContextCandidates { return _textInputCandidates; }
- (void)setAllowsTextInputContextCandidates:(BOOL)f { _textInputCandidates = f; }
- (NSAttributedString * (^)(id, NSInteger))attributedStringForCandidate { return _attributedStringForCandidate; }
- (void)setAttributedStringForCandidate:(NSAttributedString * (^)(id, NSInteger))b
{
    [_attributedStringForCandidate autorelease];
    _attributedStringForCandidate = [b copy];
}
- (NSArray *)candidates { return _candidates ?: @[]; }
- (void)setCandidates:(NSArray *)c forSelectedRange:(NSRange)r inString:(NSString *)s
{
    [_candidates autorelease];
    _candidates = [c copy];
}

@end
