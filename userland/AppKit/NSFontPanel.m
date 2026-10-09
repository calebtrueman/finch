/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFontPanel: the shared panel for choosing a font, in Finch's own look:
 * three lists (families, the family's faces, sizes), a size field and a
 * preview. Choosing in it sends NSFontManager's -modifyFontViaPanel:, and the
 * receiver of changeFont: asks -panelConvertFont: (through the manager's
 * -convertFont:) what its font becomes: the panel's family (keeping the
 * font's traits and weight) or, once the user picks one, its face, at the
 * panel's size, as Apple's panel converts.
 */
#import "NSControl_Finch.h"

FINCH_PRIVATE NSArray *FinchFontFaces(NSString *family);
FINCH_PRIVATE NSString *FinchFontFaceOf(NSFont *font);

#pragma mark - A list

/* A plain list of strings in a scroll view: click to choose. */
@interface _FinchFontList : NSView {
@public
    NSArray<NSString *> *_items;
    NSInteger _selected;
    id _target; /* not retained */
    SEL _action;
}
- (void)setItems:(NSArray<NSString *> *)items;
- (void)selectItem:(NSString *)item;
@end

static const CGFloat ROW = 18;

@implementation _FinchFontList

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    _selected = -1;
    return self;
}

- (void)dealloc
{
    [_items release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)_finchResize
{
    NSSize s = [[self enclosingScrollView] contentSize];
    [self setFrameSize:NSMakeSize(s.width, MAX(s.height, ROW * [_items count]))];
}

- (void)setItems:(NSArray<NSString *> *)items
{
    [_items release];
    _items = [items copy];
    _selected = -1;
    [self _finchResize];
    [self setNeedsDisplay:YES];
}

- (void)selectItem:(NSString *)item
{
    _selected = item ? (NSInteger)[_items indexOfObject:item] : -1;
    if (_selected == (NSInteger)NSNotFound)
        _selected = -1;
    if (_selected >= 0)
        [self scrollRectToVisible:NSMakeRect(0, ROW * _selected, 1, ROW)];
    [self setNeedsDisplay:YES];
}

- (NSString *)selectedItem { return _selected >= 0 ? [_items objectAtIndex:(NSUInteger)_selected] : nil; }

- (void)drawRect:(NSRect)dirty
{
    [[NSColor textBackgroundColor] setFill];
    NSRectFill(dirty);
    NSDictionary *plain = @{ NSFontAttributeName : [NSFont systemFontOfSize:12], NSForegroundColorAttributeName : [NSColor textColor] };
    NSDictionary *chosen = @{ NSFontAttributeName : [NSFont systemFontOfSize:12], NSForegroundColorAttributeName : [NSColor whiteColor] };
    NSInteger first = MAX(0, (NSInteger)floor(NSMinY(dirty) / ROW)), last = MIN((NSInteger)[_items count] - 1, (NSInteger)ceil(NSMaxY(dirty) / ROW));
    for (NSInteger i = first; i <= last; i++) {
        NSRect r = NSMakeRect(0, ROW * i, NSWidth([self bounds]), ROW);
        if (i == _selected) {
            [FinchAccentColor() setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 3, 1) xRadius:4 yRadius:4] fill];
        }
        [[_items objectAtIndex:(NSUInteger)i] drawAtPoint:NSMakePoint(8, NSMinY(r) + 2) withAttributes:i == _selected ? chosen : plain];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger i = (NSInteger)floor(p.y / ROW);
    if (i < 0 || i >= (NSInteger)[_items count])
        return;
    _selected = i;
    [self setNeedsDisplay:YES];
    if (_action)
        [NSApp sendAction:_action to:_target from:self];
}

@end

#pragma mark - The panel

static NSFontPanel *sharedPanel;

@interface NSFontManager (FinchPanelFactory)
+ (Class)_finchFontPanelFactory;
@end

@implementation NSFontPanel {
    _FinchFontList *_families, *_faces, *_sizes;
    NSTextField *_sizeField, *_preview;
    NSView *_accessory;
    NSString *_family, *_faceName; /* the face chosen by the user, or nil */
    CGFloat _size;
    BOOL _disabled, _worksWhenModal, _keyIfNeeded;
}

+ (BOOL)sharedFontPanelExists { return sharedPanel != nil; }

+ (NSFontPanel *)sharedFontPanel
{
    @synchronized([NSFontPanel class]) {
        if (!sharedPanel) {
            Class c = [NSFontManager _finchFontPanelFactory] ?: [NSFontPanel class];
            sharedPanel = [[c alloc] initWithContentRect:NSMakeRect(0, 0, 480, 300)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
        }
    }
    return sharedPanel;
}

static _FinchFontList *
add_list(NSFontPanel *self, NSView *content, NSRect frame, SEL action)
{
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:frame];
    [sv setHasVerticalScroller:YES];
    [sv setBorderType:NSLineBorder];
    [sv setAutoresizingMask:NSViewHeightSizable | (frame.origin.x > 200 ? NSViewMinXMargin : NSViewWidthSizable)];
    _FinchFontList *list = [[_FinchFontList alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
    list->_target = self;
    list->_action = action;
    [sv setDocumentView:list];
    [content addSubview:sv];
    [sv release];
    return [list autorelease];
}

- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing
                              defer:(BOOL)flag
{
    self = [super initWithContentRect:rect styleMask:style backing:backing defer:flag];
    if (!self)
        return nil;
    [self setTitle:@"Fonts"];
    [self setFloatingPanel:YES];
    [self setHidesOnDeactivate:YES];
    _keyIfNeeded = YES;
    _worksWhenModal = YES;
    _size = 12;
    NSView *content = [self contentView];
    CGFloat h = NSHeight(rect);
    _preview = [[NSTextField labelWithString:@""] retain];
    [_preview setFrame:NSMakeRect(12, h - 48, NSWidth(rect) - 24, 36)];
    [_preview setAlignment:NSTextAlignmentCenter];
    [_preview setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:_preview];
    _families = [add_list(self, content, NSMakeRect(12, 12, 200, h - 70), @selector(_finchFamilyChosen:)) retain];
    _faces = [add_list(self, content, NSMakeRect(220, 12, 150, h - 70), @selector(_finchFaceChosen:)) retain];
    _sizes = [add_list(self, content, NSMakeRect(378, 12, 90, h - 100), @selector(_finchSizeChosen:)) retain];
    _sizeField = [[NSTextField textFieldWithString:@"12"] retain];
    [_sizeField setFrame:NSMakeRect(378, h - 82, 90, 24)];
    [_sizeField setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [_sizeField setTarget:self];
    [_sizeField setAction:@selector(_finchSizeTyped:)];
    [content addSubview:_sizeField];
    [_sizes setItems:@[ @"9", @"10", @"11", @"12", @"13", @"14", @"18", @"24", @"36", @"48", @"64", @"72", @"96", @"144", @"288" ]];
    [self reloadDefaultFontFamilies];
    return self;
}

- (void)dealloc
{
    [_families release];
    [_faces release];
    [_sizes release];
    [_sizeField release];
    [_preview release];
    [_accessory release];
    [_family release];
    [_faceName release];
    [super dealloc];
}

- (BOOL)becomesKeyOnlyIfNeeded { return _keyIfNeeded; }
- (void)setBecomesKeyOnlyIfNeeded:(BOOL)flag { _keyIfNeeded = flag; }
- (BOOL)worksWhenModal { return _worksWhenModal; }
- (void)setWorksWhenModal:(BOOL)flag { _worksWhenModal = flag; }
- (BOOL)isEnabled { return !_disabled; }
- (void)setEnabled:(BOOL)flag { _disabled = !flag; }
- (NSView *)accessoryView { return _accessory; }

- (void)setAccessoryView:(NSView *)view
{
    [_accessory removeFromSuperview];
    [view retain];
    [_accessory release];
    _accessory = view;
    if (view) {
        NSRect f = [[self contentView] bounds];
        [view setFrameOrigin:NSMakePoint(12, 4)];
        [[self contentView] addSubview:view];
        (void)f;
    }
}

- (void)reloadDefaultFontFamilies
{
    [_families setItems:[[NSFontManager sharedFontManager] availableFontFamilies]];
    [_families selectItem:_family];
    [self _finchShowFaces];
}

- (void)_finchShowFaces
{
    NSMutableArray *faces = [NSMutableArray array];
    for (NSArray *f in FinchFontFaces(_family))
        [faces addObject:[f objectAtIndex:0]];
    [_faces setItems:faces];
}

- (void)_finchShowPreview:(NSFont *)font
{
    if (!font) {
        [_preview setStringValue:@""];
        return;
    }
    [_preview setFont:[font fontWithSize:MIN([font pointSize], 24)]];
    [_preview setStringValue:[NSString stringWithFormat:@"%@ %@ %g pt", [font familyName], FinchFontFaceOf(font) ?: @"",
                                                                       [font pointSize]]];
}

- (void)setPanelFont:(NSFont *)font isMultiple:(BOOL)flag
{
    if (!font)
        return;
    [_family release];
    _family = [[font familyName] copy];
    [_faceName release];
    _faceName = nil;
    _size = [font pointSize];
    [_families selectItem:_family];
    [self _finchShowFaces];
    [_faces selectItem:FinchFontFaceOf(font)];
    [_sizeField setStringValue:[NSString stringWithFormat:@"%g", _size]];
    [_sizes selectItem:[NSString stringWithFormat:@"%g", _size]];
    [self _finchShowPreview:flag ? nil : font];
}

- (NSFont *)panelConvertFont:(NSFont *)font
{
    NSFontManager *fm = [NSFontManager sharedFontManager];
    NSFont *f = font;
    if (_faceName) {
        for (NSArray *face in FinchFontFaces(_family))
            if ([[face objectAtIndex:0] isEqualToString:_faceName])
                f = [NSFont fontWithName:[face objectAtIndex:1] size:[font pointSize]] ?: f;
    } else if (_family) {
        f = [fm convertFont:f toFamily:_family];
    }
    if (_size > 0)
        f = [fm convertFont:f toSize:_size];
    return f;
}

- (NSFontPanelModeMask)_finchValidModes
{
    id r = [[NSApp keyWindow] firstResponder];
    if ([r respondsToSelector:@selector(validModesForFontPanel:)])
        return [r validModesForFontPanel:self];
    return NSFontPanelModesMaskStandardModes;
}

#pragma mark Choosing

- (void)_finchChanged
{
    if (_disabled)
        return;
    NSFontManager *fm = [NSFontManager sharedFontManager];
    if ([fm selectedFont])
        [self _finchShowPreview:[self panelConvertFont:[fm selectedFont]]];
    [fm modifyFontViaPanel:self];
}

- (void)_finchFamilyChosen:(_FinchFontList *)list
{
    [_family release];
    _family = [[list selectedItem] copy];
    [_faceName release];
    _faceName = nil;
    [self _finchShowFaces];
    NSFont *sel = [[NSFontManager sharedFontManager] selectedFont];
    if (sel)
        [_faces selectItem:FinchFontFaceOf([[NSFontManager sharedFontManager] convertFont:sel toFamily:_family])];
    [self _finchChanged];
}

- (void)_finchFaceChosen:(_FinchFontList *)list
{
    [_faceName release];
    _faceName = [[list selectedItem] copy];
    [self _finchChanged];
}

- (void)_finchSizeChosen:(_FinchFontList *)list
{
    _size = [[list selectedItem] doubleValue];
    [_sizeField setStringValue:[list selectedItem] ?: @""];
    [self _finchChanged];
}

- (void)_finchSizeTyped:(NSTextField *)field
{
    CGFloat s = [field doubleValue];
    if (s <= 0)
        return;
    _size = s;
    [_sizes selectItem:[NSString stringWithFormat:@"%g", s]];
    [self _finchChanged];
}

@end
