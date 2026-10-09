/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Each displayed component keeps the URL for the path up to that point. */
#import "NSPathControl_Finch.h"

@implementation NSPathCell {
    NSURL *_URL;
    NSArray *_components, *_allowedTypes;
    NSColor *_background;
    id _placeholder, _delegate;
    NSPathStyle _pathStyle;
    SEL _doubleAction;
    NSPathComponentCell *_clicked, *_hovered;
}
+ (Class)pathComponentCellClass { return [NSPathComponentCell class]; }
- (instancetype)init { return [self initTextCell:@""]; }
- (instancetype)initTextCell:(NSString *)s
{
    if (!(self = [super initTextCell:@""])) return nil;
    _components = [@[] retain]; [self setEditable:YES]; [self setSelectable:YES];
    if ([s length]) [self setStringValue:s]; return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder])) return nil;
    _URL = [[coder decodeObjectForKey:@"NSContents"] copy];
    _components = [[coder decodeObjectForKey:@"NSPathComponentCells"] copy] ?: [@[] retain];
    _pathStyle = [coder decodeIntegerForKey:@"NSPathStyle"];
    _allowedTypes = [[coder decodeObjectForKey:@"NSAllowedTypes"] copy];
    _background = [[coder decodeObjectForKey:@"NSBackgroundColor"] copy];
    _placeholder = [[coder decodeObjectForKey:@"NSPlaceholderString"] copy]; _delegate = [coder decodeObjectForKey:@"NSDelegate"];
    NSString *action = [coder decodeObjectForKey:@"NSDoubleAction"]; if (action) _doubleAction = NSSelectorFromString(action);
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder]; [coder encodeObject:_URL forKey:@"NSContents"]; [coder encodeObject:_components forKey:@"NSPathComponentCells"];
    [coder encodeInteger:_pathStyle forKey:@"NSPathStyle"]; [coder encodeObject:_allowedTypes forKey:@"NSAllowedTypes"];
    [coder encodeObject:_background forKey:@"NSBackgroundColor"]; [coder encodeObject:_placeholder forKey:@"NSPlaceholderString"];
    [coder encodeConditionalObject:_delegate forKey:@"NSDelegate"]; if (_doubleAction) [coder encodeObject:NSStringFromSelector(_doubleAction) forKey:@"NSDoubleAction"];
}
- (void)dealloc { [_URL release]; [_components release]; [_allowedTypes release]; [_background release]; [_placeholder release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone
{
    NSPathCell *c = [super copyWithZone:zone]; [c->_URL retain];
    c->_components = [[NSArray alloc] initWithArray:_components copyItems:YES]; [c->_allowedTypes retain];
    [c->_background retain]; [c->_placeholder retain]; c->_clicked = nil; c->_hovered = nil; return c;
}
- (NSPathStyle)pathStyle { return _pathStyle; }
- (void)setPathStyle:(NSPathStyle)s { _pathStyle = s; [self _finchChanged]; }
- (NSURL *)URL { return _URL; }
- (id)objectValue { return _URL; }
- (NSString *)stringValue { return [_URL absoluteString] ?: @""; }
- (void)setStringValue:(NSString *)s { [self setObjectValue:s]; }
- (void)setObjectValue:(id)o
{
    if ([o isKindOfClass:[NSURL class]] || !o) [self setURL:o];
    else if ([o isKindOfClass:[NSString class]]) {
        NSURL *URL = [NSURL URLWithString:o]; [self setURL:[[URL scheme] length] ? URL : [NSURL fileURLWithPath:o]];
    } else [NSException raise:NSInvalidArgumentException format:@"A path needs a URL or string"];
}
- (void)setURL:(NSURL *)URL
{
    NSURL *copy = [URL copy]; [_URL release]; _URL = copy;
    NSMutableArray *cells = [NSMutableArray array];
    NSArray *parts = [[URL path] pathComponents]; NSMutableString *path = [NSMutableString string];
    BOOL file = [URL isFileURL];
    if (file && _pathStyle == NSPathStylePopUp) {
        NSPathComponentCell *computer = [[[[self class] pathComponentCellClass] alloc] initTextCell:[[NSProcessInfo processInfo] hostName]];
        [computer setURL:[NSURL URLWithString:@"file:/"]];
        [computer setFont:[self font]]; [computer setControlSize:[self controlSize]];
        [computer setImage:[[NSWorkspace sharedWorkspace] iconForFile:@"/"]];
        [cells addObject:computer]; [computer release];
    }
    NSURLComponents *urlParts = URL ? [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES] : nil;
    [urlParts setQuery:nil]; [urlParts setFragment:nil];
    for (NSString *part in parts) {
        if ([part isEqual:@"/"]) [path setString:@"/"];
        else { if (![path hasSuffix:@"/"]) [path appendString:@"/"]; [path appendString:part]; }
        if (!file && [part isEqual:@"/"]) continue;
        NSURL *componentURL;
        if (file) componentURL = [NSURL fileURLWithPath:path isDirectory:NO];
        else { [urlParts setPath:path]; componentURL = [urlParts URL]; }
        NSString *title = part;
        if (file) {
            NSString *display = [[NSFileManager defaultManager] displayNameAtPath:path];
            if ([display length]) title = display;
        }
        NSPathComponentCell *cell = [[[[self class] pathComponentCellClass] alloc] initTextCell:title];
        [cell setURL:componentURL]; [cell setFont:[self font]]; [cell setControlSize:[self controlSize]];
        [cell setControlView:[self controlView]];
        if (file) [cell setImage:[[NSWorkspace sharedWorkspace] iconForFile:path]];
        [cells addObject:cell]; [cell release];
    }
    [self setPathComponentCells:cells];
}
- (NSArray *)pathComponentCells { return _components; }
- (void)setPathComponentCells:(NSArray *)cells
{
    NSArray *copy = [cells copy] ?: [@[] retain]; [_components release]; _components = copy;
    _clicked = nil; _hovered = nil;
    for (NSPathComponentCell *cell in _components) [cell setControlView:[self controlView]];
    [self _finchChanged];
}
- (void)setControlView:(NSView *)view { [super setControlView:view]; for (NSPathComponentCell *cell in _components) [cell setControlView:view]; }
- (NSArray *)allowedTypes { return _allowedTypes; }
- (void)setAllowedTypes:(NSArray *)a { NSArray *copy = [a copy]; [_allowedTypes release]; _allowedTypes = copy; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (SEL)doubleAction { return _doubleAction; }
- (void)setDoubleAction:(SEL)action { _doubleAction = action; }
- (NSColor *)backgroundColor { return _background; }
- (void)setBackgroundColor:(NSColor *)c { NSColor *copy = [c copy]; [_background release]; _background = copy; [self _finchChanged]; }
- (NSString *)placeholderString { return [_placeholder isKindOfClass:[NSString class]] ? _placeholder : nil; }
- (void)setPlaceholderString:(NSString *)s { id copy = [s copy]; [_placeholder release]; _placeholder = copy; [self _finchChanged]; }
- (NSAttributedString *)placeholderAttributedString { return [_placeholder isKindOfClass:[NSAttributedString class]] ? _placeholder : nil; }
- (void)setPlaceholderAttributedString:(NSAttributedString *)s { id copy = [s copy]; [_placeholder release]; _placeholder = copy; [self _finchChanged]; }
- (void)setControlSize:(NSControlSize)s { [super setControlSize:s]; for (NSCell *cell in _components) [cell setControlSize:s]; }
- (void)setFont:(NSFont *)font { [super setFont:font]; for (NSCell *cell in _components) [cell setFont:font]; }
- (NSPathComponentCell *)clickedPathComponentCell { return _clicked; }
- (void)_finchSetClickedCell:(NSPathComponentCell *)cell { _clicked = cell; }
- (BOOL)isOpaque { return _background && [_background alphaComponent] == 1; }
- (NSSize)cellSizeForBounds:(NSRect)r
{
    if (![_components count] && ![_placeholder length]) return NSZeroSize;
    CGFloat width = 0, height = [self controlSize] == NSControlSizeMini ? 15 : 19;
    if (_pathStyle == NSPathStylePopUp && [_components count]) width = [[_components lastObject] cellSize].width + 24;
    else for (NSCell *cell in _components) width += [cell cellSize].width + 9;
    if (![_components count]) width = [_placeholder isKindOfClass:[NSString class]] ? [_placeholder sizeWithAttributes:[self _finchTextAttributes]].width : [_placeholder size].width;
    return NSMakeSize(ceil(width), height);
}
- (NSArray *)_finchComponentRects:(NSRect)frame
{
    NSMutableArray *rects = [NSMutableArray array]; NSUInteger count = [_components count]; if (!count) return rects;
    if (_pathStyle == NSPathStylePopUp) {
        for (NSUInteger i = 0; i < count; i++) [rects addObject:[NSValue valueWithRect:i + 1 == count ? NSMakeRect(frame.origin.x + 3, frame.origin.y, MAX(0, frame.size.width - 20), frame.size.height) : NSZeroRect]];
        return rects;
    }
    CGFloat *widths = calloc(count, sizeof(CGFloat)), total = 0;
    for (NSUInteger i = 0; i < count; i++) { widths[i] = [[_components objectAtIndex:i] cellSize].width + (i + 1 < count ? 9 : 0); total += widths[i]; }
    CGFloat deficit = MAX(0, total - frame.size.width);
    for (NSUInteger pass = 0; pass < 2 && deficit > 0; pass++) for (NSUInteger i = 0; i < count && deficit > 0; i++) {
        if (!pass && (i + 1 == count || [_components objectAtIndex:i] == _hovered)) continue;
        CGFloat minimum = pass ? 16 : 30, remove = MIN(deficit, MAX(0, widths[i] - minimum)); widths[i] -= remove; deficit -= remove;
    }
    CGFloat x = frame.origin.x;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat width = MAX(0, MIN(widths[i], NSMaxX(frame) - x));
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x, frame.origin.y, width, frame.size.height)]]; x += width;
    }
    free(widths); return rects;
}
- (NSRect)rectOfPathComponentCell:(NSPathComponentCell *)cell withFrame:(NSRect)frame inView:(NSView *)view
{
    NSUInteger i = [_components indexOfObjectIdenticalTo:cell]; return i == NSNotFound ? NSZeroRect : [[[self _finchComponentRects:frame] objectAtIndex:i] rectValue];
}
- (NSPathComponentCell *)pathComponentCellAtPoint:(NSPoint)p withFrame:(NSRect)frame inView:(NSView *)view
{
    NSArray *rects = [self _finchComponentRects:frame];
    for (NSUInteger i = 0; i < [rects count]; i++) if (NSPointInRect(p, [[rects objectAtIndex:i] rectValue])) return [_components objectAtIndex:i]; return nil;
}
- (void)mouseEntered:(NSEvent *)event withFrame:(NSRect)frame inView:(NSView *)view
{
    _hovered = [self pathComponentCellAtPoint:[view convertPoint:[event locationInWindow] fromView:nil] withFrame:frame inView:view]; [self _finchChanged];
}
- (void)mouseExited:(NSEvent *)event withFrame:(NSRect)frame inView:(NSView *)view { _hovered = nil; [self _finchChanged]; }
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    if (_background) { [_background setFill]; NSRectFillUsingOperation(frame, NSCompositingOperationSourceOver); }
    if (_pathStyle == NSPathStylePopUp) FinchDrawBezel(frame, 4, FinchControlFill(NO), FinchControlStroke());
    if (![_components count]) {
        NSAttributedString *placeholder = [_placeholder isKindOfClass:[NSAttributedString class]] ? _placeholder :
            [[[NSAttributedString alloc] initWithString:_placeholder ?: @"" attributes:[self _finchTextAttributes]] autorelease];
        FinchDrawCellText(placeholder, NSInsetRect(frame, 5, 1), [view isFlipped]);
    }
    NSArray *rects = [self _finchComponentRects:frame];
    for (NSUInteger i = 0; i < [_components count]; i++) {
        NSRect r = [[rects objectAtIndex:i] rectValue]; if (NSIsEmptyRect(r)) continue;
        NSRect content = r; BOOL arrow = i + 1 < [_components count] && _pathStyle != NSPathStylePopUp;
        if (arrow) content.size.width = MAX(0, content.size.width - 9);
        [[_components objectAtIndex:i] drawWithFrame:content inView:view];
        if (arrow) {
            [[NSColor secondaryLabelColor] setStroke]; NSBezierPath *p = [NSBezierPath bezierPath];
            [p moveToPoint:NSMakePoint(NSMaxX(r) - 7, NSMidY(r) - 4)]; [p lineToPoint:NSMakePoint(NSMaxX(r) - 3, NSMidY(r))];
            [p lineToPoint:NSMakePoint(NSMaxX(r) - 7, NSMidY(r) + 4)]; [p stroke];
        }
    }
    if (_pathStyle == NSPathStylePopUp) {
        [[NSColor secondaryLabelColor] setStroke]; NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(NSMaxX(frame) - 13, NSMidY(frame) - 2)]; [p lineToPoint:NSMakePoint(NSMaxX(frame) - 9, NSMidY(frame) + 2)];
        [p lineToPoint:NSMakePoint(NSMaxX(frame) - 5, NSMidY(frame) - 2)]; [p stroke];
    }
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { return [self isEnabled]; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityListRole; }
- (NSString *)accessibilitySubrole { return nil; }
- (NSArray *)accessibilityChildren { return _components; }
@end
