/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSControl_Finch.h"
#import "NSKeyValueBinding_Finch.h"

NSNotificationName NSComboBoxWillPopUpNotification = @"NSComboBoxWillPopUpNotification";
NSNotificationName NSComboBoxWillDismissNotification = @"NSComboBoxWillDismissNotification";
NSNotificationName NSComboBoxSelectionDidChangeNotification = @"NSComboBoxSelectionDidChangeNotification";
NSNotificationName NSComboBoxSelectionIsChangingNotification = @"NSComboBoxSelectionIsChangingNotification";

@interface NSTextField (FinchComboEditing)
- (void)textDidChange:(NSNotification *)note;
- (BOOL)textView:(NSTextView *)view doCommandBySelector:(SEL)selector;
@end
@interface NSComboBoxCell (FinchComboList)
- (id)_finchListValueAtIndex:(NSInteger)i;
@end

@implementation NSComboBox {
    BOOL _deleting, _completing;
    NSUInteger _lastTypedLength;
}
+ (Class)cellClass
{
    Class c = [super cellClass]; return c == [NSTextFieldCell class] ? [NSComboBoxCell class] : c;
}
- (BOOL)hasVerticalScroller { return [[self cell] hasVerticalScroller]; }
- (void)setHasVerticalScroller:(BOOL)b { [[self cell] setHasVerticalScroller:b]; }
- (NSSize)intercellSpacing { return [[self cell] intercellSpacing]; }
- (void)setIntercellSpacing:(NSSize)s { [[self cell] setIntercellSpacing:s]; }
- (CGFloat)itemHeight { return [[self cell] itemHeight]; }
- (void)setItemHeight:(CGFloat)h { [[self cell] setItemHeight:h]; }
- (NSInteger)numberOfVisibleItems { return [[self cell] numberOfVisibleItems]; }
- (void)setNumberOfVisibleItems:(NSInteger)n { [[self cell] setNumberOfVisibleItems:n]; }
- (BOOL)isButtonBordered { return [[self cell] isButtonBordered]; }
- (void)setButtonBordered:(BOOL)b { [[self cell] setButtonBordered:b]; }
- (BOOL)usesDataSource { return [[self cell] usesDataSource]; }
- (void)setUsesDataSource:(BOOL)b { [[self cell] setUsesDataSource:b]; }
- (id)dataSource { return [[self cell] dataSource]; }
- (void)setDataSource:(id)d { [[self cell] setDataSource:d]; }
- (BOOL)completes { return [[self cell] completes]; }
- (void)setCompletes:(BOOL)b { [[self cell] setCompletes:b]; }
- (NSInteger)numberOfItems { return [[self cell] numberOfItems]; }
- (NSInteger)indexOfSelectedItem { return [[self cell] indexOfSelectedItem]; }
- (NSArray *)objectValues { return [[self cell] objectValues]; }
- (id)objectValueOfSelectedItem { return [[self cell] objectValueOfSelectedItem]; }
- (id)itemObjectValueAtIndex:(NSInteger)i { return [[self cell] itemObjectValueAtIndex:i]; }
- (NSInteger)indexOfItemWithObjectValue:(id)o { return [[self cell] indexOfItemWithObjectValue:o]; }
- (void)reloadData { [[self cell] reloadData]; }
- (void)noteNumberOfItemsChanged { [[self cell] noteNumberOfItemsChanged]; }
- (void)scrollItemAtIndexToTop:(NSInteger)i { [[self cell] scrollItemAtIndexToTop:i]; }
- (void)scrollItemAtIndexToVisible:(NSInteger)i { [[self cell] scrollItemAtIndexToVisible:i]; }
- (void)selectItemAtIndex:(NSInteger)i { [[self cell] selectItemAtIndex:i]; }
- (void)deselectItemAtIndex:(NSInteger)i { [[self cell] deselectItemAtIndex:i]; }
- (void)selectItemWithObjectValue:(id)o { [[self cell] selectItemWithObjectValue:o]; }
- (void)addItemWithObjectValue:(id)o { [[self cell] addItemWithObjectValue:o]; }
- (void)addItemsWithObjectValues:(NSArray *)a { [[self cell] addItemsWithObjectValues:a]; }
- (void)insertItemWithObjectValue:(id)o atIndex:(NSInteger)i { [[self cell] insertItemWithObjectValue:o atIndex:i]; }
- (void)removeItemAtIndex:(NSInteger)i { [[self cell] removeItemAtIndex:i]; }
- (void)removeItemWithObjectValue:(id)o { [[self cell] removeItemWithObjectValue:o]; }
- (void)removeAllItems { [[self cell] removeAllItems]; }
- (void)_finchNotify:(NSNotificationName)name selector:(SEL)selector
{
    NSNotification *n = [NSNotification notificationWithName:name object:self];
    id d = [self delegate];
    if ([d respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(d, selector, n);
    [[NSNotificationCenter defaultCenter] postNotification:n];
}
- (void)_finchComboSelectionChanged
{
    [self _finchNotify:NSComboBoxSelectionDidChangeNotification selector:@selector(comboBoxSelectionDidChange:)];
    FinchBindingPush(self, NSSelectedIndexBinding, @([self indexOfSelectedItem]));
    if (FinchBindingFor(self, NSSelectedObjectBinding) || FinchBindingFor(self, NSSelectedValueBinding)) {
        id selected = [self indexOfSelectedItem] < 0 ? nil : [self objectValue];
        FinchBindingPush(self, NSSelectedObjectBinding, selected);
        FinchBindingPush(self, NSSelectedValueBinding, selected);
    }
}
- (void)textDidChange:(NSNotification *)note
{
    if (_completing) return;
    NSTextView *ed = [note object];
    NSUInteger typedLength = [[ed string] length];
    if ([self completes] && !_deleting && typedLength > _lastTypedLength && [ed selectedRange].length == 0) {
        NSString *s = [ed string]; NSUInteger length = [s length];
        if (length && [ed selectedRange].location == length) {
            NSString *completed = [[self cell] completedString:s];
            if ([completed length] > length) {
                _completing = YES; [ed setString:completed];
                [ed setSelectedRange:NSMakeRange(length, [completed length] - length)]; _completing = NO;
            }
        }
    }
    _lastTypedLength = typedLength; _deleting = NO; [super textDidChange:note];
}
- (void)_finchChooseItem:(NSMenuItem *)item
{
    [self selectItemAtIndex:[item tag]]; [self sendAction:[self action] to:[self target]];
}
- (void)_finchPopUp:(NSEvent *)event
{
    [self _finchNotify:NSComboBoxWillPopUpNotification selector:@selector(comboBoxWillPopUp:)];
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    for (NSInteger i = 0; i < [self numberOfItems]; i++) {
        id value = [[self cell] _finchListValueAtIndex:i];
        NSMenuItem *item = [menu addItemWithTitle:[value description] ?: @"" action:@selector(_finchChooseItem:) keyEquivalent:@""];
        [item setTarget:self]; [item setTag:i]; [item setState:i == [self indexOfSelectedItem] ? NSControlStateValueOn : NSControlStateValueOff];
    }
    [menu popUpMenuPositioningItem:[menu itemWithTag:[self indexOfSelectedItem]] atLocation:NSMakePoint(0, NSMaxY([self bounds])) inView:self];
    [self _finchNotify:NSComboBoxWillDismissNotification selector:@selector(comboBoxWillDismiss:)];
}
- (BOOL)textView:(NSTextView *)view doCommandBySelector:(SEL)selector
{
    if ([super textView:view doCommandBySelector:selector]) return YES;
    _deleting = selector == @selector(deleteBackward:) || selector == @selector(deleteForward:) || selector == @selector(delete:);
    if (selector == @selector(moveDown:) || selector == @selector(moveUp:)) {
        NSInteger i = [self indexOfSelectedItem] + (selector == @selector(moveDown:) ? 1 : -1);
        if (i >= 0 && i < [self numberOfItems]) {
            [self selectItemAtIndex:i]; [view setString:[self stringValue]]; [view selectAll:nil];
        }
        return YES;
    }
    return NO;
}
- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled]) return;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    if (p.x >= NSMaxX([self bounds]) - 24 || ![self isEditable]) [self _finchPopUp:event];
    else [super mouseDown:event];
}
+ (NSArray *)_finchBuiltinBindings
{
    return [[super _finchBuiltinBindings] arrayByAddingObjectsFromArray:@[NSContentBinding, NSContentValuesBinding, NSSelectedIndexBinding, NSSelectedObjectBinding, NSSelectedValueBinding]];
}
- (void)_finchBindingChanged:(_FinchBinding *)b
{
    if ([b->_name isEqual:NSContentBinding] || [b->_name isEqual:NSContentValuesBinding]) {
        id a = [b rawValue]; [self setUsesDataSource:NO]; [self removeAllItems];
        if ([a isKindOfClass:[NSArray class]]) [self addItemsWithObjectValues:a];
    } else if ([b->_name isEqual:NSSelectedIndexBinding]) [self selectItemAtIndex:[[b rawValue] integerValue]];
    else if ([b->_name isEqual:NSSelectedObjectBinding] || [b->_name isEqual:NSSelectedValueBinding]) [self selectItemWithObjectValue:[b rawValue]];
    else [super _finchBindingChanged:b];
}
- (BOOL)isAccessibilityElement { return NO; }
- (void)_finchWillSendAction { FinchBindingPush(self, NSValueBinding, [self objectValue]); }
- (NSString *)accessibilityRole { return NSAccessibilityUnknownRole; }
- (NSString *)accessibilitySubrole { return nil; }
@end
