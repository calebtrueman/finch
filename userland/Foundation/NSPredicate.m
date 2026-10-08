/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSPredicate, NSComparisonPredicate, NSCompoundPredicate and NSExpression
 * (docs/design/FOUNDATION.md), against the SDK's headers, with Apple's
 * class names (NSTruePredicate, NSKeyPathExpression, ...).
 *
 * Format strings are parsed by recursive descent with Apple's precedence:
 * OR < AND < NOT < comparison; + - < * / < ** < unary minus < key paths and
 * subscripts. Keywords are case-insensitive; %@ %K %d %i %u %ld %lu %lld
 * %llu %f %s %c and %% take arguments. Descriptions are Apple's
 * (name == "Bob", (a AND b) OR c, age + (1 * 2), 0 - x, CAST(0.000000,
 * "NSDate"), sum:({1, 2, 3}), BLOCKPREDICATE(0x...)). Evaluation goes
 * through key-value coding.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>

#include "Foundation_Finch.h"

/* MARK: - Expressions */

@interface NSExpression () {
@public
    id _value;                  /* constant; variable name; key path; function name; block; symbol */
    NSExpression *_operand;     /* function target; subquery collection; set left; conditional true */
    NSArray *_arguments;        /* function arguments; aggregate members */
    NSExpression *_right;       /* set right; conditional false */
    NSPredicate *_predicate;    /* subquery; conditional */
}
@end

#define EXPRESSION_CLASS(NAME) @interface NAME : NSExpression @end @implementation NAME @end
EXPRESSION_CLASS(NSConstantValueExpression)
EXPRESSION_CLASS(NSSelfExpression)
EXPRESSION_CLASS(NSVariableExpression)
EXPRESSION_CLASS(NSKeyPathExpression)
EXPRESSION_CLASS(NSFunctionExpression)
EXPRESSION_CLASS(NSAggregateExpression)
EXPRESSION_CLASS(NSSubqueryExpression)
EXPRESSION_CLASS(NSSetExpression)
EXPRESSION_CLASS(NSAnyKeyExpression)
EXPRESSION_CLASS(NSBlockExpression)
EXPRESSION_CLASS(NSTernaryExpression)
EXPRESSION_CLASS(NSSymbolicExpression)   /* FIRST, LAST, SIZE in subscripts */
#undef EXPRESSION_CLASS

static Class
expression_class(NSExpressionType type)
{
    switch (type) {
    case NSConstantValueExpressionType: return [NSConstantValueExpression class];
    case NSEvaluatedObjectExpressionType: return [NSSelfExpression class];
    case NSVariableExpressionType: return [NSVariableExpression class];
    case NSKeyPathExpressionType: return [NSKeyPathExpression class];
    case NSFunctionExpressionType: return [NSFunctionExpression class];
    case NSAggregateExpressionType: return [NSAggregateExpression class];
    case NSSubqueryExpressionType: return [NSSubqueryExpression class];
    case NSUnionSetExpressionType: case NSIntersectSetExpressionType: case NSMinusSetExpressionType: return [NSSetExpression class];
    case NSAnyKeyExpressionType: return [NSAnyKeyExpression class];
    case NSBlockExpressionType: return [NSBlockExpression class];
    case NSConditionalExpressionType: return [NSTernaryExpression class];
    }
    return [NSExpression class];
}

static NSExpression *
make(NSExpressionType type)
{
    return [[[expression_class(type) alloc] initWithExpressionType:type] autorelease];
}

static NSExpression *
symbol(NSString *name)
{
    NSExpression *e = [[[NSSymbolicExpression alloc] initWithExpressionType:NSConstantValueExpressionType] autorelease];
    e->_value = [name copy];
    return e;
}

static NSString *
quoted(NSString *s)
{
    NSMutableString *m = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '"' || c == '\\') [m appendString:@"\\"];
        [m appendFormat:@"%C", c];
    }
    [m appendString:@"\""];
    return m;
}

static NSString *
const_description(id v)
{
    if (!v || v == [NSNull null]) return @"nil";
    if ([v isKindOfClass:[NSString class]]) return quoted(v);
    if ([v isKindOfClass:[NSDate class]]) return [NSString stringWithFormat:@"CAST(%f, \"NSDate\")", [v timeIntervalSinceReferenceDate]];
    if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] || [v isKindOfClass:[NSOrderedSet class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id o in v) [parts addObject:const_description(o)];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    return [v description];
}

static id evaluate_predicate(NSPredicate *p, id object, NSMutableDictionary *bindings);

@implementation NSExpression

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithExpressionType:(NSExpressionType)type
{
    if ((self = [super init])) _expressionType = type;
    return self;
}

- (instancetype)init { return [self initWithExpressionType:NSConstantValueExpressionType]; }

- (void)dealloc
{
    [_value release];
    [_operand release];
    [_arguments release];
    [_right release];
    [_predicate release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { }
- (void)allowEvaluation { }

+ (NSExpression *)expressionForConstantValue:(id)obj
{
    NSExpression *e = make(NSConstantValueExpressionType);
    e->_value = [obj retain];
    return e;
}

+ (NSExpression *)expressionForEvaluatedObject { return make(NSEvaluatedObjectExpressionType); }

+ (NSExpression *)expressionForVariable:(NSString *)string
{
    NSExpression *e = make(NSVariableExpressionType);
    e->_value = [string copy];
    return e;
}

+ (NSExpression *)expressionForKeyPath:(NSString *)keyPath
{
    NSExpression *e = make(NSKeyPathExpressionType);
    e->_value = [keyPath copy];
    return e;
}

+ (NSExpression *)expressionForFunction:(NSString *)name arguments:(NSArray *)parameters
{
    NSExpression *e = make(NSFunctionExpressionType);
    e->_value = [name copy];
    e->_arguments = [parameters copy];
    return e;
}

+ (NSExpression *)expressionForFunction:(NSExpression *)target selectorName:(NSString *)name arguments:(NSArray *)parameters
{
    NSExpression *e = make(NSFunctionExpressionType);
    e->_value = [name copy];
    e->_operand = [target retain];
    e->_arguments = [parameters copy];
    return e;
}

+ (NSExpression *)expressionForAggregate:(NSArray<NSExpression *> *)subexpressions
{
    NSExpression *e = make(NSAggregateExpressionType);
    e->_arguments = [subexpressions copy];
    return e;
}

static NSExpression *
set_expression(NSExpressionType type, NSExpression *left, NSExpression *right)
{
    NSExpression *e = make(type);
    e->_operand = [left retain];
    e->_right = [right retain];
    return e;
}

+ (NSExpression *)expressionForUnionSet:(NSExpression *)left with:(NSExpression *)right { return set_expression(NSUnionSetExpressionType, left, right); }
+ (NSExpression *)expressionForIntersectSet:(NSExpression *)left with:(NSExpression *)right { return set_expression(NSIntersectSetExpressionType, left, right); }
+ (NSExpression *)expressionForMinusSet:(NSExpression *)left with:(NSExpression *)right { return set_expression(NSMinusSetExpressionType, left, right); }

+ (NSExpression *)expressionForSubquery:(NSExpression *)expression usingIteratorVariable:(NSString *)variable predicate:(NSPredicate *)predicate
{
    NSExpression *e = make(NSSubqueryExpressionType);
    e->_operand = [expression retain];
    e->_value = [variable copy];
    e->_predicate = [predicate retain];
    return e;
}

+ (NSExpression *)expressionForAnyKey { return make(NSAnyKeyExpressionType); }

+ (NSExpression *)expressionForBlock:(id (^)(id, NSArray<NSExpression *> *, NSMutableDictionary *))block arguments:(NSArray<NSExpression *> *)arguments
{
    NSExpression *e = make(NSBlockExpressionType);
    e->_value = [block copy];
    e->_arguments = [arguments copy];
    return e;
}

+ (NSExpression *)expressionForConditional:(NSPredicate *)predicate trueExpression:(NSExpression *)trueExpression falseExpression:(NSExpression *)falseExpression
{
    NSExpression *e = make(NSConditionalExpressionType);
    e->_predicate = [predicate retain];
    e->_operand = [trueExpression retain];
    e->_right = [falseExpression retain];
    return e;
}

- (NSExpressionType)expressionType { return _expressionType; }
- (id)constantValue { return _expressionType == NSConstantValueExpressionType ? _value : nil; }
- (NSString *)keyPath { return _expressionType == NSKeyPathExpressionType ? _value : nil; }
- (NSString *)function { return _expressionType == NSFunctionExpressionType ? _value : nil; }
- (NSString *)variable { return _expressionType == NSVariableExpressionType || _expressionType == NSSubqueryExpressionType ? _value : nil; }
- (NSExpression *)operand { return _operand; }
- (NSArray *)arguments { return _arguments; }
- (id)collection { return _expressionType == NSAggregateExpressionType ? _arguments : _operand; }
- (NSPredicate *)predicate { return _predicate; }
- (NSExpression *)leftExpression { return _operand; }
- (NSExpression *)rightExpression { return _right; }
- (NSExpression *)trueExpression { return _operand; }
- (NSExpression *)falseExpression { return _right; }
- (id (^)(id, NSArray<NSExpression *> *, NSMutableDictionary *))expressionBlock { return _expressionType == NSBlockExpressionType ? _value : nil; }

/* MARK: Description */

static NSDictionary *
infix_operators(void)
{
    static NSDictionary *ops;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ops = [@{ @"add:to:": @"+", @"from:subtract:": @"-", @"multiply:by:": @"*", @"divide:by:": @"/", @"raise:toPower:": @"**" } retain];
    });
    return ops;
}

static BOOL
is_infix(NSExpression *e)
{
    return e->_expressionType == NSFunctionExpressionType && !e->_operand && [infix_operators() objectForKey:e->_value] && [e->_arguments count] == 2;
}

static NSString *
operand_description(NSExpression *e)
{
    return is_infix(e) ? [NSString stringWithFormat:@"(%@)", e] : [e description];
}

static NSString *
joined(NSArray *expressions)
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSExpression *a in expressions) [parts addObject:[a description]];
    return [parts componentsJoinedByString:@", "];
}

- (NSString *)description
{
    if ([self isKindOfClass:[NSSymbolicExpression class]]) return _value;
    switch (_expressionType) {
    case NSConstantValueExpressionType: return const_description(_value);
    case NSEvaluatedObjectExpressionType: return @"SELF";
    case NSVariableExpressionType: return [@"$" stringByAppendingString:_value];
    case NSKeyPathExpressionType: return _value;
    case NSAnyKeyExpressionType: return @"ANYKEY";
    case NSAggregateExpressionType: return [NSString stringWithFormat:@"{%@}", joined(_arguments)];
    case NSUnionSetExpressionType: return [NSString stringWithFormat:@"%@ UNION %@", _operand, _right];
    case NSIntersectSetExpressionType: return [NSString stringWithFormat:@"%@ INTERSECT %@", _operand, _right];
    case NSMinusSetExpressionType: return [NSString stringWithFormat:@"%@ MINUS %@", _operand, _right];
    case NSSubqueryExpressionType: return [NSString stringWithFormat:@"SUBQUERY(%@, $%@, %@)", _operand, _value, [_predicate predicateFormat]];
    case NSConditionalExpressionType: return [NSString stringWithFormat:@"TERNARY(%@, %@, %@)", [_predicate predicateFormat], _operand, _right];
    case NSBlockExpressionType: return [NSString stringWithFormat:@"BLOCK(%p, %@)", _value, joined(_arguments)];
    case NSFunctionExpressionType: break;
    }
    NSString *f = _value;
    if (_operand) {
        if ([f isEqualToString:@"valueForKeyPath:"]) return [NSString stringWithFormat:@"%@.%@", _operand, [[_arguments firstObject] constantValue]];
        NSMutableString *s = [NSMutableString stringWithFormat:@"FUNCTION(%@, %@", _operand, quoted(f)];
        for (NSExpression *a in _arguments) [s appendFormat:@", %@", a];
        [s appendString:@")"];
        return s;
    }
    if (is_infix(self))
        return [NSString stringWithFormat:@"%@ %@ %@", operand_description(_arguments[0]), [infix_operators() objectForKey:f], operand_description(_arguments[1])];
    if ([f isEqualToString:@"objectFrom:withIndex:"] && [_arguments count] == 2) return [NSString stringWithFormat:@"%@[%@]", _arguments[0], _arguments[1]];
    if ([f isEqualToString:@"castObject:toType:"] && [_arguments count] == 2) return [NSString stringWithFormat:@"CAST(%@, %@)", _arguments[0], _arguments[1]];
    return [NSString stringWithFormat:@"%@(%@)", f, joined(_arguments)];
}

- (NSString *)predicateFormat { return [self description]; }

/* MARK: Evaluation */

static NSArray *
as_array(id v)
{
    if (!v) return nil;
    if ([v isKindOfClass:[NSArray class]]) return v;
    if ([v isKindOfClass:[NSSet class]]) return [v allObjects];
    if ([v isKindOfClass:[NSOrderedSet class]]) return [v array];
    if ([v isKindOfClass:[NSDictionary class]]) return [v allValues];
    return nil;
}

static NSDecimalNumber *
as_decimal(id v)
{
    return [v isKindOfClass:[NSDecimalNumber class]] ? v : [NSDecimalNumber decimalNumberWithDecimal:[v decimalValue]];
}

static NSNumber *
number_result(double d)
{
    return [NSNumber numberWithDouble:d];
}

static id
arithmetic(NSString *f, NSArray *args)
{
    id a = [args count] > 0 ? args[0] : nil, b = [args count] > 1 ? args[1] : nil;
    if ([f isEqualToString:@"add:to:"] || [f isEqualToString:@"from:subtract:"]) {
        if ([a isKindOfClass:[NSDate class]] && [b isKindOfClass:[NSNumber class]])
            return [a dateByAddingTimeInterval:[f isEqualToString:@"add:to:"] ? [b doubleValue] : -[b doubleValue]];
        BOOL integral = strchr("cCsSiIlLqQ", *[a objCType]) && strchr("cCsSiIlLqQ", *[b objCType]);
        if (integral) {
            long long r = [f isEqualToString:@"add:to:"] ? [a longLongValue] + [b longLongValue] : [a longLongValue] - [b longLongValue];
            return [NSNumber numberWithLongLong:r];
        }
        return number_result([f isEqualToString:@"add:to:"] ? [a doubleValue] + [b doubleValue] : [a doubleValue] - [b doubleValue]);
    }
    if ([f isEqualToString:@"multiply:by:"]) {
        if (strchr("cCsSiIlLqQ", *[a objCType]) && strchr("cCsSiIlLqQ", *[b objCType])) return [NSNumber numberWithLongLong:[a longLongValue] * [b longLongValue]];
        return number_result([a doubleValue] * [b doubleValue]);
    }
    if ([f isEqualToString:@"divide:by:"]) {
        /* Integers divide as integers, as Apple's do (10 / 4 is 2). */
        if (strchr("cCsSiIlLqQ", *[a objCType]) && strchr("cCsSiIlLqQ", *[b objCType]) && [b longLongValue])
            return [NSNumber numberWithLongLong:[a longLongValue] / [b longLongValue]];
        return number_result([a doubleValue] / [b doubleValue]);
    }
    if ([f isEqualToString:@"modulus:by:"]) return [NSNumber numberWithLongLong:[a longLongValue] % MAX(1, [b longLongValue])];
    if ([f isEqualToString:@"raise:toPower:"]) return number_result(pow([a doubleValue], [b doubleValue]));
    if ([f isEqualToString:@"sqrt:"]) return number_result(sqrt([a doubleValue]));
    if ([f isEqualToString:@"log:"]) return number_result(log10([a doubleValue]));
    if ([f isEqualToString:@"ln:"]) return number_result(log([a doubleValue]));
    if ([f isEqualToString:@"exp:"]) return number_result(exp([a doubleValue]));
    if ([f isEqualToString:@"floor:"]) return number_result(floor([a doubleValue]));
    if ([f isEqualToString:@"ceiling:"]) return number_result(ceil([a doubleValue]));
    if ([f isEqualToString:@"abs:"]) return number_result(fabs([a doubleValue]));
    if ([f isEqualToString:@"trunc:"]) return number_result(trunc([a doubleValue]));
    if ([f isEqualToString:@"onesComplement:"]) return [NSNumber numberWithLongLong:~[a longLongValue]];
    if ([f isEqualToString:@"bitwiseAnd:with:"]) return [NSNumber numberWithLongLong:[a longLongValue] & [b longLongValue]];
    if ([f isEqualToString:@"bitwiseOr:with:"]) return [NSNumber numberWithLongLong:[a longLongValue] | [b longLongValue]];
    if ([f isEqualToString:@"bitwiseXor:with:"]) return [NSNumber numberWithLongLong:[a longLongValue] ^ [b longLongValue]];
    if ([f isEqualToString:@"leftshift:by:"]) return [NSNumber numberWithLongLong:[a longLongValue] << [b longLongValue]];
    if ([f isEqualToString:@"rightshift:by:"]) return [NSNumber numberWithLongLong:[a longLongValue] >> [b longLongValue]];
    if ([f isEqualToString:@"uppercase:"]) return [a uppercaseString];
    if ([f isEqualToString:@"lowercase:"]) return [a lowercaseString];
    if ([f isEqualToString:@"now"]) return [NSDate date];
    if ([f isEqualToString:@"random"]) return number_result((double)arc4random() / UINT32_MAX);
    if ([f isEqualToString:@"randomn:"]) return [NSNumber numberWithUnsignedInt:arc4random_uniform((uint32_t)[a unsignedIntValue])];
    if ([f isEqualToString:@"noindex:"]) return a;
    if ([f isEqualToString:@"distanceToLocation:fromLocation:"]) return nil;
    NSArray *list = as_array(a);
    if ([f isEqualToString:@"count:"]) return [NSNumber numberWithUnsignedInteger:[list count]];
    if ([f isEqualToString:@"sum:"] || [f isEqualToString:@"average:"]) {
        NSDecimalNumber *sum = [NSDecimalNumber zero];
        for (id v in list) sum = [sum decimalNumberByAdding:as_decimal(v)];
        if ([f isEqualToString:@"sum:"]) return sum;
        return [list count] ? [sum decimalNumberByDividingBy:[NSDecimalNumber decimalNumberWithMantissa:[list count] exponent:0 isNegative:NO]] : nil;
    }
    if ([f isEqualToString:@"min:"] || [f isEqualToString:@"max:"]) {
        id best = nil;
        BOOL max = [f isEqualToString:@"max:"];
        for (id v in list) if (!best || [v compare:best] == (max ? NSOrderedDescending : NSOrderedAscending)) best = v;
        return best;
    }
    if ([f isEqualToString:@"median:"]) {
        NSArray *s = [list sortedArrayUsingSelector:@selector(compare:)];
        return [s count] ? s[[s count] / 2] : nil;
    }
    if ([f isEqualToString:@"mode:"]) {
        NSCountedSet *c = [NSCountedSet setWithArray:list];
        NSMutableArray *r = [NSMutableArray array];
        NSUInteger most = 0;
        for (id v in c) most = MAX(most, [c countForObject:v]);
        for (id v in c) if ([c countForObject:v] == most) [r addObject:v];
        return r;
    }
    if ([f isEqualToString:@"stddev:"]) {
        double sum = 0, sq = 0;
        for (id v in list) { sum += [v doubleValue]; sq += [v doubleValue] * [v doubleValue]; }
        double n = (double)[list count];
        return n ? number_result(sqrt(sq / n - (sum / n) * (sum / n))) : nil;
    }
    FinchRaise(NSInvalidArgumentException, "Unsupported function %s", [f UTF8String]);
}

static id
index_into(id collection, id index)
{
    if ([index isKindOfClass:[NSString class]]) {
        NSArray *a = as_array(collection);
        if ([index isEqualToString:@"SIZE"]) return [NSNumber numberWithUnsignedInteger:[collection count]];
        if ([index isEqualToString:@"FIRST"]) return [a firstObject];
        if ([index isEqualToString:@"LAST"]) return [a lastObject];
        if ([collection isKindOfClass:[NSDictionary class]]) return [collection objectForKey:index];
        return nil;
    }
    if ([collection isKindOfClass:[NSDictionary class]]) return [collection objectForKey:index];
    NSArray *a = as_array(collection);
    NSUInteger i = [index unsignedIntegerValue];
    if (i >= [a count]) FinchRaise(NSRangeException, "*** -[NSArray objectAtIndex:]: index %lu beyond bounds", (unsigned long)i);
    return a[i];
}

static id
cast(id value, NSString *type)
{
    if ([type isEqualToString:@"NSDate"]) return [NSDate dateWithTimeIntervalSinceReferenceDate:[value doubleValue]];
    if ([type isEqualToString:@"NSNumber"]) {
        if ([value isKindOfClass:[NSDate class]]) return number_result([value timeIntervalSinceReferenceDate]);
        if ([value isKindOfClass:[NSString class]]) return number_result([value doubleValue]);
        return value;
    }
    if ([type isEqualToString:@"NSString"]) return [value description];
    Class c = NSClassFromString(type);
    return [value isKindOfClass:c] ? value : nil;
}

- (id)expressionValueWithObject:(id)object context:(NSMutableDictionary *)context
{
    if ([self isKindOfClass:[NSSymbolicExpression class]]) return _value;
    switch (_expressionType) {
    case NSConstantValueExpressionType: return _value;
    case NSEvaluatedObjectExpressionType: return object;
    case NSVariableExpressionType: {
        id v = [context objectForKey:_value];
        if (!v && ![context objectForKey:_value])
            FinchRaise(NSInvalidArgumentException, "Can't get value for '%s' in bindings %s.", [_value UTF8String], [[context description] UTF8String]);
        return v == [NSNull null] ? nil : v;
    }
    case NSKeyPathExpressionType: return [object valueForKeyPath:_value];
    case NSAnyKeyExpressionType: return [object isKindOfClass:[NSDictionary class]] ? [object allValues] : nil;
    case NSAggregateExpressionType: {
        NSMutableArray *a = [NSMutableArray array];
        for (NSExpression *e in _arguments) {
            id v = [e expressionValueWithObject:object context:context];
            [a addObject:v ? v : [NSNull null]];
        }
        return a;
    }
    case NSUnionSetExpressionType: case NSIntersectSetExpressionType: case NSMinusSetExpressionType: {
        NSMutableSet *s = [NSMutableSet setWithArray:as_array([_operand expressionValueWithObject:object context:context])];
        NSSet *r = [NSSet setWithArray:as_array([_right expressionValueWithObject:object context:context])];
        if (_expressionType == NSUnionSetExpressionType) [s unionSet:r];
        else if (_expressionType == NSIntersectSetExpressionType) [s intersectSet:r];
        else [s minusSet:r];
        return s;
    }
    case NSSubqueryExpressionType: {
        id coll = [_operand expressionValueWithObject:object context:context];
        NSMutableDictionary *bindings = context ? [[context mutableCopy] autorelease] : [NSMutableDictionary dictionary];
        NSMutableArray *r = [NSMutableArray array];
        for (id v in as_array(coll)) {
            [bindings setObject:v forKey:_value];
            if ([evaluate_predicate(_predicate, object, bindings) boolValue]) [r addObject:v];
        }
        return r;
    }
    case NSConditionalExpressionType:
        return [evaluate_predicate(_predicate, object, context) boolValue] ? [_operand expressionValueWithObject:object context:context]
                                                                           : [_right expressionValueWithObject:object context:context];
    case NSBlockExpressionType: return ((id (^)(id, NSArray *, NSMutableDictionary *))_value)(object, _arguments, context);
    case NSFunctionExpressionType: break;
    }
    NSMutableArray *args = [NSMutableArray array];
    for (NSExpression *e in _arguments) {
        id v = [e expressionValueWithObject:object context:context];
        [args addObject:v ? v : [NSNull null]];
    }
    for (NSUInteger i = 0; i < [args count]; i++) if (args[i] == [NSNull null] && ![_value hasPrefix:@"objectFrom"]) args[i] = (id)kCFNull;
    if (_operand) {
        id target = [_operand expressionValueWithObject:object context:context];
        if ([_value isEqualToString:@"valueForKeyPath:"]) return [target valueForKeyPath:[args firstObject]];
        SEL sel = NSSelectorFromString(_value);
        if (![target respondsToSelector:sel]) return nil;
        id (*send)(id, SEL, ...) = (id (*)(id, SEL, ...))objc_msgSend;
        switch ([args count]) {
        case 0: return send(target, sel);
        case 1: return send(target, sel, args[0]);
        default: return send(target, sel, args[0], args[1]);
        }
    }
    if ([_value isEqualToString:@"objectFrom:withIndex:"]) return index_into(args[0] == [NSNull null] ? nil : args[0], args[1]);
    if ([_value isEqualToString:@"castObject:toType:"]) return cast(args[0], args[1]);
    for (NSUInteger i = 0; i < [args count]; i++) if (args[i] == (id)kCFNull) return nil;
    return arithmetic(_value, args);
}

@end

/* MARK: - Predicates */

@interface NSTruePredicate : NSPredicate @end
@interface NSFalsePredicate : NSPredicate @end
@interface NSBlockPredicate : NSPredicate {
@public
    BOOL (^_block)(id, NSDictionary *);
}
@end

static NSPredicate *parse_predicate(NSString *format, NSArray *argumentArray, va_list *argList);

@implementation NSPredicate

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSPredicate *)predicateWithFormat:(NSString *)format argumentArray:(NSArray *)arguments { return parse_predicate(format, arguments, NULL); }

+ (NSPredicate *)predicateWithFormat:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    NSPredicate *p = parse_predicate(format, nil, &ap);
    va_end(ap);
    return p;
}

+ (NSPredicate *)predicateWithFormat:(NSString *)format arguments:(va_list)argList
{
    va_list ap;
    va_copy(ap, argList);
    NSPredicate *p = parse_predicate(format, nil, &ap);
    va_end(ap);
    return p;
}

+ (NSPredicate *)predicateFromMetadataQueryString:(NSString *)queryString { return nil; }

+ (NSPredicate *)predicateWithValue:(BOOL)value
{
    return [[[(value ? [NSTruePredicate class] : [NSFalsePredicate class]) alloc] init] autorelease];
}

+ (NSPredicate *)predicateWithBlock:(BOOL (^)(id, NSDictionary<NSString *, id> *))block
{
    NSBlockPredicate *p = [[[NSBlockPredicate alloc] init] autorelease];
    p->_block = [block copy];
    return p;
}

- (NSString *)predicateFormat { FinchAbstract(self, _cmd); }
- (NSString *)description { return [self predicateFormat]; }
- (instancetype)predicateWithSubstitutionVariables:(NSDictionary<NSString *, id> *)variables { return self; }
- (BOOL)evaluateWithObject:(id)object { return [self evaluateWithObject:object substitutionVariables:nil]; }
- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary<NSString *, id> *)bindings { FinchAbstract(self, _cmd); }
- (void)allowEvaluation { }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { }
- (BOOL)isEqual:(id)object { return object == self || ([object isKindOfClass:[NSPredicate class]] && [[self predicateFormat] isEqualToString:[object predicateFormat]]); }
- (NSUInteger)hash { return [[self predicateFormat] hash]; }

@end

@implementation NSTruePredicate
- (NSString *)predicateFormat { return @"TRUEPREDICATE"; }
- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)bindings { return YES; }
@end

@implementation NSFalsePredicate
- (NSString *)predicateFormat { return @"FALSEPREDICATE"; }
- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)bindings { return NO; }
@end

@implementation NSBlockPredicate
- (void)dealloc { [_block release]; [super dealloc]; }
- (NSString *)predicateFormat { return [NSString stringWithFormat:@"BLOCKPREDICATE(%p)", _block]; }
- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)bindings { return _block(object, bindings); }
@end

static id
evaluate_predicate(NSPredicate *p, id object, NSMutableDictionary *bindings)
{
    return [NSNumber numberWithBool:[p evaluateWithObject:object substitutionVariables:bindings]];
}

/* Constants for the variables in an expression. */
static NSExpression *
substitute(NSExpression *e, NSDictionary *vars)
{
    if (!e) return nil;
    switch (e->_expressionType) {
    case NSVariableExpressionType: {
        id v = [vars objectForKey:e->_value];
        return v ? [NSExpression expressionForConstantValue:v == [NSNull null] ? nil : v] : e;
    }
    case NSFunctionExpressionType: case NSAggregateExpressionType: case NSBlockExpressionType: case NSUnionSetExpressionType:
    case NSIntersectSetExpressionType: case NSMinusSetExpressionType: case NSSubqueryExpressionType: case NSConditionalExpressionType: {
        NSExpression *c = [[[[e class] alloc] initWithExpressionType:e->_expressionType] autorelease];
        c->_value = [e->_value retain];
        c->_operand = [substitute(e->_operand, vars) retain];
        c->_right = [substitute(e->_right, vars) retain];
        c->_predicate = [[e->_predicate predicateWithSubstitutionVariables:vars] retain];
        NSMutableArray *a = e->_arguments ? [NSMutableArray array] : nil;
        for (NSExpression *x in e->_arguments) [a addObject:substitute(x, vars)];
        c->_arguments = [a copy];
        return c;
    }
    default: return e;
    }
}

/* MARK: - NSComparisonPredicate */

/* The UTI operators have no public operator types; these are Finch's. UTI
 * comparisons need the type database (Uniform Type Identifiers), which
 * Finch doesn't have yet: they evaluate false. */
enum { UTI_CONFORMS_TO = 2000, UTI_EQUALS = 2001 };

@implementation NSComparisonPredicate {
    NSExpression *_left, *_rightExpr;
    NSComparisonPredicateModifier _modifier;
    NSPredicateOperatorType _type;
    NSComparisonPredicateOptions _options;
    SEL _selector;
}

+ (NSComparisonPredicate *)predicateWithLeftExpression:(NSExpression *)lhs rightExpression:(NSExpression *)rhs modifier:(NSComparisonPredicateModifier)modifier
                                                   type:(NSPredicateOperatorType)type options:(NSComparisonPredicateOptions)options
{
    return [[[self alloc] initWithLeftExpression:lhs rightExpression:rhs modifier:modifier type:type options:options] autorelease];
}

+ (NSComparisonPredicate *)predicateWithLeftExpression:(NSExpression *)lhs rightExpression:(NSExpression *)rhs customSelector:(SEL)selector
{
    return [[[self alloc] initWithLeftExpression:lhs rightExpression:rhs customSelector:selector] autorelease];
}

- (instancetype)initWithLeftExpression:(NSExpression *)lhs rightExpression:(NSExpression *)rhs modifier:(NSComparisonPredicateModifier)modifier
                                  type:(NSPredicateOperatorType)type options:(NSComparisonPredicateOptions)options
{
    if ((self = [super init])) {
        _left = [lhs retain];
        _rightExpr = [rhs retain];
        _modifier = modifier;
        _type = type;
        _options = options;
    }
    return self;
}

- (instancetype)initWithLeftExpression:(NSExpression *)lhs rightExpression:(NSExpression *)rhs customSelector:(SEL)selector
{
    if ((self = [self initWithLeftExpression:lhs rightExpression:rhs modifier:NSDirectPredicateModifier type:NSCustomSelectorPredicateOperatorType options:0]))
        _selector = selector;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }

- (void)dealloc
{
    [_left release];
    [_rightExpr release];
    [super dealloc];
}

- (NSPredicateOperatorType)predicateOperatorType { return _type; }
- (NSComparisonPredicateModifier)comparisonPredicateModifier { return _modifier; }
- (NSExpression *)leftExpression { return _left; }
- (NSExpression *)rightExpression { return _rightExpr; }
- (SEL)customSelector { return _selector; }
- (NSComparisonPredicateOptions)options { return _options; }

static NSString *
operator_name(NSPredicateOperatorType type)
{
    switch (type) {
    case NSLessThanPredicateOperatorType: return @"<";
    case NSLessThanOrEqualToPredicateOperatorType: return @"<=";
    case NSGreaterThanPredicateOperatorType: return @">";
    case NSGreaterThanOrEqualToPredicateOperatorType: return @">=";
    case NSEqualToPredicateOperatorType: return @"==";
    case NSNotEqualToPredicateOperatorType: return @"!=";
    case NSMatchesPredicateOperatorType: return @"MATCHES";
    case NSLikePredicateOperatorType: return @"LIKE";
    case NSBeginsWithPredicateOperatorType: return @"BEGINSWITH";
    case NSEndsWithPredicateOperatorType: return @"ENDSWITH";
    case NSInPredicateOperatorType: return @"IN";
    case NSContainsPredicateOperatorType: return @"CONTAINS";
    case NSBetweenPredicateOperatorType: return @"BETWEEN";
    case NSCustomSelectorPredicateOperatorType: return @"";
    }
    if ((NSUInteger)type == UTI_CONFORMS_TO) return @"UTI-CONFORMS-TO";
    if ((NSUInteger)type == UTI_EQUALS) return @"UTI-EQUALS";
    return @"?";
}

- (NSString *)predicateFormat
{
    NSMutableString *s = [NSMutableString string];
    if (_modifier == NSAnyPredicateModifier) [s appendString:@"ANY "];
    if (_modifier == NSAllPredicateModifier) [s appendString:@"ALL "];
    NSString *op = _type == NSCustomSelectorPredicateOperatorType ? NSStringFromSelector(_selector) : operator_name(_type);
    NSString *opts = @"";
    if (_options & (NSCaseInsensitivePredicateOption | NSDiacriticInsensitivePredicateOption | NSNormalizedPredicateOption)) {
        opts = [NSString stringWithFormat:@"[%@%@%@]", (_options & NSCaseInsensitivePredicateOption) ? @"c" : @"",
            (_options & NSDiacriticInsensitivePredicateOption) ? @"d" : @"", (_options & NSNormalizedPredicateOption) ? @"n" : @""];
    }
    [s appendFormat:@"%@ %@%@ %@", _left, op, opts, _rightExpr];
    return s;
}

- (instancetype)predicateWithSubstitutionVariables:(NSDictionary *)variables
{
    NSComparisonPredicate *p = [[[NSComparisonPredicate alloc] initWithLeftExpression:substitute(_left, variables) rightExpression:substitute(_rightExpr, variables)
                                                                              modifier:_modifier type:_type options:_options] autorelease];
    p->_selector = _selector;
    return p;
}

static NSStringCompareOptions
string_options(NSComparisonPredicateOptions o)
{
    NSStringCompareOptions s = 0;
    if (o & NSCaseInsensitivePredicateOption) s |= NSCaseInsensitiveSearch;
    if (o & NSDiacriticInsensitivePredicateOption) s |= NSDiacriticInsensitiveSearch;
    return s;
}

static BOOL
equal_values(id a, id b, NSComparisonPredicateOptions options)
{
    if (a == b) return YES;
    if (!a || !b || a == [NSNull null] || b == [NSNull null]) return (!a || a == [NSNull null]) && (!b || b == [NSNull null]);
    if ([a isKindOfClass:[NSString class]] && [b isKindOfClass:[NSString class]])
        return [a compare:b options:string_options(options)] == NSOrderedSame;
    if ([a isKindOfClass:[NSNumber class]] && [b isKindOfClass:[NSNumber class]]) return [a compare:b] == NSOrderedSame;
    return [a isEqual:b];
}

static NSString *
like_pattern(NSString *wild)
{
    NSMutableString *r = [NSMutableString stringWithString:@"^"];
    for (NSUInteger i = 0; i < [wild length]; i++) {
        unichar c = [wild characterAtIndex:i];
        if (c == '*') [r appendString:@".*"];
        else if (c == '?') [r appendString:@"."];
        else if (c == '\\' && i + 1 < [wild length]) [r appendString:[NSRegularExpression escapedPatternForString:[NSString stringWithFormat:@"%C", [wild characterAtIndex:++i]]]];
        else [r appendString:[NSRegularExpression escapedPatternForString:[NSString stringWithFormat:@"%C", c]]];
    }
    [r appendString:@"$"];
    return r;
}

static BOOL
regex_match(NSString *s, NSString *pattern, NSComparisonPredicateOptions options, BOOL anchored)
{
    if (![s isKindOfClass:[NSString class]] || ![pattern isKindOfClass:[NSString class]]) return NO;
    NSRegularExpressionOptions o = (options & NSCaseInsensitivePredicateOption) ? NSRegularExpressionCaseInsensitive : 0;
    NSString *p = anchored ? pattern : pattern;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p options:o error:NULL];
    if (!re) FinchRaise(NSInvalidArgumentException, "Can't do regex matching, reason: (Can't open pattern U_REGEX_RULE_SYNTAX (string %s, pattern %s, case 0, canon 0))",
        [s UTF8String], [pattern UTF8String]);
    NSRange m = [re rangeOfFirstMatchInString:s options:NSMatchingAnchored range:NSMakeRange(0, [s length])];
    return m.location == 0 && m.length == [s length];
}

static BOOL
compare(id l, id r, NSPredicateOperatorType type, NSComparisonPredicateOptions options, SEL selector)
{
    if (l == [NSNull null]) l = nil;
    if (r == [NSNull null]) r = nil;
    switch (type) {
    case NSEqualToPredicateOperatorType: return equal_values(l, r, options);
    case NSNotEqualToPredicateOperatorType: return !equal_values(l, r, options);
    case NSLessThanPredicateOperatorType: case NSLessThanOrEqualToPredicateOperatorType:
    case NSGreaterThanPredicateOperatorType: case NSGreaterThanOrEqualToPredicateOperatorType: {
        if (!l || !r) return NO;
        NSComparisonResult c = ([l isKindOfClass:[NSString class]] && [r isKindOfClass:[NSString class]]) ? [l compare:r options:string_options(options)] : [l compare:r];
        if (type == NSLessThanPredicateOperatorType) return c == NSOrderedAscending;
        if (type == NSLessThanOrEqualToPredicateOperatorType) return c != NSOrderedDescending;
        if (type == NSGreaterThanPredicateOperatorType) return c == NSOrderedDescending;
        return c != NSOrderedAscending;
    }
    case NSMatchesPredicateOperatorType: return regex_match(l, r, options, YES);
    case NSLikePredicateOperatorType: return [r isKindOfClass:[NSString class]] && regex_match(l, like_pattern(r), options, YES);
    case NSBeginsWithPredicateOperatorType:
        return [l isKindOfClass:[NSString class]] && [r isKindOfClass:[NSString class]] &&
            [l rangeOfString:r options:string_options(options) | NSAnchoredSearch].location != NSNotFound;
    case NSEndsWithPredicateOperatorType:
        return [l isKindOfClass:[NSString class]] && [r isKindOfClass:[NSString class]] &&
            [l rangeOfString:r options:string_options(options) | NSAnchoredSearch | NSBackwardsSearch].location != NSNotFound;
    case NSContainsPredicateOperatorType:
        if ([l isKindOfClass:[NSString class]]) return [r isKindOfClass:[NSString class]] && ([r length] == 0 || [l rangeOfString:r options:string_options(options)].location != NSNotFound);
        for (id v in as_array(l)) if (equal_values(v, r, options)) return YES;
        return NO;
    case NSInPredicateOperatorType:
        if ([r isKindOfClass:[NSString class]]) return [l isKindOfClass:[NSString class]] && [r rangeOfString:l options:string_options(options)].location != NSNotFound;
        if ([r isKindOfClass:[NSDictionary class]]) r = [r allValues];
        for (id v in as_array(r)) if (equal_values(l, v, options)) return YES;
        return NO;
    case NSBetweenPredicateOperatorType: {
        NSArray *bounds = as_array(r);
        if ([bounds count] != 2 || !l) return NO;
        return [l compare:bounds[0]] != NSOrderedAscending && [l compare:bounds[1]] != NSOrderedDescending;
    }
    case NSCustomSelectorPredicateOperatorType:
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(l, selector, r);
    }
    return NO;
}

- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)bindings
{
    NSMutableDictionary *ctx = bindings ? [[bindings mutableCopy] autorelease] : nil;
    id l = [_left expressionValueWithObject:object context:ctx];
    id r = [_rightExpr expressionValueWithObject:object context:ctx];
    if (_modifier == NSDirectPredicateModifier) return compare(l, r, _type, _options, _selector);
    NSArray *items = as_array(l);
    if (!items) {
        if (!l) return NO;
        FinchRaise(NSInvalidArgumentException, "The left hand side for an ALL or ANY operator must be either an NSArray or an NSSet.");
    }
    for (id v in items) {
        BOOL m = compare(v, r, _type, _options, _selector);
        if (_modifier == NSAnyPredicateModifier && m) return YES;
        if (_modifier == NSAllPredicateModifier && !m) return NO;
    }
    return _modifier == NSAllPredicateModifier;
}

@end

/* MARK: - NSCompoundPredicate */

@implementation NSCompoundPredicate {
    NSCompoundPredicateType _type;
    NSArray *_subpredicates;
}

+ (NSCompoundPredicate *)andPredicateWithSubpredicates:(NSArray<NSPredicate *> *)subpredicates
{
    return [[[self alloc] initWithType:NSAndPredicateType subpredicates:subpredicates] autorelease];
}

+ (NSCompoundPredicate *)orPredicateWithSubpredicates:(NSArray<NSPredicate *> *)subpredicates
{
    return [[[self alloc] initWithType:NSOrPredicateType subpredicates:subpredicates] autorelease];
}

+ (NSCompoundPredicate *)notPredicateWithSubpredicate:(NSPredicate *)predicate
{
    return [[[self alloc] initWithType:NSNotPredicateType subpredicates:@[ predicate ]] autorelease];
}

- (instancetype)initWithType:(NSCompoundPredicateType)type subpredicates:(NSArray<NSPredicate *> *)subpredicates
{
    if ((self = [super init])) {
        _type = type;
        _subpredicates = [subpredicates copy];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)dealloc { [_subpredicates release]; [super dealloc]; }
- (NSCompoundPredicateType)compoundPredicateType { return _type; }
- (NSArray *)subpredicates { return _subpredicates; }

/* Compound subpredicates are parenthesized, as Apple's are. */
static NSString *
sub_format(NSPredicate *p)
{
    NSString *f = [p predicateFormat];
    return [p isKindOfClass:[NSCompoundPredicate class]] ? [NSString stringWithFormat:@"(%@)", f] : f;
}

- (NSString *)predicateFormat
{
    if (_type == NSNotPredicateType) return [@"NOT " stringByAppendingString:sub_format([_subpredicates firstObject])];
    if (![_subpredicates count]) return _type == NSAndPredicateType ? @"TRUEPREDICATE" : @"FALSEPREDICATE";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSPredicate *p in _subpredicates) [parts addObject:sub_format(p)];
    return [parts componentsJoinedByString:_type == NSAndPredicateType ? @" AND " : @" OR "];
}

- (instancetype)predicateWithSubstitutionVariables:(NSDictionary *)variables
{
    NSMutableArray *subs = [NSMutableArray array];
    for (NSPredicate *p in _subpredicates) [subs addObject:[p predicateWithSubstitutionVariables:variables]];
    return [[[NSCompoundPredicate alloc] initWithType:_type subpredicates:subs] autorelease];
}

- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)bindings
{
    switch (_type) {
    case NSNotPredicateType: return ![[_subpredicates firstObject] evaluateWithObject:object substitutionVariables:bindings];
    case NSAndPredicateType:
        for (NSPredicate *p in _subpredicates) if (![p evaluateWithObject:object substitutionVariables:bindings]) return NO;
        return YES;
    case NSOrPredicateType:
        for (NSPredicate *p in _subpredicates) if ([p evaluateWithObject:object substitutionVariables:bindings]) return YES;
        return NO;
    }
    return NO;
}

@end

/* MARK: - The parser */

typedef enum { T_END, T_IDENT, T_NUMBER, T_STRING, T_VARIABLE, T_ARG, T_OP } TokenKind;

typedef struct {
    TokenKind kind;
    NSString *text;     /* identifier, operator, string contents, variable name, arg spec */
    id value;           /* number */
} Token;

typedef struct {
    NSString *format;
    NSMutableArray *tokens;   /* NSValue-wrapped Token pointers, kept alive by `storage` */
    NSMutableData *storage;
    NSUInteger at, count;
    NSArray *argArray;
    NSUInteger argIndex;
    va_list *args;
} Parser;

static void __attribute__((noreturn))
parse_error(Parser *p)
{
    FinchRaise(NSInvalidArgumentException, "Unable to parse the format string \"%s\"", [p->format UTF8String]);
}

static Token *
tok(Parser *p, NSUInteger i)
{
    return i < p->count ? &((Token *)[p->storage mutableBytes])[i] : &((Token *)[p->storage mutableBytes])[p->count];
}

static Token *peek(Parser *p) { return tok(p, p->at); }
static Token *next(Parser *p) { Token *t = tok(p, p->at); if (p->at < p->count) p->at++; return t; }

static BOOL
is_word(Token *t, const char *word)
{
    return t->kind == T_IDENT && [t->text caseInsensitiveCompare:[NSString stringWithUTF8String:word]] == NSOrderedSame;
}

static BOOL
is_op(Token *t, const char *op)
{
    return t->kind == T_OP && [t->text isEqualToString:[NSString stringWithUTF8String:op]];
}

static void
expect_op(Parser *p, const char *op)
{
    if (!is_op(next(p), op)) parse_error(p);
}

static void
tokenize(Parser *p)
{
    NSString *s = p->format;
    NSUInteger n = [s length], i = 0;
    NSMutableData *store = [NSMutableData data];
    while (1) {
        while (i < n && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[s characterAtIndex:i]]) i++;
        Token t = { T_END, nil, nil };
        if (i >= n) {
            [store appendBytes:&t length:sizeof(t)];
            break;
        }
        unichar c = [s characterAtIndex:i];
        if (c == '"' || c == '\'') {
            NSMutableString *str = [NSMutableString string];
            i++;
            while (i < n && [s characterAtIndex:i] != c) {
                unichar d = [s characterAtIndex:i];
                if (d == '\\' && i + 1 < n) {
                    unichar e = [s characterAtIndex:++i];
                    switch (e) {
                    case 'n': d = '\n'; break;
                    case 't': d = '\t'; break;
                    case 'r': d = '\r'; break;
                    default: d = e; break;
                    }
                }
                [str appendFormat:@"%C", d];
                i++;
            }
            if (i >= n) parse_error(p);
            i++;
            t.kind = T_STRING;
            t.text = [str retain];
        } else if (c == '%') {
            NSUInteger start = i++;
            while (i < n && strchr("lhqz", (char)[s characterAtIndex:i])) i++;
            if (i >= n) parse_error(p);
            i++;
            t.kind = T_ARG;
            t.text = [[s substringWithRange:NSMakeRange(start, i - start)] retain];
            if ([t.text isEqualToString:@"%%"]) {
                t.kind = T_OP;
            }
        } else if (c == '$') {
            NSUInteger start = ++i;
            while (i < n && ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:[s characterAtIndex:i]] || [s characterAtIndex:i] == '_')) i++;
            t.kind = T_VARIABLE;
            t.text = [[s substringWithRange:NSMakeRange(start, i - start)] retain];
        } else if ((c >= '0' && c <= '9') || (c == '.' && i + 1 < n && [s characterAtIndex:i + 1] >= '0' && [s characterAtIndex:i + 1] <= '9')) {
            NSUInteger start = i;
            if (c == '0' && i + 1 < n && strchr("xXoObB", (char)[s characterAtIndex:i + 1])) {
                unichar base = [s characterAtIndex:i + 1];
                i += 2;
                NSUInteger ds = i;
                while (i < n && [[NSCharacterSet alphanumericCharacterSet] characterIsMember:[s characterAtIndex:i]]) i++;
                /* Apple's reads hex; 0o and 0b literals come out as 0. */
                long long v = (base == 'x' || base == 'X') ? strtoll([[s substringWithRange:NSMakeRange(ds, i - ds)] UTF8String], NULL, 16) : 0;
                t.value = [[NSNumber numberWithLongLong:v] retain];
            } else {
                BOOL real = NO;
                while (i < n) {
                    unichar d = [s characterAtIndex:i];
                    if (d >= '0' && d <= '9') { i++; continue; }
                    if (d == '.' && !real) { real = YES; i++; continue; }
                    if ((d == 'e' || d == 'E') && i + 1 < n) {
                        real = YES;
                        i++;
                        if ([s characterAtIndex:i] == '-' || [s characterAtIndex:i] == '+') i++;
                        continue;
                    }
                    break;
                }
                NSString *num = [s substringWithRange:NSMakeRange(start, i - start)];
                t.value = [(real ? [NSNumber numberWithDouble:[num doubleValue]] : [NSNumber numberWithLongLong:[num longLongValue]]) retain];
            }
            t.kind = T_NUMBER;
        } else if ([[NSCharacterSet letterCharacterSet] characterIsMember:c] || c == '_' || c == '@' || c == '#') {
            NSUInteger start = i++;
            while (i < n) {
                unichar d = [s characterAtIndex:i];
                if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:d] || d == '_' || d == ':') { i++; continue; }
                if (d == '-' && i + 1 < n && [[s substringWithRange:NSMakeRange(start, i - start)] caseInsensitiveCompare:@"UTI"] == NSOrderedSame) { i++; continue; }
                if (d == '-' && [[[s substringWithRange:NSMakeRange(start, i - start)] uppercaseString] hasPrefix:@"UTI-"] && i + 1 < n) { i++; continue; }
                break;
            }
            t.kind = T_IDENT;
            t.text = [[s substringWithRange:NSMakeRange(start, i - start)] retain];
        } else {
            static const char *ops[] = { "**", "==", "!=", "<>", ">=", "=>", "<=", "=<", "&&", "||", "<", ">", "=", "!", "+", "-", "*", "/", "(", ")",
                                         "{", "}", "[", "]", ",", ".", NULL };
            const char *match = NULL;
            for (int k = 0; ops[k]; k++) {
                size_t len = strlen(ops[k]);
                if (i + len <= n && [[s substringWithRange:NSMakeRange(i, len)] isEqualToString:[NSString stringWithUTF8String:ops[k]]]) { match = ops[k]; break; }
            }
            if (!match) parse_error(p);
            t.kind = T_OP;
            t.text = [[NSString stringWithUTF8String:match] retain];
            i += strlen(match);
        }
        [store appendBytes:&t length:sizeof(t)];
    }
    p->storage = store;
    p->count = [store length] / sizeof(Token) - 1;
}

static void
release_tokens(Parser *p)
{
    Token *t = [p->storage mutableBytes];
    for (NSUInteger i = 0; i <= p->count; i++) {
        [t[i].text release];
        [t[i].value release];
    }
}

/* The next argument for a format specifier. */
static id
take_argument(Parser *p, NSString *spec)
{
    if (p->argArray) {
        if (p->argIndex >= [p->argArray count]) parse_error(p);
        id v = p->argArray[p->argIndex++];
        return v == [NSNull null] ? nil : v;
    }
    if (!p->args) parse_error(p);
    unichar c = [spec characterAtIndex:[spec length] - 1];
    BOOL longlong = [spec rangeOfString:@"ll"].location != NSNotFound || [spec rangeOfString:@"q"].location != NSNotFound;
    BOOL lng = !longlong && [spec rangeOfString:@"l"].location != NSNotFound;
    switch (c) {
    case '@': case 'K': return va_arg(*p->args, id);
    case 'd': case 'i':
        if (longlong) return [NSNumber numberWithLongLong:va_arg(*p->args, long long)];
        if (lng) return [NSNumber numberWithLong:va_arg(*p->args, long)];
        return [NSNumber numberWithInt:va_arg(*p->args, int)];
    case 'u': case 'x': case 'X': case 'o':
        if (longlong) return [NSNumber numberWithUnsignedLongLong:va_arg(*p->args, unsigned long long)];
        if (lng) return [NSNumber numberWithUnsignedLong:va_arg(*p->args, unsigned long)];
        return [NSNumber numberWithUnsignedInt:va_arg(*p->args, unsigned int)];
    case 'f': case 'e': case 'g': return [NSNumber numberWithDouble:va_arg(*p->args, double)];
    case 'c': return [NSString stringWithFormat:@"%c", (char)va_arg(*p->args, int)];
    case 's': {
        const char *s = va_arg(*p->args, const char *);
        return s ? [NSString stringWithUTF8String:s] : nil;
    }
    case 'p': return [NSNumber numberWithUnsignedLongLong:(unsigned long long)(uintptr_t)va_arg(*p->args, void *)];
    }
    parse_error(p);
}

static NSExpression *parse_expression(Parser *p);
static NSPredicate *parse_or(Parser *p);

static NSExpression *
keypath_or_function(Parser *p, NSExpression *base, NSString *component)
{
    if (!base) return [NSExpression expressionForKeyPath:component];
    if (base->_expressionType == NSKeyPathExpressionType)
        return [NSExpression expressionForKeyPath:[NSString stringWithFormat:@"%@.%@", base->_value, component]];
    if (base->_expressionType == NSEvaluatedObjectExpressionType) return [NSExpression expressionForKeyPath:component];
    return [NSExpression expressionForFunction:base selectorName:@"valueForKeyPath:" arguments:@[ [NSExpression expressionForConstantValue:component] ]];
}

static NSString *
identifier_text(Token *t)
{
    return [t->text hasPrefix:@"#"] ? [t->text substringFromIndex:1] : t->text;
}

static NSExpression *
parse_primary(Parser *p)
{
    Token *t = next(p);
    switch (t->kind) {
    case T_NUMBER: return [NSExpression expressionForConstantValue:t->value];
    case T_STRING: return [NSExpression expressionForConstantValue:t->text];
    case T_VARIABLE: return [NSExpression expressionForVariable:t->text];
    case T_ARG: {
        id v = take_argument(p, t->text);
        if ([t->text hasSuffix:@"K"]) {
            if (![v isKindOfClass:[NSString class]]) parse_error(p);
            return [NSExpression expressionForKeyPath:v];
        }
        return [NSExpression expressionForConstantValue:v];
    }
    case T_OP:
        if (is_op(t, "(")) {
            NSExpression *e = parse_expression(p);
            expect_op(p, ")");
            return e;
        }
        if (is_op(t, "{")) {
            NSMutableArray *items = [NSMutableArray array];
            if (!is_op(peek(p), "}")) {
                do [items addObject:parse_expression(p)];
                while (is_op(peek(p), ",") && next(p));
            }
            expect_op(p, "}");
            return [NSExpression expressionForAggregate:items];
        }
        parse_error(p);
    case T_IDENT: break;
    default: parse_error(p);
    }
    NSString *word = [t->text uppercaseString];
    if ([word isEqualToString:@"SELF"]) return [NSExpression expressionForEvaluatedObject];
    if ([word isEqualToString:@"NIL"] || [word isEqualToString:@"NULL"]) return [NSExpression expressionForConstantValue:nil];
    if ([word isEqualToString:@"YES"] || [word isEqualToString:@"TRUE"]) return [NSExpression expressionForConstantValue:@YES];
    if ([word isEqualToString:@"NO"] || [word isEqualToString:@"FALSE"]) return [NSExpression expressionForConstantValue:@NO];
    if ([word isEqualToString:@"FIRST"] || [word isEqualToString:@"LAST"] || [word isEqualToString:@"SIZE"]) return symbol(word);
    if ([word isEqualToString:@"ANYKEY"]) return [NSExpression expressionForAnyKey];
    if ([word isEqualToString:@"SUBQUERY"] && is_op(peek(p), "(")) {
        next(p);
        NSExpression *coll = parse_expression(p);
        expect_op(p, ",");
        Token *v = next(p);
        if (v->kind != T_VARIABLE) parse_error(p);
        expect_op(p, ",");
        NSPredicate *pred = parse_or(p);
        expect_op(p, ")");
        return [NSExpression expressionForSubquery:coll usingIteratorVariable:v->text predicate:pred];
    }
    if ([word isEqualToString:@"FUNCTION"] && is_op(peek(p), "(")) {
        next(p);
        NSExpression *target = parse_expression(p);
        expect_op(p, ",");
        Token *sel = next(p);
        if (sel->kind != T_STRING) parse_error(p);
        NSMutableArray *args = [NSMutableArray array];
        while (is_op(peek(p), ",") && next(p)) [args addObject:parse_expression(p)];
        expect_op(p, ")");
        return [NSExpression expressionForFunction:target selectorName:sel->text arguments:args];
    }
    if (([word isEqualToString:@"CAST"] || [word isEqualToString:@"TERNARY"]) && is_op(peek(p), "(")) {
        next(p);
        if ([word isEqualToString:@"TERNARY"]) {
            NSPredicate *cond = parse_or(p);
            expect_op(p, ",");
            NSExpression *a = parse_expression(p);
            expect_op(p, ",");
            NSExpression *b = parse_expression(p);
            expect_op(p, ")");
            return [NSExpression expressionForConditional:cond trueExpression:a falseExpression:b];
        }
        NSExpression *value = parse_expression(p);
        expect_op(p, ",");
        NSExpression *type = parse_expression(p);
        expect_op(p, ")");
        /* Casts of constants are done here, as Apple's are. */
        if (type->_expressionType == NSConstantValueExpressionType && value->_expressionType == NSConstantValueExpressionType &&
            [type->_value isKindOfClass:[NSString class]])
            return [NSExpression expressionForConstantValue:cast(value->_value, type->_value)];
        return [NSExpression expressionForFunction:@"castObject:toType:" arguments:@[ value, type ]];
    }
    /* A function call: name:(args), e.g. sum:({1, 2}) */
    if ([t->text hasSuffix:@":"] && is_op(peek(p), "(")) {
        next(p);
        NSMutableArray *args = [NSMutableArray array];
        if (!is_op(peek(p), ")")) {
            do [args addObject:parse_expression(p)];
            while (is_op(peek(p), ",") && next(p));
        }
        expect_op(p, ")");
        return [NSExpression expressionForFunction:t->text arguments:args];
    }
    if (([word isEqualToString:@"NOW"] || [word isEqualToString:@"RANDOM"]) && is_op(peek(p), "(")) {
        next(p);
        expect_op(p, ")");
        return [NSExpression expressionForFunction:[t->text lowercaseString] arguments:@[]];
    }
    return [NSExpression expressionForKeyPath:identifier_text(t)];
}

static NSExpression *
parse_postfix(Parser *p)
{
    NSExpression *e = parse_primary(p);
    for (;;) {
        if (is_op(peek(p), ".")) {
            next(p);
            Token *c = next(p);
            if (c->kind == T_ARG && [c->text hasSuffix:@"K"]) {
                id v = take_argument(p, c->text);
                e = keypath_or_function(p, e, v);
            } else if (c->kind == T_IDENT) {
                e = keypath_or_function(p, e, identifier_text(c));
            } else {
                parse_error(p);
            }
        } else if (is_op(peek(p), "[")) {
            next(p);
            NSExpression *index = parse_expression(p);
            expect_op(p, "]");
            e = [NSExpression expressionForFunction:@"objectFrom:withIndex:" arguments:@[ e, index ]];
        } else {
            return e;
        }
    }
}

static NSExpression *
parse_unary(Parser *p)
{
    if (is_op(peek(p), "-")) {
        next(p);
        NSExpression *e = parse_unary(p);
        if (e->_expressionType == NSConstantValueExpressionType && [e->_value isKindOfClass:[NSNumber class]]) {
            NSNumber *n = e->_value;
            return [NSExpression expressionForConstantValue:strchr("fd", *[n objCType]) ? [NSNumber numberWithDouble:-[n doubleValue]]
                                                                                        : [NSNumber numberWithLongLong:-[n longLongValue]]];
        }
        return [NSExpression expressionForFunction:@"from:subtract:" arguments:@[ [NSExpression expressionForConstantValue:@0], e ]];
    }
    return parse_postfix(p);
}

static NSExpression *
parse_power(Parser *p)
{
    NSExpression *e = parse_unary(p);
    while (is_op(peek(p), "**")) {
        next(p);
        e = [NSExpression expressionForFunction:@"raise:toPower:" arguments:@[ e, parse_unary(p) ]];
    }
    return e;
}

static NSExpression *
parse_multiplicative(Parser *p)
{
    NSExpression *e = parse_power(p);
    for (;;) {
        if (is_op(peek(p), "*")) { next(p); e = [NSExpression expressionForFunction:@"multiply:by:" arguments:@[ e, parse_power(p) ]]; }
        else if (is_op(peek(p), "/")) { next(p); e = [NSExpression expressionForFunction:@"divide:by:" arguments:@[ e, parse_power(p) ]]; }
        else return e;
    }
}

static NSExpression *
parse_expression(Parser *p)
{
    NSExpression *e = parse_multiplicative(p);
    for (;;) {
        if (is_op(peek(p), "+")) { next(p); e = [NSExpression expressionForFunction:@"add:to:" arguments:@[ e, parse_multiplicative(p) ]]; }
        else if (is_op(peek(p), "-")) { next(p); e = [NSExpression expressionForFunction:@"from:subtract:" arguments:@[ e, parse_multiplicative(p) ]]; }
        else return e;
    }
}

/* An operator and its [cdn] options, if one is next. */
static BOOL
parse_operator(Parser *p, NSPredicateOperatorType *type, NSComparisonPredicateOptions *options)
{
    Token *t = peek(p);
    NSPredicateOperatorType op;
    if (is_op(t, "==") || is_op(t, "=")) op = NSEqualToPredicateOperatorType;
    else if (is_op(t, "!=") || is_op(t, "<>")) op = NSNotEqualToPredicateOperatorType;
    else if (is_op(t, "<")) op = NSLessThanPredicateOperatorType;
    else if (is_op(t, "<=") || is_op(t, "=<")) op = NSLessThanOrEqualToPredicateOperatorType;
    else if (is_op(t, ">")) op = NSGreaterThanPredicateOperatorType;
    else if (is_op(t, ">=") || is_op(t, "=>")) op = NSGreaterThanOrEqualToPredicateOperatorType;
    else if (is_word(t, "MATCHES")) op = NSMatchesPredicateOperatorType;
    else if (is_word(t, "LIKE")) op = NSLikePredicateOperatorType;
    else if (is_word(t, "BEGINSWITH")) op = NSBeginsWithPredicateOperatorType;
    else if (is_word(t, "ENDSWITH")) op = NSEndsWithPredicateOperatorType;
    else if (is_word(t, "IN")) op = NSInPredicateOperatorType;
    else if (is_word(t, "CONTAINS")) op = NSContainsPredicateOperatorType;
    else if (is_word(t, "BETWEEN")) op = NSBetweenPredicateOperatorType;
    else if (is_word(t, "UTI-CONFORMS-TO")) op = (NSPredicateOperatorType)UTI_CONFORMS_TO;
    else if (is_word(t, "UTI-EQUALS")) op = (NSPredicateOperatorType)UTI_EQUALS;
    else return NO;
    next(p);
    NSComparisonPredicateOptions o = 0;
    if (is_op(peek(p), "[")) {
        next(p);
        Token *f = next(p);
        if (f->kind != T_IDENT) parse_error(p);
        for (NSUInteger i = 0; i < [f->text length]; i++) {
            unichar c = [f->text characterAtIndex:i];
            if (c == 'c' || c == 'C') o |= NSCaseInsensitivePredicateOption;
            else if (c == 'd' || c == 'D') o |= NSDiacriticInsensitivePredicateOption;
            else if (c == 'n' || c == 'N') o |= NSNormalizedPredicateOption;
            else if (c != 'l' && c != 'L') parse_error(p);
        }
        expect_op(p, "]");
    }
    *type = op;
    *options = o;
    return YES;
}


static NSPredicate *
parse_comparison(Parser *p)
{
    Token *t = peek(p);
    if (is_word(t, "TRUEPREDICATE")) { next(p); return [NSPredicate predicateWithValue:YES]; }
    if (is_word(t, "FALSEPREDICATE")) { next(p); return [NSPredicate predicateWithValue:NO]; }
    NSComparisonPredicateModifier modifier = NSDirectPredicateModifier;
    BOOL none = NO;
    if (is_word(t, "ANY") || is_word(t, "SOME")) { next(p); modifier = NSAnyPredicateModifier; }
    else if (is_word(t, "ALL")) { next(p); modifier = NSAllPredicateModifier; }
    else if (is_word(t, "NONE")) { next(p); modifier = NSAnyPredicateModifier; none = YES; }
    NSExpression *left = parse_expression(p);
    NSPredicateOperatorType type;
    NSComparisonPredicateOptions options;
    if (!parse_operator(p, &type, &options)) parse_error(p);
    NSExpression *right = parse_expression(p);
    NSPredicate *c = [NSComparisonPredicate predicateWithLeftExpression:left rightExpression:right modifier:modifier type:type options:options];
    return none ? [NSCompoundPredicate notPredicateWithSubpredicate:c] : c;
}

static NSPredicate *
parse_not(Parser *p)
{
    if (is_word(peek(p), "NOT") || is_op(peek(p), "!")) {
        next(p);
        return [NSCompoundPredicate notPredicateWithSubpredicate:parse_not(p)];
    }
    if (is_op(peek(p), "(")) {
        /* A parenthesized predicate, or an expression that starts with "(". */
        NSUInteger save = p->at, saveArg = p->argIndex;
        va_list saved;
        if (p->args) va_copy(saved, *p->args);
        @try {
            next(p);
            NSPredicate *inner = parse_or(p);
            expect_op(p, ")");
            if (p->args) va_end(saved);
            return inner;
        } @catch (NSException *e) {
            p->at = save;
            p->argIndex = saveArg;
            if (p->args) {
                va_end(*p->args);
                va_copy(*p->args, saved);
                va_end(saved);
            }
        }
    }
    return parse_comparison(p);
}

static NSPredicate *
parse_and(Parser *p)
{
    NSMutableArray *subs = [NSMutableArray arrayWithObject:parse_not(p)];
    while (is_word(peek(p), "AND") || is_op(peek(p), "&&")) {
        next(p);
        [subs addObject:parse_not(p)];
    }
    return [subs count] == 1 ? subs[0] : [NSCompoundPredicate andPredicateWithSubpredicates:subs];
}

static NSPredicate *
parse_or(Parser *p)
{
    NSMutableArray *subs = [NSMutableArray arrayWithObject:parse_and(p)];
    while (is_word(peek(p), "OR") || is_op(peek(p), "||")) {
        next(p);
        [subs addObject:parse_and(p)];
    }
    return [subs count] == 1 ? subs[0] : [NSCompoundPredicate orPredicateWithSubpredicates:subs];
}

static NSPredicate *
parse_predicate(NSString *format, NSArray *argumentArray, va_list *argList)
{
    if (!format) FinchRaise(NSInvalidArgumentException, "*** +[NSPredicate predicateWithFormat:]: nil format string");
    Parser p = { 0 };
    p.format = format;
    p.argArray = argumentArray;
    p.args = argList;
    tokenize(&p);
    NSPredicate *result = nil;
    @try {
        result = parse_or(&p);
        if (peek(&p)->kind != T_END) parse_error(&p);
    } @finally {
        release_tokens(&p);
    }
    return result;
}

static NSExpression *
parse_expression_format(NSString *format, NSArray *argumentArray, va_list *argList)
{
    Parser p = { 0 };
    p.format = format;
    p.argArray = argumentArray;
    p.args = argList;
    tokenize(&p);
    NSExpression *result = nil;
    @try {
        result = parse_expression(&p);
        if (peek(&p)->kind != T_END) parse_error(&p);
    } @finally {
        release_tokens(&p);
    }
    return result;
}

@implementation NSExpression (NSExpressionFormat)

+ (NSExpression *)expressionWithFormat:(NSString *)format argumentArray:(NSArray *)arguments
{
    return parse_expression_format(format, arguments, NULL);
}

+ (NSExpression *)expressionWithFormat:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    NSExpression *e = parse_expression_format(format, nil, &ap);
    va_end(ap);
    return e;
}

+ (NSExpression *)expressionWithFormat:(NSString *)format arguments:(va_list)argList
{
    va_list ap;
    va_copy(ap, argList);
    NSExpression *e = parse_expression_format(format, nil, &ap);
    va_end(ap);
    return e;
}

@end

/* MARK: - Filtering collections */

@implementation NSArray (NSPredicateSupport)
- (NSArray *)filteredArrayUsingPredicate:(NSPredicate *)predicate
{
    NSMutableArray *r = [NSMutableArray array];
    for (id o in self) if ([predicate evaluateWithObject:o]) [r addObject:o];
    return [NSArray arrayWithArray:r];
}
@end

@implementation NSMutableArray (NSPredicateSupport)
- (void)filterUsingPredicate:(NSPredicate *)predicate
{
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
    NSUInteger i = 0;
    for (id o in self) {
        if (![predicate evaluateWithObject:o]) [drop addIndex:i];
        i++;
    }
    [self removeObjectsAtIndexes:drop];
}
@end

@implementation NSSet (NSPredicateSupport)
- (NSSet *)filteredSetUsingPredicate:(NSPredicate *)predicate
{
    NSMutableSet *r = [NSMutableSet set];
    for (id o in self) if ([predicate evaluateWithObject:o]) [r addObject:o];
    return [NSSet setWithSet:r];
}
@end

@implementation NSMutableSet (NSPredicateSupport)
- (void)filterUsingPredicate:(NSPredicate *)predicate
{
    for (id o in [self allObjects]) if (![predicate evaluateWithObject:o]) [self removeObject:o];
}
@end

@implementation NSOrderedSet (NSPredicateSupport)
- (NSOrderedSet *)filteredOrderedSetUsingPredicate:(NSPredicate *)p
{
    NSMutableOrderedSet *r = [NSMutableOrderedSet orderedSet];
    for (id o in self) if ([p evaluateWithObject:o]) [r addObject:o];
    return [NSOrderedSet orderedSetWithOrderedSet:r];
}
@end

@implementation NSMutableOrderedSet (NSPredicateSupport)
- (void)filterUsingPredicate:(NSPredicate *)p
{
    for (id o in [self array]) if (![p evaluateWithObject:o]) [self removeObject:o];
}
@end
