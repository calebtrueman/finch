/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSPathControl_Finch.h"

@implementation NSPathControl {
    NSArray *_items, *_dragTypes;
    id _delegate;
    NSMenu *_pathMenu;
    NSDragOperation _localMask, _remoteMask;
}
+ (Class)cellClass { return [super cellClass] ?: [NSPathCell class]; }
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _localMask = NSDragOperationEvery; [(NSPathCell *)[self cell] setDelegate:(id)self];
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeURL, NSFilenamesPboardType]];
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _localMask = NSDragOperationEvery; [(NSPathCell *)[self cell] setDelegate:(id)self];
        _pathMenu = [[coder decodeObjectForKey:@"NSMenu"] retain];
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeURL, NSFilenamesPboardType]];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [super encodeWithCoder:coder]; [coder encodeObject:_pathMenu forKey:@"NSMenu"]; }
- (void)dealloc { [_items release]; [_dragTypes release]; [_pathMenu release]; [super dealloc]; }
- (void)registerForDraggedTypes:(NSArray *)types { NSArray *copy = [types copy]; [_dragTypes release]; _dragTypes = copy; }
- (void)unregisterDraggedTypes { [_dragTypes release]; _dragTypes = nil; }
- (NSArray *)registeredDraggedTypes { return _dragTypes ?: @[]; }
- (BOOL)isEditable { return [[self cell] isEditable]; }
- (void)setEditable:(BOOL)b { [[self cell] setEditable:b]; }
- (NSArray *)allowedTypes { return [[self cell] allowedTypes]; }
- (void)setAllowedTypes:(NSArray *)a { [[self cell] setAllowedTypes:a]; }
- (NSString *)placeholderString { return [[self cell] placeholderString]; }
- (void)setPlaceholderString:(NSString *)s { [[self cell] setPlaceholderString:s]; }
- (NSAttributedString *)placeholderAttributedString { return [[self cell] placeholderAttributedString]; }
- (void)setPlaceholderAttributedString:(NSAttributedString *)s { [[self cell] setPlaceholderAttributedString:s]; }
- (NSURL *)URL { return [[self cell] URL]; }
- (void)setURL:(NSURL *)URL { [[self cell] setURL:URL]; [_items release]; _items = nil; [self invalidateIntrinsicContentSize]; }
- (SEL)doubleAction { return [[self cell] doubleAction]; }
- (void)setDoubleAction:(SEL)action { [[self cell] setDoubleAction:action]; }
- (NSPathStyle)pathStyle { return [[self cell] pathStyle]; }
- (void)setPathStyle:(NSPathStyle)style { [[self cell] setPathStyle:style]; [self invalidateIntrinsicContentSize]; }
- (NSColor *)backgroundColor { return [[self cell] backgroundColor]; }
- (void)setBackgroundColor:(NSColor *)color { [[self cell] setBackgroundColor:color]; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (NSMenu *)menu { return _pathMenu; }
- (void)setMenu:(NSMenu *)menu { [menu retain]; [_pathMenu release]; _pathMenu = menu; }
- (NSArray *)pathComponentCells { return [[self cell] pathComponentCells]; }
- (void)setPathComponentCells:(NSArray *)cells { [[self cell] setPathComponentCells:cells]; [_items release]; _items = nil; }
- (NSArray *)pathItems
{
    NSArray *cells = [self pathComponentCells];
    BOOL matches = [_items count] == [cells count];
    for (NSUInteger i = 0; matches && i < [cells count]; i++) matches = [[_items objectAtIndex:i] _finchCell] == [cells objectAtIndex:i];
    if (!_items || !matches) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSPathComponentCell *cell in cells) [items addObject:[[[NSPathControlItem alloc] _finchInitWithCell:cell] autorelease]];
        [_items release]; _items = [items copy];
    }
    return _items;
}
- (void)setPathItems:(NSArray *)items
{
    NSMutableArray *cells = [NSMutableArray array];
    for (NSPathControlItem *item in items) {
        if (![item isKindOfClass:[NSPathControlItem class]]) [NSException raise:NSInvalidArgumentException format:@"A path item must be an NSPathControlItem"];
        [cells addObject:[item _finchCell]];
    }
    [[self cell] setPathComponentCells:cells]; NSArray *copy = [items copy] ?: [@[] retain]; [_items release]; _items = copy;
}
- (NSPathComponentCell *)clickedPathComponentCell { return [[self cell] clickedPathComponentCell]; }
- (NSPathControlItem *)clickedPathItem
{
    NSPathComponentCell *clicked = [self clickedPathComponentCell];
    for (NSPathControlItem *item in [self pathItems]) if ([item _finchCell] == clicked) return item; return nil;
}
- (void)setDraggingSourceOperationMask:(NSDragOperation)mask forLocal:(BOOL)local { if (local) _localMask = mask; else _remoteMask = mask; }
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)local { return local ? _localMask : _remoteMask; }
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context { return context == NSDraggingContextWithinApplication ? _localMask : _remoteMask; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return [self isEnabled]; }
- (void)_finchClickComponent:(NSPathComponentCell *)cell doubleClick:(BOOL)twice
{
    [[self cell] _finchSetClickedCell:cell];
    [self sendAction:twice && [self doubleAction] ? [self doubleAction] : [self action] to:[self target]];
    [[self cell] _finchSetClickedCell:nil];
}
- (void)performClick:(id)sender { if ([self isEnabled]) [self _finchClickComponent:[[self pathComponentCells] lastObject] doubleClick:NO]; }
- (void)_finchChooseComponent:(NSMenuItem *)item { [self _finchClickComponent:[item representedObject] doubleClick:NO]; }
- (void)_finchChoosePath:(id)sender
{
    if (![self isEditable] || ![self isEnabled]) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel]; [panel setAllowsMultipleSelection:NO]; [panel setCanChooseDirectories:YES];
    NSArray *types = [self allowedTypes]; NSMutableArray *files = [NSMutableArray array];
    for (NSString *type in types) if (![type isEqual:@"public.folder"] && ![type isEqual:@"public.directory"]) [files addObject:type];
    [panel setCanChooseFiles:!types || [files count] > 0]; if ([files count]) [panel setAllowedFileTypes:files];
    if ([_delegate respondsToSelector:@selector(pathControl:willDisplayOpenPanel:)]) [_delegate pathControl:self willDisplayOpenPanel:panel];
    if ([panel runModal] == NSModalResponseOK) { [self setURL:[panel URL]]; [self _finchClickComponent:nil doubleClick:NO]; }
}
- (void)_finchPopUp
{
    NSMenu *menu = _pathMenu ?: [[[NSMenu alloc] initWithTitle:@""] autorelease];
    if (!_pathMenu) {
        for (NSPathComponentCell *cell in [[self pathComponentCells] reverseObjectEnumerator]) {
            NSMenuItem *item = [menu addItemWithTitle:[cell stringValue] action:@selector(_finchChooseComponent:) keyEquivalent:@""];
            [item setTarget:self]; [item setRepresentedObject:cell]; [item setImage:[cell image]];
        }
        if ([self isEditable]) { if ([menu numberOfItems]) [menu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *item = [menu addItemWithTitle:@"Choose…" action:@selector(_finchChoosePath:) keyEquivalent:@""]; [item setTarget:self]; }
    }
    if ([_delegate respondsToSelector:@selector(pathControl:willPopUpMenu:)]) [_delegate pathControl:self willPopUpMenu:menu];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY([self bounds])) inView:self];
}
- (BOOL)_finchStartDrag:(NSPathComponentCell *)cell event:(NSEvent *)event
{
    if (![[self cell] isSelectable] || ![cell URL]) return NO;
    NSPasteboard *board = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag]; [board clearContents];
    [board setString:[[cell URL] absoluteString] forType:NSPasteboardTypeURL];
    [board setString:[cell stringValue] forType:NSPasteboardTypeString];
    if ([[cell URL] isFileURL]) [board setPropertyList:@[[[cell URL] path]] forType:NSFilenamesPboardType];
    BOOL allowed = NO; [[self cell] _finchSetClickedCell:cell];
    if ([_delegate respondsToSelector:@selector(pathControl:shouldDragItem:withPasteboard:)]) allowed = [_delegate pathControl:self shouldDragItem:[self clickedPathItem] withPasteboard:board];
    else if ([_delegate respondsToSelector:@selector(pathControl:shouldDragPathComponentCell:withPasteboard:)]) allowed = [_delegate pathControl:self shouldDragPathComponentCell:cell withPasteboard:board];
    [[self cell] _finchSetClickedCell:nil];
    if (!allowed) return NO;
    NSImage *image = [cell image];
    if (image && [self respondsToSelector:@selector(dragImage:at:offset:event:pasteboard:source:slideBack:)]) {
        [self dragImage:image at:[self convertPoint:[event locationInWindow] fromView:nil] offset:NSZeroSize event:event pasteboard:board source:self slideBack:YES];
        return YES;
    }
    return NO;
}
- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled]) return; [[self window] makeFirstResponder:self];
    if ([self pathStyle] == NSPathStylePopUp) { [self _finchPopUp]; return; }
    NSPoint start = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPathComponentCell *cell = [[self cell] pathComponentCellAtPoint:start withFrame:[self bounds] inView:self]; if (!cell) return;
    [cell setHighlighted:YES]; BOOL inside = YES;
    for (;;) {
        NSEvent *next = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged]; if (!next) break;
        NSPoint p = [self convertPoint:[next locationInWindow] fromView:nil];
        if ([next type] == NSEventTypeLeftMouseDragged && hypot(p.x - start.x, p.y - start.y) > 4 && [self _finchStartDrag:cell event:next]) { [cell setHighlighted:NO]; return; }
        inside = [[self cell] pathComponentCellAtPoint:p withFrame:[self bounds] inView:self] == cell;
        [cell setHighlighted:inside]; if ([next type] == NSEventTypeLeftMouseUp) break;
    }
    [cell setHighlighted:NO]; if (inside) [self _finchClickComponent:cell doubleClick:[event clickCount] > 1];
}
- (void)keyDown:(NSEvent *)event
{
    NSString *s = [event charactersIgnoringModifiers];
    if ([s isEqual:@" "] && [self pathStyle] == NSPathStylePopUp) [self _finchPopUp];
    else if ([s isEqual:@"\r"] || [s isEqual:@" "]) [self performClick:self]; else [super keyDown:event];
}
- (NSURL *)_finchURLFromPasteboard:(NSPasteboard *)board
{
    NSString *url = [board stringForType:NSPasteboardTypeFileURL] ?: [board stringForType:NSPasteboardTypeURL];
    if ([url length]) return [NSURL URLWithString:url];
    NSArray *files = [board propertyListForType:NSFilenamesPboardType]; return [files count] ? [NSURL fileURLWithPath:[files firstObject]] : nil;
}
- (BOOL)_finchAcceptsURL:(NSURL *)url
{
    if (!url || ![self isEnabled] || ![self isEditable]) return NO;
    NSArray *types = [self allowedTypes]; if (!types) return YES; if (![types count]) return NO;
    BOOL directory = NO; [[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&directory];
    Class typeClass = NSClassFromString(@"UTType");
    id actual = directory ? [typeClass typeWithIdentifier:@"public.folder"] : [typeClass typeWithFilenameExtension:[url pathExtension]];
    for (NSString *type in types) {
        if ([[url pathExtension] caseInsensitiveCompare:type] == NSOrderedSame) return YES;
        if (directory && ([type isEqual:@"public.folder"] || [type isEqual:@"public.directory"])) return YES;
        id allowed = [typeClass typeWithIdentifier:type]; if (actual && allowed && [actual conformsToType:allowed]) return YES;
    }
    return NO;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    if ([_delegate respondsToSelector:@selector(pathControl:validateDrop:)]) return [_delegate pathControl:self validateDrop:info];
    return [self _finchAcceptsURL:[self _finchURLFromPasteboard:[info draggingPasteboard]]] ? NSDragOperationCopy : NSDragOperationNone;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return [self draggingEntered:info]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info { return [self draggingEntered:info] != NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    if ([_delegate respondsToSelector:@selector(pathControl:acceptDrop:)]) return [_delegate pathControl:self acceptDrop:info];
    NSURL *url = [self _finchURLFromPasteboard:[info draggingPasteboard]]; if (![self _finchAcceptsURL:url]) return NO;
    [self setURL:url]; [self _finchClickComponent:nil doubleClick:NO]; return YES;
}
- (BOOL)isAccessibilityElement { return NO; }
- (NSString *)accessibilityRole { return NSAccessibilityUnknownRole; }
- (NSString *)accessibilitySubrole { return nil; }

/* A bound value shows as the path; anything else (the binding's placeholder for no value,
   which nibs give as a string or attributed string) shows as the placeholder text, as
   Apple's does. */
- (void)_finchShowBoundValue:(id)value kind:(int)kind binding:(id)binding
{
    NSPathCell *cell = (NSPathCell *)[self cell];
    if ([value isKindOfClass:[NSURL class]] || (kind == 0 && [value isKindOfClass:[NSString class]])) {
        [self setObjectValue:value];
        return;
    }
    [cell setURL:nil];
    if ([value isKindOfClass:[NSAttributedString class]])
        [cell setPlaceholderAttributedString:value];
    else if ([value isKindOfClass:[NSString class]])
        [cell setPlaceholderString:value];
    [self setNeedsDisplay:YES];
}
@end
