/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "AppKit_Finch.h"

static NSString *expression_title(NSExpression *e)
{
    if ([e expressionType] == NSKeyPathExpressionType)
        return [e keyPath];
    if ([e expressionType] == NSConstantValueExpressionType)
        return [[e constantValue] description] ?: @"";
    return [e description];
}
static NSString *operator_title(NSInteger op)
{
    switch (op) {
    case NSLessThanPredicateOperatorType:
        return @"is less than";
    case NSLessThanOrEqualToPredicateOperatorType:
        return @"is at most";
    case NSGreaterThanPredicateOperatorType:
        return @"is greater than";
    case NSGreaterThanOrEqualToPredicateOperatorType:
        return @"is at least";
    case NSEqualToPredicateOperatorType:
        return @"is";
    case NSNotEqualToPredicateOperatorType:
        return @"is not";
    case NSMatchesPredicateOperatorType:
        return @"matches";
    case NSLikePredicateOperatorType:
        return @"is like";
    case NSBeginsWithPredicateOperatorType:
        return @"begins with";
    case NSEndsWithPredicateOperatorType:
        return @"ends with";
    case NSInPredicateOperatorType:
        return @"is in";
    case NSContainsPredicateOperatorType:
        return @"contains";
    case NSBetweenPredicateOperatorType:
        return @"is between";
    default:
        return @"is";
    }
}
static NSPopUpButton *template_popup(NSArray *objects, NSInteger kind)
{
    NSPopUpButton *p = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 120, 24) pullsDown:NO] autorelease];
    for (id o in objects) {
        NSString *t = kind == 0                                ? expression_title(o)
                      : kind == 1                              ? operator_title([o integerValue])
                      : [o integerValue] == NSAndPredicateType ? @"All"
                      : [o integerValue] == NSOrPredicateType  ? @"Any"
                                                               : @"None";
        [p addItemWithTitle:t];
        [[p lastItem] setRepresentedObject:o];
    }
    return p;
}
static void select_represented(NSPopUpButton *popup, id value)
{
    NSInteger i = 0;
    for (NSMenuItem *item in [popup itemArray]) {
        if ([[item representedObject] isEqual:value] ||
            [[[item representedObject] description] isEqual:[value description]]) {
            [popup selectItemAtIndex:i];
            return;
        }
        i++;
    }
}

@implementation NSPredicateEditorRowTemplate {
    NSArray *_left, *_right, *_operators, *_compound, *_views;
    NSAttributeType _attribute;
    NSComparisonPredicateModifier _modifier;
    NSUInteger _options;
}
- (instancetype)initWithLeftExpressions:(NSArray *)left
                       rightExpressions:(NSArray *)right
                               modifier:(NSComparisonPredicateModifier)modifier
                              operators:(NSArray *)operators
                                options:(NSUInteger)options
{
    self = [super init];
    if (self) {
        _left = [left copy];
        _right = [right copy];
        _modifier = modifier;
        _operators = [operators copy];
        _options = options;
    }
    return self;
}
- (instancetype)initWithLeftExpressions:(NSArray *)left
           rightExpressionAttributeType:(NSAttributeType)type
                               modifier:(NSComparisonPredicateModifier)modifier
                              operators:(NSArray *)operators
                                options:(NSUInteger)options
{
    self = [super init];
    if (self) {
        _left = [left copy];
        _modifier = modifier;
        _operators = [operators copy];
        _options = options;
        _attribute = type;
    }
    return self;
}
- (instancetype)initWithCompoundTypes:(NSArray *)types
{
    self = [super init];
    if (self)
        _compound = [types copy];
    return self;
}
- (NSArray *)leftExpressions
{
    return _left;
}
- (NSArray *)rightExpressions
{
    return _right;
}
- (NSArray *)operators
{
    return _operators;
}
- (NSArray *)compoundTypes
{
    return _compound;
}
- (NSAttributeType)rightExpressionAttributeType
{
    return _attribute;
}
- (NSComparisonPredicateModifier)modifier
{
    return _modifier;
}
- (NSUInteger)options
{
    return _options;
}
- (NSArray *)templateViews
{
    if (!_views) {
        if (_compound) {
            NSPopUpButton *first = template_popup(_compound, 2),
                          *suffix = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 170, 24)
                                                                pullsDown:NO] autorelease];
            [suffix addItemWithTitle:@"of the following are true"];
            _views = [@[ first, suffix ] copy];
        } else {
            NSView *right = nil;
            if (_right)
                right = template_popup(_right, 0);
            else if (_attribute == NSBooleanAttributeType) {
                NSPopUpButton *p = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 80, 24)
                                                               pullsDown:NO] autorelease];
                [p addItemWithTitle:@"Yes"];
                [[p lastItem] setRepresentedObject:@YES];
                [p addItemWithTitle:@"No"];
                [[p lastItem] setRepresentedObject:@NO];
                right = p;
            } else if (_attribute == NSDateAttributeType) {
                NSDatePicker *d = [[[NSDatePicker alloc] initWithFrame:NSMakeRect(0, 0, 160, 24)] autorelease];
                right = d;
            } else
                right = [NSTextField textFieldWithString:@""];
            _views = [@[ template_popup(_left ?: @[], 0), template_popup(_operators ?: @[], 1), right ] copy];
        }
    }
    return _views;
}
- (double)matchForPredicate:(NSPredicate *)predicate
{
    if (_compound) {
        if (![predicate isKindOfClass:[NSCompoundPredicate class]])
            return 0;
        NSCompoundPredicate *p = (id)predicate;
        if ([p compoundPredicateType] == NSNotPredicateType) {
            NSArray *sub = [p subpredicates];
            if ([sub count] != 1 || ![sub[0] isKindOfClass:[NSCompoundPredicate class]] ||
                [(NSCompoundPredicate *)sub[0] compoundPredicateType] != NSOrPredicateType)
                return 0;
        }
        return [_compound containsObject:@([p compoundPredicateType])] ? 0.5 : 0;
    }
    if (![predicate isKindOfClass:[NSComparisonPredicate class]])
        return 0;
    NSComparisonPredicate *p = (id)predicate;
    BOOL left = NO, right = NO;
    for (NSExpression *e in _left)
        if ([[e description] isEqual:[[p leftExpression] description]])
            left = YES;
    if (!left || ![_operators containsObject:@([p predicateOperatorType])])
        return 0;
    if (_right) {
        for (NSExpression *e in _right)
            if ([[e description] isEqual:[[p rightExpression] description]])
                right = YES;
        if (!right)
            return 0;
    }
    double score = _right ? 0.99 : 0.81;
    if ([p options] != _options)
        score *= 0.9;
    if ([p comparisonPredicateModifier] != _modifier)
        score *= 0.9;
    return score;
}
- (void)setPredicate:(NSPredicate *)predicate
{
    NSArray *v = [self templateViews];
    if (_compound) {
        if ([predicate isKindOfClass:[NSCompoundPredicate class]])
            select_represented(v[0], @([(NSCompoundPredicate *)predicate compoundPredicateType]));
        return;
    }
    if (![predicate isKindOfClass:[NSComparisonPredicate class]])
        return;
    NSComparisonPredicate *p = (id)predicate;
    select_represented(v[0], [p leftExpression]);
    select_represented(v[1], @([p predicateOperatorType]));
    if (_right)
        select_represented(v[2], [p rightExpression]);
    else {
        id value = [[p rightExpression] expressionType] == NSConstantValueExpressionType
                       ? [[p rightExpression] constantValue]
                       : nil;
        if (_attribute == NSBooleanAttributeType)
            select_represented(v[2], @([value boolValue]));
        else if (_attribute == NSDateAttributeType) {
            if ([value isKindOfClass:[NSDate class]])
                [(NSDatePicker *)v[2] setDateValue:value];
        } else
            [(NSControl *)v[2] setObjectValue:value ?: @""];
    }
}
- (NSPredicate *)predicateWithSubpredicates:(NSArray *)subpredicates
{
    NSArray *v = [self templateViews];
    if (_compound) {
        NSInteger type = [[[v[0] selectedItem] representedObject] integerValue];
        NSArray *sub = subpredicates ?: @[];
        if (type == NSNotPredicateType)
            return [NSCompoundPredicate
                notPredicateWithSubpredicate:[NSCompoundPredicate orPredicateWithSubpredicates:sub]];
        return [[[NSCompoundPredicate alloc] initWithType:type subpredicates:sub] autorelease];
    }
    NSExpression *l = [[v[0] selectedItem] representedObject], *r = nil;
    if (_right)
        r = [[v[2] selectedItem] representedObject];
    else {
        id value = nil;
        if (_attribute == NSBooleanAttributeType)
            value = [[v[2] selectedItem] representedObject];
        else if (_attribute == NSDateAttributeType)
            value = [v[2] dateValue];
        else if (_attribute == NSInteger16AttributeType || _attribute == NSInteger32AttributeType ||
                 _attribute == NSInteger64AttributeType)
            value = @([v[2] integerValue]);
        else if (_attribute == NSDecimalAttributeType || _attribute == NSDoubleAttributeType ||
                 _attribute == NSFloatAttributeType)
            value = @([v[2] doubleValue]);
        else
            value = [v[2] stringValue];
        r = [NSExpression expressionForConstantValue:value ?: @""];
    }
    if (!l || !r)
        return [NSPredicate predicateWithValue:YES];
    return [NSComparisonPredicate predicateWithLeftExpression:l
                                              rightExpression:r
                                                     modifier:_modifier
                                                         type:[[[v[1] selectedItem] representedObject] integerValue]
                                                      options:_options];
}
- (NSArray *)displayableSubpredicatesOfPredicate:(NSPredicate *)predicate
{
    if (![predicate isKindOfClass:[NSCompoundPredicate class]])
        return nil;
    NSCompoundPredicate *p = (id)predicate;
    if ([p compoundPredicateType] == NSNotPredicateType) {
        NSArray *a = [p subpredicates];
        if ([a count] == 1 && [a[0] isKindOfClass:[NSCompoundPredicate class]])
            return [a[0] subpredicates];
    }
    return [p subpredicates];
}
- (id)copyWithZone:(NSZone *)zone
{
    NSPredicateEditorRowTemplate *t = _compound ? [[[self class] allocWithZone:zone] initWithCompoundTypes:_compound]
                                      : _right  ? [[[self class] allocWithZone:zone] initWithLeftExpressions:_left
                                                                                           rightExpressions:_right
                                                                                                   modifier:_modifier
                                                                                                  operators:_operators
                                                                                                    options:_options]
                                                : [[[self class] allocWithZone:zone] initWithLeftExpressions:_left
                                                                               rightExpressionAttributeType:_attribute
                                                                                                   modifier:_modifier
                                                                                                  operators:_operators
                                                                                                    options:_options];
    if (_views && !_compound && !_right && [_views count] > 2) {
        id from = _views[2], to = [t templateViews][2];
        if ([from isKindOfClass:[NSDatePicker class]])
            [to setDateValue:[from dateValue]];
        else if (![from isKindOfClass:[NSPopUpButton class]])
            [to setObjectValue:[from objectValue]];
    }
    return t;
}
+ (NSArray *)templatesWithAttributeKeyPaths:(NSArray *)paths inEntityDescription:(NSEntityDescription *)entity
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *path in paths) {
        id current = entity, property = nil;
        NSArray *pieces = [path componentsSeparatedByString:@"."];
        for (NSString *piece in pieces) {
            property = [current propertiesByName][piece];
            if ([property respondsToSelector:@selector(destinationEntity)])
                current = [property destinationEntity];
        }
        if (![property respondsToSelector:@selector(attributeType)])
            continue;
        NSAttributeType type = [property attributeType];
        NSArray *ops = type == NSStringAttributeType    ? @[ @4, @5, @99, @8, @9 ]
                       : type == NSBooleanAttributeType ? @[ @4, @5 ]
                                                        : @[ @4, @5, @0, @1, @2, @3 ];
        [out addObject:[[[self alloc] initWithLeftExpressions:@[ [NSExpression expressionForKeyPath:path] ]
                                 rightExpressionAttributeType:type
                                                     modifier:NSDirectPredicateModifier
                                                    operators:ops
                                                      options:0] autorelease]];
    }
    return out;
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [super init];
    if (self) {
        _options = [c decodeIntegerForKey:@"NSPredicateTemplateOptions"];
        _modifier = [c decodeIntegerForKey:@"NSPredicateTemplateModifier"];
        _attribute = [c decodeIntegerForKey:@"NSPredicateTemplateRightAttributeType"];
        _views = [[c decodeObjectForKey:@"NSPredicateTemplateViews"] copy];
        NSInteger type = [c decodeIntegerForKey:@"NSPredicateTemplateType"];
        NSMutableArray *a = [NSMutableArray array], *b = [NSMutableArray array], *d = [NSMutableArray array];
        if ([_views count])
            for (NSMenuItem *i in [(NSPopUpButton *)_views[0] itemArray])
                if ([i representedObject])
                    [a addObject:[i representedObject]];
        if (type == 2)
            _compound = [a copy];
        else {
            _left = [a copy];
            if ([_views count] > 1)
                for (NSMenuItem *i in [(NSPopUpButton *)_views[1] itemArray])
                    if ([i representedObject])
                        [b addObject:[i representedObject]];
            _operators = [b copy];
            if ([_views count] > 2 && [_views[2] isKindOfClass:[NSPopUpButton class]] && !_attribute) {
                for (NSMenuItem *i in [_views[2] itemArray])
                    if ([i representedObject])
                        [d addObject:[i representedObject]];
                _right = [d copy];
            }
        }
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeInteger:_compound ? 2 : _right ? 0 : 1 forKey:@"NSPredicateTemplateType"];
    [c encodeInteger:_options forKey:@"NSPredicateTemplateOptions"];
    [c encodeInteger:_modifier forKey:@"NSPredicateTemplateModifier"];
    [c encodeInteger:_attribute forKey:@"NSPredicateTemplateRightAttributeType"];
    [c encodeObject:[self templateViews] forKey:@"NSPredicateTemplateViews"];
}
- (void)dealloc
{
    [_left release];
    [_right release];
    [_operators release];
    [_compound release];
    [_views release];
    [super dealloc];
}
@end

@interface NSRuleEditor (FinchPredicateRows)
- (void)_finchRebuildRows;
@end
@implementation NSPredicateEditor {
    NSArray *_templates;
    NSMutableDictionary *_rowTemplates;
    BOOL _settingPredicate;
}
- (void)_finchPredicateSetup
{
    _templates = [@[ [[[NSPredicateEditorRowTemplate alloc] initWithCompoundTypes:@[ @1, @2, @0 ]] autorelease] ] copy];
    _rowTemplates = [NSMutableDictionary new];
}
- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
        [self _finchPredicateSetup];
    return self;
}
- (NSArray *)rowTemplates
{
    return _templates;
}
- (void)setRowTemplates:(NSArray *)v
{
    NSArray *copy = [v copy] ?: [@[] copy];
    [_templates release];
    _templates = copy;
}
- (NSPredicateEditorRowTemplate *)_finchTemplateForPredicate:(NSPredicate *)predicate
{
    double best = 0;
    NSPredicateEditorRowTemplate *match = nil;
    for (NSPredicateEditorRowTemplate *t in _templates) {
        double score = [t matchForPredicate:predicate];
        if (score > best) {
            best = score;
            match = t;
        }
    }
    return [[match copy] autorelease];
}
- (void)_finchAppendPredicate:(NSPredicate *)predicate parent:(NSInteger)parent
{
    NSPredicateEditorRowTemplate *t = [self _finchTemplateForPredicate:predicate];
    if (!t)
        return;
    [t setPredicate:predicate];
    NSInteger i = [self numberOfRows];
    NSArray *sub = [t displayableSubpredicatesOfPredicate:predicate];
    BOOL wasSetting = _settingPredicate;
    _settingPredicate = YES;
    [self insertRowAtIndex:i
                  withType:sub ? NSRuleEditorRowTypeCompound : NSRuleEditorRowTypeSimple
             asSubrowOfRow:parent
                   animate:NO];
    _settingPredicate = wasSetting;
    _rowTemplates[@(i)] = t;
    NSArray *views = [t templateViews];
    [self setCriteria:views andDisplayValues:views forRowAtIndex:i];
    for (NSPredicate *p in sub)
        [self _finchAppendPredicate:p parent:i];
}
- (void)insertRowAtIndex:(NSInteger)i
                withType:(NSRuleEditorRowType)type
           asSubrowOfRow:(NSInteger)parent
                 animate:(BOOL)animate
{
    NSMutableDictionary *shifted = [NSMutableDictionary dictionary];
    for (NSNumber *key in _rowTemplates)
        shifted[@([key integerValue] >= i ? [key integerValue] + 1 : [key integerValue])] = _rowTemplates[key];
    [super insertRowAtIndex:i withType:type asSubrowOfRow:parent animate:animate];
    [_rowTemplates setDictionary:shifted];
    if (!_settingPredicate) {
        NSPredicateEditorRowTemplate *chosen = nil;
        for (NSPredicateEditorRowTemplate *t in _templates)
            if (([t compoundTypes] != nil) == (type == NSRuleEditorRowTypeCompound)) {
                chosen = [[t copy] autorelease];
                break;
            }
        if (chosen) {
            _rowTemplates[@(i)] = chosen;
            NSArray *views = [chosen templateViews];
            [self setCriteria:views andDisplayValues:views forRowAtIndex:i];
        }
    }
}
- (void)setObjectValue:(id)value
{
    if (value && ![value isKindOfClass:[NSPredicate class]])
        [NSException raise:NSInvalidArgumentException format:@"A predicate editor needs an NSPredicate value."];
    _settingPredicate = YES;
    [self removeRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [self numberOfRows])]
               includeSubrows:YES];
    [_rowTemplates removeAllObjects];
    if (value)
        [self _finchAppendPredicate:value parent:-1];
    _settingPredicate = NO;
    [self reloadPredicate];
}
- (id)objectValue
{
    return [self predicate];
}
- (NSPredicate *)predicateForRow:(NSInteger)i
{
    NSPredicateEditorRowTemplate *t = _rowTemplates[@(i)];
    if (!t)
        return [super predicateForRow:i];
    NSMutableArray *sub = [NSMutableArray array];
    [[self subrowIndexesForRow:i] enumerateIndexesUsingBlock:^(NSUInteger j, BOOL *stop) {
      NSPredicate *p = [self predicateForRow:j];
      if (p)
          [sub addObject:p];
    }];
    return [t predicateWithSubpredicates:sub];
}
- (void)addRow:(id)sender
{
    if (_settingPredicate) {
        [super addRow:sender];
        return;
    }
    NSPredicateEditorRowTemplate *chosen = nil;
    for (NSPredicateEditorRowTemplate *t in _templates)
        if (![t compoundTypes]) {
            chosen = t;
            break;
        }
    if (chosen)
        [self _finchAppendPredicate:[chosen predicateWithSubpredicates:nil] parent:-1];
    else
        [super addRow:sender];
}
- (void)removeRowsAtIndexes:(NSIndexSet *)indexes includeSubrows:(BOOL)include
{
    /* Keep the template tied to its surviving views when row numbers move. */
    NSMutableDictionary *byView = [NSMutableDictionary dictionary];
    for (NSNumber *key in _rowTemplates) {
        NSArray *v = [self displayValuesForRow:[key integerValue]];
        if ([v count])
            byView[[NSValue valueWithNonretainedObject:v[0]]] = _rowTemplates[key];
    }
    [super removeRowsAtIndexes:indexes includeSubrows:include];
    [_rowTemplates removeAllObjects];
    for (NSInteger i = 0; i < [self numberOfRows]; i++) {
        NSArray *v = [self displayValuesForRow:i];
        if ([v count]) {
            id t = byView[[NSValue valueWithNonretainedObject:v[0]]];
            if (t)
                _rowTemplates[@(i)] = t;
        }
    }
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [super initWithCoder:c];
    if (self) {
        [self _finchPredicateSetup];
        NSArray *t = [c decodeObjectForKey:@"NSPredicateTemplates"];
        if (t)
            [self setRowTemplates:t];
        NSPredicate *p = [c decodeObjectForKey:@"NSPredicateEditorPredicate"];
        if (p)
            [self setObjectValue:p];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [super encodeWithCoder:c];
    [c encodeObject:_templates forKey:@"NSPredicateTemplates"];
    [c encodeObject:[self predicate] forKey:@"NSPredicateEditorPredicate"];
}
- (void)dealloc
{
    [_templates release];
    [_rowTemplates release];
    [super dealloc];
}
@end
