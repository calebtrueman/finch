/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextStorage (the text system's attributed string: edit tracking,
 * delegate calls and notifications, its layout managers) and
 * NSConcreteTextStorage, the class [NSTextStorage alloc] makes, as Apple's.
 * Apps subclass NSTextStorage and implement the four primitives
 * (-string, -attributesAtIndex:effectiveRange:,
 * -replaceCharactersInRange:withString:, -setAttributes:range:), calling
 * -edited:range:changeInLength: from the mutating two.
 */
#import "UIFoundationInternal.h"

@interface NSConcreteTextStorage : NSTextStorage
@end

@interface NSLayoutManager (UIFTextStorage)
- (void)_uifSetTextStorage:(NSTextStorage *)textStorage;
@end

@interface NSTextStorage () {
    NSMutableArray *_layoutManagers;
    NSTextStorageEditActions _editedMask;
    NSRange _editedRange;
    NSInteger _changeInLength;
    NSInteger _editingDepth;
    __weak id<NSTextStorageDelegate> _delegate;
    __weak id<NSTextStorageObserving> _observer;
    BOOL _processing;
}
@end

@implementation NSTextStorage

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSTextStorage class])
        return [NSConcreteTextStorage allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _layoutManagers = [NSMutableArray new];
        _editedRange = NSMakeRange(NSNotFound, 0);
    }
    return self;
}

- (void)dealloc
{
    for (NSLayoutManager *lm in _layoutManagers)
        [lm _uifSetTextStorage:nil];
    [_layoutManagers release];
    [super dealloc];
}

- (NSArray *)layoutManagers { return [[_layoutManagers copy] autorelease]; }

- (void)addLayoutManager:(NSLayoutManager *)lm
{
    if (!lm || [_layoutManagers indexOfObjectIdenticalTo:lm] != NSNotFound)
        return;
    [lm.textStorage removeLayoutManager:lm];
    [_layoutManagers addObject:lm];
    [lm _uifSetTextStorage:self];
}

- (void)removeLayoutManager:(NSLayoutManager *)lm
{
    NSUInteger i = [_layoutManagers indexOfObjectIdenticalTo:lm];
    if (i == NSNotFound)
        return;
    [[lm retain] autorelease];
    [lm _uifSetTextStorage:nil];
    [_layoutManagers removeObjectAtIndex:i];
}

- (NSTextStorageEditActions)editedMask { return _editedMask; }
- (NSRange)editedRange { return _editedRange; }
- (NSInteger)changeInLength { return _changeInLength; }
- (id<NSTextStorageDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSTextStorageDelegate>)delegate { _delegate = delegate; }
- (id<NSTextStorageObserving>)textStorageObserver { return _observer; }
- (void)setTextStorageObserver:(id<NSTextStorageObserving>)observer { _observer = observer; }
- (BOOL)fixesAttributesLazily { return NO; }
- (void)invalidateAttributesInRange:(NSRange)range { }
- (void)ensureAttributesAreFixedInRange:(NSRange)range { }

- (void)edited:(NSTextStorageEditActions)mask range:(NSRange)range changeInLength:(NSInteger)delta
{
    /* The range in the text as it is after this edit, merged with the
     * earlier edits' (moved by this one's change in length). */
    NSRange now = NSMakeRange(range.location, (NSUInteger)MAX((NSInteger)range.length + delta, 0));
    if (!_editedMask || _editedRange.location == NSNotFound) {
        _editedRange = now;
        _changeInLength = delta;
    } else {
        NSRange old = _editedRange;
        if (NSMaxRange(old) > range.location)
            old.length = (NSUInteger)MAX((NSInteger)old.length + delta, 0);
        _editedRange = NSUnionRange(old, now);
        _changeInLength += delta;
    }
    _editedMask |= mask;
    if (_editingDepth == 0)
        [self processEditing];
}

- (void)beginEditing { _editingDepth++; }

- (void)endEditing
{
    if (_editingDepth > 0 && --_editingDepth == 0 && _editedMask)
        [self processEditing];
}

- (void)processEditing
{
    if (_processing)
        return;
    _processing = YES;
    id<NSTextStorageDelegate> d = _delegate;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if ([d respondsToSelector:@selector(textStorage:willProcessEditing:range:changeInLength:)])
        [d textStorage:self willProcessEditing:_editedMask range:_editedRange changeInLength:_changeInLength];
    [nc postNotificationName:NSTextStorageWillProcessEditingNotification object:self];
    if ([d respondsToSelector:@selector(textStorage:didProcessEditing:range:changeInLength:)])
        [d textStorage:self didProcessEditing:_editedMask range:_editedRange changeInLength:_changeInLength];
    [nc postNotificationName:NSTextStorageDidProcessEditingNotification object:self];
    NSTextStorageEditActions mask = _editedMask;
    NSRange range = _editedRange;
    NSInteger delta = _changeInLength;
    _editedMask = 0;
    _editedRange.location = NSNotFound;
    _changeInLength = 0;
    _processing = NO;
    NSRange invalid = range;
    for (NSLayoutManager *lm in [[_layoutManagers copy] autorelease])
        [lm processEditingForTextStorage:self edited:mask range:range changeInLength:delta invalidatedRange:invalid];
    [_observer processEditingForTextStorage:self edited:mask range:range changeInLength:delta invalidatedRange:invalid];
}

- (Class)classForCoder { return [NSTextStorage class]; }

@end

@implementation NSConcreteTextStorage {
    NSMutableAttributedString *_contents;
}

- (instancetype)init
{
    if ((self = [super init]))
        _contents = [NSMutableAttributedString new];
    return self;
}

- (void)dealloc
{
    [_contents release];
    [super dealloc];
}

- (NSString *)string { return _contents.string; }
- (NSUInteger)length { return _contents.length; }

- (NSDictionary *)attributesAtIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range
{
    return [_contents attributesAtIndex:location effectiveRange:range];
}

- (id)attribute:(NSAttributedStringKey)name atIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range
{
    return [_contents attribute:name atIndex:location effectiveRange:range];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)str
{
    NSUInteger before = _contents.length;
    [_contents replaceCharactersInRange:range withString:str ? str : @""];
    [self edited:NSTextStorageEditedCharacters range:range changeInLength:(NSInteger)_contents.length - (NSInteger)before];
}

- (void)setAttributes:(NSDictionary *)attrs range:(NSRange)range
{
    [_contents setAttributes:attrs range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

@end
