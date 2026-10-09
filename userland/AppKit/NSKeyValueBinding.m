/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Cocoa bindings (NSKeyValueBinding.h): -bind:toObject:withKeyPath:options:
 * and the rest of NSObject's binding API, the selection markers and their
 * placeholders, and what the standard views and controls do with their
 * bindings.
 *
 * A binding is a _FinchBinding: it observes the bound object's key path with
 * KVO and, when it changes, gives the receiver the new value (transformed,
 * markers and nil replaced by placeholders). Where the receiver's value
 * comes from the user (a control's value, a pop-up's selection, a text
 * view's text), the binding pushes it back through the key path: controls
 * before they send their action (NSControl's -sendAction:to: calls
 * FinchBindingsControlWillSendAction, even without an action), text fields
 * when editing ends (or as the text changes, with
 * NSContinuouslyUpdatesValueBindingOption), text views on their text
 * notifications. A binding being edited registers with the bound object as
 * an NSEditor (-objectDidBeginEditing:), as Apple's binders do, so a
 * controller can commit or discard the edit.
 *
 * As measured on macOS 26 (see appkit-bindings-test.m): NSObject's own
 * bindings are one-way and fall back to key-value coding (binding a key the
 * receiver lacks raises NSUnknownKeyException); infoForBinding:'s options
 * hold every option the binding understands, NSNull where unset; text
 * fields show placeholders as their placeholder string and turn
 * non-editable without a selection (NSConditionallySetsEditable);
 * checkboxes show multiple values as the mixed state; "enabled2"... are
 * ANDed with "enabled", "hidden2"... ORed with "hidden"; NSTextView has
 * attributedString but no value binding; pop-up buttons build their items
 * from content/contentValues/contentObjects and add an item for a selected
 * object or value they don't have.
 */
#import "NSControl_Finch.h"
#import "NSKeyValueBinding_Finch.h"

#pragma mark - Names

NSBindingInfoKey NSObservedObjectKey = @"NSObservedObject";
NSBindingInfoKey NSObservedKeyPathKey = @"NSObservedKeyPath";
NSBindingInfoKey NSOptionsKey = @"NSOptions";

NSBindingName NSAlignmentBinding = @"alignment";
NSBindingName NSAlternateImageBinding = @"alternateImage";
NSBindingName NSAlternateTitleBinding = @"alternateTitle";
NSBindingName NSAnimateBinding = @"animate";
NSBindingName NSAnimationDelayBinding = @"animationDelay";
NSBindingName NSArgumentBinding = @"argument";
NSBindingName NSAttributedStringBinding = @"attributedString";
NSBindingName NSContentArrayBinding = @"contentArray";
NSBindingName NSContentArrayForMultipleSelectionBinding = @"contentArrayForMultipleSelection";
NSBindingName NSContentBinding = @"content";
NSBindingName NSContentDictionaryBinding = @"contentDictionary";
NSBindingName NSContentHeightBinding = @"contentHeight";
NSBindingName NSContentObjectBinding = @"contentObject";
NSBindingName NSContentObjectsBinding = @"contentObjects";
NSBindingName NSContentSetBinding = @"contentSet";
NSBindingName NSContentValuesBinding = @"contentValues";
NSBindingName NSContentWidthBinding = @"contentWidth";
NSBindingName NSCriticalValueBinding = @"criticalValue";
NSBindingName NSDataBinding = @"data";
NSBindingName NSDisplayPatternTitleBinding = @"displayPatternTitle";
NSBindingName NSDisplayPatternValueBinding = @"displayPatternValue";
NSBindingName NSDocumentEditedBinding = @"documentEdited";
NSBindingName NSDoubleClickArgumentBinding = @"doubleClickArgument";
NSBindingName NSDoubleClickTargetBinding = @"doubleClickTarget";
NSBindingName NSEditableBinding = @"editable";
NSBindingName NSEnabledBinding = @"enabled";
NSBindingName NSExcludedKeysBinding = @"excludedKeys";
NSBindingName NSFilterPredicateBinding = @"filterPredicate";
NSBindingName NSFontBinding = @"font";
NSBindingName NSFontBoldBinding = @"fontBold";
NSBindingName NSFontFamilyNameBinding = @"fontFamilyName";
NSBindingName NSFontItalicBinding = @"fontItalic";
NSBindingName NSFontNameBinding = @"fontName";
NSBindingName NSFontSizeBinding = @"fontSize";
NSBindingName NSHeaderTitleBinding = @"headerTitle";
NSBindingName NSHiddenBinding = @"hidden";
NSBindingName NSImageBinding = @"image";
NSBindingName NSIncludedKeysBinding = @"includedKeys";
NSBindingName NSInitialKeyBinding = @"initialKey";
NSBindingName NSInitialValueBinding = @"initialValue";
NSBindingName NSIsIndeterminateBinding = @"isIndeterminate";
NSBindingName NSLabelBinding = @"label";
NSBindingName NSLocalizedKeyDictionaryBinding = @"localizedKeyDictionary";
NSBindingName NSManagedObjectContextBinding = @"managedObjectContext";
NSBindingName NSMaximumRecentsBinding = @"maximumRecents";
NSBindingName NSMaxValueBinding = @"maxValue";
NSBindingName NSMaxWidthBinding = @"maxWidth";
NSBindingName NSMinValueBinding = @"minValue";
NSBindingName NSMinWidthBinding = @"minWidth";
NSBindingName NSMixedStateImageBinding = @"mixedStateImage";
NSBindingName NSOffStateImageBinding = @"offStateImage";
NSBindingName NSOnStateImageBinding = @"onStateImage";
NSBindingName NSPositioningRectBinding = @"positioningRect";
NSBindingName NSPredicateBinding = @"predicate";
NSBindingName NSRecentSearchesBinding = @"recentSearches";
NSBindingName NSRepresentedFilenameBinding = @"representedFilename";
NSBindingName NSRowHeightBinding = @"rowHeight";
NSBindingName NSSelectedIdentifierBinding = @"selectedIdentifier";
NSBindingName NSSelectedIndexBinding = @"selectedIndex";
NSBindingName NSSelectedLabelBinding = @"selectedLabel";
NSBindingName NSSelectedObjectBinding = @"selectedObject";
NSBindingName NSSelectedObjectsBinding = @"selectedObjects";
NSBindingName NSSelectedTagBinding = @"selectedTag";
NSBindingName NSSelectedValueBinding = @"selectedValue";
NSBindingName NSSelectedValuesBinding = @"selectedValues";
NSBindingName NSSelectionIndexesBinding = @"selectionIndexes";
NSBindingName NSSelectionIndexPathsBinding = @"selectionIndexPaths";
NSBindingName NSSortDescriptorsBinding = @"sortDescriptors";
NSBindingName NSTargetBinding = @"target";
NSBindingName NSTextColorBinding = @"textColor";
NSBindingName NSTitleBinding = @"title";
NSBindingName NSToolTipBinding = @"toolTip";
NSBindingName NSTransparentBinding = @"transparent";
NSBindingName NSValueBinding = @"value";
NSBindingName NSValuePathBinding = @"valuePath";
NSBindingName NSValueURLBinding = @"valueURL";
NSBindingName NSVisibleBinding = @"visible";
NSBindingName NSWarningValueBinding = @"warningValue";
NSBindingName NSWidthBinding = @"width";

NSBindingOption NSAllowsEditingMultipleValuesSelectionBindingOption = @"NSAllowsEditingMultipleValuesSelection";
NSBindingOption NSAllowsNullArgumentBindingOption = @"NSAllowsNullArgument";
NSBindingOption NSAlwaysPresentsApplicationModalAlertsBindingOption = @"NSAlwaysPresentsApplicationModalAlerts";
NSBindingOption NSConditionallySetsEditableBindingOption = @"NSConditionallySetsEditable";
NSBindingOption NSConditionallySetsEnabledBindingOption = @"NSConditionallySetsEnabled";
NSBindingOption NSConditionallySetsHiddenBindingOption = @"NSConditionallySetsHidden";
NSBindingOption NSContinuouslyUpdatesValueBindingOption = @"NSContinuouslyUpdatesValue";
NSBindingOption NSCreatesSortDescriptorBindingOption = @"NSCreatesSortDescriptor";
NSBindingOption NSDeletesObjectsOnRemoveBindingsOption = @"NSDeletesObjectsOnRemove";
NSBindingOption NSDisplayNameBindingOption = @"NSDisplayName";
NSBindingOption NSDisplayPatternBindingOption = @"NSDisplayPattern";
NSBindingOption NSContentPlacementTagBindingOption = @"NSContentPlacementTag";
NSBindingOption NSHandlesContentAsCompoundValueBindingOption = @"NSHandlesContentAsCompoundValue";
NSBindingOption NSInsertsNullPlaceholderBindingOption = @"NSInsertsNullPlaceholder";
NSBindingOption NSInvokesSeparatelyWithArrayObjectsBindingOption = @"NSInvokesSeparatelyWithArrayObjects";
NSBindingOption NSMultipleValuesPlaceholderBindingOption = @"NSMultipleValuesPlaceholder";
NSBindingOption NSNoSelectionPlaceholderBindingOption = @"NSNoSelectionPlaceholder";
NSBindingOption NSNotApplicablePlaceholderBindingOption = @"NSNotApplicablePlaceholder";
NSBindingOption NSNullPlaceholderBindingOption = @"NSNullPlaceholder";
NSBindingOption NSRaisesForNotApplicableKeysBindingOption = @"NSRaisesForNotApplicableKeys";
NSBindingOption NSPredicateFormatBindingOption = @"NSPredicateFormat";
NSBindingOption NSSelectorNameBindingOption = @"NSSelectorName";
NSBindingOption NSSelectsAllWhenSettingContentBindingOption = @"NSSelectsAllWhenSettingContent";
NSBindingOption NSValidatesImmediatelyBindingOption = @"NSValidatesImmediately";
NSBindingOption NSValueTransformerNameBindingOption = @"NSValueTransformerName";
NSBindingOption NSValueTransformerBindingOption = @"NSValueTransformer";

#pragma mark - Markers


@interface NSBindingSelectionMarker (Finch)
- (instancetype)_finchInit;
@end

/* Apple's markers are instances of a private NSBindingSelectionMarker subclass. */
@interface _NSStateMarker : NSBindingSelectionMarker {
    NSString *_description;
}
- (instancetype)_finchInitWithDescription:(NSString *)description;
@end

/* The deprecated globals are the same objects. */
id NSMultipleValuesMarker, NSNoSelectionMarker, NSNotApplicableMarker;

static _NSStateMarker *multipleMarker, *noSelectionMarker, *notApplicableMarker;
static void make_markers(void);

@implementation NSBindingSelectionMarker

- (instancetype)init
{
    [self release];
    return nil;
}

- (instancetype)_finchInit { return [super init]; }

/* The deprecated globals are set when the class loads. */
+ (void)load
{
    make_markers();
    NSMultipleValuesMarker = multipleMarker;
    NSNoSelectionMarker = noSelectionMarker;
    NSNotApplicableMarker = notApplicableMarker;
}
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

static void
make_markers(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        multipleMarker = [[_NSStateMarker alloc] _finchInitWithDescription:@"<MULTIPLE VALUES MARKER>"];
        noSelectionMarker = [[_NSStateMarker alloc] _finchInitWithDescription:@"<NO SELECTION MARKER>"];
        notApplicableMarker = [[_NSStateMarker alloc] _finchInitWithDescription:@"<NOT APPLICABLE MARKER>"];
    });
}

+ (NSBindingSelectionMarker *)multipleValuesSelectionMarker { make_markers(); return multipleMarker; }
+ (NSBindingSelectionMarker *)noSelectionMarker { make_markers(); return noSelectionMarker; }
+ (NSBindingSelectionMarker *)notApplicableSelectionMarker { make_markers(); return notApplicableMarker; }

+ (void)setDefaultPlaceholder:(id)placeholder forMarker:(NSBindingSelectionMarker *)marker onClass:(Class)objectClass
                  withBinding:(NSBindingName)binding
{
    [objectClass setDefaultPlaceholder:placeholder forMarker:marker withBinding:binding];
}

+ (id)defaultPlaceholderForMarker:(NSBindingSelectionMarker *)marker onClass:(Class)objectClass withBinding:(NSBindingName)binding
{
    return [objectClass defaultPlaceholderForMarker:marker withBinding:binding];
}

@end

@implementation _NSStateMarker

- (instancetype)_finchInitWithDescription:(NSString *)d
{
    self = [super _finchInit];
    _description = [d copy];
    return self;
}

- (NSString *)description { return _description; }
- (oneway void)release {}
- (instancetype)retain { return self; }
- (instancetype)autorelease { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }

@end



BOOL
NSIsControllerMarker(id object)
{
    make_markers();
    return object && (object == multipleMarker || object == noSelectionMarker || object == notApplicableMarker);
}

#pragma mark - Placeholders

enum { MK_NONE, MK_NULL, MK_MULTIPLE, MK_NOSELECTION, MK_NOTAPPLICABLE };

static int
marker_kind(id v)
{
    make_markers();
    if (v == multipleMarker)
        return MK_MULTIPLE;
    if (v == noSelectionMarker)
        return MK_NOSELECTION;
    if (v == notApplicableMarker)
        return MK_NOTAPPLICABLE;
    if (!v || v == [NSNull null])
        return MK_NULL;
    return MK_NONE;
}

static NSString *
placeholder_option(int kind)
{
    switch (kind) {
    case MK_MULTIPLE: return NSMultipleValuesPlaceholderBindingOption;
    case MK_NOSELECTION: return NSNoSelectionPlaceholderBindingOption;
    case MK_NOTAPPLICABLE: return NSNotApplicablePlaceholderBindingOption;
    default: return NSNullPlaceholderBindingOption;
    }
}

/* +setDefaultPlaceholder:forMarker:withBinding:, by class, binding and option name. */
static NSMutableDictionary *user_placeholders;

static NSString *
placeholder_key(Class c, NSString *binding, id marker)
{
    return [NSString stringWithFormat:@"%s\n%@\n%@", class_getName(c), binding, placeholder_option(marker_kind(marker))];
}

/* What Apple's controls use when nothing is set (text values show these words). */
static id
builtin_placeholder(Class c, NSString *binding, int kind)
{
    BOOL textual = ([c isSubclassOfClass:[NSTextField class]] && [binding isEqualToString:NSValueBinding]) ||
                   ([c isSubclassOfClass:[NSPopUpButton class]] && [binding isEqualToString:NSSelectedValueBinding]);
    if (textual) {
        switch (kind) {
        case MK_MULTIPLE: return @"Multiple Values";
        case MK_NOSELECTION: return @"No Selection";
        case MK_NOTAPPLICABLE: return @"Not Applicable";
        default: return nil;
        }
    }
    if ([c isSubclassOfClass:[NSPopUpButton class]] &&
        ([binding isEqualToString:NSContentBinding] || [binding isEqualToString:NSContentValuesBinding]) && kind == MK_NULL)
        return @"No Value";
    return nil;
}

static id
default_placeholder(Class c, NSString *binding, int kind)
{
    @synchronized([NSBindingSelectionMarker class]) {
        for (Class k = c; k; k = class_getSuperclass(k)) {
            id m = kind == MK_MULTIPLE ? multipleMarker : kind == MK_NOSELECTION ? noSelectionMarker
                                                       : kind == MK_NOTAPPLICABLE ? notApplicableMarker : nil;
            id v = [user_placeholders objectForKey:placeholder_key(k, binding, m)];
            if (v)
                return v == [NSNull null] ? nil : [[v retain] autorelease];
        }
    }
    return builtin_placeholder(c, binding, kind);
}

@implementation NSObject (NSPlaceholders)

+ (void)setDefaultPlaceholder:(id)placeholder forMarker:(id)marker withBinding:(NSBindingName)binding
{
    make_markers();
    @synchronized([NSBindingSelectionMarker class]) {
        if (!user_placeholders)
            user_placeholders = [[NSMutableDictionary alloc] init];
        NSString *k = placeholder_key(self, binding, marker);
        /* nil goes back to the built-in default, unless a superclass has one */
        if (placeholder)
            [user_placeholders setObject:placeholder forKey:k];
        else
            [user_placeholders removeObjectForKey:k];
    }
}

+ (id)defaultPlaceholderForMarker:(id)marker withBinding:(NSBindingName)binding
{
    make_markers();
    return default_placeholder(self, binding, marker_kind(marker));
}

@end

#pragma mark - The binding object

static char bindingsKey, conditionalKey;
static int observeContext;

static BOOL
truthy(id v)
{
    if (!v || v == [NSNull null] || NSIsControllerMarker(v))
        return NO;
    if ([v respondsToSelector:@selector(boolValue)])
        return [v boolValue];
    return YES;
}

static BOOL
option_bool(NSDictionary *options, NSString *key)
{
    id v = [options objectForKey:key];
    return v && v != [NSNull null] && [v boolValue];
}


/* Owners keep their bindings here; when the owner goes, so do they. */
@interface _FinchBindingSet : NSObject {
@public
    NSMutableDictionary *_bindings;
    NSMutableArray *_order; /* names, in the order they were bound */
}
@end

@implementation _FinchBindingSet

- (instancetype)init
{
    self = [super init];
    _bindings = [[NSMutableDictionary alloc] init];
    _order = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc
{
    for (_FinchBinding *b in [_bindings allValues]) {
        b->_owner = nil;
        [b _finchDisconnect];
    }
    [_bindings release];
    [_order release];
    [super dealloc];
}

@end

static _FinchBindingSet *
binding_set(id owner, BOOL create)
{
    _FinchBindingSet *s = objc_getAssociatedObject(owner, &bindingsKey);
    if (!s && create) {
        s = [[_FinchBindingSet alloc] init];
        objc_setAssociatedObject(owner, &bindingsKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [s release];
    }
    return s;
}

id
FinchBindingFor(id object, NSString *binding)
{
    if (!object || !binding)
        return nil;
    _FinchBindingSet *s = binding_set(object, NO);
    return s ? [s->_bindings objectForKey:binding] : nil;
}

/* The names bound on an object that start with `base` ("enabled", "enabled2", ...). */
static NSArray *
numbered_bindings(id owner, NSString *base)
{
    _FinchBindingSet *s = binding_set(owner, NO);
    NSMutableArray *out = [NSMutableArray array];
    if (!s)
        return out;
    if ([s->_bindings objectForKey:base])
        [out addObject:[s->_bindings objectForKey:base]];
    for (NSInteger i = 2;; i++) {
        _FinchBinding *b = [s->_bindings objectForKey:[NSString stringWithFormat:@"%@%ld", base, (long)i]];
        if (!b)
            break;
        [out addObject:b];
    }
    return out;
}

static BOOL
is_numbered(NSString *binding, NSString *base)
{
    if (![binding hasPrefix:base] || [binding length] <= [base length])
        return NO;
    NSString *rest = [binding substringFromIndex:[base length]];
    return [rest integerValue] >= 2 && [[NSString stringWithFormat:@"%ld", (long)[rest integerValue]] isEqualToString:rest];
}

@implementation _FinchBinding

- (void)dealloc
{
    [_name release];
    [_observedPath release];
    [_observed release];
    [_keyPath release];
    [_options release];
    [_transformer release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p: %@ -> %@>", [self class], self, _name, _keyPath];
}

- (void)_finchConnect
{
    if (_connected)
        return;
    _connected = YES;
    /* KVO can't go through a collection ("items.name"): observe up to it, as the collection changes */
    NSArray *parts = [_keyPath componentsSeparatedByString:@"."];
    NSString *path = _keyPath;
    Class arrayProxy = NSClassFromString(@"_NSControllerArrayProxy");
    for (NSUInteger i = 1; i < [parts count]; i++) {
        NSString *prefix = [[parts subarrayWithRange:NSMakeRange(0, i)] componentsJoinedByString:@"."];
        if ([[parts objectAtIndex:i] hasPrefix:@"@"]) {
            path = prefix;
            break;
        }
        id v = nil;
        @try {
            v = [_observed valueForKeyPath:prefix];
        } @catch (NSException *e) {
            break;
        }
        if (([v isKindOfClass:[NSArray class]] && ![v isKindOfClass:arrayProxy]) || [v isKindOfClass:[NSSet class]] ||
            [v isKindOfClass:[NSOrderedSet class]]) {
            path = prefix;
            break;
        }
    }
    _observedPath = [path copy];
    [_observed addObserver:self forKeyPath:_observedPath options:0 context:&observeContext];
    if ([_owner isKindOfClass:[NSTextView class]]) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(_finchTextBegan:) name:NSTextDidBeginEditingNotification object:_owner];
        [nc addObserver:self selector:@selector(_finchTextChanged:) name:NSTextDidChangeNotification object:_owner];
        [nc addObserver:self selector:@selector(_finchTextEnded:) name:NSTextDidEndEditingNotification object:_owner];
    }
}

- (void)_finchDisconnect
{
    if (!_connected)
        return;
    _connected = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_editing && [_observed respondsToSelector:@selector(objectDidEndEditing:)])
        [_observed objectDidEndEditing:self];
    _editing = NO;
    @try {
        [_observed removeObserver:self forKeyPath:_observedPath context:&observeContext];
    } @catch (NSException *e) {
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != &observeContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (_pushing || !_owner)
        return;
    [_owner _finchBindingChanged:self];
}

/* The bound value as it is: a marker, nil, or the model's value. */
- (id)rawValue
{
    id v;
    @try {
        v = [_observed valueForKeyPath:_keyPath];
    } @catch (NSException *e) {
        if ([[e name] isEqualToString:NSUndefinedKeyException] &&
            !option_bool(_options, NSRaisesForNotApplicableKeysBindingOption))
            return [NSBindingSelectionMarker notApplicableSelectionMarker];
        @throw;
    }
    return v;
}

/* The value transformed (markers aren't), and which kind of value it is. */
- (id)valueWithKind:(int *)kind
{
    id v = [self rawValue];
    int k = marker_kind(v);
    if (k == MK_NONE || k == MK_NULL) {
        if (_transformer)
            v = [_transformer transformedValue:v == [NSNull null] ? nil : v];
        k = marker_kind(v);
    }
    if (kind)
        *kind = k;
    return k == MK_NULL ? nil : v;
}

/* The value to show: the transformed value, or the placeholder for nil or a marker (nil for NSNull). */
- (id)displayValueWithKind:(int *)kind
{
    int k;
    id v = [self valueWithKind:&k];
    if (kind)
        *kind = k;
    if (k == MK_NONE)
        return v;
    id p = [_options objectForKey:placeholder_option(k)];
    return p == [NSNull null] ? nil : p;
}

- (void)push:(id)value
{
    if (!_observed)
        return;
    if (_transformer) {
        if (![[_transformer class] allowsReverseTransformation])
            return;
        value = [_transformer reverseTransformedValue:value];
    }
    _pushing = YES;
    @try {
        [_observed setValue:value forKeyPath:_keyPath];
    } @finally {
        _pushing = NO;
    }
}

#pragma mark NSEditor

- (void)_finchBeginEditing
{
    if (_editing)
        return;
    _editing = YES;
    if ([_observed respondsToSelector:@selector(objectDidBeginEditing:)])
        [_observed objectDidBeginEditing:self];
}

- (void)_finchEndEditing
{
    if (!_editing)
        return;
    _editing = NO;
    if ([_observed respondsToSelector:@selector(objectDidEndEditing:)])
        [_observed objectDidEndEditing:self];
}

- (BOOL)commitEditing
{
    if (!_editing)
        return YES;
    NSWindow *w = [_owner respondsToSelector:@selector(window)] ? [(NSView *)_owner window] : nil;
    if ([_owner isKindOfClass:[NSControl class]] && [(NSControl *)_owner currentEditor]) {
        if (w && ![w makeFirstResponder:w])
            return NO;
        if ([(NSControl *)_owner currentEditor]) {
            /* not in a window that could take it away: end the edit here */
            [(NSControl *)_owner validateEditing];
            [self push:[(NSControl *)_owner objectValue]];
            [(NSControl *)_owner abortEditing];
        }
    } else if ([_owner isKindOfClass:[NSTextView class]]) {
        if (w && [w firstResponder] == _owner && ![w makeFirstResponder:w])
            return NO;
        [self push:[[[NSAttributedString alloc] initWithAttributedString:[(NSTextView *)_owner textStorage]] autorelease]];
    }
    [self _finchEndEditing];
    return YES;
}

- (BOOL)commitEditingAndReturnError:(NSError **)error
{
    if (error)
        *error = nil;
    return [self commitEditing];
}

- (void)commitEditingWithDelegate:(id)delegate didCommitSelector:(SEL)sel contextInfo:(void *)contextInfo
{
    BOOL ok = [self commitEditing];
    if (delegate && sel)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, sel, self, ok, contextInfo);
}

- (void)discardEditing
{
    if ([_owner isKindOfClass:[NSControl class]])
        [(NSControl *)_owner abortEditing];
    [self _finchEndEditing];
    if (_owner)
        [_owner _finchBindingChanged:self];
}

#pragma mark Text views

- (void)_finchTextBegan:(NSNotification *)n
{
    [self _finchBeginEditing];
}

- (void)_finchTextChanged:(NSNotification *)n
{
    [self _finchBeginEditing];
    if (option_bool(_options, NSContinuouslyUpdatesValueBindingOption))
        [_owner _finchPushBinding:self];
}

- (void)_finchTextEnded:(NSNotification *)n
{
    [_owner _finchPushBinding:self];
    [self _finchEndEditing];
}

@end

void
FinchBindingPush(id object, NSString *binding, id value)
{
    _FinchBinding *b = FinchBindingFor(object, binding);
    [b push:value];
}

#pragma mark - Options

static NSDictionary *
generic_options(void)
{
    NSNull *n = [NSNull null];
    return @{
        NSMultipleValuesPlaceholderBindingOption : n,
        NSNoSelectionPlaceholderBindingOption : n,
        NSNotApplicablePlaceholderBindingOption : n,
        NSNullPlaceholderBindingOption : n,
        NSRaisesForNotApplicableKeysBindingOption : @YES,
        NSValueTransformerBindingOption : n,
        NSValueTransformerNameBindingOption : n,
    };
}

/* The options a value-like binding of a control understands, beyond the generic ones. */
static NSDictionary *
control_value_options(BOOL text)
{
    NSMutableDictionary *d = [[generic_options() mutableCopy] autorelease];
    [d addEntriesFromDictionary:@{
        NSAllowsEditingMultipleValuesSelectionBindingOption : @YES,
        NSAlwaysPresentsApplicationModalAlertsBindingOption : @NO,
        NSConditionallySetsHiddenBindingOption : @NO,
        NSValidatesImmediatelyBindingOption : @NO,
    }];
    if (text) {
        [d setObject:@YES forKey:NSConditionallySetsEditableBindingOption];
        [d setObject:@NO forKey:NSConditionallySetsEnabledBindingOption];
        [d setObject:@NO forKey:NSContinuouslyUpdatesValueBindingOption];
    } else {
        [d setObject:@YES forKey:NSConditionallySetsEnabledBindingOption];
    }
    return d;
}

#pragma mark - NSObject's bindings

static NSMutableDictionary *exposed_by_class; /* class name -> NSMutableArray */

@implementation NSObject (FinchBindings)

/* The class's own list of bindings (Apple's lists don't simply add up down the hierarchy). */
+ (NSArray *)_finchBuiltinBindings { return nil; }

/* Whether the class handles the binding itself (rather than through KVC). */
- (BOOL)_finchHandlesBinding:(NSString *)binding { return NO; }

- (NSDictionary *)_finchDefaultOptionsForBinding:(NSString *)binding { return generic_options(); }

- (Class)_finchValueClassForBinding:(NSString *)binding { return Nil; }

/* The bound value changed: show it. NSObject's: key-value coding. */
- (void)_finchBindingChanged:(_FinchBinding *)b
{
    id v = [b displayValueWithKind:NULL];
    id cur = [self valueForKey:b->_name];
    if (cur == v || [cur isEqual:v])
        return;
    [self setValue:v forKey:b->_name];
}

/* The user changed what the binding shows: give it to the bound object. */
- (void)_finchPushBinding:(_FinchBinding *)b
{
}

- (void)_finchWillSendAction
{
}

@end

@implementation NSObject (NSKeyValueBindingCreation)

+ (void)exposeBinding:(NSBindingName)binding
{
    @synchronized([NSBindingSelectionMarker class]) {
        if (!exposed_by_class)
            exposed_by_class = [[NSMutableDictionary alloc] init];
        NSString *k = NSStringFromClass(self);
        NSMutableArray *a = [exposed_by_class objectForKey:k];
        if (!a) {
            a = [NSMutableArray array];
            [exposed_by_class setObject:a forKey:k];
        }
        if (![a containsObject:binding])
            [a addObject:binding];
    }
}

- (NSArray<NSBindingName> *)exposedBindings
{
    NSMutableArray *out = [NSMutableArray arrayWithArray:[[self class] _finchBuiltinBindings] ?: @[]];
    for (Class c = [self class]; c; c = class_getSuperclass(c)) {
        @synchronized([NSBindingSelectionMarker class]) {
            for (NSString *b in [exposed_by_class objectForKey:NSStringFromClass(c)])
                if (![out containsObject:b])
                    [out addObject:b];
        }
    }
    _FinchBindingSet *s = binding_set(self, NO);
    /* what's bound is exposed too (even a binding that failed) */
    for (NSString *b in s ? s->_order : nil)
        if (![out containsObject:b])
            [out addObject:b];
    return out;
}

- (Class)valueClassForBinding:(NSBindingName)binding
{
    return [self _finchValueClassForBinding:binding];
}

- (void)bind:(NSBindingName)binding toObject:(id)observable withKeyPath:(NSString *)keyPath
     options:(NSDictionary<NSBindingOption, id> *)options
{
    if (!binding || !keyPath)
        [NSException raise:NSInvalidArgumentException format:@"%@: binding and key path must not be nil", self];
    if (FinchBindingFor(self, binding))
        [self unbind:binding];
    make_markers();
    _FinchBinding *b = [[_FinchBinding alloc] init];
    b->_owner = self;
    b->_name = [binding copy];
    b->_observed = [observable retain];
    b->_keyPath = [keyPath copy];
    NSMutableDictionary *o = [[[self _finchDefaultOptionsForBinding:binding] mutableCopy] autorelease];
    /* default placeholders set for the class stand in for the built-in ones */
    for (int k = MK_NULL; k <= MK_NOTAPPLICABLE; k++) {
        NSString *key = placeholder_option(k);
        if (![o objectForKey:key])
            continue;
        id p = default_placeholder([self class], binding, k);
        if (p)
            [o setObject:p forKey:key];
    }
    for (NSString *k in options)
        [o setObject:[options objectForKey:k] forKey:k];
    id t = [o objectForKey:NSValueTransformerBindingOption];
    if ([t isKindOfClass:[NSValueTransformer class]]) {
        b->_transformer = [t retain];
    } else {
        id name = [o objectForKey:NSValueTransformerNameBindingOption];
        if ([name isKindOfClass:[NSString class]]) {
            b->_transformer = [[NSValueTransformer valueTransformerForName:name] retain];
            if (!b->_transformer)
                NSLog(@"Cannot find value transformer with name %@", name);
            else
                [o setObject:b->_transformer forKey:NSValueTransformerBindingOption];
        }
    }
    b->_options = [o copy];
    _FinchBindingSet *s = binding_set(self, YES);
    [s->_bindings setObject:b forKey:binding];
    [s->_order addObject:binding];
    [b release];
    [b _finchConnect];
    [self _finchBindingChanged:b];
}

- (void)unbind:(NSBindingName)binding
{
    _FinchBindingSet *s = binding_set(self, NO);
    if (!s)
        return;
    _FinchBinding *b = [[[s->_bindings objectForKey:binding] retain] autorelease];
    if (!b)
        return;
    [b _finchDisconnect];
    b->_owner = nil;
    [s->_bindings removeObjectForKey:binding];
    [s->_order removeObject:binding];
    [self _finchBindingRemoved:binding];
}

- (void)_finchBindingRemoved:(NSString *)binding
{
}

- (NSDictionary<NSBindingInfoKey, id> *)infoForBinding:(NSBindingName)binding
{
    _FinchBinding *b = FinchBindingFor(self, binding);
    if (!b)
        return nil;
    return @{
        NSObservedObjectKey : b->_observed ?: [NSNull null],
        NSObservedKeyPathKey : b->_keyPath,
        NSOptionsKey : b->_options,
    };
}

/* Option descriptions are Core Data attribute descriptions, which Finch doesn't have yet. */
- (NSArray<NSAttributeDescription *> *)optionDescriptionsForBinding:(NSBindingName)binding
{
    return @[];
}

@end

#pragma mark - Views

/* What a value binding turned off (editable, enabled) so it can turn it back on. */
static NSMutableDictionary *
conditional_state(id owner)
{
    NSMutableDictionary *d = objc_getAssociatedObject(owner, &conditionalKey);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(owner, &conditionalKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return d;
}

static void
apply_hidden(NSView *view)
{
    NSArray *bs = numbered_bindings(view, NSHiddenBinding);
    if (![bs count])
        return;
    BOOL hidden = NO;
    for (_FinchBinding *b in bs)
        hidden = hidden || truthy([b displayValueWithKind:NULL]);
    if ([[conditional_state(view) objectForKey:@"hidden"] boolValue])
        hidden = YES;
    [view setHidden:hidden];
}

@implementation NSView (FinchBindings)

+ (NSArray *)_finchBuiltinBindings { return @[ NSToolTipBinding, NSHiddenBinding ]; }

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSHiddenBinding] ||
           (is_numbered(binding, NSHiddenBinding) && FinchBindingFor(self, NSHiddenBinding)) ||
           [binding isEqualToString:NSToolTipBinding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSHiddenBinding])
        return [NSNumber class];
    if ([binding isEqualToString:NSToolTipBinding])
        return [NSString class];
    return [super _finchValueClassForBinding:binding];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    NSString *name = b->_name;
    if ([name isEqualToString:NSHiddenBinding] || (is_numbered(name, NSHiddenBinding) && FinchBindingFor(self, NSHiddenBinding))) {
        apply_hidden(self);
        return;
    }
    if ([name isEqualToString:NSEditableBinding] && [self respondsToSelector:@selector(setEditable:)]) {
        [(NSTextField *)self setEditable:truthy([b displayValueWithKind:NULL])];
        return;
    }
    if ([name isEqualToString:NSToolTipBinding]) {
        id v = [b displayValueWithKind:NULL];
        [self setToolTip:[v isKindOfClass:[NSString class]] ? v : [v description]];
        return;
    }
    [super _finchBindingChanged:b];
}

- (void)_finchBindingRemoved:(NSString *)binding
{
    if (is_numbered(binding, NSHiddenBinding))
        apply_hidden(self);
}

@end

#pragma mark - Controls

static void
apply_enabled(NSControl *control)
{
    NSArray *bs = numbered_bindings(control, NSEnabledBinding);
    BOOL enabled = YES;
    for (_FinchBinding *b in bs)
        enabled = enabled && truthy([b displayValueWithKind:NULL]);
    NSMutableDictionary *cond = conditional_state(control);
    if ([[cond objectForKey:@"enabled"] boolValue])
        enabled = NO;
    if ([bs count] || [cond objectForKey:@"enabled"])
        [control setEnabled:enabled];
    if (![[cond objectForKey:@"enabled"] boolValue])
        [cond removeObjectForKey:@"enabled"];
}

/* A value binding showing a marker or nil: whether it turns the control's editing or enabling off. */
static void
apply_conditions(NSControl *control, _FinchBinding *b, int kind)
{
    NSDictionary *o = b->_options;
    BOOL blocked = kind == MK_NOSELECTION || kind == MK_NOTAPPLICABLE ||
                   (kind == MK_MULTIPLE && !option_bool(o, NSAllowsEditingMultipleValuesSelectionBindingOption));
    NSMutableDictionary *cond = conditional_state(control);
    if (option_bool(o, NSConditionallySetsEditableBindingOption) && [control respondsToSelector:@selector(setEditable:)]) {
        BOOL was = [[cond objectForKey:@"editable"] boolValue];
        if (blocked && [(NSTextField *)control isEditable]) {
            [(NSTextField *)control setEditable:NO];
            [cond setObject:@YES forKey:@"editable"];
        } else if (!blocked && was) {
            [(NSTextField *)control setEditable:YES];
            [cond removeObjectForKey:@"editable"];
        }
    }
    if (option_bool(o, NSConditionallySetsEnabledBindingOption)) {
        BOOL was = [[cond objectForKey:@"enabled"] boolValue];
        if (blocked != was) {
            [cond setObject:@(blocked) forKey:@"enabled"];
            apply_enabled(control);
        }
    }
    if (option_bool(o, NSConditionallySetsHiddenBindingOption)) {
        [cond setObject:@(blocked) forKey:@"hidden"];
        apply_hidden(control);
    }
}

@implementation NSControl (FinchBindings)

+ (NSArray *)_finchBuiltinBindings
{
    return @[ NSEnabledBinding, NSToolTipBinding, NSHiddenBinding, NSValueBinding, NSFontBinding, NSAlignmentBinding ];
}

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSEnabledBinding] ||
           (is_numbered(binding, NSEnabledBinding) && FinchBindingFor(self, NSEnabledBinding)) ||
           [binding isEqualToString:NSValueBinding] || [super _finchHandlesBinding:binding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSEnabledBinding] || [binding isEqualToString:NSValueBinding] ||
        [binding isEqualToString:NSEditableBinding] || [binding isEqualToString:NSMinValueBinding] ||
        [binding isEqualToString:NSMaxValueBinding] || [binding isEqualToString:NSAlignmentBinding])
        return [NSNumber class];
    if ([binding isEqualToString:NSFontBinding])
        return [NSFont class];
    if ([binding isEqualToString:NSTextColorBinding])
        return [NSColor class];
    return [super _finchValueClassForBinding:binding];
}

- (NSDictionary *)_finchDefaultOptionsForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSValueBinding])
        return control_value_options(NO);
    return [super _finchDefaultOptionsForBinding:binding];
}

/* The value to show for a value binding: the control's own way (NSControl: its object value). */
- (void)_finchShowBoundValue:(id)value kind:(int)kind binding:(_FinchBinding *)b
{
    [self setObjectValue:value];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    NSString *name = b->_name;
    if ([name isEqualToString:NSEnabledBinding] || (is_numbered(name, NSEnabledBinding) && FinchBindingFor(self, NSEnabledBinding))) {
        apply_enabled(self);
        return;
    }
    if ([name isEqualToString:NSValueBinding] && ![self _finchHandlesBinding:name]) {
        /* no value binding (a push button): as KVC finds no "value" key (not the control's own ivar) */
        [self valueForUndefinedKey:name];
        return;
    }
    if ([name isEqualToString:NSValueBinding]) {
        int kind;
        id v = [b displayValueWithKind:&kind];
        [self _finchShowBoundValue:v kind:kind binding:b];
        apply_conditions(self, b, kind);
        return;
    }
    [super _finchBindingChanged:b];
}

- (void)_finchBindingRemoved:(NSString *)binding
{
    if (is_numbered(binding, NSEnabledBinding))
        apply_enabled(self);
    [super _finchBindingRemoved:binding];
}

/* The control's value for a value binding, as it is pushed. */
- (id)_finchBoundValue
{
    return [self objectValue];
}

- (void)_finchPushBinding:(_FinchBinding *)b
{
    if ([b->_name isEqualToString:NSValueBinding])
        [b push:[self _finchBoundValue]];
}

/* Before the action: the bindings that follow the user's choice. */
- (void)_finchWillSendAction
{
    _FinchBinding *b = FinchBindingFor(self, NSValueBinding);
    if (b && [self _finchHandlesBinding:NSValueBinding])
        [self _finchPushBinding:b];
}

@end

@implementation NSTextField (FinchBindings)

+ (NSArray *)_finchBuiltinBindings
{
    return @[
        NSFontBinding, NSFontItalicBinding, NSFontBoldBinding, NSEditableBinding, NSTextColorBinding, NSAlignmentBinding,
        NSValueBinding, NSFontFamilyNameBinding, NSEnabledBinding, NSToolTipBinding, @"displayPatternValue1",
        NSFontSizeBinding, NSFontNameBinding, NSHiddenBinding
    ];
}

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSTextColorBinding] || [super _finchHandlesBinding:binding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSValueBinding])
        return [NSString class];
    return [super _finchValueClassForBinding:binding];
}

- (NSDictionary *)_finchDefaultOptionsForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSValueBinding]) {
        NSMutableDictionary *d = [[control_value_options(YES) mutableCopy] autorelease];
        [d setObject:@"Multiple Values" forKey:NSMultipleValuesPlaceholderBindingOption];
        [d setObject:@"No Selection" forKey:NSNoSelectionPlaceholderBindingOption];
        [d setObject:@"Not Applicable" forKey:NSNotApplicablePlaceholderBindingOption];
        return d;
    }
    return [super _finchDefaultOptionsForBinding:binding];
}

- (void)_finchShowBoundValue:(id)value kind:(int)kind binding:(_FinchBinding *)b
{
    if (kind == MK_NONE) {
        [self setObjectValue:value];
        return;
    }
    [self setObjectValue:nil];
    if (value)
        [self setPlaceholderString:[value isKindOfClass:[NSString class]] ? value : [value description]];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    if ([b->_name isEqualToString:NSTextColorBinding]) {
        id v = [b displayValueWithKind:NULL];
        if (v && ![v isKindOfClass:[NSColor class]])
            [NSException raise:NSInternalInconsistencyException format:@"Cannot create NSColor from object %@ of class %@", v,
                               [v class]];
        [self setTextColor:v];
        return;
    }
    [super _finchBindingChanged:b];
}

/* Text fields give their value when editing ends, not when they send their action. */
- (void)_finchWillSendAction
{
}

@end

/* Buttons with a state (checkboxes, radio buttons, toggles) bind their state as the value. */
static BOOL
button_has_state(NSButton *button)
{
    id cell = [button cell];
    if (![cell isKindOfClass:[NSButtonCell class]] || [button isKindOfClass:[NSPopUpButton class]])
        return NO;
    return [cell showsStateBy] != 0;
}

@implementation NSButton (FinchBindings)

+ (NSArray *)_finchBuiltinBindings
{
    return @[
        NSAlternateImageBinding, NSFontBinding, NSArgumentBinding, NSFontBoldBinding, NSFontItalicBinding, NSTitleBinding,
        NSAlternateTitleBinding, NSImageBinding, NSFontFamilyNameBinding, NSTargetBinding, NSEnabledBinding,
        NSHiddenBinding, NSFontSizeBinding, NSFontNameBinding, NSToolTipBinding
    ];
}

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSValueBinding])
        return button_has_state(self);
    return [super _finchHandlesBinding:binding];
}

- (void)_finchShowBoundValue:(id)value kind:(int)kind binding:(_FinchBinding *)b
{
    if (kind == MK_MULTIPLE) {
        [self setAllowsMixedState:YES];
        [self setState:NSControlStateValueMixed];
        return;
    }
    NSControlStateValue state = NSControlStateValueOff;
    if (kind == MK_NONE && [value respondsToSelector:@selector(integerValue)]) {
        NSInteger i = [value isKindOfClass:[NSNumber class]] ? [value integerValue] : [value boolValue];
        state = i < 0 ? NSControlStateValueMixed : i > 0 ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (kind == MK_NONE && value) {
        state = NSControlStateValueOn;
    }
    [self setState:state];
}

- (id)_finchBoundValue
{
    NSControlStateValue state = [self state];
    if (state == NSControlStateValueMixed)
        return [NSNumber numberWithInteger:state];
    return [NSNumber numberWithBool:state == NSControlStateValueOn];
}

@end

@implementation NSSlider (FinchBindings)

+ (NSArray *)_finchBuiltinBindings
{
    return @[ NSMaxValueBinding, NSValueBinding, NSEnabledBinding, NSToolTipBinding, NSMinValueBinding, NSHiddenBinding ];
}

- (void)_finchShowBoundValue:(id)value kind:(int)kind binding:(_FinchBinding *)b
{
    if (kind != MK_NONE && kind != MK_NULL)
        return;
    [self setDoubleValue:[value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0];
}

- (id)_finchBoundValue
{
    return [NSNumber numberWithDouble:[self doubleValue]];
}

@end

#pragma mark - Pop-up buttons

static char popupExtraKey;

@implementation NSPopUpButton (FinchBindings)

+ (NSArray *)_finchBuiltinBindings
{
    return @[
        NSToolTipBinding, NSFontBinding, NSSelectedValueBinding, NSSelectedObjectBinding, NSFontBoldBinding,
        NSFontItalicBinding, NSSelectedTagBinding, NSFontFamilyNameBinding, NSEnabledBinding, NSContentObjectsBinding,
        NSHiddenBinding, NSFontSizeBinding, NSFontNameBinding, NSContentValuesBinding, NSSelectedIndexBinding,
        NSContentBinding
    ];
}

static BOOL
is_selection_binding(NSString *b)
{
    return [b isEqualToString:NSSelectedIndexBinding] || [b isEqualToString:NSSelectedObjectBinding] ||
           [b isEqualToString:NSSelectedValueBinding] || [b isEqualToString:NSSelectedTagBinding];
}

static BOOL
is_content_binding(NSString *b)
{
    return [b isEqualToString:NSContentBinding] || [b isEqualToString:NSContentValuesBinding] ||
           [b isEqualToString:NSContentObjectsBinding];
}

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSValueBinding])
        return NO;
    return is_selection_binding(binding) || [binding isEqualToString:NSContentBinding] ||
           ([binding isEqualToString:NSContentValuesBinding] || [binding isEqualToString:NSContentObjectsBinding]) ||
           [super _finchHandlesBinding:binding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSSelectedIndexBinding] || [binding isEqualToString:NSSelectedTagBinding])
        return [NSNumber class];
    if ([binding isEqualToString:NSSelectedValueBinding])
        return [NSString class];
    if (is_content_binding(binding) || [binding isEqualToString:NSSelectedObjectBinding])
        return Nil;
    return [super _finchValueClassForBinding:binding];
}

- (NSDictionary *)_finchDefaultOptionsForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSContentBinding] || [binding isEqualToString:NSContentValuesBinding]) {
        NSMutableDictionary *d = [[generic_options() mutableCopy] autorelease];
        [d setObject:@0 forKey:NSContentPlacementTagBindingOption];
        [d setObject:@NO forKey:NSInsertsNullPlaceholderBindingOption];
        [d setObject:@"No Value" forKey:NSNullPlaceholderBindingOption];
        return d;
    }
    if (is_selection_binding(binding)) {
        NSMutableDictionary *d = [[control_value_options(NO) mutableCopy] autorelease];
        if ([binding isEqualToString:NSSelectedValueBinding]) {
            [d setObject:@"Multiple Values" forKey:NSMultipleValuesPlaceholderBindingOption];
            [d setObject:@"No Selection" forKey:NSNoSelectionPlaceholderBindingOption];
            [d setObject:@"Not Applicable" forKey:NSNotApplicablePlaceholderBindingOption];
        }
        return d;
    }
    return [super _finchDefaultOptionsForBinding:binding];
}

/* Whether the first item stands for nil (NSInsertsNullPlaceholderBindingOption). */
- (NSInteger)_finchNullOffset
{
    _FinchBinding *c = FinchBindingFor(self, NSContentBinding) ?: FinchBindingFor(self, NSContentValuesBinding);
    return c && option_bool(c->_options, NSInsertsNullPlaceholderBindingOption) ? 1 : 0;
}

- (void)_finchRemoveExtraItem
{
    NSMenuItem *extra = objc_getAssociatedObject(self, &popupExtraKey);
    if (!extra)
        return;
    NSInteger i = [[self menu] indexOfItem:extra];
    if (i >= 0)
        [[self menu] removeItemAtIndex:i];
    objc_setAssociatedObject(self, &popupExtraKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/* A selected object or value the items don't have: an item of its own, at the end. */
- (void)_finchSelectExtraTitle:(NSString *)title object:(id)object
{
    NSMenuItem *extra = objc_getAssociatedObject(self, &popupExtraKey);
    if (!extra) {
        extra = [[[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""] autorelease];
        [[self menu] addItem:extra];
        objc_setAssociatedObject(self, &popupExtraKey, extra, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [extra setTitle:title ?: @""];
    [extra setRepresentedObject:object];
    [self selectItem:extra];
}

static NSArray *
as_array(id v)
{
    if ([v isKindOfClass:[NSArray class]])
        return v;
    if ([v isKindOfClass:[NSSet class]] || [v isKindOfClass:[NSOrderedSet class]])
        return [v allObjects];
    return nil;
}

- (void)_finchRebuildItems
{
    _FinchBinding *cb = FinchBindingFor(self, NSContentBinding), *vb = FinchBindingFor(self, NSContentValuesBinding),
                  *ob = FinchBindingFor(self, NSContentObjectsBinding);
    if (!cb && !vb)
        return;
    NSInteger selected = [self indexOfSelectedItem];
    NSArray *content = cb ? as_array([cb valueWithKind:NULL]) : nil;
    NSArray *values = vb ? as_array([vb valueWithKind:NULL]) : nil;
    NSArray *objects = ob ? as_array([ob valueWithKind:NULL]) : nil;
    NSUInteger n = values ? [values count] : [content count];
    objc_setAssociatedObject(self, &popupExtraKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMenu *menu = [self menu];
    [menu removeAllItems];
    _FinchBinding *first = cb ?: vb;
    if (option_bool(first->_options, NSInsertsNullPlaceholderBindingOption)) {
        id p = [first->_options objectForKey:NSNullPlaceholderBindingOption];
        NSString *t = p == [NSNull null] || !p ? @"" : [p description];
        [menu addItem:[[[NSMenuItem alloc] initWithTitle:t action:NULL keyEquivalent:@""] autorelease]];
    }
    for (NSUInteger i = 0; i < n; i++) {
        id v = values ? [values objectAtIndex:i] : [content objectAtIndex:i];
        NSString *title = v == [NSNull null] ? @"" : [v isKindOfClass:[NSString class]] ? v : [v description];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title ?: @"" action:NULL keyEquivalent:@""];
        id rep = objects && i < [objects count] ? [objects objectAtIndex:i] : i < [content count] ? [content objectAtIndex:i] : nil;
        [item setRepresentedObject:rep == [NSNull null] ? nil : rep];
        [menu addItem:item];
        [item release];
    }
    BOOL reselected = NO;
    for (NSString *s in @[ NSSelectedIndexBinding, NSSelectedObjectBinding, NSSelectedValueBinding, NSSelectedTagBinding ]) {
        _FinchBinding *sb = FinchBindingFor(self, s);
        if (sb) {
            [self _finchShowSelection:sb];
            reselected = YES;
        }
    }
    if (!reselected && [self numberOfItems])
        [self selectItemAtIndex:selected >= 0 && selected < [self numberOfItems] ? selected : 0];
    [self synchronizeTitleAndSelectedItem];
}

- (void)_finchShowSelection:(_FinchBinding *)b
{
    NSString *name = b->_name;
    int kind;
    id v = [b valueWithKind:&kind];
    if (kind != MK_NONE && kind != MK_NULL)
        v = nil;
    NSInteger offset = [self _finchNullOffset];
    if ([name isEqualToString:NSSelectedIndexBinding]) {
        NSInteger i = v ? [v integerValue] : -1;
        [self _finchRemoveExtraItem];
        if (i >= 0 && i + offset < [self numberOfItems])
            [self selectItemAtIndex:i + offset];
        else
            [self selectItemAtIndex:offset && !v ? 0 : -1];
    } else if ([name isEqualToString:NSSelectedTagBinding]) {
        [self _finchRemoveExtraItem];
        if (![self selectItemWithTag:[v integerValue]])
            [self selectItemAtIndex:-1];
    } else if ([name isEqualToString:NSSelectedObjectBinding]) {
        NSInteger found = -1;
        NSMenuItem *extra = objc_getAssociatedObject(self, &popupExtraKey);
        NSArray *items = [self itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *it = [items objectAtIndex:i];
            if (it == extra)
                continue;
            if (!v ? (offset && i == 0) : (i >= (NSUInteger)offset && [[it representedObject] isEqual:v])) {
                found = (NSInteger)i;
                break;
            }
        }
        if (found >= 0) {
            [self _finchRemoveExtraItem];
            [self selectItemAtIndex:found];
        } else {
            NSString *title = v ? [v description] : nil;
            if (!v) {
                /* nil shows as the content's null placeholder */
                _FinchBinding *c = FinchBindingFor(self, NSContentBinding) ?: FinchBindingFor(self, NSContentValuesBinding);
                id p = c ? [c->_options objectForKey:NSNullPlaceholderBindingOption] : nil;
                title = p && p != [NSNull null] ? [p description] : @"";
            }
            [self _finchSelectExtraTitle:title object:v];
        }
    } else if ([name isEqualToString:NSSelectedValueBinding]) {
        NSInteger found = -1;
        NSMenuItem *extra = objc_getAssociatedObject(self, &popupExtraKey);
        NSArray *items = [self itemArray];
        for (NSUInteger i = (NSUInteger)offset; i < [items count]; i++) {
            NSMenuItem *it = [items objectAtIndex:i];
            if (it != extra && v && [[it title] isEqualToString:[v description]]) {
                found = (NSInteger)i;
                break;
            }
        }
        if (!v && offset)
            found = 0;
        if (found >= 0) {
            [self _finchRemoveExtraItem];
            [self selectItemAtIndex:found];
        } else {
            [self _finchSelectExtraTitle:v ? [v description] : @"" object:nil];
        }
    }
    [self synchronizeTitleAndSelectedItem];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    NSString *name = b->_name;
    if (is_content_binding(name)) {
        [self _finchRebuildItems];
        return;
    }
    if (is_selection_binding(name)) {
        int kind;
        [b valueWithKind:&kind];
        [self _finchShowSelection:b];
        apply_conditions(self, b, kind);
        return;
    }
    [super _finchBindingChanged:b];
}

- (void)_finchPushBinding:(_FinchBinding *)b
{
    NSString *name = b->_name;
    NSInteger offset = [self _finchNullOffset];
    NSInteger i = [self indexOfSelectedItem];
    BOOL onNull = offset && i == 0;
    if ([name isEqualToString:NSSelectedIndexBinding])
        [b push:i < 0 || onNull ? nil : [NSNumber numberWithInteger:i - offset]];
    else if ([name isEqualToString:NSSelectedObjectBinding])
        [b push:onNull ? nil : [[self selectedItem] representedObject]];
    else if ([name isEqualToString:NSSelectedValueBinding])
        [b push:onNull ? nil : [self titleOfSelectedItem]];
    else if ([name isEqualToString:NSSelectedTagBinding])
        [b push:[NSNumber numberWithInteger:[self selectedTag]]];
}

- (void)_finchWillSendAction
{
    for (NSString *s in @[ NSSelectedIndexBinding, NSSelectedObjectBinding, NSSelectedValueBinding, NSSelectedTagBinding ]) {
        _FinchBinding *b = FinchBindingFor(self, s);
        if (b)
            [self _finchPushBinding:b];
    }
}

@end

#pragma mark - Text views

@implementation NSTextView (FinchBindings)

+ (NSArray *)_finchBuiltinBindings
{
    return @[ NSEditableBinding, NSValueURLBinding, NSToolTipBinding, NSValuePathBinding, NSDataBinding,
              NSAttributedStringBinding, NSHiddenBinding ];
}

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSAttributedStringBinding] || [super _finchHandlesBinding:binding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSAttributedStringBinding] || [binding isEqualToString:NSDataBinding])
        return [NSData class];
    if ([binding isEqualToString:NSEditableBinding])
        return [NSNumber class];
    return [super _finchValueClassForBinding:binding];
}

- (NSDictionary *)_finchDefaultOptionsForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSAttributedStringBinding]) {
        NSMutableDictionary *d = [[generic_options() mutableCopy] autorelease];
        [d addEntriesFromDictionary:@{
            NSAllowsEditingMultipleValuesSelectionBindingOption : @YES,
            NSAlwaysPresentsApplicationModalAlertsBindingOption : @NO,
            NSConditionallySetsEditableBindingOption : @YES,
            NSConditionallySetsHiddenBindingOption : @NO,
            NSContinuouslyUpdatesValueBindingOption : @NO,
            NSValidatesImmediatelyBindingOption : @NO,
        }];
        return d;
    }
    return [super _finchDefaultOptionsForBinding:binding];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    if ([b->_name isEqualToString:NSAttributedStringBinding]) {
        int kind;
        id v = [b displayValueWithKind:&kind];
        NSTextStorage *ts = [self textStorage];
        if ([v isKindOfClass:[NSAttributedString class]])
            [ts setAttributedString:v];
        else
            [ts replaceCharactersInRange:NSMakeRange(0, [ts length]) withString:v ? [v description] : @""];
        BOOL blocked = kind == MK_NOSELECTION || kind == MK_NOTAPPLICABLE ||
                       (kind == MK_MULTIPLE && !option_bool(b->_options, NSAllowsEditingMultipleValuesSelectionBindingOption));
        if (option_bool(b->_options, NSConditionallySetsEditableBindingOption)) {
            NSMutableDictionary *cond = conditional_state(self);
            if (blocked && [self isEditable]) {
                [self setEditable:NO];
                [cond setObject:@YES forKey:@"editable"];
            } else if (!blocked && [[cond objectForKey:@"editable"] boolValue]) {
                [self setEditable:YES];
                [cond removeObjectForKey:@"editable"];
            }
        }
        return;
    }
    [super _finchBindingChanged:b];
}

- (void)_finchPushBinding:(_FinchBinding *)b
{
    if ([b->_name isEqualToString:NSAttributedStringBinding])
        [b push:[[[NSAttributedString alloc] initWithAttributedString:[self textStorage]] autorelease]];
}

@end

#pragma mark - Hooks

void
FinchBindingsControlWillSendAction(NSControl *control)
{
    if (!binding_set(control, NO))
        return;
    [control _finchWillSendAction];
}

void
FinchBindingsControlEdited(NSControl *control, int phase)
{
    _FinchBinding *b = FinchBindingFor(control, NSValueBinding);
    if (!b || ![control _finchHandlesBinding:NSValueBinding])
        return;
    switch (phase) {
    case FinchEditBegan:
        [b _finchBeginEditing];
        break;
    case FinchEditChanged:
        [b _finchBeginEditing];
        if (option_bool(b->_options, NSContinuouslyUpdatesValueBindingOption)) {
            [control validateEditing];
            [control _finchPushBinding:b];
        }
        break;
    case FinchEditEnded:
        [control _finchPushBinding:b];
        [b _finchEndEditing];
        break;
    }
}
