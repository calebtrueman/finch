/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-bindings-test: Cocoa bindings and the controllers, and
 * NSFontManager, without a screen: binding values both ways, transformers,
 * placeholders and markers, the standard controls' bindings (text fields,
 * checkboxes, sliders, pop-up buttons, text views, views), editing and
 * NSEditor commits, NSObjectController and NSArrayController (content,
 * selection, arrangement, adding and removing), NSUserDefaultsController
 * (on a private suite; the user's defaults are only read), a nib of bound
 * controls compiled by ibtool (appkit-bindings-test.xib), and NSFontManager's
 * conversions on fonts both systems have (Liberation Sans and Inter,
 * registered from Finch's build on the host).
 *
 * Prints everything; run it against Apple's AppKit and Finch's
 * (DYLD_FRAMEWORK_PATH) and diff all but the first line, which is where
 * NSArrayController came from.
 *
 *   finch-appkit-bindings-test [path to appkit-bindings-test.nib] [directory with Finch's fonts]
 */
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", [s UTF8String]);
}

#define DO(stmt)                                                                \
    do {                                                                        \
        @try {                                                                  \
            stmt;                                                               \
        } @catch (NSException * e) {                                            \
            out(@"  %s: raises %@", #stmt, e.name);                             \
        }                                                                       \
    } while (0)

static void
spin(void)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

/* Values without addresses: arrays and index sets on one line. */
static NSString *
D(id v)
{
    if (!v)
        return @"nil";
    if (v == [NSNull null])
        return @"<null>";
    if ([v isKindOfClass:[NSIndexSet class]]) {
        NSMutableArray *a = [NSMutableArray array];
        [v enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
            [a addObject:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
        }];
        return [NSString stringWithFormat:@"{%@}", [a componentsJoinedByString:@","]];
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id o in v)
            [a addObject:D(o)];
        return [NSString stringWithFormat:@"[%@]", [a componentsJoinedByString:@", "]];
    }
    if ([v isKindOfClass:[NSAttributedString class]])
        return [NSString stringWithFormat:@"attr'%@'", [v string]];
    if ([v isKindOfClass:[NSFont class]])
        return [NSString stringWithFormat:@"%@ %g", [v fontName], [v pointSize]];
    if ([v isKindOfClass:[NSNumber class]] && strcmp([v objCType], "c") == 0)
        return [v boolValue] ? @"YES" : @"NO";
    return [v description];
}

/* An options dictionary, sorted, NSNull as "-". */
static NSString *
O(NSDictionary *o)
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [[o allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id v = o[k];
        if ([v isKindOfClass:[NSFont class]])
            v = @"<font>";
        if ([v isKindOfClass:[NSValueTransformer class]])
            v = @"<transformer>";
        [parts addObject:[NSString stringWithFormat:@"%@=%@", [k hasPrefix:@"NS"] ? [k substringFromIndex:2] : k,
                                                    v == [NSNull null] ? @"-" : v]];
    }
    return [parts componentsJoinedByString:@" "];
}

static NSString *
sorted(NSArray *a)
{
    return [[a sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
}

#pragma mark - Model

@interface Item : NSObject
@property (copy) NSString *name;
@property BOOL flag;
@property double value;
@property NSInteger num;
@property (strong) id obj;
@end

@implementation Item
- (NSString *)description { return [NSString stringWithFormat:@"Item(%@)", _name]; }
@end

static Item *
item(NSString *name, double value)
{
    Item *i = [Item new];
    i.name = name;
    i.value = value;
    return i;
}

static NSString *
names(id array)
{
    NSMutableArray *a = [NSMutableArray array];
    for (Item *i in array)
        [a addObject:[i isKindOfClass:[Item class]] ? (i.name ?: @"nil") : D(i)];
    return [a componentsJoinedByString:@","];
}

@interface Holder : NSObject
@property (strong) NSMutableArray *items;
@property (strong) NSIndexSet *picked;
@property (strong) NSArray *sorts;
@property (strong) id thing;
@end
@implementation Holder
@end

/* Records the key paths it's told about (each once, in order). */
@interface Recorder : NSObject
@property (strong) NSMutableArray *seen;
@end

@implementation Recorder
- (instancetype)init
{
    self = [super init];
    _seen = [NSMutableArray array];
    return self;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([change[NSKeyValueChangeNotificationIsPriorKey] boolValue])
        return;
    if (![_seen containsObject:keyPath])
        [_seen addObject:keyPath];
}
- (NSString *)take
{
    NSString *s = sorted(_seen);
    [_seen removeAllObjects];
    return [s length] ? s : @"(none)";
}
@end

/* An editor that says what it's asked. */
@interface Editor : NSObject <NSEditor>
@property BOOL refuse;
@end
@implementation Editor
- (BOOL)commitEditing
{
    out(@"  editor: commit");
    return !_refuse;
}
- (void)discardEditing { out(@"  editor: discard"); }
@end

/* A reversible transformer: numbers <-> "#n". */
@interface Hash : NSValueTransformer
@end
@implementation Hash
+ (Class)transformedValueClass { return [NSString class]; }
+ (BOOL)allowsReverseTransformation { return YES; }
- (id)transformedValue:(id)v { return v ? [NSString stringWithFormat:@"#%@", v] : @"#none"; }
- (id)reverseTransformedValue:(id)v
{
    return [v hasPrefix:@"#"] ? @([[v substringFromIndex:1] integerValue]) : nil;
}
@end

/* A custom bindable view. */
@interface Gauge : NSView
@property double level;
@end
@implementation Gauge
+ (void)initialize
{
    if (self == [Gauge class])
        [self exposeBinding:@"level"];
}
@end

#pragma mark - Names and markers

static void
test_names(void)
{
    out(@"== names");
    NSArray *names = @[
        NSValueBinding, NSEnabledBinding, NSHiddenBinding, NSEditableBinding, NSToolTipBinding, NSFontBinding,
        NSTextColorBinding, NSContentBinding, NSContentValuesBinding, NSContentObjectsBinding, NSContentArrayBinding,
        NSContentObjectBinding, NSContentSetBinding, NSSelectedIndexBinding, NSSelectedObjectBinding,
        NSSelectedValueBinding, NSSelectedTagBinding, NSSelectionIndexesBinding, NSSortDescriptorsBinding,
        NSFilterPredicateBinding, NSAttributedStringBinding, NSDataBinding, NSTitleBinding, NSImageBinding,
        NSMaxValueBinding, NSMinValueBinding, NSAlignmentBinding, NSArgumentBinding, NSTargetBinding,
        NSDisplayPatternValueBinding, NSContentDictionaryBinding, NSManagedObjectContextBinding, NSVisibleBinding,
        NSTransparentBinding, NSPositioningRectBinding, NSInitialKeyBinding, NSInitialValueBinding,
        NSIncludedKeysBinding, NSExcludedKeysBinding, NSLocalizedKeyDictionaryBinding, NSSelectedObjectsBinding,
        NSSelectionIndexPathsBinding, NSRowHeightBinding, NSIsIndeterminateBinding, NSCriticalValueBinding,
        NSWarningValueBinding, NSDocumentEditedBinding, NSRepresentedFilenameBinding
    ];
    out(@"bindings %@", [names componentsJoinedByString:@" "]);
    NSArray *opts = @[
        NSAllowsEditingMultipleValuesSelectionBindingOption, NSAllowsNullArgumentBindingOption,
        NSAlwaysPresentsApplicationModalAlertsBindingOption, NSConditionallySetsEditableBindingOption,
        NSConditionallySetsEnabledBindingOption, NSConditionallySetsHiddenBindingOption,
        NSContinuouslyUpdatesValueBindingOption, NSCreatesSortDescriptorBindingOption,
        NSDeletesObjectsOnRemoveBindingsOption, NSDisplayNameBindingOption, NSDisplayPatternBindingOption,
        NSContentPlacementTagBindingOption, NSHandlesContentAsCompoundValueBindingOption,
        NSInsertsNullPlaceholderBindingOption, NSInvokesSeparatelyWithArrayObjectsBindingOption,
        NSMultipleValuesPlaceholderBindingOption, NSNoSelectionPlaceholderBindingOption,
        NSNotApplicablePlaceholderBindingOption, NSNullPlaceholderBindingOption,
        NSRaisesForNotApplicableKeysBindingOption, NSPredicateFormatBindingOption, NSSelectorNameBindingOption,
        NSSelectsAllWhenSettingContentBindingOption, NSValidatesImmediatelyBindingOption,
        NSValueTransformerNameBindingOption, NSValueTransformerBindingOption
    ];
    out(@"options %@", [opts componentsJoinedByString:@" "]);
    out(@"info keys %@ %@ %@", NSObservedObjectKey, NSObservedKeyPathKey, NSOptionsKey);
    for (id m in @[ NSMultipleValuesMarker, NSNoSelectionMarker, NSNotApplicableMarker ])
        out(@"marker %@ isMarker %d copy same %d", m, NSIsControllerMarker(m), [m copy] == m);
    out(@"selection markers same %d %d %d", NSBindingSelectionMarker.multipleValuesSelectionMarker == NSMultipleValuesMarker,
        NSBindingSelectionMarker.noSelectionMarker == NSNoSelectionMarker,
        NSBindingSelectionMarker.notApplicableSelectionMarker == NSNotApplicableMarker);
    out(@"isMarker nil %d string %d null %d", NSIsControllerMarker(nil), NSIsControllerMarker(@"x"),
        NSIsControllerMarker([NSNull null]));
    out(@"marker kind %d", [NSNoSelectionMarker isKindOfClass:[NSBindingSelectionMarker class]]);
}

#pragma mark - NSObject's bindings

static void
test_object_bindings(void)
{
    out(@"== object bindings");
    Item *m = item(@"m", 1);
    Holder *h = [Holder new];
    [h bind:@"thing" toObject:m withKeyPath:@"value" options:nil];
    out(@"bound: thing %@", D(h.thing));
    NSDictionary *info = [h infoForBinding:@"thing"];
    out(@"info object same %d keyPath %@ options %@", info[NSObservedObjectKey] == m, info[NSObservedKeyPathKey],
        O(info[NSOptionsKey]));
    m.value = 3;
    out(@"model -> thing %@", D(h.thing));
    h.thing = @9;
    out(@"thing set: model %g (one-way)", m.value);
    [h bind:@"thing" toObject:m withKeyPath:@"name" options:@{
        NSValueTransformerNameBindingOption : NSIsNilTransformerName
    }];
    out(@"rebound with NSIsNil: %@ info keyPath %@", D(h.thing), [h infoForBinding:@"thing"][NSObservedKeyPathKey]);
    m.name = nil;
    out(@"name nil: %@", D(h.thing));
    [h bind:@"thing" toObject:m withKeyPath:@"name" options:@{ NSNullPlaceholderBindingOption : @"(empty)" }];
    out(@"null placeholder: %@", D(h.thing));
    m.name = @"back";
    out(@"value again: %@", D(h.thing));
    [h bind:@"thing" toObject:m withKeyPath:@"num" options:@{ NSValueTransformerBindingOption : [Hash new] }];
    m.num = 4;
    out(@"transformer object: %@ options transformer set %d", D(h.thing),
        [[h infoForBinding:@"thing"][NSOptionsKey][NSValueTransformerBindingOption] isKindOfClass:[Hash class]]);
    [h unbind:@"thing"];
    m.num = 5;
    out(@"unbound: %@ info %@", D(h.thing), D([h infoForBinding:@"thing"]));
    [h unbind:@"never"];
    out(@"unbind unbound: ok");
    DO([h bind:@"nokey" toObject:m withKeyPath:@"name" options:nil]);
    out(@"exposed object [%@] holder [%@]", sorted([[NSObject new] exposedBindings]), sorted([h exposedBindings]));
    Gauge *g = [Gauge new];
    out(@"exposed gauge [%@]", sorted([g exposedBindings]));
    [g bind:@"level" toObject:m withKeyPath:@"value" options:nil];
    m.value = 0.75;
    out(@"gauge level %g valueClass %@", g.level, [g valueClassForBinding:@"level"]);
    [g unbind:@"level"];
}

#pragma mark - Exposed bindings and options

static void
show_options(id v, NSString *binding, NSString *keyPath, id target)
{
    @try {
        [v bind:binding toObject:target withKeyPath:keyPath options:nil];
    } @catch (NSException *e) {
        out(@"  %@ %@: raises %@", [v className], binding, e.name);
        return;
    }
    out(@"  %@ %@: %@", [v className], binding, O([v infoForBinding:binding][NSOptionsKey]));
    [v unbind:binding];
}

static void
test_exposed(void)
{
    out(@"== exposed bindings");
    out(@"text field [%@]", sorted([[NSTextField new] exposedBindings]));
    out(@"button [%@]", sorted([[NSButton new] exposedBindings]));
    out(@"slider [%@]", sorted([[NSSlider new] exposedBindings]));
    out(@"popup [%@]", sorted([[NSPopUpButton new] exposedBindings]));
    out(@"text view [%@]", sorted([[NSTextView new] exposedBindings]));
    out(@"view [%@]", sorted([[NSView new] exposedBindings]));
    out(@"object controller [%@]", sorted([[NSObjectController new] exposedBindings]));
    out(@"array controller [%@]", sorted([[NSArrayController new] exposedBindings]));
    out(@"defaults controller [%@]", sorted([[[NSUserDefaultsController alloc] initWithDefaults:nil initialValues:nil] exposedBindings]));
    NSTextField *tf = [NSTextField new];
    out(@"value classes: tf value %@ enabled %@ hidden %@ editable %@ toolTip %@ font %@ textColor %@ foo %@",
        [tf valueClassForBinding:NSValueBinding], [tf valueClassForBinding:NSEnabledBinding],
        [tf valueClassForBinding:NSHiddenBinding], [tf valueClassForBinding:NSEditableBinding],
        [tf valueClassForBinding:NSToolTipBinding], [tf valueClassForBinding:NSFontBinding],
        [tf valueClassForBinding:NSTextColorBinding], [tf valueClassForBinding:@"foo"]);
    NSButton *cb = [NSButton checkboxWithTitle:@"c" target:nil action:nil];
    NSSlider *s = [NSSlider new];
    NSPopUpButton *p = [NSPopUpButton new];
    NSTextView *tv = [NSTextView new];
    NSObjectController *oc = [NSObjectController new];
    NSArrayController *ac = [NSArrayController new];
    out(@"value classes: checkbox %@ slider %@ max %@ popup content %@ selectedIndex %@ selectedObject %@ selectedValue %@",
        [cb valueClassForBinding:NSValueBinding], [s valueClassForBinding:NSValueBinding],
        [s valueClassForBinding:NSMaxValueBinding], [p valueClassForBinding:NSContentBinding],
        [p valueClassForBinding:NSSelectedIndexBinding], [p valueClassForBinding:NSSelectedObjectBinding],
        [p valueClassForBinding:NSSelectedValueBinding]);
    out(@"value classes: text view %@ view hidden %@ oc content %@ ac content %@ selection %@ sort %@ filter %@",
        [tv valueClassForBinding:NSAttributedStringBinding], [[NSView new] valueClassForBinding:NSHiddenBinding],
        [oc valueClassForBinding:NSContentObjectBinding], [ac valueClassForBinding:NSContentArrayBinding],
        [ac valueClassForBinding:NSSelectionIndexesBinding], [ac valueClassForBinding:NSSortDescriptorsBinding],
        [ac valueClassForBinding:NSFilterPredicateBinding]);

    out(@"options:");
    Item *m = item(@"m", 1);
    Holder *h = [Holder new];
    h.items = [NSMutableArray array];
    for (NSString *b in @[ NSValueBinding, NSEnabledBinding, NSHiddenBinding, NSEditableBinding, NSTextColorBinding ])
        show_options(tf, b, @"obj", m);
    for (NSString *b in @[ NSValueBinding, NSEnabledBinding, NSTitleBinding ])
        show_options(cb, b, @"obj", m);
    show_options([NSButton buttonWithTitle:@"push" target:nil action:nil], NSValueBinding, @"obj", m);
    for (NSString *b in @[ NSValueBinding, NSMaxValueBinding ])
        show_options(s, b, @"value", m);
    for (NSString *b in @[ NSContentBinding, NSContentValuesBinding ])
        show_options(p, b, @"items", h);
    for (NSString *b in @[ NSSelectedIndexBinding, NSSelectedObjectBinding, NSSelectedValueBinding, NSSelectedTagBinding ])
        show_options(p, b, @"obj", m);
    for (NSString *b in @[ NSAttributedStringBinding, NSEditableBinding ])
        show_options(tv, b, @"obj", m);
    for (NSString *b in @[ NSHiddenBinding, NSToolTipBinding ])
        show_options([NSView new], b, @"obj", m);
    show_options(oc, NSContentObjectBinding, @"obj", m);
    show_options(ac, NSContentArrayBinding, @"items", h);
    for (NSString *b in @[ NSSelectionIndexesBinding, NSSortDescriptorsBinding, NSFilterPredicateBinding ])
        show_options(ac, b, @"obj", m);
    show_options([NSSecureTextField new], NSValueBinding, @"obj", m);
}

#pragma mark - Controls

static NSString *
field(NSTextField *tf)
{
    return [NSString stringWithFormat:@"'%@' placeholder %@ editable %d enabled %d", tf.stringValue, D(tf.placeholderString),
                                      tf.isEditable, tf.isEnabled];
}

static void
test_controls(void)
{
    out(@"== controls");
    Item *m = item(@"first", 2);
    NSTextField *tf = [NSTextField textFieldWithString:@"x"];
    [tf bind:NSValueBinding toObject:m withKeyPath:@"name" options:nil];
    out(@"text field: %@", field(tf));
    m.name = @"second";
    out(@"model changed: %@", field(tf));
    m.name = nil;
    out(@"nil: %@", field(tf));
    [tf bind:NSValueBinding toObject:m withKeyPath:@"name" options:@{ NSNullPlaceholderBindingOption : @"none" }];
    out(@"null placeholder: %@", field(tf));
    m.name = @"third";
    out(@"value again: %@", field(tf));
    tf.stringValue = @"typed";
    [tf sendAction:@selector(doSomething:) to:nil];
    out(@"text field sendAction: model %@ (text fields give their value when editing ends)", m.name);
    [tf bind:NSValueBinding toObject:m withKeyPath:@"value" options:nil];
    out(@"number: %@", field(tf));
    [tf bind:NSValueBinding toObject:m withKeyPath:@"num" options:@{ NSValueTransformerNameBindingOption : @"Hash" }];
    out(@"transformer by name: %@", field(tf));

    out(@"enabled, hidden, editable, toolTip, font, textColor:");
    [tf bind:NSEnabledBinding toObject:m withKeyPath:@"flag" options:nil];
    out(@"  enabled from NO: %d", tf.isEnabled);
    m.flag = YES;
    out(@"  enabled from YES: %d", tf.isEnabled);
    [tf bind:@"enabled2" toObject:m withKeyPath:@"num" options:nil];
    out(@"  enabled2 num %ld: %d exposed has enabled2 %d", (long)m.num, tf.isEnabled,
        [[tf exposedBindings] containsObject:@"enabled2"]);
    m.num = 0;
    out(@"  enabled2 num 0: %d", tf.isEnabled);
    m.num = 3;
    out(@"  enabled2 num 3: %d", tf.isEnabled);
    [tf unbind:@"enabled2"];
    [tf bind:NSEnabledBinding toObject:m withKeyPath:@"flag"
          options:@{ NSValueTransformerNameBindingOption : NSNegateBooleanTransformerName }];
    out(@"  negated: %d", tf.isEnabled);
    [tf unbind:NSEnabledBinding];
    [tf bind:NSHiddenBinding toObject:m withKeyPath:@"flag" options:nil];
    out(@"  hidden %d", tf.isHidden);
    [tf bind:@"hidden2" toObject:m withKeyPath:@"num" options:nil];
    m.flag = NO;
    out(@"  hidden2 num 3, flag NO: %d", tf.isHidden);
    m.num = 0;
    out(@"  both off: %d", tf.isHidden);
    [tf unbind:@"hidden2"];
    [tf unbind:NSHiddenBinding];
    [tf bind:NSEditableBinding toObject:m withKeyPath:@"flag" options:nil];
    out(@"  editable %d", tf.isEditable);
    [tf unbind:NSEditableBinding];
    tf.editable = YES;
    m.obj = @"tip";
    [tf bind:NSToolTipBinding toObject:m withKeyPath:@"obj" options:nil];
    out(@"  toolTip %@", tf.toolTip);
    m.obj = [NSFont userFixedPitchFontOfSize:21];
    [tf unbind:NSToolTipBinding];
    [tf bind:NSFontBinding toObject:m withKeyPath:@"obj" options:nil];
    out(@"  font size %g", tf.font.pointSize);
    [tf unbind:NSFontBinding];
    m.obj = [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1];
    [tf bind:NSTextColorBinding toObject:m withKeyPath:@"obj" options:nil];
    out(@"  text color red %g", tf.textColor.redComponent);
    DO(m.obj = @42);
    [tf unbind:NSTextColorBinding];

    out(@"checkbox:");
    NSButton *cb = [NSButton checkboxWithTitle:@"c" target:nil action:nil];
    m.flag = YES;
    [cb bind:NSValueBinding toObject:m withKeyPath:@"flag" options:nil];
    out(@"  state %ld", (long)cb.state);
    m.flag = NO;
    out(@"  model NO: state %ld", (long)cb.state);
    [cb performClick:nil];
    out(@"  click: state %ld model %d", (long)cb.state, m.flag);
    m.obj = @"YES";
    [cb bind:NSValueBinding toObject:m withKeyPath:@"obj" options:nil];
    out(@"  string YES: state %ld", (long)cb.state);
    [cb performClick:nil];
    out(@"  click: model %@", D(m.obj));
    NSButton *push = [NSButton buttonWithTitle:@"push" target:nil action:nil];
    DO([push bind:NSValueBinding toObject:m withKeyPath:@"flag" options:nil]);
    [push unbind:NSValueBinding];

    out(@"slider:");
    NSSlider *s = [NSSlider sliderWithValue:0 minValue:0 maxValue:10 target:nil action:nil];
    [s bind:NSValueBinding toObject:m withKeyPath:@"value" options:nil];
    out(@"  value %g", s.doubleValue);
    m.value = 4;
    out(@"  model 4: %g", s.doubleValue);
    s.doubleValue = 6;
    out(@"  set 6: model %g", m.value);
    [s sendAction:NULL to:nil];
    out(@"  sendAction: model %g", m.value);
    m.num = 20;
    [s bind:NSMaxValueBinding toObject:m withKeyPath:@"num" options:nil];
    out(@"  max %g", s.maxValue);
    [s bind:NSMinValueBinding toObject:m withKeyPath:@"value" options:nil];
    out(@"  min %g", s.minValue);

    out(@"view:");
    NSView *v = [NSView new];
    m.flag = YES;
    [v bind:NSHiddenBinding toObject:m withKeyPath:@"flag" options:nil];
    out(@"  hidden %d", v.isHidden);
    v.hidden = NO;
    out(@"  view set: model %d (one-way)", m.flag);
    m.name = @"tip";
    [v bind:NSToolTipBinding toObject:m withKeyPath:@"name" options:nil];
    out(@"  toolTip %@", v.toolTip);
}

#pragma mark - Pop-up buttons

static NSString *
popup(NSPopUpButton *p)
{
    return [NSString stringWithFormat:@"[%@] selected %ld", [p.itemTitles componentsJoinedByString:@","],
                                      (long)p.indexOfSelectedItem];
}

static void
test_popups(void)
{
    out(@"== pop-up buttons");
    NSMutableArray *list = [@[ item(@"a", 1), item(@"b", 2), item(@"c", 3) ] mutableCopy];
    Holder *h = [Holder new];
    h.items = list;
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 20) pullsDown:NO];
    [p bind:NSContentBinding toObject:h withKeyPath:@"items" options:nil];
    out(@"content: %@", popup(p));
    out(@"represented %@", names([p.itemArray valueForKey:@"representedObject"]));
    [p bind:NSContentValuesBinding toObject:h withKeyPath:@"items.name" options:nil];
    out(@"content values: %@", popup(p));
    Item *m = item(@"m", 0);
    [p bind:NSSelectedIndexBinding toObject:m withKeyPath:@"num" options:nil];
    out(@"selected index 0: %@", popup(p));
    m.num = 2;
    out(@"model 2: %@", popup(p));
    [p selectItemAtIndex:1];
    [p sendAction:p.action to:p.target];
    out(@"pick 1: model %ld", (long)m.num);
    [h mutableArrayValueForKey:@"items"][0] = item(@"A", 9);
    out(@"content replaced: %@", popup(p));
    [p unbind:NSSelectedIndexBinding];
    m.obj = nil;
    [p bind:NSSelectedObjectBinding toObject:m withKeyPath:@"obj" options:nil];
    out(@"selected object nil: %@", popup(p));
    m.obj = h.items[2];
    out(@"selected object c: %@", popup(p));
    [p selectItemAtIndex:0];
    [p sendAction:p.action to:p.target];
    out(@"pick 0: model %@", D(m.obj));
    m.obj = @"elsewhere";
    out(@"not there: %@", popup(p));
    m.obj = h.items[1];
    out(@"back: %@", popup(p));
    [p unbind:NSSelectedObjectBinding];
    [p bind:NSSelectedValueBinding toObject:m withKeyPath:@"name" options:nil];
    out(@"selected value m: %@", popup(p));
    m.name = @"c";
    out(@"selected value c: %@", popup(p));
    [p selectItemAtIndex:0];
    [p sendAction:p.action to:p.target];
    out(@"pick 0: model %@", m.name);
    [p unbind:NSSelectedValueBinding];

    NSPopUpButton *q = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 20) pullsDown:NO];
    Item *n = item(@"n", 0);
    n.obj = @[ @"one", @"two", @"three" ];
    [q bind:NSContentBinding toObject:n withKeyPath:@"obj"
         options:@{ NSInsertsNullPlaceholderBindingOption : @YES, NSNullPlaceholderBindingOption : @"--" }];
    out(@"null placeholder: %@", popup(q));
    Holder *hn = [Holder new];
    hn.thing = @0;
    [q bind:NSSelectedIndexBinding toObject:hn withKeyPath:@"thing" options:nil];
    out(@"selected index 0: %@", popup(q));
    n.obj = @[ @4, @5 ];
    out(@"new content: %@", popup(q));
    [q selectItemAtIndex:0];
    [q sendAction:q.action to:q.target];
    out(@"pick placeholder: model %@", D(hn.thing));
    [q unbind:NSContentBinding];
    out(@"unbound content: %@", popup(q));
}

#pragma mark - Text views and editing

static void
test_editing(void)
{
    out(@"== editing");
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 200) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    w.releasedWhenClosed = NO;
    NSObjectController *oc = [[NSObjectController alloc] initWithContent:item(@"start", 1)];
    NSTextField *tf = [NSTextField textFieldWithString:@""];
    tf.frame = NSMakeRect(10, 10, 200, 24);
    [w.contentView addSubview:tf];
    [tf bind:NSValueBinding toObject:oc withKeyPath:@"selection.name" options:nil];
    out(@"field %@ controller editing %d", tf.stringValue, oc.isEditing);
    [w makeFirstResponder:tf];
    NSTextView *fe = (NSTextView *)[w fieldEditor:YES forObject:tf];
    out(@"first responder is the field editor %d; editing %d", w.firstResponder == fe, oc.isEditing);
    [fe insertText:@"X" replacementRange:NSMakeRange(NSNotFound, 0)];
    out(@"typed: model %@ editing %d", [oc.content name], oc.isEditing);
    out(@"commit %d: model %@ editing %d field %@ still editing %d", [oc commitEditing], [oc.content name], oc.isEditing,
        tf.stringValue, w.firstResponder == fe);
    [w makeFirstResponder:tf];
    fe = (NSTextView *)[w fieldEditor:YES forObject:tf];
    [fe insertText:@"Y" replacementRange:NSMakeRange(NSNotFound, 0)];
    out(@"typed: editing %d", oc.isEditing);
    [oc discardEditing];
    out(@"discard: model %@ field %@ editing %d", [oc.content name], tf.stringValue, oc.isEditing);
    [w makeFirstResponder:tf];
    fe = (NSTextView *)[w fieldEditor:YES forObject:tf];
    [fe insertText:@"Z" replacementRange:NSMakeRange(NSNotFound, 0)];
    [fe insertNewline:nil];
    out(@"return: model %@ editing %d", [oc.content name], oc.isEditing);

    NSTextField *t2 = [NSTextField textFieldWithString:@""];
    t2.frame = NSMakeRect(10, 40, 200, 24);
    [w.contentView addSubview:t2];
    [t2 bind:NSValueBinding toObject:oc withKeyPath:@"selection.name" options:@{ NSContinuouslyUpdatesValueBindingOption : @YES }];
    [w makeFirstResponder:t2];
    fe = (NSTextView *)[w fieldEditor:YES forObject:t2];
    [fe insertText:@"Q" replacementRange:NSMakeRange(NSNotFound, 0)];
    out(@"continuous: model %@ other field %@", [oc.content name], tf.stringValue);
    [fe insertText:@"R" replacementRange:NSMakeRange(NSNotFound, 0)];
    out(@"continuous: model %@", [oc.content name]);
    [w makeFirstResponder:nil];
    out(@"ended: editing %d", oc.isEditing);

    out(@"editors:");
    Editor *e = [Editor new];
    [oc objectDidBeginEditing:e];
    [oc objectDidBeginEditing:e];
    out(@"  editing %d", oc.isEditing);
    out(@"  commit %d editing %d", [oc commitEditing], oc.isEditing);
    e.refuse = YES;
    out(@"  refused commit %d", [oc commitEditing]);
    [oc discardEditing];
    out(@"  discard: editing %d", oc.isEditing);
    [oc objectDidBeginEditing:e];
    [oc objectDidEndEditing:e];
    out(@"  ended: editing %d", oc.isEditing);
    out(@"  responds: object %d control %d controller %d", [NSObject instancesRespondToSelector:@selector(commitEditing)],
        [NSControl instancesRespondToSelector:@selector(commitEditing)], [NSController instancesRespondToSelector:@selector(commitEditing)]);

    out(@"text views:");
    Item *m = item(@"tv", 0);
    m.obj = [[NSAttributedString alloc] initWithString:@"attr" attributes:@{}];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    [tv bind:NSAttributedStringBinding toObject:m withKeyPath:@"obj" options:nil];
    out(@"  shows '%@'", tv.string);
    m.obj = [[NSAttributedString alloc] initWithString:@"changed" attributes:@{}];
    out(@"  model changed '%@'", tv.string);
    [tv insertText:@"+" replacementRange:NSMakeRange(0, 0)];
    out(@"  typed (not first responder): model %@", D(m.obj));
    [w.contentView addSubview:tv];
    [w makeFirstResponder:tv];
    [tv insertText:@"+" replacementRange:NSMakeRange(0, 0)];
    out(@"  typed (first responder): model %@", D(m.obj));
    [w makeFirstResponder:nil];
    out(@"  resigned: model %@", D(m.obj));
    NSTextView *t5 = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    [t5 bind:NSAttributedStringBinding toObject:m withKeyPath:@"obj" options:@{ NSContinuouslyUpdatesValueBindingOption : @YES }];
    [w.contentView addSubview:t5];
    [w makeFirstResponder:t5];
    [t5 insertText:@"#" replacementRange:NSMakeRange(0, 0)];
    out(@"  continuous: model %@ other '%@'", D(m.obj), tv.string);
    [w makeFirstResponder:nil];
    m.obj = @"plain";
    out(@"  plain string '%@'", tv.string);
    DO([tv bind:NSValueBinding toObject:m withKeyPath:@"name" options:nil]);
}

#pragma mark - Controllers

static void
test_object_controller(void)
{
    out(@"== object controller");
    NSObjectController *oc = [NSObjectController new];
    out(@"new: content %@ selected [%@] objectClass %@ editable %d canAdd %d canRemove %d prepares %d editing %d",
        D(oc.content), names(oc.selectedObjects), oc.objectClass, oc.isEditable, oc.canAdd, oc.canRemove,
        oc.automaticallyPreparesContent, oc.isEditing);
    out(@"selection name %@ same proxy %d", [oc valueForKeyPath:@"selection.name"], oc.selection == oc.selection);
    Item *a = item(@"a", 1);
    oc.content = a;
    out(@"content a: name %@ value %@ selected [%@] canAdd %d canRemove %d", [oc valueForKeyPath:@"selection.name"],
        [oc valueForKeyPath:@"selection.value"], names(oc.selectedObjects), oc.canAdd, oc.canRemove);
    [oc setValue:@"b" forKeyPath:@"selection.name"];
    out(@"set through selection: model %@", a.name);
    DO([oc valueForKeyPath:@"selection.nokey"]);
    Recorder *r = [Recorder new];
    [oc addObserver:r forKeyPath:@"selection.name" options:0 context:NULL];
    [oc addObserver:r forKeyPath:@"content" options:0 context:NULL];
    [oc addObserver:r forKeyPath:@"canRemove" options:0 context:NULL];
    a.name = @"c";
    out(@"model changed: %@", [r take]);
    oc.content = item(@"d", 2);
    out(@"content changed: %@", [r take]);
    Item *gone = oc.content;
    gone.name = @"gone";
    out(@"old content changed: %@", [r take]);
    id o = [oc newObject];
    out(@"newObject %@ empty %d", [o class] == [NSMutableDictionary class] || [o isKindOfClass:[NSMutableDictionary class]] ? @"dictionary" : @"other", [o count] == 0);
    oc.objectClass = [Item class];
    out(@"newObject %@", D([oc newObject]));
    [oc remove:nil];
    out(@"remove: content %@ (deferred)", D(oc.content));
    spin();
    out(@"after the run loop: content %@ %@", D(oc.content), [r take]);
    [oc add:nil];
    out(@"add: content %@ (deferred)", D(oc.content));
    spin();
    out(@"after the run loop: content %@ %@", D(oc.content), [r take]);
    [oc removeObserver:r forKeyPath:@"selection.name"];
    [oc removeObserver:r forKeyPath:@"content"];
    [oc removeObserver:r forKeyPath:@"canRemove"];
    NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:@"add" action:@selector(add:) keyEquivalent:@""];
    NSMenuItem *rem = [[NSMenuItem alloc] initWithTitle:@"remove" action:@selector(remove:) keyEquivalent:@""];
    NSMenuItem *other = [[NSMenuItem alloc] initWithTitle:@"other" action:@selector(other:) keyEquivalent:@""];
    out(@"validate: add %d remove %d other %d", [oc validateUserInterfaceItem:add], [oc validateUserInterfaceItem:rem],
        [oc validateUserInterfaceItem:other]);
    oc.content = nil;
    out(@"no content: add %d remove %d", [oc validateUserInterfaceItem:add], [oc validateUserInterfaceItem:rem]);
    oc.editable = NO;
    out(@"not editable: canAdd %d canRemove %d validate add %d", oc.canAdd, oc.canRemove, [oc validateUserInterfaceItem:add]);
    NSObjectController *p = [NSObjectController new];
    [p prepareContent];
    out(@"prepared: %@", [p.content isKindOfClass:[NSMutableDictionary class]] ? @"dictionary" : D(p.content));
    NSObjectController *init = [[NSObjectController alloc] initWithContent:@"x"];
    out(@"initWithContent: %@ editable %d", D(init.content), init.isEditable);

    out(@"bound content:");
    Holder *h = [Holder new];
    h.thing = item(@"held", 5);
    NSObjectController *bc = [NSObjectController new];
    bc.objectClass = [Item class];
    [bc bind:NSContentObjectBinding toObject:h withKeyPath:@"thing" options:nil];
    out(@"  content %@", D(bc.content));
    h.thing = item(@"held2", 6);
    out(@"  model changed: %@", D(bc.content));
    [bc remove:nil];
    spin();
    out(@"  removed: model %@", D(h.thing));
    [bc add:nil];
    spin();
    out(@"  added: model %@ same %d", D(h.thing), h.thing == bc.content);

    out(@"bound fields with markers:");
    NSTextField *tf = [NSTextField textFieldWithString:@""];
    [tf bind:NSValueBinding toObject:bc withKeyPath:@"selection.name" options:nil];
    out(@"  %@", field(tf));
    bc.content = nil;
    out(@"  no selection: %@", field(tf));
    bc.content = item(@"back", 0);
    out(@"  back: %@", field(tf));
}

static NSString *
ac_state(NSArrayController *ac)
{
    return [NSString stringWithFormat:@"arranged [%@] selection %@", names(ac.arrangedObjects), D(ac.selectionIndexes)];
}

static void
test_array_controller(void)
{
    out(@"== array controller");
    NSArrayController *ac = [NSArrayController new];
    out(@"new: avoids %d preserves %d selectsInserted %d clearsFilter %d autoRearranges %d alwaysMultiple %d content %@ "
        @"arranged [%@] index %ld selection.name %@ objectClass %@ keys %@",
        ac.avoidsEmptySelection, ac.preservesSelection, ac.selectsInsertedObjects, ac.clearsFilterPredicateOnInsertion,
        ac.automaticallyRearrangesObjects, ac.alwaysUsesMultipleValuesMarker, D(ac.content), names(ac.arrangedObjects),
        (long)ac.selectionIndex, [ac valueForKeyPath:@"selection.name"], ac.objectClass, D(ac.automaticRearrangementKeyPaths));
    NSMutableArray *arr = [@[ item(@"x", 3), item(@"y", 1), item(@"z", 2) ] mutableCopy];
    ac.content = arr;
    out(@"content: same %d %@ count %@", ac.content == arr, ac_state(ac), [ac valueForKeyPath:@"arrangedObjects.@count"]);
    out(@"selection.name %@ selected [%@]", [ac valueForKeyPath:@"selection.name"], names(ac.selectedObjects));
    out(@"arrangedObjects.name %@", D([ac valueForKeyPath:@"arrangedObjects.name"]));
    [ac setSelectionIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
    out(@"two selected: name %@ value %@", [ac valueForKeyPath:@"selection.name"], [ac valueForKeyPath:@"selection.value"]);
    [ac setValue:@"same" forKeyPath:@"selection.name"];
    out(@"set both: %@ name %@", names(ac.arrangedObjects), [ac valueForKeyPath:@"selection.name"]);
    ac.alwaysUsesMultipleValuesMarker = YES;
    out(@"always multiple: %@", [ac valueForKeyPath:@"selection.name"]);
    ac.alwaysUsesMultipleValuesMarker = NO;
    ((Item *)arr[0]).name = @"x";
    ((Item *)arr[1]).name = @"y";
    out(@"set empty: %d %@", [ac setSelectionIndexes:[NSIndexSet indexSet]], ac_state(ac));
    out(@"no selection: name %@ index %ld canRemove %d", [ac valueForKeyPath:@"selection.name"], (long)ac.selectionIndex,
        ac.canRemove);
    ac.avoidsEmptySelection = NO;
    ac.avoidsEmptySelection = YES;
    out(@"avoids again: %@", ac_state(ac));
    [ac setSelectionIndex:1];
    ac.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"value" ascending:YES] ];
    out(@"sorted: %@ content [%@]", ac_state(ac), names(ac.content));
    ac.filterPredicate = [NSPredicate predicateWithFormat:@"value > 1"];
    out(@"filtered: %@", ac_state(ac));
    [ac setSelectionIndex:5];
    out(@"select 5: %@", ac_state(ac));
    [ac addObject:item(@"w", 0)];
    out(@"add non-matching: %@ content [%@] filter %@", ac_state(ac), names(ac.content), D(ac.filterPredicate));
    ac.filterPredicate = [NSPredicate predicateWithFormat:@"value > 1"];
    [ac insertObject:item(@"v", 9) atArrangedObjectIndex:0];
    out(@"insert at 0: %@ content [%@] filter %@", ac_state(ac), names(ac.content), D(ac.filterPredicate));
    ac.clearsFilterPredicateOnInsertion = NO;
    ac.filterPredicate = [NSPredicate predicateWithFormat:@"value > 1"];
    [ac insertObject:item(@"u", 8) atArrangedObjectIndex:1];
    out(@"insert keeping the filter: %@ content [%@]", ac_state(ac), names(ac.content));
    ac.filterPredicate = nil;
    out(@"unfiltered: %@", ac_state(ac));
    [ac setSelectionIndexes:[NSIndexSet indexSetWithIndex:2]];
    [ac removeObjectAtArrangedObjectIndex:2];
    out(@"remove selected: %@", ac_state(ac));
    out(@"setSelectedObjects %d: %@", [ac setSelectedObjects:@[ ac.arrangedObjects[3] ]], ac_state(ac));
    out(@"can: next %d previous %d insert %d add %d remove %d", ac.canSelectNext, ac.canSelectPrevious, ac.canInsert,
        ac.canAdd, ac.canRemove);
    [ac selectNext:nil];
    out(@"selectNext: %@ (deferred)", D(ac.selectionIndexes));
    spin();
    out(@"after the run loop: %@", D(ac.selectionIndexes));
    [ac selectPrevious:nil];
    spin();
    out(@"selectPrevious: %@", D(ac.selectionIndexes));
    ac.objectClass = [Item class];
    [ac add:nil];
    out(@"add: count %lu (deferred)", (unsigned long)[ac.arrangedObjects count]);
    spin();
    out(@"after the run loop: %@", ac_state(ac));
    [ac insert:nil];
    spin();
    out(@"insert: %@", ac_state(ac));
    [ac remove:nil];
    spin();
    out(@"remove: %@", ac_state(ac));
    out(@"content is the same array %d: [%@]", ac.content == arr, names(arr));
    ac.preservesSelection = NO;
    [ac setSelectionIndex:1];
    ac.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:NO] ];
    out(@"not preserving: %@", ac_state(ac));
    ac.preservesSelection = YES;
    [ac setSelectionIndex:1];
    NSArray *before = ac.selectedObjects;
    ac.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
    out(@"preserving: %@ same objects %d", ac_state(ac), [ac.selectedObjects isEqual:before]);
    ac.content = @[ item(@"p", 1), item(@"q", 2) ];
    out(@"new content: %@", ac_state(ac));
    ac.content = nil;
    out(@"nil content: %@ name %@", ac_state(ac), [ac valueForKeyPath:@"selection.name"]);

    out(@"more:");
    NSArrayController *b = [[NSArrayController alloc] initWithContent:@[ item(@"a", 1), item(@"b", 2), item(@"c", 3) ]];
    out(@"  initWithContent: %@", ac_state(b));
    b.content = [@[ item(@"a", 1), item(@"b", 2), item(@"c", 3) ] mutableCopy];
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(add:) keyEquivalent:@""];
    out(@"  validate add %d", [b validateUserInterfaceItem:mi]);
    mi.action = @selector(remove:);
    out(@"  validate remove %d", [b validateUserInterfaceItem:mi]);
    mi.action = @selector(insert:);
    out(@"  validate insert %d", [b validateUserInterfaceItem:mi]);
    mi.action = @selector(selectNext:);
    out(@"  validate selectNext %d", [b validateUserInterfaceItem:mi]);
    mi.action = @selector(selectPrevious:);
    out(@"  validate selectPrevious %d", [b validateUserInterfaceItem:mi]);
    [b setSelectionIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 3)]];
    [b removeObjectsAtArrangedObjectIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
    out(@"  remove 0-1 of all selected: %@", ac_state(b));
    out(@"  addSelectionIndexes 7: %d %@", [b addSelectionIndexes:[NSIndexSet indexSetWithIndex:7]], D(b.selectionIndexes));
    [b addObjects:@[ item(@"d", 4), item(@"e", 5) ]];
    out(@"  addObjects: %@", ac_state(b));
    b.selectsInsertedObjects = NO;
    [b addObject:item(@"f", 6)];
    out(@"  not selecting inserted: %@", ac_state(b));
    [b removeObject:b.arrangedObjects[1]];
    out(@"  removeObject: %@", ac_state(b));
    [b removeSelectedObjects:b.selectedObjects];
    out(@"  removeSelectedObjects: %@", ac_state(b));
    [b addSelectedObjects:@[ b.arrangedObjects[0] ]];
    out(@"  addSelectedObjects: %@", ac_state(b));
    [b removeSelectionIndexes:[NSIndexSet indexSetWithIndex:0]];
    out(@"  removeSelectionIndexes: %@", ac_state(b));
    b.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"value" ascending:NO] ];
    out(@"  descending: %@ keys %@", ac_state(b), D(b.automaticRearrangementKeyPaths));
    b.automaticallyRearrangesObjects = YES;
    b.filterPredicate = [NSPredicate predicateWithFormat:@"name != 'zz' AND value < 100"];
    out(@"  rearranging keys %@", D(b.automaticRearrangementKeyPaths));
    ((Item *)b.arrangedObjects[0]).value = -1;
    out(@"  value changed: %@", ac_state(b));
    ((Item *)b.arrangedObjects[0]).name = @"zz";
    out(@"  filtered out: %@", ac_state(b));

    out(@"observing:");
    NSArrayController *c = [[NSArrayController alloc] initWithContent:[@[ item(@"a", 1), item(@"b", 2) ] mutableCopy]];
    Recorder *r = [Recorder new];
    for (NSString *k in @[ @"arrangedObjects", @"selectionIndexes", @"selection.name", @"arrangedObjects.name", @"canRemove",
                           @"selectedObjects", @"content" ])
        [c addObserver:r forKeyPath:k options:0 context:NULL];
    ((Item *)c.arrangedObjects[1]).name = @"B";
    out(@"  unselected object renamed: %@", [r take]);
    ((Item *)c.arrangedObjects[0]).name = @"A";
    out(@"  selected object renamed: %@", [r take]);
    [c setSelectionIndex:1];
    out(@"  selection changed: %@", [r take]);
    [c addObject:item(@"c", 3)];
    out(@"  added: %@", [r take]);
    c.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"value" ascending:NO] ];
    out(@"  sorted: %@", [r take]);
    for (NSString *k in @[ @"arrangedObjects", @"selectionIndexes", @"selection.name", @"arrangedObjects.name", @"canRemove",
                           @"selectedObjects", @"content" ])
        [c removeObserver:r forKeyPath:k];

    out(@"bindings:");
    Holder *h = [Holder new];
    h.items = [@[ item(@"one", 1), item(@"two", 2), item(@"three", 3) ] mutableCopy];
    h.picked = [NSIndexSet indexSetWithIndex:1];
    NSArrayController *d = [NSArrayController new];
    d.objectClass = [Item class];
    [d bind:NSContentArrayBinding toObject:h withKeyPath:@"items" options:nil];
    out(@"  content array: %@", ac_state(d));
    [d bind:NSSelectionIndexesBinding toObject:h withKeyPath:@"picked" options:nil];
    out(@"  selection indexes: %@ model %@", ac_state(d), D(h.picked));
    [d setSelectionIndex:2];
    out(@"  selected 2: model %@", D(h.picked));
    h.picked = [NSIndexSet indexSetWithIndex:0];
    out(@"  model picked 0: %@", ac_state(d));
    [d addObject:item(@"four", 4)];
    out(@"  added: model items [%@] picked %@", names(h.items), D(h.picked));
    [[h mutableArrayValueForKey:@"items"] removeObjectAtIndex:0];
    out(@"  model removed: %@", ac_state(d));
    h.sorts = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
    [d bind:NSSortDescriptorsBinding toObject:h withKeyPath:@"sorts" options:nil];
    out(@"  sort descriptors: %@", ac_state(d));
    d.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"value" ascending:NO] ];
    out(@"  set on controller: model %@", [[h.sorts firstObject] key]);
    NSTextField *count = [NSTextField labelWithString:@""];
    [count bind:NSValueBinding toObject:d withKeyPath:@"arrangedObjects.@count" options:nil];
    out(@"  count field %@", count.stringValue);
    [d addObject:item(@"five", 5)];
    out(@"  count field %@", count.stringValue);
    NSTextField *name = [NSTextField textFieldWithString:@""];
    [name bind:NSValueBinding toObject:d withKeyPath:@"selection.name" options:nil];
    out(@"  name field %@", field(name));
    [d setSelectionIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
    out(@"  two selected: %@", field(name));
    [d setSelectionIndexes:[NSIndexSet indexSet]];
    out(@"  none selected: %@", field(name));
    [d setSelectionIndex:0];
    out(@"  one selected: %@", field(name));
    NSButton *cb = [NSButton checkboxWithTitle:@"flag" target:nil action:nil];
    [cb bind:NSValueBinding toObject:d withKeyPath:@"selection.flag" options:nil];
    [d setSelectionIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
    ((Item *)d.arrangedObjects[0]).flag = YES;
    out(@"  checkbox multiple: state %ld enabled %d mixed %d", (long)cb.state, cb.isEnabled, cb.allowsMixedState);
    [cb performClick:nil];
    out(@"  click: state %ld flags %d %d", (long)cb.state, ((Item *)d.arrangedObjects[0]).flag, ((Item *)d.arrangedObjects[1]).flag);
    [d setSelectionIndexes:[NSIndexSet indexSet]];
    out(@"  checkbox none: state %ld enabled %d", (long)cb.state, cb.isEnabled);
    NSTextField *t2 = [NSTextField textFieldWithString:@""];
    [t2 bind:NSValueBinding toObject:d withKeyPath:@"selection.name"
          options:@{ NSNoSelectionPlaceholderBindingOption : @"NOSEL", NSConditionallySetsEditableBindingOption : @NO,
                     NSConditionallySetsEnabledBindingOption : @YES }];
    out(@"  own placeholder: %@", field(t2));
    [NSTextField setDefaultPlaceholder:@"DEF" forMarker:NSNoSelectionMarker withBinding:NSValueBinding];
    out(@"  default placeholder %@ on NSControl %@", [NSTextField defaultPlaceholderForMarker:NSNoSelectionMarker withBinding:NSValueBinding],
        [NSControl defaultPlaceholderForMarker:NSNoSelectionMarker withBinding:NSValueBinding]);
    NSTextField *t3 = [NSTextField textFieldWithString:@""];
    [t3 bind:NSValueBinding toObject:d withKeyPath:@"selection.name" options:nil];
    out(@"  default placeholder: %@ info %@", field(t3), [t3 infoForBinding:NSValueBinding][NSOptionsKey][NSNoSelectionPlaceholderBindingOption]);
    [NSTextField setDefaultPlaceholder:nil forMarker:NSNoSelectionMarker withBinding:NSValueBinding];
    out(@"  built-in placeholders: %@ / %@ / %@", [NSTextField defaultPlaceholderForMarker:NSMultipleValuesMarker withBinding:NSValueBinding],
        [NSTextField defaultPlaceholderForMarker:nil withBinding:NSValueBinding],
        [NSBindingSelectionMarker defaultPlaceholderForMarker:NSBindingSelectionMarker.noSelectionMarker onClass:[NSSlider class]
                                                  withBinding:NSValueBinding]);
    [NSBindingSelectionMarker setDefaultPlaceholder:@"slider none" forMarker:NSBindingSelectionMarker.noSelectionMarker
                                            onClass:[NSSlider class] withBinding:NSValueBinding];
    out(@"  set on a class: %@", [NSSlider defaultPlaceholderForMarker:NSNoSelectionMarker withBinding:NSValueBinding]);
    [NSBindingSelectionMarker setDefaultPlaceholder:nil forMarker:NSBindingSelectionMarker.noSelectionMarker
                                            onClass:[NSSlider class] withBinding:NSValueBinding];
}

#pragma mark - User defaults

static void
test_defaults(void)
{
    out(@"== user defaults controller");
    NSUserDefaultsController *s = [NSUserDefaultsController sharedUserDefaultsController];
    out(@"shared: same %d standard %d applies %d initial %@ unapplied %d", s == [NSUserDefaultsController sharedUserDefaultsController],
        s.defaults == [NSUserDefaults standardUserDefaults], s.appliesImmediately, D(s.initialValues), s.hasUnappliedChanges);
    NSString *suite = @"org.finch.bindings-test";
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [d removePersistentDomainForName:suite];
    [d registerDefaults:@{ @"reg" : @"registered" }];
    NSUserDefaultsController *c = [[NSUserDefaultsController alloc] initWithDefaults:d initialValues:@{ @"name" : @"init", @"n" : @5 }];
    out(@"values: same %d name %@ n %@ reg %@ missing %@", c.values == c.values, [c.values valueForKey:@"name"],
        [c.values valueForKey:@"n"], [c.values valueForKey:@"reg"], D([c.values valueForKey:@"missing"]));
    out(@"key path: %@", [c valueForKeyPath:@"values.name"]);
    Recorder *r = [Recorder new];
    [c addObserver:r forKeyPath:@"values.name" options:0 context:NULL];
    [c setValue:@"set" forKeyPath:@"values.name"];
    out(@"set: defaults %@ values %@ unapplied %d %@", [d objectForKey:@"name"], [c valueForKeyPath:@"values.name"],
        c.hasUnappliedChanges, [r take]);
    [d setObject:@"direct" forKey:@"name"];
    out(@"set in the defaults: values %@ %@", [c valueForKeyPath:@"values.name"], [r take]);
    c.appliesImmediately = NO;
    [c setValue:@"pending" forKeyPath:@"values.name"];
    out(@"pending: defaults %@ values %@ unapplied %d %@", [d objectForKey:@"name"], [c valueForKeyPath:@"values.name"],
        c.hasUnappliedChanges, [r take]);
    [c revert:nil];
    spin();
    out(@"revert: defaults %@ values %@ %@", [d objectForKey:@"name"], [c valueForKeyPath:@"values.name"], [r take]);
    [c setValue:@"pending2" forKeyPath:@"values.name"];
    [c save:nil];
    out(@"save: defaults %@ (deferred)", [d objectForKey:@"name"]);
    spin();
    out(@"after the run loop: defaults %@ values %@", [d objectForKey:@"name"], [c valueForKeyPath:@"values.name"]);
    [r take];
    [c revertToInitialValues:nil];
    spin();
    out(@"revert to initial: defaults %@ values %@ n %@ %@", [d objectForKey:@"name"], [c valueForKeyPath:@"values.name"],
        D([d objectForKey:@"n"]), [r take]);
    [c save:nil];
    spin();
    out(@"save: defaults %@ n %@", [d objectForKey:@"name"], [d objectForKey:@"n"]);
    c.appliesImmediately = YES;
    [d setObject:@"other" forKey:@"name"];
    [c revertToInitialValues:nil];
    spin();
    out(@"revert to initial, applying: defaults %@ values %@", [d objectForKey:@"name"], [c valueForKeyPath:@"values.name"]);
    NSTextField *tf = [NSTextField textFieldWithString:@""];
    [tf bind:NSValueBinding toObject:c withKeyPath:@"values.name" options:nil];
    out(@"field %@", tf.stringValue);
    [c setValue:@"via controller" forKeyPath:@"values.name"];
    out(@"field %@", tf.stringValue);
    [d setObject:@"via defaults" forKey:@"name"];
    out(@"field %@", tf.stringValue);
    NSButton *cb = [NSButton checkboxWithTitle:@"b" target:nil action:nil];
    [cb bind:NSValueBinding toObject:c withKeyPath:@"values.check" options:nil];
    [cb performClick:nil];
    out(@"checkbox: defaults %@", D([d objectForKey:@"check"]));
    [tf unbind:NSValueBinding];
    [cb unbind:NSValueBinding];
    [c removeObserver:r forKeyPath:@"values.name"];
    out(@"initial nil: %@", D([[[NSUserDefaultsController alloc] initWithDefaults:d initialValues:nil] initialValues]));
    [d removePersistentDomainForName:suite];
}

#pragma mark - The nib

@interface Owner : NSObject
@property (strong) IBOutlet NSObjectController *objectController;
@property (strong) IBOutlet NSArrayController *arrayController;
@property (strong) IBOutlet NSUserDefaultsController *defaultsController;
@property (strong) IBOutlet NSTextField *nameField, *greeting, *countField;
@property (strong) IBOutlet NSButton *check;
@property (strong) IBOutlet NSPopUpButton *popup;
@property (strong) IBOutlet NSSlider *slider;
@property (strong) IBOutlet NSWindow *window;
@property (strong) Item *model;
@property (strong) NSMutableArray *items;
@property (strong) NSArray *sorts;
@end
@implementation Owner
@end

static void
test_nib(NSString *path)
{
    out(@"== nib");
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"FinchBindingsTestGreeting" : @"hello from the registration domain",
        @"FinchBindingsTestHidden" : @NO
    }];
    Owner *owner = [Owner new];
    owner.model = item(@"nib model", 0);
    owner.items = [@[ item(@"pear", 30), item(@"apple", 10), item(@"fig", 20) ] mutableCopy];
    owner.sorts = @[ [NSSortDescriptor sortDescriptorWithKey:@"value" ascending:YES] ];
    NSNib *nib = [[NSNib alloc] initWithNibData:[NSData dataWithContentsOfFile:path] bundle:nil];
    NSArray *top = nil;
    out(@"instantiated %d", [nib instantiateWithOwner:owner topLevelObjects:&top]);
    NSObjectController *oc = owner.objectController;
    NSArrayController *ac = owner.arrayController;
    out(@"object controller: content %@ editable %d objectClass %@ prepares %d", D(oc.content), oc.isEditable, oc.objectClass,
        oc.automaticallyPreparesContent);
    out(@"array controller: %@ avoids %d preserves %d selectsInserted %d clearsFilter %d autoRearranges %d objectClass %@",
        ac_state(ac), ac.avoidsEmptySelection, ac.preservesSelection, ac.selectsInsertedObjects,
        ac.clearsFilterPredicateOnInsertion, ac.automaticallyRearrangesObjects, ac.objectClass);
    out(@"defaults controller shared %d", owner.defaultsController == [NSUserDefaultsController sharedUserDefaultsController]);
    NSDictionary *info = [owner.nameField infoForBinding:NSValueBinding];
    out(@"name field: %@ toolTip %@ bound to controller %d %@ options %@", field(owner.nameField), owner.nameField.toolTip,
        info[NSObservedObjectKey] == oc, info[NSObservedKeyPathKey], O(info[NSOptionsKey]));
    out(@"check: state %ld", (long)owner.check.state);
    out(@"popup: %@", popup(owner.popup));
    out(@"greeting: %@ hidden %d", owner.greeting.stringValue, owner.greeting.isHidden);
    out(@"slider: value %g enabled %d info %@", owner.slider.doubleValue, owner.slider.isEnabled,
        O([owner.slider infoForBinding:NSEnabledBinding][NSOptionsKey]));
    out(@"count: %@", owner.countField.stringValue);
    owner.model.name = nil;
    out(@"model name nil: %@", field(owner.nameField));
    owner.model = nil;
    out(@"no model: %@ check enabled %d", field(owner.nameField), owner.check.isEnabled);
    owner.model = item(@"another", 0);
    owner.model.flag = YES;
    out(@"another model: %@ check %ld slider enabled %d", field(owner.nameField), (long)owner.check.state, owner.slider.isEnabled);
    [ac setSelectionIndex:2];
    out(@"select 2: popup %@ slider %g", popup(owner.popup), owner.slider.doubleValue);
    [owner.popup selectItemAtIndex:0];
    [owner.popup sendAction:owner.popup.action to:owner.popup.target];
    out(@"pick 0: %@", ac_state(ac));
    ((Item *)owner.items[0]).value = 5;
    out(@"rearranged: %@ popup %@", ac_state(ac), popup(owner.popup));
    [ac addObject:item(@"kiwi", 1)];
    out(@"added: items [%@] count %@ popup %@", names(owner.items), owner.countField.stringValue, popup(owner.popup));
    owner.slider.doubleValue = 77;
    [owner.slider sendAction:owner.slider.action to:owner.slider.target];
    out(@"slid: selection value %@", [ac valueForKeyPath:@"selection.value"]);
    owner.sorts = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
    out(@"sorted by name: %@", ac_state(ac));
    for (id o in top)
        if ([o isKindOfClass:[NSWindow class]])
            [o close];
}

#pragma mark - Fonts

@interface FontTarget : NSResponder
@end
@implementation FontTarget
- (void)changeFont:(id)sender
{
    NSFont *f = [sender convertFont:[NSFont fontWithName:@"LiberationSans" size:12]];
    out(@"  changeFont: from %@ action %lu -> %@ %g", [sender className], (unsigned long)[sender currentFontAction], f.fontName,
        f.pointSize);
}
@end

static NSString *
member_desc(NSArray *m)
{
    return [NSString stringWithFormat:@"%@|%@|%@|%lx", m[0], m[1], m[2], (unsigned long)[m[3] unsignedLongValue]];
}

static void
test_fonts(NSString *dir)
{
    out(@"== fonts");
    /* Apple's host doesn't have Finch's fonts: register them from the build (Finch has them installed) */
    if (![NSFont fontWithName:@"Inter-Regular" size:12] || ![[NSFont fontWithName:@"Inter-Regular" size:12].fontName isEqualToString:@"Inter-Regular"]) {
        for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL])
            if ([n hasPrefix:@"Inter"] || [n hasPrefix:@"LiberationSans"])
                CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:n]],
                                                 kCTFontManagerScopeProcess, NULL);
    }
    NSFontManager *fm = [NSFontManager sharedFontManager];
    out(@"shared same %d class %@ enabled %d action %@ target %@ selected %@ multiple %d delegate %@", fm == [NSFontManager sharedFontManager],
        [fm className], fm.isEnabled, NSStringFromSelector(fm.action), fm.target, fm.selectedFont, fm.isMultiple, fm.delegate);
    out(@"has fonts %d %d families %d %d", [fm.availableFonts containsObject:@"LiberationSans-Bold"], [fm.availableFonts containsObject:@"Inter-Black"],
        [fm.availableFontFamilies containsObject:@"Liberation Sans"], [fm.availableFontFamilies containsObject:@"Inter"]);
    out(@"fonts sorted %d", [fm.availableFonts isEqualToArray:[fm.availableFonts sortedArrayUsingSelector:@selector(compare:)]]);
    for (NSArray *m in [fm availableMembersOfFontFamily:@"Liberation Sans"])
        out(@"  Liberation Sans: %@", member_desc(m));
    for (NSArray *m in [fm availableMembersOfFontFamily:@"Inter"])
        if (![m[0] isEqualToString:@"Inter-LightItalic"])
            out(@"  Inter: %@", member_desc(m));
    out(@"no such family: %@", [fm availableMembersOfFontFamily:@"Nope Family"]);
    NSFont *r = [NSFont fontWithName:@"LiberationSans" size:12];
    out(@"regular %@ traits %lx weight %ld", r.fontName, (unsigned long)[fm traitsOfFont:r], (long)[fm weightOfFont:r]);
    NSFont *b = [fm convertFont:r toHaveTrait:NSBoldFontMask];
    out(@"+bold %@ traits %lx weight %ld", b.fontName, (unsigned long)[fm traitsOfFont:b], (long)[fm weightOfFont:b]);
    NSFont *bi = [fm convertFont:b toHaveTrait:NSItalicFontMask];
    out(@"+italic %@ traits %lx", bi.fontName, (unsigned long)[fm traitsOfFont:bi]);
    out(@"-bold %@ -italic %@ +unbold %@ +unitalic %@", [fm convertFont:bi toNotHaveTrait:NSBoldFontMask].fontName,
        [fm convertFont:bi toNotHaveTrait:NSItalicFontMask].fontName, [fm convertFont:bi toHaveTrait:NSUnboldFontMask].fontName,
        [fm convertFont:bi toHaveTrait:NSUnitalicFontMask].fontName);
    out(@"-bold of regular %@ +bold of bold %@", [fm convertFont:r toNotHaveTrait:NSBoldFontMask].fontName,
        [fm convertFont:b toHaveTrait:NSBoldFontMask].fontName);
    NSFont *big = [fm convertFont:r toSize:30];
    out(@"size %@ %g", big.fontName, big.pointSize);
    out(@"to family Inter %@; nope %@", [fm convertFont:bi toFamily:@"Inter"].fontName, [fm convertFont:bi toFamily:@"Nope"].fontName);
    out(@"to face %@ / nope %@", [fm convertFont:r toFace:@"LiberationSans-BoldItalic"].fontName, [fm convertFont:r toFace:@"Nope"].fontName);
    out(@"heavier %@ lighter %@ lighter of regular %@", [fm convertWeight:YES ofFont:r].fontName, [fm convertWeight:NO ofFont:b].fontName,
        [fm convertWeight:NO ofFont:r].fontName);
    for (NSString *n in @[ @"Inter-Regular", @"Inter-Thin", @"Inter-Light", @"Inter-Medium", @"Inter-SemiBold", @"Inter-Bold",
                           @"Inter-ExtraBold", @"Inter-Black", @"Inter-Italic", @"Inter-BoldItalic" ]) {
        NSFont *f = [NSFont fontWithName:n size:12];
        out(@"  %@ weight %ld traits %lx", f.fontName, (long)[fm weightOfFont:f], (unsigned long)[fm traitsOfFont:f]);
    }
    NSFont *f = [NSFont fontWithName:@"Inter-Regular" size:12];
    NSMutableArray *chain = [NSMutableArray array];
    for (int i = 0; i < 6; i++) {
        f = [fm convertWeight:YES ofFont:f];
        [chain addObject:f.fontName];
    }
    out(@"heavier from Inter-Regular: %@", [chain componentsJoinedByString:@" "]);
    [chain removeAllObjects];
    for (int i = 0; i < 4; i++) {
        f = [fm convertWeight:NO ofFont:f];
        [chain addObject:f.fontName];
    }
    out(@"lighter from Inter-Black: %@", [chain componentsJoinedByString:@" "]);
    out(@"lighter from Inter-Regular: %@", [fm convertWeight:NO ofFont:[NSFont fontWithName:@"Inter-Regular" size:12]].fontName);
    for (int w = 4; w <= 15; w++)
        out(@"  family Inter weight %d: %@ bold %@ italic %@ | Liberation %@ italic %@", w,
            [fm fontWithFamily:@"Inter" traits:0 weight:w size:11].fontName,
            [fm fontWithFamily:@"Inter" traits:NSBoldFontMask weight:w size:11].fontName,
            w >= 5 ? [fm fontWithFamily:@"Inter" traits:NSItalicFontMask weight:w size:11].fontName : @"-",
            [fm fontWithFamily:@"Liberation Sans" traits:0 weight:w size:11].fontName,
            [fm fontWithFamily:@"Liberation Sans" traits:NSItalicFontMask weight:w size:11].fontName);
    out(@"family Inter weight 0: %@ bold %@; size %g; nope %@", [fm fontWithFamily:@"Inter" traits:0 weight:0 size:11].fontName,
        [fm fontWithFamily:@"Inter" traits:NSBoldFontMask weight:0 size:11].fontName,
        [fm fontWithFamily:@"Inter" traits:0 weight:5 size:17].pointSize, [fm fontWithFamily:@"Nope" traits:0 weight:5 size:11]);
    for (NSString *n in @[ @"Inter-Thin", @"Inter-Medium", @"Inter-SemiBold", @"Inter-ExtraBold", @"Inter-Black", @"Inter-MediumItalic" ]) {
        NSFont *g = [NSFont fontWithName:n size:12];
        out(@"  %@: +bold %@ -bold %@ +italic %@ -italic %@", n, [fm convertFont:g toHaveTrait:NSBoldFontMask].fontName,
            [fm convertFont:g toNotHaveTrait:NSBoldFontMask].fontName, [fm convertFont:g toHaveTrait:NSItalicFontMask].fontName,
            [fm convertFont:g toNotHaveTrait:NSItalicFontMask].fontName);
    }
    for (NSString *n in @[ @"Inter-Bold", @"Inter-SemiBoldItalic", @"LiberationSans-BoldItalic", @"Inter-Thin" ]) {
        NSFont *g = [NSFont fontWithName:n size:12];
        out(@"  %@: to Liberation Sans %@, to Inter %@, to face Inter-Medium %@", n, [fm convertFont:g toFamily:@"Liberation Sans"].fontName,
            [fm convertFont:g toFamily:@"Inter"].fontName, [fm convertFont:g toFace:@"Inter-Medium"].fontName);
    }
    NSPredicate *ours = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'Inter' OR SELF BEGINSWITH 'LiberationSans'"];
    out(@"with bold: %@", [[[fm availableFontNamesWithTraits:NSBoldFontMask] filteredArrayUsingPredicate:ours] componentsJoinedByString:@","]);
    out(@"with bold italic: %@", [[[fm availableFontNamesWithTraits:NSBoldFontMask | NSItalicFontMask] filteredArrayUsingPredicate:ours]
                                     componentsJoinedByString:@","]);
    out(@"with unbold: %lu", (unsigned long)[[fm availableFontNamesWithTraits:NSUnboldFontMask] count]);
    out(@"has traits %d %d %d %d", [fm fontNamed:@"Inter-SemiBold" hasTraits:NSBoldFontMask], [fm fontNamed:@"LiberationSans-Bold" hasTraits:NSItalicFontMask],
        [fm fontNamed:@"Inter-Medium" hasTraits:NSUnboldFontMask], [fm fontNamed:@"Inter-Italic" hasTraits:NSItalicFontMask | NSUnboldFontMask]);
    out(@"localized %@|%@|%@", [fm localizedNameForFamily:@"Inter" face:@"SemiBold Italic"], [fm localizedNameForFamily:@"Inter" face:@"Nope"],
        [fm localizedNameForFamily:@"Nope" face:nil]);

    out(@"actions:");
    [fm setSelectedFont:r isMultiple:NO];
    out(@"  selected %@ multiple %d", fm.selectedFont.fontName, fm.isMultiple);
    FontTarget *t = [FontTarget new];
    fm.target = t;
    NSMenuItem *mi = [NSMenuItem new];
    mi.tag = NSBoldFontMask;
    [fm addFontTrait:mi];
    out(@"  after addFontTrait: action %lu", (unsigned long)fm.currentFontAction);
    mi.tag = NSItalicFontMask;
    [fm removeFontTrait:mi];
    for (NSNumber *a in @[ @(NSSizeUpFontAction), @(NSSizeDownFontAction), @(NSHeavierFontAction), @(NSLighterFontAction) ]) {
        mi.tag = a.integerValue;
        [fm modifyFont:mi];
    }
    out(@"  convertFont without an action: %@ %g action %lu", [fm convertFont:r].fontName, [fm convertFont:r].pointSize,
        (unsigned long)fm.currentFontAction);
    out(@"  convertFontTraits %lx", (unsigned long)[fm convertFontTraits:NSItalicFontMask]);
    out(@"  convertAttributes %@", D([[fm convertAttributes:@{ NSFontAttributeName : r, @"other" : @1 }] objectForKey:NSFontAttributeName]));
    fm.action = @selector(otherAction:);
    out(@"  action %@", NSStringFromSelector(fm.action));
    fm.action = @selector(changeFont:);
    [fm setSelectedFont:[NSFont fontWithName:@"Inter-Medium" size:15] isMultiple:YES];
    out(@"  selected %@ multiple %d", fm.selectedFont.fontName, fm.isMultiple);
    fm.target = nil;

    out(@"menu:");
    out(@"  before %@", [fm fontMenu:NO]);
    NSMenu *menu = [fm fontMenu:YES];
    out(@"  %@ same %d", menu.title, menu == [fm fontMenu:YES]);
    for (NSMenuItem *it in menu.itemArray)
        out(@"  '%@' %@ tag %ld key '%@' mask %lx target %@ submenu %d", it.title, NSStringFromSelector(it.action), (long)it.tag,
            it.keyEquivalent, (unsigned long)it.keyEquivalentModifierMask, it.target == fm ? @"manager" : it.target ? @"other" : @"nil",
            it.hasSubmenu);

    out(@"panel:");
    out(@"  exists %d manager's %@", [NSFontPanel sharedFontPanelExists], [fm fontPanel:NO]);
    NSFontPanel *p = [NSFontPanel sharedFontPanel];
    out(@"  exists %d same %d manager's same %d title %@ floating %d keyIfNeeded %d hides %d worksWhenModal %d enabled %d "
        @"visible %d style %lx",
        [NSFontPanel sharedFontPanelExists], p == [NSFontPanel sharedFontPanel], p == [fm fontPanel:NO], p.title,
        p.isFloatingPanel, p.becomesKeyOnlyIfNeeded, p.hidesOnDeactivate, p.worksWhenModal, p.isEnabled, p.isVisible,
        (unsigned long)(p.styleMask & 0x1f));
    [p setPanelFont:[NSFont fontWithName:@"LiberationSans-Bold" size:20] isMultiple:NO];
    NSFont *c = [p panelConvertFont:[NSFont fontWithName:@"Inter-Regular" size:12]];
    out(@"  convert %@ %g", c.fontName, c.pointSize);
    [fm setSelectedFont:[NSFont fontWithName:@"Inter-Medium" size:15] isMultiple:NO];
    c = [p panelConvertFont:[NSFont fontWithName:@"LiberationSans" size:12]];
    out(@"  after setSelectedFont: convert %@ %g", c.fontName, c.pointSize);
}

#pragma mark - Main

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSArrayController class]));
        [NSApplication sharedApplication];
        [NSValueTransformer setValueTransformer:[Hash new] forName:@"Hash"];
        test_names();
        test_object_bindings();
        test_exposed();
        test_controls();
        test_popups();
        test_editing();
        test_object_controller();
        test_array_controller();
        test_defaults();
        test_nib(argc > 1 ? @(argv[1]) : @"/usr/local/share/finch/appkit-bindings-test.nib");
        test_fonts(argc > 2 ? @(argv[2]) : @"build/root/System/Library/Fonts");
    }
    return 0;
}
