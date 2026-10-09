/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-layout-test: Auto Layout without a screen. Constraints and
 * their descriptions, validation, the visual format language and its errors,
 * anchors, layout guides, priorities and inequalities as the solver weighs
 * them, intrinsic sizes, hugging and compression resistance, autoresizing
 * masks turned into constraints, fitting sizes, windows sized by their
 * content, NSStackView, a nib with constraints and a storyboard compiled by
 * ibtool (layout-test.nib, layout-test.storyboardc). Prints everything; run
 * it against Apple's AppKit and Finch's (DYLD_FRAMEWORK_PATH) and diff all
 * but the first line, which is where NSLayoutConstraint came from.
 *
 * Views are plain NSViews with explicit intrinsic sizes, so frames compare
 * exactly; pointers print as P.
 *
 *   finch-appkit-layout-test [directory holding layout-test.nib and layout-test.storyboardc]
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSRegularExpression *pointers;

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    s = [pointers stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"P"];
    printf("%s\n", [s UTF8String]);
}

static NSString *
R(NSRect r)
{
    return NSStringFromRect(r);
}

static NSString *
S(NSSize s)
{
    return NSStringFromSize(s);
}

/* A view with an intrinsic size and baselines of its own. */
@interface IV : NSView
@property NSSize size;
@property CGFloat firstBaseline, lastBaseline;
@property NSEdgeInsets insets;
@end

@implementation IV
- (NSSize)intrinsicContentSize { return self.size; }
- (CGFloat)firstBaselineOffsetFromTop { return self.firstBaseline; }
- (CGFloat)lastBaselineOffsetFromBottom { return self.lastBaseline; }
- (NSEdgeInsets)alignmentRectInsets { return self.insets; }
@end

static NSView *
root_view(NSString *ident, CGFloat w, CGFloat h)
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    v.identifier = ident;
    return v;
}

static NSView *
sub(NSView *superview, NSString *ident)
{
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.identifier = ident;
    [superview addSubview:v];
    return v;
}

static IV *
isub(NSView *superview, NSString *ident, CGFloat w, CGFloat h)
{
    IV *v = [[IV alloc] initWithFrame:NSZeroRect];
    v.size = NSMakeSize(w, h);
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.identifier = ident;
    [superview addSubview:v];
    return v;
}

static void
frames(NSString *label, NSArray<NSView *> *views)
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSView *v in views)
        [parts addObject:[NSString stringWithFormat:@"%@ %@", v.identifier ?: @"?", R(v.frame)]];
    out(@"  %@: %@", label, [parts componentsJoinedByString:@", "]);
}

static void
try_do(NSString *label, void (^block)(void))
{
    @try {
        block();
        out(@"  %@: ok", label);
    } @catch (NSException *e) {
        out(@"  %@: %@ %@", label, e.name, e.reason);
    }
}

static void
list(NSString *label, NSArray *items)
{
    out(@"  %@ (%lu):", label, (unsigned long)items.count);
    for (id i in items)
        out(@"    %@", i);
}

static NSLayoutConstraint *
P(NSLayoutConstraint *c, NSLayoutPriority p)
{
    c.priority = p;
    return c;
}

typedef NSLayoutConstraint LC;

#pragma mark - Constraints

static void
test_constraints(void)
{
    out(@"[constraints]");
    NSView *s = root_view(@"s", 400, 300);
    NSView *a = sub(s, @"a"), *b = sub(s, @"b");
    NSView *c = sub(a, nil);
    for (NSLayoutAttribute at = NSLayoutAttributeLeft; at <= NSLayoutAttributeFirstBaseline; at++) {
        out(@"  %@", [LC constraintWithItem:a attribute:at relatedBy:NSLayoutRelationEqual toItem:b attribute:at multiplier:1 constant:0]);
        out(@"  %@", [LC constraintWithItem:a attribute:at relatedBy:NSLayoutRelationGreaterThanOrEqual toItem:b attribute:at multiplier:1 constant:8]);
        out(@"  %@", [LC constraintWithItem:a attribute:at relatedBy:NSLayoutRelationLessThanOrEqual toItem:s attribute:at multiplier:1 constant:-8.5]);
        out(@"  %@", [LC constraintWithItem:s attribute:at relatedBy:NSLayoutRelationEqual toItem:a attribute:at multiplier:1 constant:3]);
    }
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeLeading relatedBy:0 toItem:b attribute:NSLayoutAttributeTrailing multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeLeading relatedBy:1 toItem:b attribute:NSLayoutAttributeTrailing multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeLeading relatedBy:-1 toItem:b attribute:NSLayoutAttributeTrailing multiplier:1 constant:-8]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeLeading relatedBy:0 toItem:b attribute:NSLayoutAttributeTrailing multiplier:2 constant:8]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeLeft relatedBy:0 toItem:b attribute:NSLayoutAttributeRight multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeTop relatedBy:0 toItem:b attribute:NSLayoutAttributeBottom multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeBottom relatedBy:0 toItem:b attribute:NSLayoutAttributeTop multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeTrailing relatedBy:0 toItem:b attribute:NSLayoutAttributeLeading multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:b attribute:NSLayoutAttributeTrailing relatedBy:0 toItem:s attribute:NSLayoutAttributeTrailing multiplier:1 constant:-8]);
    out(@"  %@", [LC constraintWithItem:s attribute:NSLayoutAttributeTrailing relatedBy:0 toItem:b attribute:NSLayoutAttributeTrailing multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:s attribute:NSLayoutAttributeBottom relatedBy:0 toItem:b attribute:NSLayoutAttributeBottom multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:c attribute:NSLayoutAttributeLeading relatedBy:0 toItem:a attribute:NSLayoutAttributeLeading multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:c attribute:NSLayoutAttributeLeading relatedBy:0 toItem:s attribute:NSLayoutAttributeLeading multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:c attribute:NSLayoutAttributeLeading relatedBy:0 toItem:b attribute:NSLayoutAttributeTrailing multiplier:1 constant:8]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:nil attribute:0 multiplier:1 constant:0.333333333]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:nil attribute:0 multiplier:1 constant:123456789]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:nil attribute:0 multiplier:1 constant:0]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:b attribute:NSLayoutAttributeHeight multiplier:0.5 constant:0]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:b attribute:NSLayoutAttributeHeight multiplier:-1 constant:-2]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:b attribute:NSLayoutAttributeHeight multiplier:0 constant:-2]);
    out(@"  %@", [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:nil attribute:0 multiplier:1 constant:-5]);

    LC *p = [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:nil attribute:0 multiplier:1 constant:5];
    out(@"  defaults: priority %g active %d archived %d identifier %@ multiplier %g", p.priority, p.active,
        p.shouldBeArchived, p.identifier, p.multiplier);
    p.priority = 250.5;
    out(@"  %@", p);
    p.priority = 999;
    out(@"  %@", p);
    p.identifier = @"x y";
    out(@"  %@", p);
    out(@"  first %@ %ld second %@ %ld relation %ld", [p.firstItem identifier], (long)p.firstAttribute, p.secondItem,
        (long)p.secondAttribute, (long)p.relation);
    try_do(@"priority 0", ^{ p.priority = 0; });
    try_do(@"priority 1001", ^{ p.priority = 1001; });
    try_do(@"constant nan", ^{ p.constant = NAN; });

    out(@"[validation]");
    struct {
        NSLayoutAttribute a1, a2;
        BOOL second;
        CGFloat m;
    } bad[] = {
        {NSLayoutAttributeLeft, NSLayoutAttributeTop, YES, 1},
        {NSLayoutAttributeWidth, NSLayoutAttributeLeft, YES, 1},
        {NSLayoutAttributeLeft, 0, NO, 1},
        {NSLayoutAttributeLeft, 0, YES, 1},
        {NSLayoutAttributeLeft, NSLayoutAttributeLeft, YES, 0},
        {NSLayoutAttributeLeading, NSLayoutAttributeLeft, YES, 1},
        {NSLayoutAttributeLeading, NSLayoutAttributeCenterX, YES, 1},
        {NSLayoutAttributeWidth, NSLayoutAttributeHeight, YES, 1},
        {NSLayoutAttributeWidth, NSLayoutAttributeWidth, NO, 1},
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        NSLayoutAttribute a1 = bad[i].a1, a2 = bad[i].a2;
        NSView *second = bad[i].second ? b : nil;
        CGFloat m = bad[i].m;
        try_do([NSString stringWithFormat:@"%ld/%ld", (long)a1, (long)a2], ^{
            [LC constraintWithItem:a attribute:a1 relatedBy:0 toItem:second attribute:a2 multiplier:m constant:0];
        });
    }
    try_do(@"nan constant", ^{
        [LC constraintWithItem:a attribute:NSLayoutAttributeWidth relatedBy:0 toItem:nil attribute:0 multiplier:1 constant:NAN];
    });
    NSView *other = root_view(@"o", 10, 10);
    try_do(@"no common ancestor", ^{ [a.leadingAnchor constraintEqualToAnchor:other.leadingAnchor].active = YES; });
}

#pragma mark - Anchors

static void
test_anchors(void)
{
    out(@"[anchors]");
    NSView *s = root_view(@"s", 400, 300);
    NSView *a = sub(s, @"a"), *b = sub(s, @"b"), *c = sub(s, nil);
    NSArray *anchors = @[ a.leadingAnchor, a.trailingAnchor, a.leftAnchor, a.rightAnchor, a.topAnchor, a.bottomAnchor,
                          a.widthAnchor, a.heightAnchor, a.centerXAnchor, a.centerYAnchor, a.firstBaselineAnchor,
                          a.lastBaselineAnchor, c.leadingAnchor ];
    for (NSLayoutAnchor *an in anchors)
        out(@"  %@ | %@ | %s | item %d same %d", an, an.name, object_getClassName(an), an.item == a,
            an == a.leadingAnchor);
    LC *q = [a.leadingAnchor constraintEqualToAnchor:b.leadingAnchor];
    out(@"  %@ first %@ second %@ same %d", q, q.firstAnchor, q.secondAnchor, q.firstAnchor == a.leadingAnchor);
    NSLayoutDimension *off = [a.leadingAnchor anchorWithOffsetToAnchor:b.trailingAnchor];
    out(@"  %@ name '%@' item %@ class %s", off, off.name, off.item, object_getClassName(off));
    LC *d = [off constraintEqualToConstant:30];
    out(@"  %@ first %@ %ld", d, d.firstItem, (long)d.firstAttribute);
    out(@"  %@", [off constraintEqualToAnchor:a.widthAnchor]);
    out(@"  %@", [a.topAnchor anchorWithOffsetToAnchor:b.bottomAnchor]);
    LC *sp = [b.leadingAnchor constraintEqualToSystemSpacingAfterAnchor:a.trailingAnchor multiplier:1];
    out(@"  %@ c=%g m=%g", sp, sp.constant, sp.multiplier);
    out(@"  %@", [b.leadingAnchor constraintGreaterThanOrEqualToSystemSpacingAfterAnchor:a.trailingAnchor multiplier:2]);
    out(@"  %@", [b.leadingAnchor constraintLessThanOrEqualToSystemSpacingAfterAnchor:a.trailingAnchor multiplier:0.5]);
    out(@"  %@", [b.topAnchor constraintEqualToSystemSpacingBelowAnchor:a.bottomAnchor multiplier:1]);
    out(@"  %@", [b.topAnchor constraintLessThanOrEqualToSystemSpacingBelowAnchor:a.bottomAnchor multiplier:1.5]);
    out(@"  %@", [b.topAnchor constraintGreaterThanOrEqualToSystemSpacingBelowAnchor:a.bottomAnchor multiplier:1]);
    out(@"  %@", [a.widthAnchor constraintEqualToAnchor:b.widthAnchor multiplier:2 constant:3]);
    out(@"  %@", [a.widthAnchor constraintGreaterThanOrEqualToAnchor:b.widthAnchor multiplier:2]);
    out(@"  %@", [a.widthAnchor constraintLessThanOrEqualToConstant:3]);
    out(@"  %@", [a.widthAnchor constraintGreaterThanOrEqualToConstant:3]);
    out(@"  %@", [a.centerXAnchor constraintLessThanOrEqualToAnchor:b.centerXAnchor constant:-4]);
    out(@"  %@", [a.firstBaselineAnchor constraintEqualToAnchor:b.lastBaselineAnchor]);

    /* anchors laid out */
    IV *x = isub(s, @"x", 40, 20), *y = isub(s, @"y", 30, 10);
    [y setContentHuggingPriority:251 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [x.leadingAnchor constraintEqualToAnchor:s.leadingAnchor constant:10],
        [x.topAnchor constraintEqualToAnchor:s.topAnchor constant:10],
        [y.leadingAnchor constraintEqualToSystemSpacingAfterAnchor:x.trailingAnchor multiplier:2],
        [y.topAnchor constraintEqualToSystemSpacingBelowAnchor:x.bottomAnchor multiplier:1],
        [[x.leadingAnchor anchorWithOffsetToAnchor:y.trailingAnchor] constraintEqualToConstant:100],
    ]];
    [s layoutSubtreeIfNeeded];
    frames(@"system spacing and offsets", @[ x, y ]);
}

#pragma mark - The visual format language

static void
test_vfl(void)
{
    out(@"[vfl]");
    NSView *s = root_view(nil, 400, 300);
    NSView *a = sub(s, nil), *b = sub(s, @"bid"), *c = sub(s, nil);
    NSView *lone = [NSView new];
    NSDictionary *views = @{@"a" : a, @"b" : b, @"c" : c, @"lone" : lone, @"_x1" : c};
    NSDictionary *metrics = @{@"m" : @12, @"p" : @300, @"f" : @2.5};
    NSArray *formats = @[
        @"|[a]|", @"H:|[a]|", @"V:|[a]|", @"[a][b]", @"[a]-[b]", @"[a]-10-[b]", @"[a]-m-[b]", @"[a]-(m)-[b]",
        @"[a]-(>=m)-[b]", @"[a]-(<=10@p)-[b]", @"[a]-(>=5,<=20)-[b]", @"[a(50)]", @"[a(==50)]", @"[a(>=50@500)]",
        @"[a(b)]", @"[a(==b)]", @"[a(>=b@200)]", @"[a(==b,>=30)]", @"|-[a]-|", @"|-0-[a]-0-|", @"|-(-5)-[a]",
        @"[a]-(f)-[b]", @"V:[a]-[b]-[c]", @"V:|-(m@750)-[a(f)]", @"[a]-m@p-[b]", @"[a(m@p)]",
        @"|-[a]-[b(==a)]-[c(==b)]-|", @"[a][_x1]", @"[a]-10.5-[b]", @"[a(-5)]", @"[a(50)]-[b]-(>=8)-|", @"[a][a]",
        @"[lone]",
        /* errors */
        @"", @"[ a ]", @"H: |-[a]", @"[a]-  10 -[b]", @"[a", @"[a]]", @"[d]", @"[a]-[d]", @"[a(d)]", @"H:[a]-x-[b]",
        @"V:|-[a]-|-[b]", @"[a]-", @"-[a]", @"|-|", @"[a]-(>=)-[b]", @"[a]-(10@)-[b]", @"[a](10)", @"[a]-10-|-[b]",
        @"X:[a]", @"|[lone]", @"[a]--[b]", @"[a(10@foo)]", @"[a]-(abc)-[b]", @"[a b]", @"[a][b]|]", @"[1a]", @"|",
        @"[a]||"
    ];
    for (NSString *f in formats) {
        @try {
            NSArray *cs = [NSLayoutConstraint constraintsWithVisualFormat:f options:0 metrics:metrics views:views];
            out(@"  '%@':", f);
            for (LC *k in cs)
                out(@"    %@ c=%g p=%g", k, k.constant, k.priority);
        } @catch (NSException *e) {
            out(@"  '%@': %@ %@", f, e.name, e.reason);
        }
    }
    NSArray *opts = @[ @(NSLayoutFormatAlignAllTop), @(NSLayoutFormatAlignAllCenterY | NSLayoutFormatDirectionLeftToRight),
                       @(NSLayoutFormatAlignAllLeading), @(NSLayoutFormatAlignAllLastBaseline),
                       @(NSLayoutFormatDirectionRightToLeft), @(NSLayoutFormatAlignAllTop | NSLayoutFormatAlignAllBottom) ];
    for (NSNumber *o in opts)
        for (NSString *f in @[ @"|-[a]-[b]-|", @"V:[a]-[b]" ]) {
            @try {
                NSArray *cs = [NSLayoutConstraint constraintsWithVisualFormat:f options:o.unsignedLongValue
                                                                      metrics:metrics views:views];
                out(@"  '%@' options %lx:", f, o.unsignedLongValue);
                for (LC *k in cs)
                    out(@"    %@", k);
            } @catch (NSException *e) {
                out(@"  '%@' options %lx: %@ %@", f, o.unsignedLongValue, e.name, e.reason);
            }
        }
    NSDictionary *d = NSDictionaryOfVariableBindings(a, b, c);
    out(@"  bindings %@ same %d", [[d.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","],
        d[@"b"] == b);

    /* laid out */
    NSView *r = root_view(@"r", 400, 300);
    IV *x = isub(r, @"x", 50, 20), *y = isub(r, @"y", 60, 30), *z = isub(r, @"z", 70, 40);
    [y setContentHuggingPriority:251 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSDictionary *v = NSDictionaryOfVariableBindings(x, y, z);
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-[x]-[y(>=100@750)]-(20)-|"
                                                                                    options:NSLayoutFormatAlignAllTop
                                                                                    metrics:nil views:v]];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-[x]-(>=10)-[z]-|"
                                                                                    options:NSLayoutFormatAlignAllCenterX
                                                                                    metrics:nil views:v]];
    [r layoutSubtreeIfNeeded];
    frames(@"laid out", @[ x, y, z ]);
}

#pragma mark - Solving

static void
test_solving(void)
{
    out(@"[solving]");
    NSView *s = root_view(@"s", 400, 300);
    NSView *v = sub(s, @"lex");
    [NSLayoutConstraint activateConstraints:@[
        [v.leftAnchor constraintEqualToAnchor:s.leftAnchor], [v.topAnchor constraintEqualToAnchor:s.topAnchor],
        [v.heightAnchor constraintEqualToConstant:10], P([v.widthAnchor constraintEqualToConstant:100], 251),
        P([v.widthAnchor constraintEqualToConstant:200], 250), P([v.widthAnchor constraintEqualToConstant:210], 250)
    ]];
    NSView *w = sub(s, @"median");
    [NSLayoutConstraint activateConstraints:@[
        [w.leftAnchor constraintEqualToAnchor:s.leftAnchor], [w.topAnchor constraintEqualToAnchor:s.topAnchor],
        [w.heightAnchor constraintEqualToConstant:10], P([w.widthAnchor constraintEqualToConstant:100], 500),
        P([w.widthAnchor constraintEqualToConstant:200], 500), P([w.widthAnchor constraintEqualToConstant:210], 500)
    ]];
    NSView *z = sub(s, @"999");
    [NSLayoutConstraint activateConstraints:@[
        [z.leftAnchor constraintEqualToAnchor:s.leftAnchor], [z.topAnchor constraintEqualToAnchor:s.topAnchor],
        [z.heightAnchor constraintEqualToConstant:10], P([z.widthAnchor constraintEqualToConstant:100], 999),
        P([z.widthAnchor constraintEqualToConstant:200], 998), P([z.widthAnchor constraintEqualToConstant:300], 998)
    ]];
    NSView *y = sub(s, @"required");
    [NSLayoutConstraint activateConstraints:@[
        [y.leftAnchor constraintEqualToAnchor:s.leftAnchor], [y.topAnchor constraintEqualToAnchor:s.topAnchor],
        [y.heightAnchor constraintEqualToConstant:10], [y.widthAnchor constraintEqualToConstant:100],
        [y.widthAnchor constraintEqualToConstant:200]
    ]];
    /* inequalities and multipliers */
    NSView *m = sub(s, @"mult"), *n = sub(s, @"ineq");
    [NSLayoutConstraint activateConstraints:@[
        [m.leadingAnchor constraintEqualToAnchor:s.leadingAnchor constant:20],
        [m.widthAnchor constraintEqualToAnchor:s.widthAnchor multiplier:0.25],
        [m.heightAnchor constraintEqualToAnchor:m.widthAnchor multiplier:0.5 constant:4],
        [m.bottomAnchor constraintEqualToAnchor:s.bottomAnchor constant:-10],
        [n.leadingAnchor constraintGreaterThanOrEqualToAnchor:m.trailingAnchor constant:30],
        P([n.leadingAnchor constraintEqualToAnchor:s.leadingAnchor], 600),
        [n.widthAnchor constraintLessThanOrEqualToConstant:80],
        P([n.widthAnchor constraintEqualToConstant:500], 300),
        [n.centerYAnchor constraintEqualToAnchor:s.centerYAnchor],
        [n.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    [s layoutSubtreeIfNeeded];
    frames(@"priorities", @[ v, w, z, y ]);
    frames(@"inequalities", @[ m, n ]);

    /* rounding: edges to whole points outside a window */
    double ms[] = {0.1, 0.13, 0.17, 0.33, 0.71, 0.77, 0.9, 0.501};
    for (int i = 0; i < 8; i++) {
        NSView *r = root_view(@"r", 100, 100);
        NSView *p = sub(r, @"p"), *q = sub(r, @"q");
        [NSLayoutConstraint activateConstraints:@[
            [LC constraintWithItem:p attribute:NSLayoutAttributeLeft relatedBy:0 toItem:r attribute:NSLayoutAttributeRight multiplier:ms[i] constant:0],
            [p.widthAnchor constraintEqualToConstant:10.3],
            [LC constraintWithItem:p attribute:NSLayoutAttributeTop relatedBy:0 toItem:r attribute:NSLayoutAttributeBottom multiplier:ms[i] constant:0],
            [p.heightAnchor constraintEqualToConstant:10.6],
            [q.leftAnchor constraintEqualToAnchor:r.leftAnchor constant:3.25],
            [q.rightAnchor constraintEqualToAnchor:r.leftAnchor constant:ms[i] * 100],
            [q.topAnchor constraintEqualToAnchor:r.topAnchor constant:ms[i] * 7],
            [q.heightAnchor constraintEqualToConstant:ms[i] * 13],
        ]];
        [r layoutSubtreeIfNeeded];
        frames([NSString stringWithFormat:@"rounding %g", ms[i]], @[ p, q ]);
    }

    /* intrinsic sizes, hugging and compression resistance */
    NSView *t = root_view(@"t", 300, 100);
    IV *h1 = isub(t, @"h1", 50, 20), *h2 = isub(t, @"h2", 60, 20), *h3 = isub(t, @"h3", 200, 20);
    [h2 setContentHuggingPriority:251 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [h3 setContentCompressionResistancePriority:740 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-[h1]-[h2]-[h3]-|"
                                                                                    options:NSLayoutFormatAlignAllTop
                                                                                    metrics:nil
                                                                                      views:NSDictionaryOfVariableBindings(h1, h2, h3)]];
    [h1.topAnchor constraintEqualToAnchor:t.topAnchor constant:5].active = YES;
    [t layoutSubtreeIfNeeded];
    frames(@"compressed", @[ h1, h2, h3 ]);
    [t setFrameSize:NSMakeSize(600, 100)];
    [t layoutSubtreeIfNeeded];
    frames(@"stretched", @[ h1, h2, h3 ]);
    h3.size = NSMakeSize(100, 30);
    [h3 invalidateIntrinsicContentSize];
    [t layoutSubtreeIfNeeded];
    frames(@"invalidated", @[ h1, h2, h3 ]);
    list(@"h1 constraints", h1.constraints);
    out(@"  priorities %g %g %g %g", [h3 contentHuggingPriorityForOrientation:0], [h3 contentHuggingPriorityForOrientation:1],
        [h3 contentCompressionResistancePriorityForOrientation:0], [h3 contentCompressionResistancePriorityForOrientation:1]);
    h1.horizontalContentSizeConstraintActive = NO;
    [t layoutSubtreeIfNeeded];
    out(@"  content constraints active %d %d", h1.horizontalContentSizeConstraintActive, h1.verticalContentSizeConstraintActive);
    list(@"h1 constraints", h1.constraints);

    /* constants and priorities changing */
    NSView *u = root_view(@"u", 200, 200);
    NSView *e = sub(u, @"e");
    LC *lead = [e.leadingAnchor constraintEqualToAnchor:u.leadingAnchor constant:10];
    LC *wid = P([e.widthAnchor constraintEqualToConstant:50], 500);
    [NSLayoutConstraint activateConstraints:@[ lead, wid, [e.topAnchor constraintEqualToAnchor:u.topAnchor],
                                               [e.heightAnchor constraintEqualToConstant:20],
                                               P([e.widthAnchor constraintEqualToConstant:70], 400) ]];
    [u layoutSubtreeIfNeeded];
    frames(@"edit", @[ e ]);
    lead.constant = 35;
    wid.constant = 60;
    [u layoutSubtreeIfNeeded];
    frames(@"constants", @[ e ]);
    wid.priority = 300;
    [u layoutSubtreeIfNeeded];
    frames(@"priority", @[ e ]);
    wid.active = NO;
    [u layoutSubtreeIfNeeded];
    frames(@"deactivated", @[ e ]);
    [u setFrameSize:NSMakeSize(100, 50)];
    [u layoutSubtreeIfNeeded];
    frames(@"root resized", @[ e ]);

    /* baselines and alignment rects */
    NSView *bl = root_view(@"bl", 300, 100);
    IV *b1 = isub(bl, @"b1", 40, 30), *b2 = isub(bl, @"b2", 40, 50);
    b1.firstBaseline = 20;
    b1.lastBaseline = 6;
    b2.firstBaseline = 12;
    b2.lastBaseline = 9;
    b2.insets = NSEdgeInsetsMake(2, 3, 4, 5);
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-[b1]-[b2]"
                                                                                    options:NSLayoutFormatAlignAllLastBaseline
                                                                                    metrics:nil
                                                                                      views:NSDictionaryOfVariableBindings(b1, b2)]];
    [b1.topAnchor constraintEqualToAnchor:bl.topAnchor constant:30].active = YES;
    [bl layoutSubtreeIfNeeded];
    frames(@"last baselines", @[ b1, b2 ]);
    out(@"  b2 alignment %@ frame for %@", R([b2 alignmentRectForFrame:b2.frame]),
        R([b2 frameForAlignmentRect:NSMakeRect(10, 10, 20, 20)]));
    [NSLayoutConstraint deactivateConstraints:bl.constraints];
    [NSLayoutConstraint activateConstraints:@[
        [b1.leadingAnchor constraintEqualToAnchor:bl.leadingAnchor], [b1.topAnchor constraintEqualToAnchor:bl.topAnchor],
        [b2.leadingAnchor constraintEqualToAnchor:b1.trailingAnchor],
        [b2.firstBaselineAnchor constraintEqualToAnchor:b1.firstBaselineAnchor]
    ]];
    [bl layoutSubtreeIfNeeded];
    frames(@"first baselines", @[ b1, b2 ]);

    /* views in different superviews */
    NSView *g = root_view(@"g", 300, 200);
    NSView *box = sub(g, @"box");
    NSView *inner = sub(box, @"inner"), *outer = sub(g, @"outer");
    [NSLayoutConstraint activateConstraints:@[
        [box.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:30],
        [box.topAnchor constraintEqualToAnchor:g.topAnchor constant:20],
        [box.widthAnchor constraintEqualToConstant:100], [box.heightAnchor constraintEqualToConstant:80],
        [inner.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10],
        [inner.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10],
        [inner.topAnchor constraintEqualToAnchor:box.topAnchor constant:5], [inner.heightAnchor constraintEqualToConstant:10],
        [outer.leadingAnchor constraintEqualToAnchor:inner.trailingAnchor constant:7],
        [outer.topAnchor constraintEqualToAnchor:inner.bottomAnchor],
        [outer.widthAnchor constraintEqualToAnchor:inner.widthAnchor multiplier:0.5],
        [outer.heightAnchor constraintEqualToConstant:12],
    ]];
    [g layoutSubtreeIfNeeded];
    frames(@"across superviews", @[ box, inner, outer ]);
}

#pragma mark - Views' constraint API

static void
test_view_api(void)
{
    out(@"[views]");
    NSView *fresh = [NSView new];
    out(@"  fresh: needsLayout %d needsUpdateConstraints %d translates %d requires %d constraints %lu", fresh.needsLayout,
        fresh.needsUpdateConstraints, fresh.translatesAutoresizingMaskIntoConstraints,
        [NSView requiresConstraintBasedLayout], (unsigned long)fresh.constraints.count);
    out(@"  insets %g %g %g %g baselines %g %g %g intrinsic %@", fresh.alignmentRectInsets.top, fresh.alignmentRectInsets.left,
        fresh.alignmentRectInsets.bottom, fresh.alignmentRectInsets.right, fresh.firstBaselineOffsetFromTop,
        fresh.lastBaselineOffsetFromBottom, fresh.baselineOffsetFromBottom, S(fresh.intrinsicContentSize));
    NSArray *controls = @[
        [NSView new], [NSTextField labelWithString:@"x"], [NSTextField textFieldWithString:@"x"],
        [NSButton buttonWithTitle:@"x" target:nil action:nil], [NSSlider new], [NSProgressIndicator new], [NSStepper new],
        [NSColorWell new], [NSImageView new], [NSBox new], [NSScrollView new], [NSControl new]
    ];
    for (NSView *v in controls)
        out(@"  %s hug %g %g compression %g %g", class_getName([v class]), [v contentHuggingPriorityForOrientation:0],
            [v contentHuggingPriorityForOrientation:1], [v contentCompressionResistancePriorityForOrientation:0],
            [v contentCompressionResistancePriorityForOrientation:1]);

    NSView *s = root_view(@"s", 400, 300);
    NSView *a = sub(s, @"a"), *b = sub(s, @"b");
    LC *y = [a.widthAnchor constraintEqualToConstant:4];
    y.active = YES;
    LC *w = [a.widthAnchor constraintEqualToAnchor:b.widthAnchor];
    w.active = YES;
    out(@"  installed on a %d, w on s %d", [a.constraints containsObject:y], [s.constraints containsObject:w]);
    [s addConstraint:[a.heightAnchor constraintEqualToConstant:3]];
    [a addConstraint:[a.heightAnchor constraintEqualToConstant:3]];
    out(@"  a %lu s %lu", (unsigned long)a.constraints.count, (unsigned long)s.constraints.count);
    LC *k = [a.widthAnchor constraintEqualToConstant:9];
    k.active = YES;
    k.active = YES;
    [a addConstraint:k];
    out(@"  twice: a %lu", (unsigned long)a.constraints.count);
    [s addConstraint:k];
    out(@"  moved: a %lu s %lu active %d", (unsigned long)a.constraints.count, (unsigned long)s.constraints.count, k.active);
    [b removeFromSuperview];
    out(@"  b removed: w active %d; a %lu s %lu", w.active, (unsigned long)a.constraints.count,
        (unsigned long)s.constraints.count);
    [s removeConstraints:s.constraints];
    out(@"  removed all: s %lu k active %d", (unsigned long)s.constraints.count, k.active);
    [NSLayoutConstraint deactivateConstraints:@[ y ]];
    out(@"  deactivated: a %lu y active %d", (unsigned long)a.constraints.count, y.active);
    [s layoutSubtreeIfNeeded];
    out(@"  after layout: s needsLayout %d needsUpdateConstraints %d", s.needsLayout, s.needsUpdateConstraints);

    /* guides */
    out(@"[guides]");
    NSView *g = root_view(@"g", 300, 200);
    NSLayoutGuide *guide = [NSLayoutGuide new];
    out(@"  new: owner %@ identifier '%@' frame %@", guide.owningView, guide.identifier, R(guide.frame));
    [g addLayoutGuide:guide];
    guide.identifier = @"gid";
    out(@"  added: owner %@ guides %lu", guide.owningView.identifier, (unsigned long)g.layoutGuides.count);
    out(@"  %@", guide.leadingAnchor);
    IV *l = isub(g, @"l", 40, 20), *r = isub(g, @"r", 40, 20);
    [NSLayoutConstraint activateConstraints:@[
        [guide.leadingAnchor constraintEqualToAnchor:l.trailingAnchor],
        [guide.trailingAnchor constraintEqualToAnchor:r.leadingAnchor],
        [guide.widthAnchor constraintEqualToAnchor:g.widthAnchor multiplier:0.5],
        [guide.topAnchor constraintEqualToAnchor:g.topAnchor constant:10],
        [guide.heightAnchor constraintEqualToConstant:30],
        [l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20],
        [l.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor],
        [r.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor],
    ]];
    for (LC *c in g.constraints)
        out(@"  %@", c);
    [g layoutSubtreeIfNeeded];
    frames(@"around a guide", @[ l, r ]);
    out(@"  guide frame %@", R(guide.frame));
    [g removeLayoutGuide:guide];
    out(@"  removed: owner %@ guides %lu constraints %lu", guide.owningView, (unsigned long)g.layoutGuides.count,
        (unsigned long)g.constraints.count);

    /* fitting sizes */
    out(@"[fitting]");
    NSView *f = root_view(@"f", 400, 300);
    NSView *fv = sub(f, @"fv");
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-20-[fv(500)]-20-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(fv)]];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-20-[fv(>=100)]-20-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(fv)]];
    [f layoutSubtreeIfNeeded];
    out(@"  root %@ fv %@", R(f.frame), R(fv.frame));
    out(@"  fitting %@ fv fitting %@", S(f.fittingSize), S(fv.fittingSize));
    NSView *f2 = root_view(@"f2", 10, 10);
    IV *i1 = isub(f2, @"i1", 50, 20), *i2 = isub(f2, @"i2", 70, 30);
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-[i1]-[i2]-|" options:NSLayoutFormatAlignAllBottom metrics:nil views:NSDictionaryOfVariableBindings(i1, i2)]];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(>=8)-[i1]-(12)-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(i1, i2)]];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(>=8)-[i2]" options:0 metrics:nil views:NSDictionaryOfVariableBindings(i1, i2)]];
    out(@"  intrinsic fitting %@ (frame %@)", S(f2.fittingSize), R(f2.frame));
    NSView *plain = root_view(@"plain", 33, 44);
    out(@"  plain fitting %@", S(plain.fittingSize));
}

#pragma mark - Autoresizing masks

static void
test_autoresizing(void)
{
    out(@"[autoresizing]");
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 500) styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered defer:YES];
    for (int m = 0; m < 64; m += 1) {
        /* (a flexible width and right margin without a flexible left: Finch's classic autoresizing rounds differently) */
        if (((m % 9) && m != 3 && m != 5 && m != 7 && m != 24 && m != 40 && m != 56) || (m & 7) == 6)
            continue;
        NSView *s = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        s.identifier = @"s";
        win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 500)];
        [win.contentView addSubview:s];
        NSView *t = [[NSView alloc] initWithFrame:NSMakeRect(20, 30, 100, 50)];
        t.identifier = @"t";
        t.autoresizingMask = m;
        [s addSubview:t];
        NSView *u = sub(s, @"u");
        [s addConstraint:[u.leadingAnchor constraintEqualToAnchor:t.trailingAnchor constant:5]];
        [s addConstraint:[u.topAnchor constraintEqualToAnchor:t.bottomAnchor]];
        [s addConstraint:[u.widthAnchor constraintEqualToConstant:10]];
        [s addConstraint:[u.heightAnchor constraintEqualToConstant:10]];
        [win layoutIfNeeded];
        out(@"  mask %d: t %@ u %@", m, R(t.frame), R(u.frame));
        for (LC *c in s.constraints)
            if ([c isKindOfClass:NSClassFromString(@"NSAutoresizingMaskLayoutConstraint")])
                out(@"    %@ | %ld %ld m=%g c=%g", c, (long)c.firstAttribute, (long)c.secondAttribute, c.multiplier, c.constant);
        [s setFrameSize:NSMakeSize(500, 400)];
        out(@"    resized: t %@", R(t.frame));
        [win layoutIfNeeded];
        out(@"    laid out: t %@ u %@", R(t.frame), R(u.frame));
    }
    /* frames set on autoresizing views move what's constrained to them */
    NSView *s = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    s.identifier = @"s";
    NSView *q = [[NSView alloc] initWithFrame:NSMakeRect(10, 10, 100, 100)];
    q.identifier = @"q";
    [s addSubview:q];
    NSView *q2 = [[NSView alloc] initWithFrame:NSMakeRect(10, 10, 50, 50)];
    q2.identifier = @"q2";
    [q addSubview:q2];
    NSView *a = sub(s, @"a");
    [NSLayoutConstraint activateConstraints:@[ [a.leftAnchor constraintEqualToAnchor:s.leftAnchor constant:5],
                                               [a.topAnchor constraintEqualToAnchor:s.topAnchor],
                                               [a.widthAnchor constraintEqualToConstant:10],
                                               [a.heightAnchor constraintEqualToConstant:10] ]];
    [s layoutSubtreeIfNeeded];
    list(@"s", s.constraints);
    list(@"q", q.constraints);
    NSView *p = [[NSView alloc] initWithFrame:NSMakeRect(200, 10, 100, 100)];
    p.identifier = @"p";
    [s addSubview:p];
    NSView *r = sub(p, @"r");
    [NSLayoutConstraint activateConstraints:@[ [r.leftAnchor constraintEqualToAnchor:p.leftAnchor constant:5],
                                               [r.topAnchor constraintEqualToAnchor:p.topAnchor],
                                               [r.widthAnchor constraintEqualToAnchor:p.widthAnchor multiplier:0.5],
                                               [r.heightAnchor constraintEqualToConstant:10] ]];
    [s layoutSubtreeIfNeeded];
    frames(@"before", @[ p, r ]);
    p.frame = NSMakeRect(200, 10, 60, 100);
    [s layoutSubtreeIfNeeded];
    frames(@"p moved", @[ p, r ]);
    list(@"p", p.constraints);
    out(@"  translating r %d", r.translatesAutoresizingMaskIntoConstraints);
}


#pragma mark - Stack views

static IV *
iv(NSString *ident, CGFloat w, CGFloat h)
{
    IV *v = [[IV alloc] initWithFrame:NSZeroRect];
    v.size = NSMakeSize(w, h);
    v.identifier = ident;
    return v;
}

static NSStackView *
pinned_stack(NSView *root, NSArray *views, NSUserInterfaceLayoutOrientation o, CGFloat w, CGFloat h)
{
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.identifier = @"stack";
    s.orientation = o;
    [root addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:10],
        [s.topAnchor constraintEqualToAnchor:root.topAnchor constant:10], [s.widthAnchor constraintEqualToConstant:w],
        [s.heightAnchor constraintEqualToConstant:h]
    ]];
    return s;
}

static void
test_stack(void)
{
    out(@"[stack]");
    NSStackView *d = [NSStackView new];
    out(@"  defaults: orientation %ld alignment %ld distribution %ld spacing %g insets %g %g %g %g detaches %d translates %d "
        @"views %lu hugging %g %g clipping %g %g requires %d",
        (long)d.orientation, (long)d.alignment, (long)d.distribution, d.spacing, d.edgeInsets.top, d.edgeInsets.left,
        d.edgeInsets.bottom, d.edgeInsets.right, d.detachesHiddenViews, d.translatesAutoresizingMaskIntoConstraints,
        (unsigned long)d.views.count, [d huggingPriorityForOrientation:0], [d huggingPriorityForOrientation:1],
        [d clippingResistancePriorityForOrientation:0], [d clippingResistancePriorityForOrientation:1],
        [NSStackView requiresConstraintBasedLayout]);
    out(@"  empty: frame %@ fitting %@ intrinsic %@", R(d.frame), S(d.fittingSize), S(d.intrinsicContentSize));
    d.orientation = NSUserInterfaceLayoutOrientationVertical;
    out(@"  vertical: alignment %ld", (long)d.alignment);
    NSStackView *w = [NSStackView stackViewWithViews:@[ iv(@"a", 50, 20), iv(@"b", 60, 40) ]];
    out(@"  with views: translates %d views %lu arranged %lu subviews %lu view translates %d leading %lu",
        w.translatesAutoresizingMaskIntoConstraints, (unsigned long)w.views.count, (unsigned long)w.arrangedSubviews.count,
        (unsigned long)w.subviews.count, [w.views[0] translatesAutoresizingMaskIntoConstraints],
        (unsigned long)[w viewsInGravity:NSStackViewGravityLeading].count);
    out(@"  fitting %@", S(w.fittingSize));

    NSLayoutAttribute hAligns[] = {NSLayoutAttributeCenterY, NSLayoutAttributeTop, NSLayoutAttributeBottom};
    NSLayoutAttribute vAligns[] = {NSLayoutAttributeCenterX, NSLayoutAttributeLeading, NSLayoutAttributeTrailing};
    for (int o = 0; o < 2; o++)
        for (int ai = 0; ai < 3; ai++)
            for (NSInteger dist = -1; dist <= 4; dist++) {
                NSView *root = root_view(@"root", 400, 300);
                NSArray *views = @[ iv(@"a", 50, 20), iv(@"b", 60, 40), iv(@"c", 30, 10) ];
                /* fill: the view that hugs least takes the room */
                [views[1] setContentHuggingPriority:200 forOrientation:o];
                NSStackView *s = pinned_stack(root, views, o, o ? 80 : 300, o ? 200 : 60);
                s.alignment = o ? vAligns[ai] : hAligns[ai];
                s.distribution = dist;
                [root layoutSubtreeIfNeeded];
                frames([NSString stringWithFormat:@"o%d align %ld dist %ld stack %@", o, (long)s.alignment,
                                                  (long)dist, R(s.frame)],
                       views);
            }

    NSView *root = root_view(@"root", 400, 300);
    NSArray *views = @[ iv(@"a", 50, 20), iv(@"b", 60, 40), iv(@"c", 30, 10) ];
    NSStackView *s = pinned_stack(root, views, NSUserInterfaceLayoutOrientationHorizontal, 250, 60);
    s.spacing = 12;
    s.edgeInsets = NSEdgeInsetsMake(5, 6, 7, 8);
    [root layoutSubtreeIfNeeded];
    frames(@"insets", views);
    [s setCustomSpacing:30 afterView:views[0]];
    out(@"  custom spacing %g %g", [s customSpacingAfterView:views[0]], [s customSpacingAfterView:views[1]]);
    [root layoutSubtreeIfNeeded];
    frames(@"custom", @[ views[0], views[2] ]);
    [views[1] setHidden:YES];
    [root layoutSubtreeIfNeeded];
    frames(@"hidden detached", @[ views[0], views[2] ]);
    out(@"  detached %lu", (unsigned long)s.detachedViews.count);
    [s removeArrangedSubview:views[2]];
    out(@"  removed: arranged %lu subviews %lu", (unsigned long)s.arrangedSubviews.count, (unsigned long)s.subviews.count);
    [views[2] removeFromSuperview];
    [s addArrangedSubview:views[2]];
    [views[0] removeFromSuperview];
    out(@"  removeFromSuperview: arranged %lu", (unsigned long)s.arrangedSubviews.count);

    NSView *r2 = root_view(@"r2", 400, 300);
    NSStackView *g = [NSStackView new];
    NSArray *gv = @[ iv(@"l1", 30, 10), iv(@"l2", 30, 10), iv(@"m", 40, 10), iv(@"t", 20, 10) ];
    [g addView:gv[0] inGravity:NSStackViewGravityLeading];
    [g addView:gv[1] inGravity:NSStackViewGravityLeading];
    [g addView:gv[2] inGravity:NSStackViewGravityCenter];
    [g addView:gv[3] inGravity:NSStackViewGravityTrailing];
    out(@"  gravities: views %lu leading %lu center %lu trailing %lu arranged %lu translates %d", (unsigned long)g.views.count,
        (unsigned long)[g viewsInGravity:NSStackViewGravityLeading].count,
        (unsigned long)[g viewsInGravity:NSStackViewGravityCenter].count,
        (unsigned long)[g viewsInGravity:NSStackViewGravityTrailing].count, (unsigned long)g.arrangedSubviews.count,
        g.translatesAutoresizingMaskIntoConstraints);
    g.translatesAutoresizingMaskIntoConstraints = NO;
    [r2 addSubview:g];
    [NSLayoutConstraint activateConstraints:@[
        [g.leadingAnchor constraintEqualToAnchor:r2.leadingAnchor], [g.topAnchor constraintEqualToAnchor:r2.topAnchor],
        [g.widthAnchor constraintEqualToConstant:300], [g.heightAnchor constraintEqualToConstant:30]
    ]];
    [r2 layoutSubtreeIfNeeded];
    frames(@"gravities", gv);
    [g insertView:iv(@"l0", 10, 10) atIndex:0 inGravity:NSStackViewGravityLeading];
    out(@"  inserted: %@", [[g.views valueForKey:@"identifier"] componentsJoinedByString:@","]);
}

#pragma mark - Windows

static void
test_window(void)
{
    out(@"[window]");
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 300, 200)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:YES];
    NSView *c = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    w.contentView = c;
    IV *x = isub(c, @"x", 10, 10);
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-20-[x(>=350)]-20-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(x)]];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-20-[x(>=100,<=400)]-20-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(x)]];
    NSRect before = w.frame;
    out(@"  before: content %@ min %@", R(c.frame), S(w.contentMinSize));
    [w layoutIfNeeded];
    out(@"  after: content %@ x %@ top kept %d", R(c.frame), R(x.frame), NSMaxY(w.frame) == NSMaxY(before));
    [w setContentSize:NSMakeSize(200, 100)];
    out(@"  set small: content %@", R(c.frame));
    [w layoutIfNeeded];
    out(@"  laid out: content %@ x %@ top kept %d", R(c.frame), R(x.frame), NSMaxY(w.frame) == NSMaxY(before));
    [w setContentSize:NSMakeSize(600, 600)];
    [w layoutIfNeeded];
    out(@"  big: content %@ x %@", R(c.frame), R(x.frame));
    out(@"  ambiguous: x %d", x.hasAmbiguousLayout);

    NSView *s = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NSView *a = sub(s, @"a"), *b = sub(s, @"b"), *cc = sub(s, @"c"), *d = sub(s, @"d");
    [NSLayoutConstraint activateConstraints:@[ [a.leftAnchor constraintEqualToAnchor:s.leftAnchor] ]];
    [NSLayoutConstraint activateConstraints:@[ [b.leftAnchor constraintEqualToAnchor:s.leftAnchor], [b.topAnchor constraintEqualToAnchor:s.topAnchor], [b.widthAnchor constraintGreaterThanOrEqualToConstant:10], [b.heightAnchor constraintEqualToConstant:10] ]];
    [NSLayoutConstraint activateConstraints:@[ [cc.leftAnchor constraintEqualToAnchor:s.leftAnchor], [cc.topAnchor constraintEqualToAnchor:s.topAnchor], P([cc.widthAnchor constraintEqualToConstant:10], 100), P([cc.widthAnchor constraintEqualToConstant:20], 100), [cc.heightAnchor constraintEqualToConstant:10] ]];
    [NSLayoutConstraint activateConstraints:@[ [d.leftAnchor constraintEqualToAnchor:s.leftAnchor], [d.topAnchor constraintEqualToAnchor:s.topAnchor], [d.widthAnchor constraintEqualToConstant:10], [d.heightAnchor constraintEqualToConstant:10] ]];
    [s layoutSubtreeIfNeeded];
    out(@"  ambiguity outside a window: %d %d %d %d", a.hasAmbiguousLayout, b.hasAmbiguousLayout, cc.hasAmbiguousLayout, d.hasAmbiguousLayout);
    NSWindow *w2 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:0 backing:NSBackingStoreBuffered defer:YES];
    w2.contentView = s;
    [w2 layoutIfNeeded];
    out(@"  in a window: %d %d %d %d", a.hasAmbiguousLayout, b.hasAmbiguousLayout, cc.hasAmbiguousLayout, d.hasAmbiguousLayout);
    out(@"  d frame %@ (2x rounding)", R(d.frame));
}


#pragma mark - Nibs and storyboards

static void
describe_tree(NSView *v, int depth)
{
    NSString *pad = [@"" stringByPaddingToLength:2 + depth * 2 withString:@" " startingAtIndex:0];
    BOOL button = [v isKindOfClass:[NSButton class]];
    /* (Apple's buttons host views of their own, with constraints) */
    out(@"%@%@ %s %@ translates %d hug %g %g compression %g %g constraints %@", pad, v.identifier, class_getName([v class]),
        button ? @"(frame not compared)" : R(v.frame), v.translatesAutoresizingMaskIntoConstraints,
        [v contentHuggingPriorityForOrientation:0], [v contentHuggingPriorityForOrientation:1],
        [v contentCompressionResistancePriorityForOrientation:0], [v contentCompressionResistancePriorityForOrientation:1],
        button ? @"-" : [NSString stringWithFormat:@"%lu", (unsigned long)v.constraints.count]);
    if ([v isKindOfClass:[NSStackView class]]) {
        NSStackView *st = (NSStackView *)v;
        out(@"%@  stack: orientation %ld alignment %ld distribution %ld spacing %g insets %g %g %g %g detaches %d views %@ "
            @"leading %lu center %lu trailing %lu hugging %g",
            pad, (long)st.orientation, (long)st.alignment, (long)st.distribution, st.spacing, st.edgeInsets.top,
            st.edgeInsets.left, st.edgeInsets.bottom, st.edgeInsets.right, st.detachesHiddenViews,
            [[st.views valueForKey:@"identifier"] componentsJoinedByString:@","],
            (unsigned long)[st viewsInGravity:NSStackViewGravityLeading].count,
            (unsigned long)[st viewsInGravity:NSStackViewGravityCenter].count,
            (unsigned long)[st viewsInGravity:NSStackViewGravityTrailing].count, [st huggingPriorityForOrientation:0]);
    }
    if (button)
        return;
    for (NSView *sub in v.subviews)
        describe_tree(sub, depth + 1);
}

static void
test_nib(NSString *dir)
{
    out(@"[nib]");
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"layout-test.nib"]];
    NSNib *nib = data ? [[NSNib alloc] initWithNibData:data bundle:nil] : nil;
    NSArray *top = nil;
    if (![nib instantiateWithOwner:nil topLevelObjects:&top]) {
        out(@"  no nib");
        return;
    }
    NSView *root = nil;
    for (id o in top)
        if ([o isKindOfClass:[NSView class]])
            root = o;
    out(@"  root %@ translates %d", root.identifier, root.translatesAutoresizingMaskIntoConstraints);
    for (LC *c in root.constraints)
        out(@"    %@ archived %d", c, c.shouldBeArchived);
    for (NSView *v in root.subviews)
        for (LC *c in v.constraints)
            out(@"    %@: %@", v.identifier, c);
    [root layoutSubtreeIfNeeded];
    describe_tree(root, 0);
    [root setFrameSize:NSMakeSize(500, 360)];
    [root layoutSubtreeIfNeeded];
    out(@"  resized:");
    describe_tree(root, 0);
}

@interface LTSegue : NSStoryboardSegue
@end

@implementation LTSegue
- (void)perform
{
    out(@"  LTSegue perform %@: %s -> %s", self.identifier, class_getName([self.sourceController class]),
        class_getName([self.destinationController class]));
}
@end

@interface LTViewController : NSViewController
@end

@implementation LTViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    out(@"  %s viewDidLoad %@", class_getName([self class]), self.view.identifier);
}
- (BOOL)shouldPerformSegueWithIdentifier:(NSStoryboardSegueIdentifier)identifier sender:(id)sender
{
    out(@"  should perform %@ sender %@", identifier, sender);
    return ![identifier isEqualToString:@"toModal"];
}
- (void)prepareForSegue:(NSStoryboardSegue *)segue sender:(id)sender
{
    out(@"  prepare %@ %s -> %s sender %@", segue.identifier, class_getName([segue.sourceController class]),
        class_getName([segue.destinationController class]), sender);
}
@end

@interface LTWindowController : NSWindowController
@end

@implementation LTWindowController
- (void)windowDidLoad
{
    [super windowDidLoad];
    out(@"  LTWindowController windowDidLoad %@", self.window.title);
}
@end

static void
test_storyboard(NSString *dir)
{
    out(@"[storyboard]");
    out(@"  main storyboard %@", [NSStoryboard mainStoryboard]);
    NSBundle *bundle = [NSBundle bundleWithPath:dir];
    NSStoryboard *sb = [NSStoryboard storyboardWithName:@"layout-test" bundle:bundle];
    out(@"  storyboard %d", sb != nil);
    if (!sb)
        return;
    NSWindowController *wc = [sb instantiateInitialController];
    out(@"  initial %s storyboard same %d window loaded %d", class_getName([wc class]), wc.storyboard == sb, wc.isWindowLoaded);
    NSWindow *w = wc.window;
    out(@"  window '%@' content %@ controller %s", w.title, R(w.contentView.frame),
        class_getName([wc.contentViewController class]));
    NSViewController *vc = wc.contentViewController;
    out(@"  content vc storyboard same %d view %@ in window %d same as content %d", vc.storyboard == sb,
        vc.view.identifier, vc.view.window == w, w.contentView == vc.view);
    [w layoutIfNeeded];
    for (NSView *v in vc.view.subviews)
        if (![v isKindOfClass:[NSButton class]])
            out(@"    %@ %@", v.identifier, R(v.frame));
    for (LC *c in vc.view.constraints)
        out(@"    %@", c);
    [vc performSegueWithIdentifier:@"toCustom" sender:@"me"];
    [vc performSegueWithIdentifier:@"toModal" sender:nil];
    @try {
        [vc performSegueWithIdentifier:@"nope" sender:nil];
    } @catch (NSException *e) {
        out(@"  %@ %@", e.name, e.reason);
    }
    NSViewController *detail = [sb instantiateControllerWithIdentifier:@"detail"];
    out(@"  detail %s loaded %d", class_getName([detail class]), detail.isViewLoaded);
    out(@"  detail view %@ %@", detail.view.identifier, R(detail.view.frame));
    NSWindowController *other = [sb instantiateControllerWithIdentifier:@"other"];
    out(@"  other %s window '%@' content %@", class_getName([other class]), other.window.title, R(other.window.contentView.frame));
    @try {
        [sb instantiateControllerWithIdentifier:@"missing"];
    } @catch (NSException *e) {
        out(@"  %@ %@", e.name, [e.reason stringByReplacingOccurrencesOfString:bundle.bundlePath withString:@"DIR"]);
    }
    __block int handled = 0;
    NSStoryboardSegue *seg = [NSStoryboardSegue segueWithIdentifier:@"manual" source:vc destination:detail
                                                     performHandler:^{ handled++; }];
    out(@"  manual segue %@ %s -> %s", seg.identifier, class_getName([seg.sourceController class]),
        class_getName([seg.destinationController class]));
    [seg perform];
    out(@"  handler ran %d", handled);
    NSStoryboardSegue *plain = [[NSStoryboardSegue alloc] initWithIdentifier:@"plain" source:vc destination:detail];
    out(@"  plain %@", plain.identifier);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("NSLayoutConstraint: %s\n", class_getImageName([NSLayoutConstraint class]));
        pointers = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+" options:0 error:NULL];
        NSString *dir = @(argc > 1 ? argv[1] : "/usr/local/share/finch");
        [NSApplication sharedApplication];
        test_constraints();
        test_anchors();
        test_vfl();
        test_solving();
        test_view_api();
        test_autoresizing();
        test_window();
        test_stack();
        test_nib(dir);
        test_storyboard(dir);
    }
    return 0;
}
