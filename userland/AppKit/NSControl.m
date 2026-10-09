/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSControl: a view that shows a cell, forwards its state and values to it,
 * tracks the mouse through it and sends its action. Without a cell (the
 * NSControl class itself) it keeps a value, target, action and enabled
 * state of its own, as Apple's does. The control's tag is its own, not the
 * cell's. Text editing (NSTextField) goes through the window's field
 * editor; the control is its delegate and turns its notifications into the
 * NSControlTextEditingDelegate ones.
 */
#import "NSControl_Finch.h"
#import "NSKeyValueBinding_Finch.h"

NSNotificationName NSControlTextDidBeginEditingNotification = @"NSControlTextDidBeginEditingNotification";
NSNotificationName NSControlTextDidEndEditingNotification = @"NSControlTextDidEndEditingNotification";
NSNotificationName NSControlTextDidChangeNotification = @"NSControlTextDidChangeNotification";

@implementation NSControl {
    NSCell *_cell;
    NSInteger _tag;
    id _value;  /* without a cell */
    id _target; /* without a cell; weak */
    SEL _action;
    NSText *_editor; /* the field editor while it edits the cell */
    struct {
        unsigned disabled : 1;
        unsigned ignoresMultiClick : 1;
        unsigned refusesFirstResponder : 1;
        unsigned expansionToolTips : 1;
        unsigned editingNotified : 1;
    } _ctl;
}

static NSMapTable *cell_classes;

+ (Class)cellClass
{
    Class c = cell_classes ? [cell_classes objectForKey:self] : nil;
    return c;
}

+ (void)setCellClass:(Class)cls
{
    if (!cell_classes)
        cell_classes = [[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                              valueOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality] retain];
    if (cls)
        [cell_classes setObject:cls forKey:self];
    else
        [cell_classes removeObjectForKey:self];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    Class c = [[self class] cellClass];
    if (c) {
        _cell = [[c alloc] init];
        [_cell setControlView:self];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _tag = [coder decodeIntegerForKey:@"NSTag"];
    id cell = [coder decodeObjectForKey:@"NSCell"];
    if ([cell isKindOfClass:[NSCell class]]) {
        _cell = [cell retain];
        [_cell setControlView:self];
        if ([coder containsValueForKey:@"NSControlSendActionMask"])
            [_cell sendActionOn:(NSEventMask)[coder decodeIntegerForKey:@"NSControlSendActionMask"]];
        /* the cell's flags say whether it's enabled; NSEnabled can only turn it off */
        if ([coder containsValueForKey:@"NSEnabled"] && ![coder decodeBoolForKey:@"NSEnabled"])
            [_cell setEnabled:NO];
    } else {
        _ctl.disabled = [coder containsValueForKey:@"NSEnabled"] && ![coder decodeBoolForKey:@"NSEnabled"];
    }
    if ([coder containsValueForKey:@"NSControlRefusesFirstResponder"] && !_cell)
        _ctl.refusesFirstResponder = [coder decodeBoolForKey:@"NSControlRefusesFirstResponder"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_cell) {
        [coder encodeObject:_cell forKey:@"NSCell"];
        [coder encodeBool:[_cell isEnabled] forKey:@"NSEnabled"];
        [coder encodeInteger:(NSInteger)[_cell _finchActionMask] forKey:@"NSControlSendActionMask"];
    } else {
        [coder encodeBool:!_ctl.disabled forKey:@"NSEnabled"];
    }
    if (_tag)
        [coder encodeInteger:_tag forKey:@"NSTag"];
}

- (void)dealloc
{
    if ([_cell controlView] == self)
        [_cell setControlView:nil];
    [_cell release];
    [_value release];
    [super dealloc];
}

#pragma mark The cell

- (id)cell { return _cell; }

- (void)setCell:(NSCell *)cell
{
    if (cell == _cell)
        return;
    [cell retain];
    if ([_cell controlView] == self)
        [_cell setControlView:nil];
    [_cell release];
    _cell = cell;
    [_cell setControlView:self];
    [self setNeedsDisplay:YES];
}

- (id)selectedCell { return _cell; }
- (NSInteger)selectedTag { return _cell ? [_cell tag] : -1; }
- (void)updateCell:(NSCell *)cell { [self setNeedsDisplay:YES]; }
- (void)updateCellInside:(NSCell *)cell { [self setNeedsDisplay:YES]; }
- (void)drawCell:(NSCell *)cell { [self setNeedsDisplay:YES]; }
- (void)drawCellInside:(NSCell *)cell { [self setNeedsDisplay:YES]; }
- (void)selectCell:(NSCell *)cell {}

#pragma mark State

- (NSInteger)tag { return _tag; }
- (void)setTag:(NSInteger)tag { _tag = tag; }
- (id)target { return _cell ? [_cell target] : _target; }

- (void)setTarget:(id)target
{
    if (_cell)
        [_cell setTarget:target];
    else
        _target = target;
}

- (SEL)action { return _cell ? [_cell action] : _action; }

- (void)setAction:(SEL)action
{
    if (_cell)
        [_cell setAction:action];
    else
        _action = action;
}

- (BOOL)ignoresMultiClick { return _ctl.ignoresMultiClick; }
- (void)setIgnoresMultiClick:(BOOL)flag { _ctl.ignoresMultiClick = flag; }
- (BOOL)isContinuous { return [_cell isContinuous]; }
- (void)setContinuous:(BOOL)flag { [_cell setContinuous:flag]; }
- (BOOL)isEnabled { return _cell ? [_cell isEnabled] : !_ctl.disabled; }

- (void)setEnabled:(BOOL)flag
{
    if (!flag)
        [self abortEditing];
    if (_cell)
        [_cell setEnabled:flag];
    else
        _ctl.disabled = !flag;
    [self setNeedsDisplay:YES];
}

- (BOOL)refusesFirstResponder { return _cell ? [_cell refusesFirstResponder] : _ctl.refusesFirstResponder; }

- (void)setRefusesFirstResponder:(BOOL)flag
{
    if (_cell)
        [_cell setRefusesFirstResponder:flag];
    else
        _ctl.refusesFirstResponder = flag;
}

- (BOOL)acceptsFirstResponder
{
    return _cell ? [_cell acceptsFirstResponder] : (!_ctl.disabled && !_ctl.refusesFirstResponder);
}

- (BOOL)needsPanelToBecomeKey { return [self acceptsFirstResponder]; }
- (BOOL)isHighlighted { return [_cell isHighlighted]; }
- (void)setHighlighted:(BOOL)flag { [_cell setHighlighted:flag]; }
- (NSControlSize)controlSize { return [_cell controlSize]; }
- (void)setControlSize:(NSControlSize)size { [_cell setControlSize:size]; }
- (NSFormatter *)formatter { return [_cell formatter]; }
- (void)setFormatter:(NSFormatter *)formatter { [_cell setFormatter:formatter]; }
- (NSFont *)font { return [_cell font]; }

- (void)setFont:(NSFont *)font
{
    if (_editor)
        [_editor setFont:font];
    [_cell setFont:font];
}

- (BOOL)usesSingleLineMode { return [_cell usesSingleLineMode]; }
- (void)setUsesSingleLineMode:(BOOL)flag { [_cell setUsesSingleLineMode:flag]; }
- (NSLineBreakMode)lineBreakMode { return [_cell lineBreakMode]; }
- (void)setLineBreakMode:(NSLineBreakMode)mode { [_cell setLineBreakMode:mode]; }
- (NSTextAlignment)alignment { return [_cell alignment]; }

- (void)setAlignment:(NSTextAlignment)alignment
{
    if (_editor)
        [_editor setAlignment:alignment];
    [_cell setAlignment:alignment];
}

- (NSWritingDirection)baseWritingDirection { return _cell ? [_cell baseWritingDirection] : NSWritingDirectionNatural; }
- (void)setBaseWritingDirection:(NSWritingDirection)d { [_cell setBaseWritingDirection:d]; }
- (BOOL)allowsExpansionToolTips { return _ctl.expansionToolTips; }
- (void)setAllowsExpansionToolTips:(BOOL)flag { _ctl.expansionToolTips = flag; }
- (NSRect)expansionFrameWithFrame:(NSRect)frame { return NSZeroRect; }
- (void)drawWithExpansionFrame:(NSRect)frame inView:(NSView *)view { [_cell drawWithExpansionFrame:frame inView:view]; }

#pragma mark Values

/* Setting a value ends any editing first, as Apple's does. */
#define VALUE_SETTER(sel, type, cellsel, box)                                                                          \
    -(void)sel(type)v                                                                                                  \
    {                                                                                                                  \
        [self abortEditing];                                                                                           \
        if (_cell)                                                                                                     \
            [_cell cellsel v];                                                                                         \
        else {                                                                                                         \
            id nv = box;                                                                                               \
            [_value release];                                                                                          \
            _value = [nv copy];                                                                                        \
        }                                                                                                              \
        [self setNeedsDisplay:YES];                                                                                    \
    }

VALUE_SETTER(setObjectValue:, id, setObjectValue:, v)
VALUE_SETTER(setIntValue:, int, setIntValue:, @(v))
VALUE_SETTER(setIntegerValue:, NSInteger, setIntegerValue:, @(v))
VALUE_SETTER(setFloatValue:, float, setFloatValue:, @(v))
VALUE_SETTER(setDoubleValue:, double, setDoubleValue:, @(v))
VALUE_SETTER(setAttributedStringValue:, NSAttributedString *, setAttributedStringValue:, v)

- (void)setStringValue:(NSString *)string
{
    [self abortEditing];
    if (_cell)
        [_cell setStringValue:string];
    else {
        [_value release];
        _value = [string copy];
    }
    [self setNeedsDisplay:YES];
}

/* Reading a value takes in what the field editor has so far. */
- (id)objectValue
{
    [self validateEditing];
    return _cell ? [_cell objectValue] : _value;
}

- (NSString *)stringValue
{
    [self validateEditing];
    if (_cell)
        return [_cell stringValue];
    if ([_value isKindOfClass:[NSString class]])
        return _value;
    if ([_value isKindOfClass:[NSAttributedString class]])
        return [_value string];
    return _value ? [_value description] : @"";
}

- (NSAttributedString *)attributedStringValue
{
    [self validateEditing];
    if (_cell)
        return [_cell attributedStringValue];
    if ([_value isKindOfClass:[NSAttributedString class]])
        return _value;
    return [[[NSAttributedString alloc] initWithString:[self stringValue]] autorelease];
}

- (int)intValue { [self validateEditing]; return _cell ? [_cell intValue] : [[self stringValue] intValue]; }
- (NSInteger)integerValue { [self validateEditing]; return _cell ? [_cell integerValue] : [[self stringValue] integerValue]; }
- (float)floatValue { [self validateEditing]; return _cell ? [_cell floatValue] : [[self stringValue] floatValue]; }
- (double)doubleValue { [self validateEditing]; return _cell ? [_cell doubleValue] : [[self stringValue] doubleValue]; }
- (void)takeIntValueFrom:(id)sender { [self setIntValue:[sender intValue]]; }
- (void)takeIntegerValueFrom:(id)sender { [self setIntegerValue:[sender integerValue]]; }
- (void)takeFloatValueFrom:(id)sender { [self setFloatValue:[sender floatValue]]; }
- (void)takeDoubleValueFrom:(id)sender { [self setDoubleValue:[sender doubleValue]]; }
- (void)takeStringValueFrom:(id)sender { [self setStringValue:[sender stringValue] ?: @""]; }
- (void)takeObjectValueFrom:(id)sender { [self setObjectValue:[sender objectValue]]; }

#pragma mark Size

- (NSSize)sizeThatFits:(NSSize)size
{
    if (!_cell)
        return [self frame].size;
    return [_cell cellSizeForBounds:NSMakeRect(0, 0, size.width, size.height)];
}

- (void)sizeToFit
{
    if (_cell)
        [self setFrameSize:[_cell cellSize]];
}

- (NSSize)intrinsicContentSize
{
    return _cell ? [_cell cellSize] : NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize
{
    [super resizeWithOldSuperviewSize:oldSize];
}

#pragma mark Actions

- (NSInteger)sendActionOn:(NSEventMask)mask
{
    return _cell ? [_cell sendActionOn:mask] : 0;
}

- (BOOL)sendAction:(SEL)action to:(id)target
{
    /* Bindings take the control's value first, with or without an action (NSKeyValueBinding.m). */
    FinchBindingsControlWillSendAction(self);
    if (!action)
        return NO;
    return [NSApp sendAction:action to:target from:self];
}

- (void)performClick:(id)sender
{
    if (![self isEnabled])
        return;
    NSCell *cell = _cell;
    if (cell) {
        [cell setHighlighted:YES];
        if ([cell _finchClickChangesState])
            [cell setNextState];
        [cell setHighlighted:NO];
    }
    [self sendAction:[self action] to:[self target]];
}

#pragma mark Events and drawing

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return NO; }
- (BOOL)_finchBecomesFirstResponderOnClick { return NO; }

- (void)mouseDown:(NSEvent *)event
{
    NSCell *cell = _cell;
    if (!cell || ![self isEnabled])
        return;
    if (_ctl.ignoresMultiClick && [event clickCount] > 1) {
        [super mouseDown:event];
        return;
    }
    NSRect bounds = [self bounds];
    BOOL untilUp = [[cell class] prefersTrackingUntilMouseUp];
    NSEvent *e = event;
    for (;;) {
        NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
        if (NSMouseInRect(p, bounds, [self isFlipped])) {
            [cell setHighlighted:YES];
            [self setNeedsDisplay:YES];
            [[self window] displayIfNeeded];
            BOOL up = [cell trackMouse:e inRect:bounds ofView:self untilMouseUp:untilUp];
            [cell setHighlighted:NO];
            [self setNeedsDisplay:YES];
            if (up)
                break;
        }
        e = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        if (!e || [e type] == NSEventTypeLeftMouseUp)
            break;
    }
}

- (void)drawRect:(NSRect)dirty
{
    [_cell drawWithFrame:[self bounds] inView:self];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    return [super performKeyEquivalent:event];
}

- (void)resetCursorRects
{
    [_cell resetCursorRect:[self bounds] inView:self];
}

#pragma mark Editing

- (NSText *)currentEditor
{
    return _editor && [_editor delegate] == (id)self ? _editor : nil;
}

- (id)_finchEditingDelegate
{
    return [self respondsToSelector:@selector(delegate)] ? [(id)self delegate] : nil;
}

/* Copy what the field editor holds into the cell. */
- (void)validateEditing
{
    NSText *ed = [self currentEditor];
    if (!ed || !_cell)
        return;
    if ([_cell allowsEditingTextAttributes] && [ed respondsToSelector:@selector(textStorage)]) {
        NSAttributedString *a = [[[(NSTextView *)ed textStorage] copy] autorelease];
        if ([_cell formatter])
            [_cell setStringValue:[a string]];
        else
            [_cell setAttributedStringValue:a];
    } else {
        [_cell setStringValue:[[[ed string] copy] autorelease] ?: @""];
    }
}

- (void)_finchStopEditor
{
    NSText *ed = _editor;
    if (!ed)
        return;
    _editor = nil;
    _ctl.editingNotified = NO;
    NSWindow *w = [self window];
    BOOL wasFirst = [w firstResponder] == (NSResponder *)ed;
    [_cell endEditing:ed];
    /* The window again, without asking the editor to resign (it may be resigning now). */
    if (wasFirst)
        [w _finchResetFirstResponder];
    [self setNeedsDisplay:YES];
}

- (BOOL)abortEditing
{
    if (!_editor)
        return NO;
    /* the field editor went on to another control without telling this one: not ours to stop */
    if ([_editor delegate] != (id)self) {
        _editor = nil;
        _ctl.editingNotified = NO;
        return NO;
    }
    [self _finchStopEditor];
    return YES;
}

- (void)_finchBeganEditor:(NSText *)editor
{
    _editor = editor;
    _ctl.editingNotified = NO;
}

- (void)editWithFrame:(NSRect)rect editor:(NSText *)editor delegate:(id)delegate event:(NSEvent *)event
{
    if (!editor)
        return;
    [self _finchBeganEditor:editor];
    [_cell editWithFrame:rect inView:self editor:editor delegate:delegate event:event];
}

- (void)selectWithFrame:(NSRect)rect editor:(NSText *)editor delegate:(id)delegate start:(NSInteger)start
                 length:(NSInteger)length
{
    if (!editor)
        return;
    [self _finchBeganEditor:editor];
    [_cell selectWithFrame:rect inView:self editor:editor delegate:delegate start:start length:length];
}

- (void)endEditing:(NSText *)editor
{
    if (editor == _editor)
        [self _finchStopEditor];
    else
        [_cell endEditing:editor];
}

/* The field editor's delegate methods (NSTextDelegate). */
- (BOOL)textShouldBeginEditing:(NSText *)text
{
    id d = [self _finchEditingDelegate];
    if ([d respondsToSelector:@selector(control:textShouldBeginEditing:)])
        return [d control:self textShouldBeginEditing:text];
    return YES;
}

- (void)_finchPost:(NSNotificationName)name selector:(SEL)sel editor:(NSText *)text
{
    NSNotification *n = [NSNotification notificationWithName:name object:self
                                                    userInfo:text ? @{@"NSFieldEditor" : text} : nil];
    id d = [self _finchEditingDelegate];
    if ([d respondsToSelector:sel])
        ((void (*)(id, SEL, id))objc_msgSend)(d, sel, n);
    [[NSNotificationCenter defaultCenter] postNotification:n];
}

- (void)textDidBeginEditing:(NSNotification *)note
{
    if (_ctl.editingNotified)
        return;
    _ctl.editingNotified = YES;
    [self _finchPost:NSControlTextDidBeginEditingNotification selector:@selector(controlTextDidBeginEditing:)
              editor:[note object]];
    FinchBindingsControlEdited(self, FinchEditBegan);
}

- (void)textDidChange:(NSNotification *)note
{
    if (!_ctl.editingNotified)
        [self textDidBeginEditing:note];
    [self _finchPost:NSControlTextDidChangeNotification selector:@selector(controlTextDidChange:) editor:[note object]];
    FinchBindingsControlEdited(self, FinchEditChanged);
}

- (BOOL)textShouldEndEditing:(NSText *)text
{
    NSFormatter *f = [_cell formatter];
    id d = [self _finchEditingDelegate];
    if (f) {
        id obj = nil;
        NSString *err = nil;
        if (![f getObjectValue:&obj forString:[text string] ?: @"" errorDescription:&err]) {
            if ([d respondsToSelector:@selector(control:didFailToFormatString:errorDescription:)])
                return [d control:self didFailToFormatString:[text string] errorDescription:err];
            return NO;
        }
        if ([d respondsToSelector:@selector(control:isValidObject:)] && ![d control:self isValidObject:obj])
            return NO;
    }
    if ([d respondsToSelector:@selector(control:textShouldEndEditing:)])
        return [d control:self textShouldEndEditing:text];
    return YES;
}

- (void)textDidEndEditing:(NSNotification *)note
{
    [self _finchTextDidEndEditing:note];
}

- (void)_finchTextDidEndEditing:(NSNotification *)note
{
    NSText *ed = [note object] ?: _editor;
    if (ed != _editor)
        return;
    [self validateEditing];
    FinchBindingsControlEdited(self, FinchEditEnded);
    BOOL notified = _ctl.editingNotified;
    [self _finchStopEditor];
    NSInteger movement = [[[note userInfo] objectForKey:@"NSTextMovement"] integerValue];
    if (notified || movement == NSTextMovementReturn)
        [self _finchPost:NSControlTextDidEndEditingNotification selector:@selector(controlTextDidEndEditing:)
                  editor:ed];
    if (movement == NSTextMovementReturn || [_cell sendsActionOnEndEditing])
        [self sendAction:[self action] to:[self target]];
    NSWindow *w = [self window];
    if (movement == NSTextMovementTab)
        [w selectKeyViewFollowingView:self];
    else if (movement == NSTextMovementBacktab)
        [w selectKeyViewPrecedingView:self];
    else if (movement == NSTextMovementReturn && [w firstResponder] == w && [self respondsToSelector:@selector(selectText:)])
        [(id)self selectText:self];
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)sel
{
    id d = [self _finchEditingDelegate];
    if ([d respondsToSelector:@selector(control:textView:doCommandBySelector:)])
        return [d control:self textView:textView doCommandBySelector:sel];
    return NO;
}

- (NSArray *)textView:(NSTextView *)textView completions:(NSArray *)words forPartialWordRange:(NSRange)range
  indexOfSelectedItem:(NSInteger *)index
{
    id d = [self _finchEditingDelegate];
    if ([d respondsToSelector:@selector(control:textView:completions:forPartialWordRange:indexOfSelectedItem:)])
        return [d control:self textView:textView completions:words forPartialWordRange:range indexOfSelectedItem:index];
    return words;
}

- (void)viewWillMoveToWindow:(NSWindow *)window
{
    if (window != [self window])
        [self abortEditing];
    [super viewWillMoveToWindow:window];
}

@end
