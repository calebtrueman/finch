/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-predicate-test: NSPredicate and NSExpression (parsing, formats,
 * evaluation, substitution, functions, filtering), one result per line so
 * runs against Apple's Foundation and Finch's can be diffed.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static const char *
masked(NSString *s)
{
    if (!s) return "(null)";
    NSMutableString *m = [[[s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "] mutableCopy];
    for (NSRange r = [m rangeOfString:@"0x"]; r.location != NSNotFound; r = [m rangeOfString:@"0x" options:0 range:NSMakeRange(r.location + 3, m.length - r.location - 3)]) {
        NSUInteger end = r.location + 2;
        while (end < m.length && isxdigit([m characterAtIndex:end])) end++;
        [m replaceCharactersInRange:NSMakeRange(r.location, end - r.location) withString:@"0xA"];
    }
    return m.UTF8String;
}

static NSDictionary *bob;

static void
check(NSString *format, ...)
{
    @try {
        va_list ap;
        va_start(ap, format);
        NSPredicate *p = [NSPredicate predicateWithFormat:format arguments:ap];
        va_end(ap);
        NSString *v;
        @try {
            v = [p evaluateWithObject:bob substitutionVariables:@{@"NAME": @"bob", @"MIN": @3}] ? @"YES" : @"NO";
        } @catch (NSException *e) {
            v = e.name;
        }
        printf("%-55s | %-60s | %s | %s\n", format.UTF8String, masked(p.predicateFormat), class_getName([p class]), v.UTF8String);
    } @catch (NSException *e) {
        printf("%-55s | %s | %s\n", format.UTF8String, e.name.UTF8String, masked(e.reason));
    }
}

static void
expression(NSString *format)
{
    @try {
        NSExpression *e = [NSExpression expressionWithFormat:format];
        id v = nil;
        @try {
            v = [e expressionValueWithObject:bob context:nil];
        } @catch (NSException *x) {
            v = x.name;
        }
        printf("expr %-40s | %-40s | type %lu | %s\n", format.UTF8String, masked(e.description), (unsigned long)e.expressionType, masked([v description]));
    } @catch (NSException *x) {
        printf("expr %-40s | %s | %s\n", format.UTF8String, x.name.UTF8String, masked(x.reason));
    }
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        bob = @{@"name": @"Bob", @"age": @35, @"tags": @[@"x", @"y"], @"scores": @[@3, @4, @5], @"flag": @YES, @"city": @"Montréal",
                @"date": [NSDate dateWithTimeIntervalSinceReferenceDate:100], @"friend": @{@"name": @"Ann", @"age": @20}, @"none": [NSNull null]};

        /* Formats and evaluation */
        check(@"name == 'Bob'");
        check(@"name = \"Bob\" && age >= 35");
        check(@"name =[c] 'BOB'");
        check(@"name != 'bob'");
        check(@"name <> 'Bob'");
        check(@"age > 30 AND age <= 40 AND flag == YES");
        check(@"age < 5 OR age > 30");
        check(@"(age < 5 OR age > 30) AND name BEGINSWITH 'B'");
        check(@"NOT (age < 5)");
        check(@"!(age < 5) || FALSEPREDICATE");
        check(@"name BEGINSWITH[c] 'b' OR NOT (age < 5)");
        check(@"name ENDSWITH 'ob'");
        check(@"name CONTAINS[c] 'O'");
        check(@"city CONTAINS[d] 'tre'");
        check(@"city ==[cd] 'MONTREAL'");
        check(@"tags CONTAINS 'y'");
        check(@"name IN {'Ann', 'Bob'}");
        check(@"'o' IN name");
        check(@"age BETWEEN {30, 40}");
        check(@"age BETWEEN %@", @[@36, @40]);
        check(@"name LIKE 'B?b'");
        check(@"name LIKE[c] '*O*'");
        check(@"name MATCHES '[A-Z][a-z]+'");
        check(@"name MATCHES '[a-z]+'");
        check(@"ANY tags == 'x'");
        check(@"SOME tags == 'z'");
        check(@"ALL scores >= 3");
        check(@"NONE scores > 4");
        check(@"ANY name == 'Bob'");
        check(@"friend.name == 'Ann' AND friend.age < age");
        check(@"SELF.name == 'Bob'");
        check(@"SELF == SELF");
        check(@"tags[FIRST] == 'x' AND tags[LAST] == 'y' AND tags[SIZE] == 2 AND scores[1] == 4");
        check(@"scores.@count == 3 AND scores.@sum == 12 AND scores.@avg == 4 AND scores.@max == 5 AND scores.@min == 3");
        check(@"@count > 3");
        check(@"age + 1 * 2 == 37");
        check(@"(age + 1) * 2 == 72");
        check(@"age - 5 / 5 == 34");
        check(@"2 ** 3 ** 2 == 64");
        check(@"-age < 0");
        check(@"age == 35.0");
        check(@"age == 0x23 AND age == 0o43 AND age == 0b100011");
        check(@"1e2 == 100");
        check(@"none == nil AND missing == nil");
        check(@"name != NULL");
        check(@"flag == TRUE AND flag != NO");
        check(@"date > CAST(0, 'NSDate') AND date < CAST(200, \"NSDate\")");
        check(@"name ==[c] $NAME");
        check(@"age > $MIN");
        check(@"age > $UNBOUND");
        check(@"SUBQUERY(scores, $s, $s > 3).@count == 2");
        check(@"SUBQUERY(tags, $t, $t BEGINSWITH 'x')[SIZE] == 1");
        check(@"TERNARY(age > 30, 'old', 'young') == 'old'");
        check(@"sum:(scores) == 12 AND count:(tags) == 2 AND max:(scores) == 5");
        check(@"average:({1, 2, 6}) == 3");
        check(@"uppercase:(name) == 'BOB' AND lowercase:(name) == 'bob'");
        check(@"sqrt:(16) == 4 AND abs:(-3) == 3 AND floor:(2.7) == 2 AND ceiling:(2.1) == 3");
        check(@"%K == %@", @"name", @"Bob");
        check(@"%K BEGINSWITH %@", @"friend.name", @"A");
        check(@"age == %d AND age != %ld AND %f < 36.0", 35, 1L, 35.5);
        check(@"name == %s", "Bob");
        check(@"name == %@", nil);
        check(@"TRUEPREDICATE");
        check(@"FALSEPREDICATE");
        check(@"name == ");
        check(@"name === 'x'");
        check(@"(name == 'x'");
        check(@"name BOGUS 'x'");

        /* Expressions */
        expression(@"1 + 2 * 3");
        expression(@"(1 + 2) * 3");
        expression(@"10 / 4");
        expression(@"7 - -2");
        expression(@"name");
        expression(@"friend.name");
        expression(@"{1, 'two', name}");
        expression(@"scores[2]");
        expression(@"sum:({1.5, 2.5})");
        expression(@"median:({3, 1, 2})");
        expression(@"stddev:({2, 4, 4, 4, 5, 5, 7, 9})");
        expression(@"CAST('5', 'NSNumber')");
        expression(@"SELF");
        expression(@"$x");
        NSExpression *u = [NSExpression expressionForUnionSet:[NSExpression expressionForConstantValue:@[@1, @2]] with:[NSExpression expressionForConstantValue:@[@2, @3]]];
        printf("union: %s = %lu\n", masked(u.description), (unsigned long)[[u expressionValueWithObject:nil context:nil] count]);
        NSExpression *fn = [NSExpression expressionForFunction:[NSExpression expressionForConstantValue:@"abc"] selectorName:@"uppercaseString" arguments:@[]];
        printf("function: %s = %s\n", masked(fn.description), masked([[fn expressionValueWithObject:nil context:nil] description]));
        NSExpression *blk = [NSExpression expressionForBlock:^id(id obj, NSArray *args, NSMutableDictionary *ctx) { return @([args count]); } arguments:@[]];
        printf("block: type %lu value %s\n", (unsigned long)blk.expressionType, masked([[blk expressionValueWithObject:nil context:nil] description]));

        /* Construction */
        NSComparisonPredicate *cp = (id)[NSPredicate predicateWithFormat:@"ALL name ==[cd] 'x'"];
        printf("comparison: op %lu options %lu modifier %lu left %lu %s right %s\n", (unsigned long)cp.predicateOperatorType, (unsigned long)cp.options,
            (unsigned long)cp.comparisonPredicateModifier, (unsigned long)cp.leftExpression.expressionType, cp.leftExpression.keyPath.UTF8String,
            masked([cp.rightExpression.constantValue description]));
        NSPredicate *built = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"age"]
                                                                rightExpression:[NSExpression expressionForConstantValue:@30]
                                                                       modifier:NSDirectPredicateModifier type:NSGreaterThanPredicateOperatorType options:0];
        NSCompoundPredicate *and = [NSCompoundPredicate andPredicateWithSubpredicates:@[built, [NSPredicate predicateWithValue:YES]]];
        printf("built: %s | %s | %s | %d\n", masked(built.predicateFormat), masked(and.predicateFormat),
            masked([NSCompoundPredicate notPredicateWithSubpredicate:and].predicateFormat), [and evaluateWithObject:bob]);
        printf("compound: type %lu subs %lu | empty and %s %d or %s %d\n", (unsigned long)and.compoundPredicateType, (unsigned long)and.subpredicates.count,
            masked([NSCompoundPredicate andPredicateWithSubpredicates:@[]].predicateFormat), [[NSCompoundPredicate andPredicateWithSubpredicates:@[]] evaluateWithObject:nil],
            masked([NSCompoundPredicate orPredicateWithSubpredicates:@[]].predicateFormat), [[NSCompoundPredicate orPredicateWithSubpredicates:@[]] evaluateWithObject:nil]);
        NSPredicate *sub = [[NSPredicate predicateWithFormat:@"name == $N AND (age > $A OR $A == nil)"] predicateWithSubstitutionVariables:@{@"N": @"x", @"A": @3}];
        printf("substituted: %s\n", masked(sub.predicateFormat));
        NSPredicate *arr = [NSPredicate predicateWithFormat:@"name == %@ AND age > %@" argumentArray:@[@"Bob", @30]];
        printf("argument array: %s %d\n", masked(arr.predicateFormat), [arr evaluateWithObject:bob]);
        NSPredicate *bp = [NSPredicate predicateWithBlock:^BOOL(id o, NSDictionary *b) { return [o[@"age"] intValue] < 30; }];
        printf("block predicate: %s %s\n", masked(bp.predicateFormat), class_getName([bp class]));
        printf("equal: %d %d\n", [[NSPredicate predicateWithFormat:@"a == 1"] isEqual:[NSPredicate predicateWithFormat:@"a = 1"]],
            [[NSPredicate predicateWithFormat:@"a == 1"] isEqual:[NSPredicate predicateWithFormat:@"a == 2"]]);

        /* Filtering */
        NSArray *people = @[@{@"name": @"Ann", @"age": @20}, @{@"name": @"Bob", @"age": @35}, @{@"name": @"cy", @"age": @40}];
        NSPredicate *old = [NSPredicate predicateWithFormat:@"age >= 35"];
        printf("filtered array: %s\n", [[[people filteredArrayUsingPredicate:old] valueForKey:@"name"] componentsJoinedByString:@","].UTF8String);
        NSMutableArray *m = [people mutableCopy];
        [m filterUsingPredicate:bp];
        printf("filtered mutable: %s\n", [[m valueForKey:@"name"] componentsJoinedByString:@","].UTF8String);
        NSSet *s = [[NSSet setWithArray:@[@1, @5, @9]] filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"SELF > 4"]];
        printf("filtered set: %s\n", [[[s allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
        NSOrderedSet *o = [[NSOrderedSet orderedSetWithArray:@[@"b", @"aa", @"c"]] filteredOrderedSetUsingPredicate:[NSPredicate predicateWithFormat:@"length == 1"]];
        printf("filtered ordered set: %s\n", [o.array componentsJoinedByString:@","].UTF8String);
    }
    return 0;
}
