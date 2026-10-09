/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The visual format language (+constraintsWithVisualFormat:options:metrics:views:):
 *
 *   (H:|V:)? (| connection)? [view(predicates)?] (connection [view...])* (connection |)?
 *   connection: nothing (0), - (the standard space), -number-, -metric-,
 *               -(predicate, ...)-; a predicate: (==|>=|<=)? (number|metric|view) (@priority)?
 *
 * Constraints come out in the order Apple's parser makes them (each view's
 * leading connection, then its own predicates; the closing connection;
 * then the alignment options), and errors read as Apple's, caret and all.
 */
#import "FinchLayoutItem.h"

@interface NSLayoutConstraint (FinchVFLPrivate)
- (void)_finchSetSymbolicConstant:(FinchLayoutSymbolicConstant)kind;
@end

typedef struct {
    NSLayoutRelation relation;
    CGFloat constant;
    id view;             /* a view instead of a constant (view predicates) */
    NSLayoutPriority priority;
    BOOL standard;       /* the bare '-' */
} Predicate;

@interface FinchVFLParser : NSObject {
  @public
    NSString *_format;
    NSUInteger _pos, _len;
    NSDictionary *_metrics, *_views;
    unichar *_chars;
}
@end

@implementation FinchVFLParser
- (void)dealloc
{
    free(_chars);
    [super dealloc];
}
@end

static void
fail(FinchVFLParser *p, NSUInteger pos, NSString *msg)
{
    NSString *pad = [@"" stringByPaddingToLength:pos withString:@" " startingAtIndex:0];
    [NSException raise:NSInvalidArgumentException
                format:@"Unable to parse constraint format: \n%@ \n%@ \n%@^", msg, p->_format, pad];
}

static unichar
peek(FinchVFLParser *p)
{
    return p->_pos < p->_len ? p->_chars[p->_pos] : 0;
}

static BOOL
is_name_start(unichar c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

static BOOL
is_name_char(unichar c)
{
    return is_name_start(c) || (c >= '0' && c <= '9');
}

static NSString *
read_name(FinchVFLParser *p)
{
    NSUInteger start = p->_pos;
    while (p->_pos < p->_len && is_name_char(p->_chars[p->_pos]))
        p->_pos++;
    return [p->_format substringWithRange:NSMakeRange(start, p->_pos - start)];
}

/* A number, or a metric's (or, if views are allowed, a view's) name. */
static void
read_object(FinchVFLParser *p, Predicate *pred, BOOL allowViews, BOOL allowSign)
{
    unichar c = peek(p);
    if ((c >= '0' && c <= '9') || c == '.' || (allowSign && c == '-')) {
        NSUInteger start = p->_pos;
        if (c == '-')
            p->_pos++;
        while (p->_pos < p->_len && ((p->_chars[p->_pos] >= '0' && p->_chars[p->_pos] <= '9') || p->_chars[p->_pos] == '.'))
            p->_pos++;
        NSString *s = [p->_format substringWithRange:NSMakeRange(start, p->_pos - start)];
        if ([s isEqualToString:@"-"] || [s isEqualToString:@"."])
            fail(p, start, @"Expected a number or key from the metrics dictionary, but encountered something else");
        pred->constant = [s doubleValue];
        return;
    }
    if (!is_name_start(c))
        fail(p, p->_pos, @"Expected a number or key from the metrics dictionary, but encountered something else");
    NSString *name = read_name(p);
    id m = p->_metrics[name];
    if (m) {
        pred->constant = [m doubleValue];
        return;
    }
    id v = allowViews ? p->_views[name] : nil;
    if (v) {
        pred->view = v;
        return;
    }
    fail(p, p->_pos,
         [NSString stringWithFormat:@"Encountered metric with name \"%@\", but value was not specified in metrics or "
                                    @"views dictionaries",
                                    name]);
}

static NSLayoutPriority
read_priority(FinchVFLParser *p)
{
    Predicate pr = {0};
    read_object(p, &pr, NO, NO);
    return (NSLayoutPriority)pr.constant;
}

static Predicate
read_predicate(FinchVFLParser *p, BOOL allowViews)
{
    Predicate pred = {NSLayoutRelationEqual, 0, nil, NSLayoutPriorityRequired, NO};
    unichar c = peek(p), d = p->_pos + 1 < p->_len ? p->_chars[p->_pos + 1] : 0;
    if (d == '=' && (c == '=' || c == '>' || c == '<')) {
        pred.relation = c == '=' ? NSLayoutRelationEqual : c == '>' ? NSLayoutRelationGreaterThanOrEqual
                                                                     : NSLayoutRelationLessThanOrEqual;
        p->_pos += 2;
    }
    read_object(p, &pred, allowViews, YES);
    if (peek(p) == '@') {
        p->_pos++;
        pred.priority = read_priority(p);
    }
    return pred;
}

/* ( predicate, predicate ... ) */
static NSArray *
read_predicate_list(FinchVFLParser *p, BOOL allowViews)
{
    NSMutableArray *list = [NSMutableArray array];
    p->_pos++;  /* ( */
    for (;;) {
        Predicate pred = read_predicate(p, allowViews);
        [list addObject:[NSValue valueWithBytes:&pred objCType:@encode(Predicate)]];
        if (peek(p) == ',') {
            p->_pos++;
            continue;
        }
        if (peek(p) != ')')
            fail(p, p->_pos, p->_pos >= p->_len ? @"Expected more input" : @"Expected ')' or ','");
        p->_pos++;
        return list;
    }
}

/* After a '-': the predicates of a connection, through its closing '-' (nil for the standard space). */
static NSArray *
read_connection(FinchVFLParser *p)
{
    unichar c = peek(p);
    if (!c)
        fail(p, p->_pos, @"Expected more input");
    if (c == '[' || c == '|') {
        Predicate pred = {NSLayoutRelationEqual, 0, nil, NSLayoutPriorityRequired, YES};
        return @[ [NSValue valueWithBytes:&pred objCType:@encode(Predicate)] ];
    }
    if (c == '-')
        fail(p, p->_pos,
             @"Cannot tell if this - is a minus sign or an accidental extra bar in the connection. Use parentheses "
             @"around negative numbers.");
    NSArray *list;
    if (c == '(') {
        list = read_predicate_list(p, NO);
    } else {
        Predicate pred = {NSLayoutRelationEqual, 0, nil, NSLayoutPriorityRequired, NO};
        read_object(p, &pred, NO, NO);
        if (peek(p) == '@') {
            p->_pos++;
            pred.priority = read_priority(p);
        }
        list = @[ [NSValue valueWithBytes:&pred objCType:@encode(Predicate)] ];
    }
    if (peek(p) != '-')
        fail(p, p->_pos, p->_pos >= p->_len ? @"Expected more input" : @"Expected a '-' here");
    p->_pos++;
    return list;
}

static Predicate
pred_at(NSArray *list, NSUInteger i)
{
    Predicate p;
    [list[i] getValue:&p];
    return p;
}

static id
superitem(id item)
{
    return [item respondsToSelector:@selector(_finchLayoutSuperitem)] ? [item _finchLayoutSuperitem] : nil;
}

@implementation NSLayoutConstraint (NSVisualFormat)

+ (NSArray<NSLayoutConstraint *> *)constraintsWithVisualFormat:(NSString *)format options:(NSLayoutFormatOptions)opts
                                                       metrics:(NSDictionary<NSString *, id> *)metrics
                                                         views:(NSDictionary<NSString *, id> *)views
{
    if (![format length])
        [NSException raise:NSInvalidArgumentException format:@"Unable to parse constraint format: It's an empty string."];
    FinchVFLParser *p = [[[FinchVFLParser alloc] init] autorelease];
    p->_format = format;
    p->_len = [format length];
    p->_chars = malloc(sizeof(unichar) * (p->_len + 1));
    [format getCharacters:p->_chars range:NSMakeRange(0, p->_len)];
    p->_metrics = metrics;
    p->_views = views;

    BOOL vertical = NO;
    if (p->_len >= 2 && p->_chars[1] == ':' && (p->_chars[0] == 'H' || p->_chars[0] == 'V')) {
        vertical = p->_chars[0] == 'V';
        p->_pos = 2;
    }
    NSLayoutFormatOptions direction = opts & NSLayoutFormatDirectionMask;
    BOOL rtl = !vertical && direction == NSLayoutFormatDirectionRightToLeft;
    BOOL absolute = !vertical && direction != NSLayoutFormatDirectionLeadingToTrailing;
    /* right to left is written as left to right, then mirrored in connect() */
    NSLayoutAttribute leadingEdge = vertical ? NSLayoutAttributeTop : absolute ? NSLayoutAttributeRight : NSLayoutAttributeLeading;
    NSLayoutAttribute trailingEdge = vertical ? NSLayoutAttributeBottom : absolute ? NSLayoutAttributeLeft : NSLayoutAttributeTrailing;
    if (absolute && !rtl) {
        leadingEdge = NSLayoutAttributeLeft;
        trailingEdge = NSLayoutAttributeRight;
    }
    NSLayoutAttribute size = vertical ? NSLayoutAttributeHeight : NSLayoutAttributeWidth;

    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *viewsInOrder = [NSMutableArray array];
    NSArray *pending = nil;    /* the connection before the next view */
    BOOL pendingFromSuper = NO;
    BOOL needsSuper = NO;
    NSUInteger lastViewEnd = 0;  /* where errors about the whole format point: after the last view */
    id prev = nil;

    /* first.leading REL second.trailing + c, and its kin; right to left, the mirror: second.left REL first.right + c */
    void (^connect)(id, NSLayoutAttribute, id, NSLayoutAttribute, NSArray *) =
        ^(id first, NSLayoutAttribute a1, id second, NSLayoutAttribute a2, NSArray *list) {
            if (rtl) {
                id t = first;
                first = second;
                second = t;
                NSLayoutAttribute ta = a1;
                a1 = a2;
                a2 = ta;
            }
            for (NSUInteger i = 0; i < [list count]; i++) {
                Predicate pr = pred_at(list, i);
                CGFloat c = pr.constant;
                if (pr.standard) {
                    BOOL toSuper = superitem(first) == second || superitem(second) == first;
                    c = toSuper ? FINCH_LAYOUT_SUPERVIEW_SPACE : FINCH_LAYOUT_SIBLING_SPACE;
                }
                NSLayoutConstraint *k = [NSLayoutConstraint _finchConstraintWithItem:first attribute:a1
                                                                           relatedBy:pr.relation toItem:second
                                                                           attribute:a2 multiplier:1 constant:c];
                if (pr.standard)
                    [k _finchSetSymbolicConstant:FinchLayoutConstantStandardSpace];
                if (pr.priority < NSLayoutPriorityRequired)
                    [k setPriority:pr.priority];
                [out addObject:k];
            }
        };

    unichar c = peek(p);
    if (c == '|') {
        p->_pos++;
        if (p->_pos >= p->_len)
            fail(p, p->_pos, @"Expected a connection after the '|' character");
        if (peek(p) == '-') {
            p->_pos++;
            pending = read_connection(p);
        } else {
            Predicate pred = {NSLayoutRelationEqual, 0, nil, NSLayoutPriorityRequired, NO};
            pending = @[ [NSValue valueWithBytes:&pred objCType:@encode(Predicate)] ];
        }
        pendingFromSuper = YES;
        needsSuper = YES;
        if (peek(p) != '[')
            fail(p, p->_pos, @"Expected a view");
    } else if (c != '[') {
        fail(p, p->_pos, @"Expected a view");
    }

    for (;;) {
        /* a view */
        p->_pos++;  /* [ */
        if (!is_name_start(peek(p)))
            fail(p, p->_pos,
                 @"Expected a view. View names must start with a letter or an underscore, then contain letters, "
                 @"numbers, and underscores.");
        NSString *name = read_name(p);
        id view = views[name];
        if (!view)
            fail(p, p->_pos, [NSString stringWithFormat:@"%@ is not a key in the views dictionary.", name]);
        NSArray *ownPredicates = nil;
        if (peek(p) == '(')
            ownPredicates = read_predicate_list(p, YES);
        if (peek(p) != ']')
            fail(p, p->_pos, @"Expected a ']' here. That is how you give the end of a view.");
        p->_pos++;
        lastViewEnd = p->_pos;
        if (pending) {
            if (pendingFromSuper) {
                id s = superitem(view);
                if (s)
                    connect(view, leadingEdge, s, leadingEdge, pending);
            } else {
                connect(view, leadingEdge, prev, trailingEdge, pending);
            }
        }
        for (NSUInteger i = 0; i < [ownPredicates count]; i++) {
            Predicate pr = pred_at(ownPredicates, i);
            NSLayoutConstraint *k = [NSLayoutConstraint _finchConstraintWithItem:view attribute:size
                                                                       relatedBy:pr.relation toItem:pr.view
                                                                       attribute:pr.view ? size : 0
                                                                      multiplier:1 constant:pr.view ? 0 : pr.constant];
            if (pr.priority < NSLayoutPriorityRequired)
                [k setPriority:pr.priority];
            [out addObject:k];
        }
        [viewsInOrder addObject:view];
        prev = view;
        pending = nil;
        pendingFromSuper = NO;

        c = peek(p);
        if (!c)
            break;
        if (c == '[') {
            Predicate pred = {NSLayoutRelationEqual, 0, nil, NSLayoutPriorityRequired, NO};
            pending = @[ [NSValue valueWithBytes:&pred objCType:@encode(Predicate)] ];
            continue;
        }
        if (c == '|') {
            p->_pos++;
            if (p->_pos < p->_len)
                fail(p, p->_pos, @"Expected the end of the format string");
            Predicate pred = {NSLayoutRelationEqual, 0, nil, NSLayoutPriorityRequired, NO};
            needsSuper = YES;
            id s = superitem(view);
            if (s)
                connect(s, trailingEdge, view, trailingEdge, @[ [NSValue valueWithBytes:&pred objCType:@encode(Predicate)] ]);
            break;
        }
        if (c != '-')
            fail(p, p->_pos, @"Expected a view or '|'");
        p->_pos++;
        pending = read_connection(p);
        c = peek(p);
        if (c == '|') {
            p->_pos++;
            if (p->_pos < p->_len)
                fail(p, p->_pos, @"Expected the end of the format string");
            needsSuper = YES;
            id s = superitem(view);
            if (s)
                connect(s, trailingEdge, view, trailingEdge, pending);
            break;
        }
        if (c != '[')
            fail(p, p->_pos, @"Expected a view or '|'");
    }

    if (needsSuper)
        for (id v in viewsInOrder)
            if (!superitem(v))
                fail(p, lastViewEnd,
                     @"Unable to interpret '|' character, because the related view doesn't have a superview");

    NSLayoutFormatOptions align = opts & NSLayoutFormatAlignmentMask;
    if (align) {
        NSLayoutFormatOptions vEdges = NSLayoutFormatAlignAllTop | NSLayoutFormatAlignAllBottom |
                                       NSLayoutFormatAlignAllCenterY | NSLayoutFormatAlignAllLastBaseline |
                                       NSLayoutFormatAlignAllFirstBaseline;
        if (vertical && (align & vEdges))
            fail(p, lastViewEnd,
                 @"Options mask required views to be aligned on a vertical edge, which is not allowed for layout that "
                 @"is also vertical.");
        if (!vertical && (align & ~vEdges))
            fail(p, lastViewEnd,
                 @"Options mask required views to be aligned on a horizontal edge, which is not allowed for layout "
                 @"that is also horizontal.");
        for (NSUInteger i = 1; i < [viewsInOrder count]; i++)
            for (NSLayoutAttribute a = NSLayoutAttributeLeft; a <= NSLayoutAttributeFirstBaseline; a++)
                if (align & (1u << a))
                    [out addObject:[NSLayoutConstraint _finchConstraintWithItem:viewsInOrder[i - 1] attribute:a
                                                                      relatedBy:NSLayoutRelationEqual
                                                                         toItem:viewsInOrder[i] attribute:a
                                                                     multiplier:1 constant:0]];
    }
    return out;
}

@end

NSDictionary *
_NSDictionaryOfVariableBindings(NSString *commaSeparatedKeysString, id firstValue, ...)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSArray *keys = [commaSeparatedKeysString componentsSeparatedByString:@","];
    va_list ap;
    va_start(ap, firstValue);
    id value = firstValue;
    for (NSString *k in keys) {
        if (!value)
            break;
        NSString *key = [k stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        d[key] = value;
        value = va_arg(ap, id);
    }
    va_end(ap);
    return d;
}
