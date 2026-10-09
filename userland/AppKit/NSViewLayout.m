/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Auto Layout in views: NSView's constraint API, layout guides, content
 * sizes, autoresizing masks as constraints, and the layout pass.
 *
 * Each layout root (a window's content view, or the top of a tree of views
 * not in a window) has an engine: Finch's Cassowary solver
 * (CoreAutoLayout's FinchLayoutSolver) holding every active constraint of
 * the views under it. Each view (and guide) has four variables: its
 * alignment rect's origin, relative to its superview's top-left corner and
 * measured downward, and its size; constraints between items in different
 * superviews add up the offsets in between, so everything is solved in the
 * root's space. As on macOS:
 *
 * - views that translate their autoresizing mask get constraints
 *   (NSAutoresizingMaskLayoutConstraint) pinning their frame as the mask
 *   says, installed on the superview, kept up to date as frames change;
 *   the classic autoresizing still runs first when a superview resizes;
 * - intrinsic sizes become NSContentSizeLayoutConstraints: <= at the
 *   hugging priority, >= at the compression resistance;
 * - a root would stay its size, at just under priority 500
 *   (NSLayoutPriorityWindowSizeStayPut); a window's content view takes the
 *   size the constraints settle on, the window growing or shrinking with its
 *   top left fixed (a root outside a window keeps its frame);
 * - frames go to the views in -layout, top down, each edge rounded to the
 *   backing pixels (to points outside a window);
 * - a required constraint that can't be satisfied is left out, with
 *   Apple's "Unable to simultaneously satisfy constraints" message.
 *
 * Hierarchy changes rebuild a root's solver; everything else (constraints
 * coming and going, constants, intrinsic sizes, frames of autoresizing
 * views, the root's size) updates it incrementally.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"
#import "CoreAutoLayout/FinchLayoutItem.h"
#import "CoreAutoLayout/FinchLayoutSolver.h"

@class FinchLayoutEngine;

typedef struct {
    uint64_t engine;  /* the engine the variables are in (its ident) */
    FinchLayoutSolverVariable x, y, w, h;
} ItemVars;

/* A view's layout state, hung off NSView's _finchLayout. */
@interface FinchViewLayout : NSObject {
  @public
    NSView *view;  /* not retained */
    NSMutableArray<NSLayoutConstraint *> *constraints;  /* installed here, in order */
    NSMutableArray<NSAutoresizingMaskLayoutConstraint *> *autoresizing;  /* the view's own (installed on its superview) */
    NSRect arFrame, arSuperBounds;
    NSUInteger arMask;
    BOOL arValid, arSuperFlipped;
    NSContentSizeLayoutConstraint *content[2];
    NSLayoutPriority hug[2], compression[2];
    BOOL hugSet[2], compressionSet[2];
    BOOL contentInactive[2];
    NSMutableArray<NSLayoutGuide *> *guides;
    NSMutableDictionary<NSNumber *, NSLayoutAnchor *> *anchors;
    ItemVars vars;
    FinchLayoutEngine *engine;  /* retained; on roots */
    BOOL dirty, rebuild;        /* on roots */
}
@end

@implementation FinchViewLayout
- (instancetype)init
{
    self = [super init];
    if (self) {
        dirty = YES;
        hug[0] = hug[1] = NSLayoutPriorityDefaultLow;
        compression[0] = compression[1] = NSLayoutPriorityDefaultHigh;
    }
    return self;
}
@end

static FinchViewLayout *
state(NSView *view)
{
    FinchViewLayout *s = [view _finchLayoutState];
    if (!s) {
        s = [[FinchViewLayout alloc] init];
        s->view = view;
        [view _finchSetLayoutState:s];
        [s release];
    }
    return s;
}

static FinchViewLayout *
state_if_any(NSView *view)
{
    return [view _finchLayoutState];
}

#pragma mark - Layout guides

@interface NSLayoutGuide () {
  @public
    __weak NSView *_owningView;
    NSString *_identifier;
    NSMutableDictionary *_anchors;
    ItemVars _vars;
}
@end

#pragma mark - Roots

/* The view a layout pass for this view solves under. */
static NSView *
layout_root(NSView *view)
{
    NSWindow *w = [view window];
    NSView *content = [w contentView];
    for (NSView *v = view; v; v = [v superview]) {
        if (v == content)
            return v;
        if (![v superview])
            return v;
    }
    return view;
}

static BOOL
is_root(NSView *view)
{
    return ![view superview] || [[view window] contentView] == view;
}

static void
mark_dirty(NSView *view, BOOL rebuild)
{
    if (!view)
        return;
    NSView *root = layout_root(view);
    FinchViewLayout *s = state(root);
    s->dirty = YES;
    if (rebuild)
        s->rebuild = YES;
    if ([root window])
        [root setNeedsLayout:YES];
}

#pragma mark - The engine

typedef struct {
    uint64_t engine;
    FinchLayoutSolverConstraint *a, *b;  /* a content-size constraint is two: hugging and compression */
    double constant;  /* the constraint's */
    double k;         /* the solver's: the expression's constant */
    NSLayoutPriority priority, priorityB;
    NSLayoutRelation relation;
    BOOL broken;
} EngineRecord;

static uint64_t next_engine_ident = 1;

@interface FinchLayoutEngine : NSObject {
  @public
    FinchLayoutSolver *solver;
    uint64_t ident;
    NSView *root;  /* not retained */
    NSMutableArray<NSLayoutConstraint *> *installed;
    FinchLayoutSolverConstraint *rootSize[2], *minSize[2], *maxSize[2];
    double rootSizeValue[2], minValue[2], maxValue[2];
    BOOL windowMode, nonNegative;
    ItemVars rootVars;
}
@end

static EngineRecord *
record_of(NSLayoutConstraint *c, FinchLayoutEngine *e)
{
    EngineRecord *r = [c _finchEngineData];
    return r && r->engine == e->ident ? r : NULL;
}

@implementation FinchLayoutEngine

- (instancetype)initWithRoot:(NSView *)view
{
    self = [super init];
    if (self) {
        solver = FinchLayoutSolverCreate();
        ident = next_engine_ident++;
        root = view;
        installed = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    for (NSLayoutConstraint *c in installed) {
        EngineRecord *r = record_of(c, self);
        if (r) {
            free(r);
            [c _finchSetEngineData:NULL];
        }
    }
    [installed release];
    FinchLayoutSolverDestroy(solver);
    [super dealloc];
}

@end

static ItemVars *
item_vars(id item)
{
    if ([item isKindOfClass:[NSView class]])
        return &state(item)->vars;
    if ([item isKindOfClass:[NSLayoutGuide class]])
        return &((NSLayoutGuide *)item)->_vars;
    return NULL;
}

static ItemVars *
vars_in(FinchLayoutEngine *e, id item)
{
    ItemVars *v = item_vars(item);
    if (!v)
        return NULL;
    if (v->engine != e->ident) {
        v->engine = e->ident;
        v->x = FinchLayoutSolverNewVariable(e->solver);
        v->y = FinchLayoutSolverNewVariable(e->solver);
        v->w = FinchLayoutSolverNewVariable(e->solver);
        v->h = FinchLayoutSolverNewVariable(e->solver);
    }
    return v;
}

static NSEdgeInsets
insets_of(id item)
{
    if ([item isKindOfClass:[NSView class]])
        return [(NSView *)item alignmentRectInsets];
    return NSEdgeInsetsMake(0, 0, 0, 0);
}

static id
superitem_of(id item)
{
    if ([item isKindOfClass:[NSLayoutGuide class]])
        return [(NSLayoutGuide *)item owningView];
    return [item superview];
}

#pragma mark - Expressions

typedef struct {
    FinchLayoutSolverVariable v[64];
    double c[64];
    int n;
    double k;
} Expr;

static void
expr_add(Expr *e, FinchLayoutSolverVariable v, double c)
{
    if (c == 0)
        return;
    for (int i = 0; i < e->n; i++)
        if (e->v[i] == v) {
            e->c[i] += c;
            return;
        }
    if (e->n < 64) {
        e->v[e->n] = v;
        e->c[e->n++] = c;
    }
}

static void abs_origin(FinchLayoutEngine *e, id item, BOOL vertical, Expr *x, double coeff);

/* The top-left of a view's frame (its content origin) in the root's space. */
static void
content_origin(FinchLayoutEngine *e, NSView *view, BOOL vertical, Expr *x, double coeff)
{
    if (!view || view == e->root)
        return;
    NSEdgeInsets in = insets_of(view);
    abs_origin(e, view, vertical, x, coeff);
    x->k -= coeff * (vertical ? in.top : in.left);
}

/* The top-left of an item's alignment rect in the root's space. */
static void
abs_origin(FinchLayoutEngine *e, id item, BOOL vertical, Expr *x, double coeff)
{
    if (item == e->root) {
        NSEdgeInsets in = insets_of(item);
        x->k += coeff * (vertical ? in.top : in.left);
        return;
    }
    ItemVars *v = vars_in(e, item);
    if (!v)
        return;
    expr_add(x, vertical ? v->y : v->x, coeff);
    content_origin(e, superitem_of(item), vertical, x, coeff);
}

static FinchLayoutSolverVariable
size_var(FinchLayoutEngine *e, id item, BOOL vertical)
{
    ItemVars *v = item == e->root ? &e->rootVars : vars_in(e, item);
    return v ? (vertical ? v->h : v->w) : 0;
}

static void
attribute_expr(FinchLayoutEngine *e, id item, NSLayoutAttribute a, Expr *x, double coeff)
{
    switch ((NSInteger)a) {
    case NSLayoutAttributeLeft:
    case NSLayoutAttributeLeading:
        abs_origin(e, item, NO, x, coeff);
        break;
    case NSLayoutAttributeRight:
    case NSLayoutAttributeTrailing:
        abs_origin(e, item, NO, x, coeff);
        expr_add(x, size_var(e, item, NO), coeff);
        break;
    case NSLayoutAttributeCenterX:
        abs_origin(e, item, NO, x, coeff);
        expr_add(x, size_var(e, item, NO), coeff * 0.5);
        break;
    case NSLayoutAttributeWidth:
        expr_add(x, size_var(e, item, NO), coeff);
        break;
    case NSLayoutAttributeTop:
        abs_origin(e, item, YES, x, coeff);
        break;
    case NSLayoutAttributeBottom:
        abs_origin(e, item, YES, x, coeff);
        expr_add(x, size_var(e, item, YES), coeff);
        break;
    case NSLayoutAttributeCenterY:
        abs_origin(e, item, YES, x, coeff);
        expr_add(x, size_var(e, item, YES), coeff * 0.5);
        break;
    case NSLayoutAttributeHeight:
        expr_add(x, size_var(e, item, YES), coeff);
        break;
    case NSLayoutAttributeFirstBaseline:
        abs_origin(e, item, YES, x, coeff);
        if ([item isKindOfClass:[NSView class]])
            x->k += coeff * [(NSView *)item firstBaselineOffsetFromTop];
        break;
    case NSLayoutAttributeLastBaseline:
        abs_origin(e, item, YES, x, coeff);
        expr_add(x, size_var(e, item, YES), coeff);
        if ([item isKindOfClass:[NSView class]])
            x->k -= coeff * [(NSView *)item lastBaselineOffsetFromBottom];
        break;
    default:
        break;
    }
}

static void
anchor_expr(FinchLayoutEngine *e, NSLayoutAnchor *anchor, Expr *x, double coeff)
{
    if ([anchor _finchFromAnchor]) {
        anchor_expr(e, [anchor _finchToAnchor], x, coeff);
        anchor_expr(e, [anchor _finchFromAnchor], x, -coeff);
        return;
    }
    attribute_expr(e, [anchor item], [anchor _finchAttribute], x, coeff);
}

/* A frame dimension of a view (its alignment size plus insets). */
static void
frame_size_expr(FinchLayoutEngine *e, NSView *view, BOOL vertical, Expr *x, double coeff)
{
    NSEdgeInsets in = insets_of(view);
    expr_add(x, size_var(e, view, vertical), coeff);
    x->k += coeff * (vertical ? in.top + in.bottom : in.left + in.right);
}

/* An autoresizing-mask constraint, in the superview's frame coordinates. */
static void
autoresizing_expr(FinchLayoutEngine *e, NSAutoresizingMaskLayoutConstraint *c, Expr *x)
{
    NSView *view = [c firstItem], *sup = [view superview];
    ItemVars *v = vars_in(e, view);
    NSEdgeInsets in = insets_of(view);
    BOOL flipped = [sup isFlipped];
    CGFloat m = [c multiplier];
    switch ([c _finchKind]) {
    case FinchAutoresizingMinX:
    case FinchAutoresizingPropMinX:
        expr_add(x, v->x, 1);
        x->k -= in.left;
        if ([c _finchKind] == FinchAutoresizingPropMinX)
            frame_size_expr(e, sup, NO, x, -m);
        break;
    case FinchAutoresizingWidth:
    case FinchAutoresizingPropWidth:
        frame_size_expr(e, view, NO, x, 1);
        if ([c _finchKind] == FinchAutoresizingPropWidth)
            frame_size_expr(e, sup, NO, x, -m);
        break;
    case FinchAutoresizingMaxXMargin:
        frame_size_expr(e, sup, NO, x, 1);
        expr_add(x, v->x, -1);
        expr_add(x, v->w, -1);
        x->k -= in.right;
        break;
    case FinchAutoresizingHeight:
    case FinchAutoresizingPropHeight:
        frame_size_expr(e, view, YES, x, 1);
        if ([c _finchKind] == FinchAutoresizingPropHeight)
            frame_size_expr(e, sup, YES, x, -m);
        break;
    case FinchAutoresizingMinY:
    case FinchAutoresizingPropMinY:
    case FinchAutoresizingMaxYMargin: {
        /* minY is the frame's distance from the superview's bottom (unflipped) or top (flipped) */
        BOOL fromTop = flipped == ([c _finchKind] != FinchAutoresizingMaxYMargin);
        if (fromTop) {
            expr_add(x, v->y, 1);
            x->k -= in.top;
        } else {
            frame_size_expr(e, sup, YES, x, 1);
            expr_add(x, v->y, -1);
            expr_add(x, v->h, -1);
            x->k -= in.bottom;
        }
        if ([c _finchKind] == FinchAutoresizingPropMinY)
            frame_size_expr(e, sup, YES, x, -m);
        break;
    }
    }
    x->k -= [c constant];
}

#pragma mark - Unsatisfiable constraints

static void
log_unsatisfiable(FinchLayoutEngine *e, NSLayoutConstraint *broken)
{
    NSArray *items = [broken _finchItems];
    NSMutableArray *conflicting = [NSMutableArray array];
    for (NSLayoutConstraint *c in e->installed) {
        if ([c priority] < NSLayoutPriorityRequired || !record_of(c, e) || record_of(c, e)->broken)
            continue;
        for (id item in [c _finchItems])
            if ([items indexOfObjectIdenticalTo:item] != NSNotFound) {
                [conflicting addObject:[NSString stringWithFormat:@"    \"%@\"", c]];
                break;
            }
    }
    [conflicting addObject:[NSString stringWithFormat:@"    \"%@\"", broken]];
    NSLog(@"Unable to simultaneously satisfy constraints:\n(\n%@\n)\n\nWill attempt to recover by breaking constraint "
          @"\n%@\n\nSet the NSUserDefault NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints to YES to have "
          @"-[NSWindow visualizeConstraints:] automatically called when this happens.  And/or, set a symbolic "
          @"breakpoint on LAYOUT_CONSTRAINTS_NOT_SATISFIABLE to catch this in the debugger.",
          [conflicting componentsJoinedByString:@",\n"], broken);
}

#pragma mark - Adding constraints to the solver

static FinchLayoutSolverConstraint *
solver_add(FinchLayoutEngine *e, Expr *x, NSLayoutRelation rel, NSLayoutPriority p)
{
    return FinchLayoutSolverAdd(e->solver, x->v, x->c, x->n, x->k, (int)rel, p);
}

static void
engine_add(FinchLayoutEngine *e, NSLayoutConstraint *c)
{
    EngineRecord *r = [c _finchEngineData];
    if (!r || r->engine != e->ident) {
        r = calloc(1, sizeof(EngineRecord));  /* a record of another engine belongs to it; that engine is gone or rebuilt */
        [c _finchSetEngineData:r];
    }
    r->engine = e->ident;
    r->constant = [c constant];
    r->priority = [c priority];
    r->relation = [c relation];
    r->a = r->b = NULL;
    r->broken = NO;
    Expr x = {0};
    if ([c isKindOfClass:[NSContentSizeLayoutConstraint class]]) {
        NSContentSizeLayoutConstraint *cs = (NSContentSizeLayoutConstraint *)c;
        BOOL vertical = [c firstAttribute] == NSLayoutAttributeHeight;
        expr_add(&x, size_var(e, [c firstItem], vertical), 1);
        x.k = -[c constant];
        r->priority = [cs huggingPriority];
        r->priorityB = [cs compressionResistancePriority];
        r->k = x.k;
        r->a = solver_add(e, &x, NSLayoutRelationLessThanOrEqual, r->priority);
        r->b = solver_add(e, &x, NSLayoutRelationGreaterThanOrEqual, r->priorityB);
        if ((!r->a && r->priority >= NSLayoutPriorityRequired) || (!r->b && r->priorityB >= NSLayoutPriorityRequired)) {
            r->broken = YES;
            log_unsatisfiable(e, c);
        }
        return;
    }
    if ([c isKindOfClass:[NSAutoresizingMaskLayoutConstraint class]]) {
        autoresizing_expr(e, (NSAutoresizingMaskLayoutConstraint *)c, &x);
    } else {
        anchor_expr(e, [c firstAnchor], &x, 1);
        NSLayoutAnchor *second = [c secondAnchor];
        if (second)
            anchor_expr(e, second, &x, -[c multiplier]);
        x.k -= [c constant];
    }
    r->k = x.k;
    r->a = solver_add(e, &x, [c relation], [c priority]);
    if (!r->a) {
        r->broken = YES;
        log_unsatisfiable(e, c);
    }
}

static void
engine_remove(FinchLayoutEngine *e, NSLayoutConstraint *c)
{
    EngineRecord *r = record_of(c, e);
    if (!r)
        return;
    if (r->a)
        FinchLayoutSolverRemove(e->solver, r->a);
    if (r->b)
        FinchLayoutSolverRemove(e->solver, r->b);
    free(r);
    [c _finchSetEngineData:NULL];
}

/* Bring a constraint already in the solver up to date. */
static void
engine_update(FinchLayoutEngine *e, NSLayoutConstraint *c)
{
    EngineRecord *r = record_of(c, e);
    BOOL content = [c isKindOfClass:[NSContentSizeLayoutConstraint class]];
    NSLayoutPriority p = content ? [(NSContentSizeLayoutConstraint *)c huggingPriority] : [c priority];
    NSLayoutPriority pb = content ? [(NSContentSizeLayoutConstraint *)c compressionResistancePriority] : r->priorityB;
    if (r->broken || p != r->priority || pb != r->priorityB || [c relation] != r->relation) {
        engine_remove(e, c);
        engine_add(e, c);
        return;
    }
    double k = [c constant];
    if (k == r->constant)
        return;
    /* the solver's constant moves opposite to the constraint's: re-solve incrementally from there */
    double solverK = r->k - (k - r->constant);
    BOOL ok = YES;
    if (r->a)
        ok = FinchLayoutSolverSetConstant(e->solver, r->a, solverK);
    if (ok && r->b)
        ok = FinchLayoutSolverSetConstant(e->solver, r->b, solverK);
    r->k = solverK;
    r->constant = k;
    if (!ok) {
        engine_remove(e, c);
        engine_add(e, c);
    }
}

#pragma mark - Gathering constraints

/* Turn a view's autoresizing mask and frame into its constraints (installed on its superview). */
static void
update_autoresizing(NSView *view)
{
    FinchViewLayout *s = state(view);
    NSView *sup = [view superview];
    NSRect frame = [view frame], sb = [sup bounds];
    NSUInteger mask = [view autoresizingMask] & 0x3f;
    BOOL flipped = [sup isFlipped];
    if (s->arValid && NSEqualRects(frame, s->arFrame) && NSEqualSizes(sb.size, s->arSuperBounds.size) &&
        mask == s->arMask && flipped == s->arSuperFlipped)
        return;
    struct {
        FinchAutoresizingKind kind;
        CGFloat m, c;
    } want[4];
    int n = 0;
    for (int axis = 0; axis < 2; axis++) {
        BOOL L = mask & (axis ? NSViewMinYMargin : NSViewMinXMargin), W = mask & (axis ? NSViewHeightSizable : NSViewWidthSizable),
             R = mask & (axis ? NSViewMaxYMargin : NSViewMaxXMargin);
        /* (frames are taken as they are: a scrolled superview's bounds origin doesn't move its subviews' constraints) */
        CGFloat origin = axis ? frame.origin.y : frame.origin.x;
        CGFloat size = axis ? frame.size.height : frame.size.width, total = axis ? sb.size.height : sb.size.width;
        CGFloat after = total - origin - size;
        FinchAutoresizingKind minK = axis ? FinchAutoresizingMinY : FinchAutoresizingMinX,
                              sizeK = axis ? FinchAutoresizingHeight : FinchAutoresizingWidth,
                              marginK = axis ? FinchAutoresizingMaxYMargin : FinchAutoresizingMaxXMargin,
                              propMinK = axis ? FinchAutoresizingPropMinY : FinchAutoresizingPropMinX,
                              propSizeK = axis ? FinchAutoresizingPropHeight : FinchAutoresizingPropWidth;
#define WANT(k, mm, cc) (want[n].kind = (k), want[n].m = (mm), want[n].c = (cc), n++)
        if (L && W && R) {
            WANT(propMinK, total ? origin / total : 0, total ? 0 : origin);
            WANT(propSizeK, total ? size / total : 0, total ? 0 : size);
        } else if (L && W) {
            WANT(marginK, 1, after);
            CGFloat m = origin + size ? size / (origin + size) : 0;
            WANT(propSizeK, m, origin + size ? -m * after : size);
        } else if (L && R) {
            WANT(sizeK, 1, size);
            CGFloat m = origin + after ? origin / (origin + after) : 0;
            WANT(propMinK, m, origin + after ? -m * size : origin);
        } else if (W && R) {
            WANT(minK, 1, origin);
            CGFloat m = size + after ? size / (size + after) : 0;
            WANT(propSizeK, m, size + after ? -m * origin : size);
        } else if (L) {
            WANT(marginK, 1, after);
            WANT(sizeK, 1, size);
        } else if (W) {
            WANT(minK, 1, origin);
            WANT(marginK, 1, after);
        } else {
            WANT(minK, 1, origin);
            WANT(sizeK, 1, size);
        }
#undef WANT
    }
    FinchViewLayout *ss = state(sup);
    BOOL same = s->autoresizing && [s->autoresizing count] == (NSUInteger)n && mask == s->arMask;
    for (int i = 0; same && i < n; i++)
        same = [s->autoresizing[i] _finchKind] == want[i].kind;
    if (same) {
        for (int i = 0; i < n; i++) {
            NSAutoresizingMaskLayoutConstraint *c = s->autoresizing[i];
            if ([c multiplier] != want[i].m) {
                same = NO;
                break;
            }
            [c setConstant:want[i].c];
        }
    }
    if (!same) {
        NSMutableArray *fresh = [NSMutableArray array];
        for (int i = 0; i < n; i++)
            [fresh addObject:[NSAutoresizingMaskLayoutConstraint _finchConstraintForView:view superview:sup
                                                                                    kind:want[i].kind
                                                                              multiplier:want[i].m
                                                                                constant:want[i].c mask:mask]];
        NSUInteger at = NSNotFound;
        for (NSAutoresizingMaskLayoutConstraint *old in s->autoresizing) {
            NSUInteger i = [ss->constraints indexOfObjectIdenticalTo:old];
            if (i != NSNotFound) {
                if (at == NSNotFound || i < at)
                    at = i;
                [ss->constraints removeObjectAtIndex:i];
            }
            [old _finchSetContainer:nil];
        }
        if (!ss->constraints)
            ss->constraints = [[NSMutableArray alloc] init];
        if (at == NSNotFound || at > [ss->constraints count])
            at = [ss->constraints count];
        for (NSAutoresizingMaskLayoutConstraint *c in fresh) {
            [ss->constraints insertObject:c atIndex:at++];
            [c _finchSetContainer:sup];
        }
        [s->autoresizing release];
        s->autoresizing = [fresh retain];
    }
    s->arFrame = frame;
    s->arSuperBounds = sb;
    s->arMask = mask;
    s->arSuperFlipped = flipped;
    s->arValid = YES;
}

static void
drop_autoresizing(NSView *view)
{
    FinchViewLayout *s = state_if_any(view);
    if (!s || !s->autoresizing)
        return;
    for (NSAutoresizingMaskLayoutConstraint *c in s->autoresizing) {
        NSView *container = [c _finchContainer];
        FinchViewLayout *cs = container ? state_if_any(container) : nil;
        if (cs)
            [cs->constraints removeObjectIdenticalTo:c];
        [c _finchSetContainer:nil];
    }
    [s->autoresizing release];
    s->autoresizing = nil;
    s->arValid = NO;
}

static NSLayoutPriority
hug_of(NSView *view, int o)
{
    return [view contentHuggingPriorityForOrientation:o];
}

static NSLayoutPriority
compression_of(NSView *view, int o)
{
    return [view contentCompressionResistancePriorityForOrientation:o];
}

/* Keep a view's content-size constraints in step with its intrinsic size. */
static void
update_content(NSView *view)
{
    FinchViewLayout *s = state(view);
    NSSize size = [view intrinsicContentSize];
    for (int o = 0; o < 2; o++) {
        CGFloat v = o ? size.height : size.width;
        BOOL want = v != NSViewNoIntrinsicMetric;
        if (!want) {
            if (s->content[o]) {
                [s->content[o] _finchSetContainer:nil];
                [s->content[o] release];
                s->content[o] = nil;
            }
            continue;
        }
        if (!s->content[o]) {
            s->content[o] = [[NSContentSizeLayoutConstraint _finchConstraintForView:view orientation:o constant:v
                                                                                hug:hug_of(view, o)
                                                              compressionResistance:compression_of(view, o)] retain];
            [s->content[o] _finchSetContainer:view];
        } else {
            [s->content[o] _finchSetHuggingPriority:hug_of(view, o) compressionResistance:compression_of(view, o)];
            [s->content[o] setConstant:v];
        }
    }
}

static BOOL
is_nested_root(NSView *view, NSView *root)
{
    return view != root && [[view window] contentView] == view;
}

/* Does anything under the root use constraints (other than autoresizing ones)? Looks only. */
static BOOL
uses_constraints(NSView *view, NSView *root)
{
    if (is_nested_root(view, root))
        return NO;
    if (view != root && ![view translatesAutoresizingMaskIntoConstraints])
        return YES;
    FinchViewLayout *s = state_if_any(view);
    for (NSLayoutConstraint *c in s ? s->constraints : nil)
        if (![c isKindOfClass:[NSAutoresizingMaskLayoutConstraint class]])
            return YES;
    for (NSView *sub in [view subviews])
        if (uses_constraints(sub, root))
            return YES;
    return NO;
}

/* Nothing does: no autoresizing constraints either. */
static void
drop_all_autoresizing(NSView *view, NSView *root)
{
    if (is_nested_root(view, root))
        return;
    drop_autoresizing(view);
    for (NSView *sub in [view subviews])
        drop_all_autoresizing(sub, root);
}

/* Walk a root's subtree: refresh the derived constraints (autoresizing masks, intrinsic sizes). */
static void
refresh(NSView *view, NSView *root, BOOL *uses)
{
    if (is_nested_root(view, root))
        return;
    FinchViewLayout *s = state(view);
    if (view != root) {
        if ([view translatesAutoresizingMaskIntoConstraints])
            update_autoresizing(view);
        else {
            drop_autoresizing(view);
            *uses = YES;
        }
    }
    update_content(view);
    if ([s->constraints count])
        *uses = YES;
    for (NSView *sub in [view subviews])
        refresh(sub, root, uses);
}

/* ... then collect every active constraint, in order. */
static void
collect(NSView *view, NSView *root, NSMutableArray *out)
{
    if (is_nested_root(view, root))
        return;
    FinchViewLayout *s = state(view);
    for (NSLayoutConstraint *c in s->constraints)
        [out addObject:c];
    for (int o = 0; o < 2; o++)
        if (s->content[o] && !s->contentInactive[o])
            [out addObject:s->content[o]];
    for (NSView *sub in [view subviews])
        collect(sub, root, out);
}

static void
gather(NSView *view, NSView *root, NSMutableArray *out, BOOL *uses)
{
    refresh(view, root, uses);
    collect(view, root, out);
}

#pragma mark - Root size

static void
set_root_size(FinchLayoutEngine *e, int o, double value, NSLayoutPriority p)
{
    if (e->rootSize[o] && e->rootSizeValue[o] == value)
        return;
    if (e->rootSize[o])
        FinchLayoutSolverRemove(e->solver, e->rootSize[o]);
    FinchLayoutSolverVariable v = o ? e->rootVars.h : e->rootVars.w;
    double one = 1;
    e->rootSize[o] = FinchLayoutSolverAdd(e->solver, &v, &one, 1, -value, 0, p);
    if (!e->rootSize[o])
        e->rootSize[o] = FinchLayoutSolverAdd(e->solver, &v, &one, 1, -value, 0, 999);
    e->rootSizeValue[o] = value;
}

static void
set_bound(FinchLayoutEngine *e, FinchLayoutSolverConstraint **slot, double *last, int o, double value, int rel)
{
    if (*slot && *last == value)
        return;
    if (*slot)
        FinchLayoutSolverRemove(e->solver, *slot);
    *slot = NULL;
    *last = value;
    if (value <= 0 && rel > 0)
        return;
    if (value >= 1e7 && rel < 0)
        return;
    FinchLayoutSolverVariable v = o ? e->rootVars.h : e->rootVars.w;
    double one = 1;
    *slot = FinchLayoutSolverAdd(e->solver, &v, &one, 1, -value, rel, NSLayoutPriorityRequired);
}

static void
update_root_size(FinchLayoutEngine *e)
{
    NSView *root = e->root;
    NSEdgeInsets in = insets_of(root);
    NSSize size = [root frame].size;
    NSWindow *w = [root window];
    e->windowMode = w && [w contentView] == root;
    /* a root stays its size just below NSLayoutPriorityWindowSizeStayPut, as Apple's: priority 500 moves it */
    NSLayoutPriority p = NSLayoutPriorityWindowSizeStayPut - 0.001f;
    if (e->windowMode) {
        NSSize mn = [w contentMinSize], mx = [w contentMaxSize];
        set_bound(e, &e->minSize[0], &e->minValue[0], 0, mn.width - in.left - in.right, 1);
        set_bound(e, &e->minSize[1], &e->minValue[1], 1, mn.height - in.top - in.bottom, 1);
        set_bound(e, &e->maxSize[0], &e->maxValue[0], 0, mx.width >= 1e7 ? 1e7 : mx.width - in.left - in.right, -1);
        set_bound(e, &e->maxSize[1], &e->maxValue[1], 1, mx.height >= 1e7 ? 1e7 : mx.height - in.top - in.bottom, -1);
    }
    set_root_size(e, 0, size.width - in.left - in.right, p);
    set_root_size(e, 1, size.height - in.top - in.bottom, p);
    if (!e->nonNegative) {
        /* a root's size doesn't go below zero (its subviews' may, and are shown empty) */
        double one = 1;
        FinchLayoutSolverAdd(e->solver, &e->rootVars.w, &one, 1, 0, FinchLayoutSolverGreaterOrEqual, NSLayoutPriorityRequired);
        FinchLayoutSolverAdd(e->solver, &e->rootVars.h, &one, 1, 0, FinchLayoutSolverGreaterOrEqual, NSLayoutPriorityRequired);
        e->nonNegative = YES;
    }
}

#pragma mark - Syncing the engine

static FinchLayoutEngine *
make_engine(NSView *root)
{
    FinchLayoutEngine *e = [[FinchLayoutEngine alloc] initWithRoot:root];
    e->rootVars.engine = e->ident;
    e->rootVars.w = FinchLayoutSolverNewVariable(e->solver);
    e->rootVars.h = FinchLayoutSolverNewVariable(e->solver);
    /* the root's own variables are rootVars */
    ItemVars *rv = item_vars(root);
    *rv = e->rootVars;
    rv->x = FinchLayoutSolverNewVariable(e->solver);
    rv->y = FinchLayoutSolverNewVariable(e->solver);
    return e;
}

/* Bring a root's engine up to date. Returns it, or nil when nothing under the root uses constraints. */
static FinchLayoutEngine *
sync_engine(NSView *root)
{
    FinchViewLayout *rs = state(root);
    if (!rs->dirty)
        return rs->engine;
    NSMutableArray *active = [NSMutableArray array];
    BOOL uses = uses_constraints(root, root);
    if (!uses)
        drop_all_autoresizing(root, root);
    else
        gather(root, root, active, &uses);
    if (!uses) {
        /* no constraints of the app's: no engine (and no autoresizing constraints) */
        if (rs->engine) {
            [rs->engine release];
            rs->engine = nil;
        }
        rs->dirty = NO;
        return nil;
    }
    if (rs->rebuild && rs->engine) {
        [rs->engine release];
        rs->engine = nil;
    }
    rs->rebuild = NO;
    FinchLayoutEngine *e = rs->engine;
    if (!e) {
        e = rs->engine = make_engine(root);
    }
    if (rs->vars.engine != e->ident) {
        /* the root moved; start over */
        [rs->engine release];
        e = rs->engine = make_engine(root);
    }
    update_root_size(e);
    NSMutableSet *now = [NSMutableSet setWithArray:active];
    for (NSLayoutConstraint *c in [[e->installed copy] autorelease]) {
        if (![now containsObject:c]) {
            engine_remove(e, c);
            [e->installed removeObjectIdenticalTo:c];
        }
    }
    NSMutableSet *had = [NSMutableSet setWithArray:e->installed];
    for (NSLayoutConstraint *c in active) {
        if ([had containsObject:c] && record_of(c, e)) {
            engine_update(e, c);
        } else {
            engine_add(e, c);
            if (![had containsObject:c])
                [e->installed addObject:c];
        }
    }
    rs->dirty = NO;
    return e;
}

#pragma mark - Frames

static CGFloat
pixel_round(CGFloat v, CGFloat scale)
{
    return floor(v * scale + 0.5) / scale;
}

static CGFloat
layout_scale(NSView *view)
{
    NSWindow *w = [view window];
    return w ? [w backingScaleFactor] : 1;
}

static FinchLayoutEngine *
engine_for(NSView *view)
{
    NSView *root = layout_root(view);
    FinchViewLayout *rs = state_if_any(root);
    return rs ? rs->engine : nil;
}

/* The frame the engine gives a subview (in its superview's coordinates, rounded). */
static BOOL
engine_frame(FinchLayoutEngine *e, NSView *view, NSRect *out)
{
    ItemVars *v = item_vars(view);
    if (!v || v->engine != e->ident || view == e->root)
        return NO;
    NSView *sup = [view superview];
    double x = FinchLayoutSolverValue(e->solver, v->x), y = FinchLayoutSolverValue(e->solver, v->y);
    double w = FinchLayoutSolverValue(e->solver, v->w), h = FinchLayoutSolverValue(e->solver, v->h);
    NSEdgeInsets in = insets_of(view);
    double fx = x - in.left, ftop = y - in.top, fw = w + in.left + in.right, fh = h + in.top + in.bottom;
    NSRect b = [sup bounds];
    double fy = [sup isFlipped] ? ftop : b.size.height - ftop - fh;
    CGFloat scale = layout_scale(sup);
    CGFloat x0 = pixel_round(fx, scale), x1 = pixel_round(fx + fw, scale);
    CGFloat y0 = pixel_round(fy, scale), y1 = pixel_round(fy + fh, scale);
    /* a negative size shows as empty, where the engine put its origin */
    *out = NSMakeRect(x0, y0, MAX(0, x1 - x0), MAX(0, y1 - y0));
    return YES;
}

static BOOL applying;

/* -[NSView layout]'s work: the engine's frames to the subviews. */
static void
apply_subview_frames(NSView *view)
{
    FinchLayoutEngine *e = engine_for(view);
    if (!e)
        return;
    BOOL saved = applying;
    applying = YES;
    for (NSView *sub in [view subviews]) {
        NSRect f;
        if (engine_frame(e, sub, &f) && !NSEqualRects(f, [sub frame]))
            [sub setFrame:f];
    }
    applying = saved;
}

/* Which views' subviews the engine would move: they need -layout. */
static void
mark_needing_layout(FinchLayoutEngine *e, NSView *view, NSView *root)
{
    if (is_nested_root(view, root))
        return;
    for (NSView *sub in [view subviews]) {
        NSRect f;
        if (engine_frame(e, sub, &f) && !NSEqualRects(f, [sub frame])) {
            [view setNeedsLayout:YES];
            break;
        }
    }
    for (NSView *sub in [view subviews])
        mark_needing_layout(e, sub, root);
}

/* A window's content view takes the size its constraints settle on: the window resizes, its top left fixed. */
static void
resize_window_if_needed(FinchLayoutEngine *e)
{
    if (!e->windowMode)
        return;
    NSView *root = e->root;
    NSEdgeInsets in = insets_of(root);
    CGFloat scale = layout_scale(root);
    double w = pixel_round(FinchLayoutSolverValue(e->solver, e->rootVars.w) + in.left + in.right, scale);
    double h = pixel_round(FinchLayoutSolverValue(e->solver, e->rootVars.h) + in.top + in.bottom, scale);
    NSSize size = [root frame].size;
    if (fabs(w - size.width) < 1e-6 && fabs(h - size.height) < 1e-6)
        return;
    [[root window] setContentSize:NSMakeSize(w, h)];
    update_root_size(e);
}

static void lay_out_tree(NSView *view, NSView *root, int depth);

static void
layout_pass(NSView *view)
{
    NSView *root = layout_root(view);
    [root updateConstraintsForSubtreeIfNeeded];
    FinchLayoutEngine *e = sync_engine(root);
    if (e) {
        resize_window_if_needed(e);
        mark_needing_layout(e, root, root);
    }
    lay_out_tree(view, root, 0);
}

static void
lay_out_tree(NSView *view, NSView *root, int depth)
{
    if (depth > 0 && is_nested_root(view, root)) {
        layout_pass(view);
        return;
    }
    for (int guard = 0; guard < 8 && [view needsLayout]; guard++) {
        [view layout];
        [view setNeedsLayout:NO];
        /* -layout may have changed constraints */
        FinchViewLayout *rs = state(root);
        if (rs->dirty) {
            FinchLayoutEngine *e = sync_engine(root);
            if (e)
                mark_needing_layout(e, view, root);
        }
    }
    for (NSView *sub in [view subviews])
        lay_out_tree(sub, root, depth + 1);
}

#pragma mark - Hooks from NSView

void
FinchLayoutViewFrameDidChange(NSView *view)
{
    /* views no constraint has touched don't matter, unless they've just stopped translating their masks */
    if (applying || (![view _finchLayoutState] && [view translatesAutoresizingMaskIntoConstraints]))
        return;
    FinchViewLayout *s = state_if_any(view);
    if (s && s->autoresizing && [view translatesAutoresizingMaskIntoConstraints] && [view superview])
        update_autoresizing(view);
    mark_dirty(view, NO);
}

void
FinchLayoutViewDidMoveToSuperview(NSView *view)
{
    FinchViewLayout *s = state_if_any(view);
    if (s && s->engine && !is_root(view)) {
        [s->engine release];
        s->engine = nil;
    }
    if (s)
        s->arValid = NO;
    mark_dirty(view, YES);
}

/* Constraints that relate items no longer under a view go, as on macOS, when a subtree leaves. */
void
FinchLayoutViewWillLeaveSuperview(NSView *view, NSView *superview)
{
    drop_autoresizing(view);
    for (NSView *v = superview; v; v = [v superview]) {
        FinchViewLayout *s = state_if_any(v);
        if (!s || ![s->constraints count])
            continue;
        for (NSLayoutConstraint *c in [[s->constraints copy] autorelease]) {
            for (id item in [c _finchItems]) {
                NSView *iv = [item isKindOfClass:[NSLayoutGuide class]] ? [(NSLayoutGuide *)item owningView] : item;
                if (![iv isKindOfClass:[NSView class]])
                    continue;
                if ([iv isDescendantOf:view] || ![iv isDescendantOf:v]) {
                    [v removeConstraint:c];
                    break;
                }
            }
        }
    }
    mark_dirty(superview, YES);
}

void
FinchLayoutViewDealloc(NSView *view)
{
    FinchViewLayout *s = state_if_any(view);
    if (!s)
        return;
    for (NSLayoutConstraint *c in s->constraints)
        [c _finchSetContainer:nil];
    [s->constraints release];
    for (int o = 0; o < 2; o++) {
        [s->content[o] _finchSetContainer:nil];
        [s->content[o] release];
    }
    drop_autoresizing(view);
    [s->guides release];
    [s->anchors release];
    [s->engine release];
    s->view = nil;
}

#pragma mark - NSView's constraint API

@implementation NSView (NSConstraintBasedLayoutInstallingConstraints)

- (NSArray<NSLayoutConstraint *> *)constraints
{
    FinchViewLayout *s = state_if_any(self);
    if (!s)
        return @[];
    NSMutableArray *a = [NSMutableArray arrayWithArray:s->constraints ?: @[]];
    for (int o = 0; o < 2; o++)
        if (s->content[o])
            [a addObject:s->content[o]];
    return a;
}

- (void)addConstraint:(NSLayoutConstraint *)constraint
{
    if (!constraint)
        return;
    NSView *old = [constraint _finchContainer];
    if (old == self)
        return;
    [constraint retain];
    if (old)
        [old removeConstraint:constraint];
    FinchViewLayout *s = state(self);
    if (!s->constraints)
        s->constraints = [[NSMutableArray alloc] init];
    [s->constraints addObject:constraint];
    [constraint _finchSetContainer:self];
    [constraint release];
    mark_dirty(self, NO);
}

- (void)addConstraints:(NSArray<NSLayoutConstraint *> *)constraints
{
    for (NSLayoutConstraint *c in constraints)
        [self addConstraint:c];
}

- (void)removeConstraint:(NSLayoutConstraint *)constraint
{
    FinchViewLayout *s = state_if_any(self);
    if (!s || [constraint _finchContainer] != self)
        return;
    [[constraint retain] autorelease];
    [constraint _finchSetContainer:nil];
    [s->constraints removeObjectIdenticalTo:constraint];
    mark_dirty(self, NO);
}

- (void)removeConstraints:(NSArray<NSLayoutConstraint *> *)constraints
{
    for (NSLayoutConstraint *c in [[constraints copy] autorelease])
        [self removeConstraint:c];
}

- (NSLayoutXAxisAnchor *)leadingAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeLeading]; }
- (NSLayoutXAxisAnchor *)trailingAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeTrailing]; }
- (NSLayoutXAxisAnchor *)leftAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeLeft]; }
- (NSLayoutXAxisAnchor *)rightAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeRight]; }
- (NSLayoutYAxisAnchor *)topAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeTop]; }
- (NSLayoutYAxisAnchor *)bottomAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeBottom]; }
- (NSLayoutDimension *)widthAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeWidth]; }
- (NSLayoutDimension *)heightAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeHeight]; }
- (NSLayoutXAxisAnchor *)centerXAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeCenterX]; }
- (NSLayoutYAxisAnchor *)centerYAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeCenterY]; }
- (NSLayoutYAxisAnchor *)firstBaselineAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeFirstBaseline]; }
- (NSLayoutYAxisAnchor *)lastBaselineAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeLastBaseline]; }

@end

@implementation NSView (FinchLayoutItem)

- (id)_finchLayoutSuperitem { return [self superview]; }
- (id)_finchLayoutContainer { return self; }

- (NSLayoutAnchor *)_finchAnchorForAttribute:(NSLayoutAttribute)attribute
{
    FinchViewLayout *s = state(self);
    if (!s->anchors)
        s->anchors = [[NSMutableDictionary alloc] init];
    NSLayoutAnchor *a = s->anchors[@(attribute)];
    if (!a) {
        a = [NSLayoutAnchor _finchNewAnchorWithItem:self attribute:attribute];
        s->anchors[@(attribute)] = a;
    }
    return a;
}

- (void)_finchLayoutConstraintDidChange:(NSLayoutConstraint *)constraint
{
    mark_dirty(self, NO);
}

@end

#pragma mark - Core layout methods

@implementation NSView (NSConstraintBasedLayoutCoreMethods)

- (void)updateConstraints
{
    [self setNeedsUpdateConstraints:NO];
}

static void
update_constraints_tree(NSView *view)
{
    for (NSView *sub in [view subviews])
        update_constraints_tree(sub);
    if ([view respondsToSelector:@selector(_finchLayoutRefresh)])
        [(id)view _finchLayoutRefresh];  /* stack views: hidden views coming and going */
    if ([view needsUpdateConstraints]) {
        [view updateConstraints];
        [view setNeedsUpdateConstraints:NO];
    }
}

- (void)updateConstraintsForSubtreeIfNeeded
{
    update_constraints_tree(self);
}

@end

@implementation NSView (NSConstraintBasedLayoutLayout)

- (void)layout
{
    apply_subview_frames(self);
    [self setNeedsLayout:NO];
}

- (void)layoutSubtreeIfNeeded
{
    layout_pass(self);
}

@end

@implementation NSView (NSConstraintBasedCompatibility)
+ (BOOL)requiresConstraintBasedLayout { return NO; }
@end

#pragma mark - Content sizes, alignment and baselines

@implementation NSView (NSConstraintBasedLayoutLayering)

- (NSRect)alignmentRectForFrame:(NSRect)frame
{
    NSEdgeInsets in = [self alignmentRectInsets];
    BOOL flipped = [[self superview] isFlipped];
    return NSMakeRect(frame.origin.x + in.left, frame.origin.y + (flipped ? in.top : in.bottom),
                      frame.size.width - in.left - in.right, frame.size.height - in.top - in.bottom);
}

- (NSRect)frameForAlignmentRect:(NSRect)rect
{
    NSEdgeInsets in = [self alignmentRectInsets];
    BOOL flipped = [[self superview] isFlipped];
    return NSMakeRect(rect.origin.x - in.left, rect.origin.y - (flipped ? in.top : in.bottom),
                      rect.size.width + in.left + in.right, rect.size.height + in.top + in.bottom);
}

- (NSEdgeInsets)alignmentRectInsets { return NSEdgeInsetsMake(0, 0, 0, 0); }
- (CGFloat)firstBaselineOffsetFromTop { return 0; }
- (CGFloat)lastBaselineOffsetFromBottom { return [self baselineOffsetFromBottom]; }
- (CGFloat)baselineOffsetFromBottom { return 0; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric); }

- (void)invalidateIntrinsicContentSize
{
    if ([self _finchLayoutState])
        mark_dirty(self, NO);
}

- (NSLayoutPriority)_finchDefaultHuggingPriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    return NSLayoutPriorityDefaultLow;
}

- (NSLayoutPriority)_finchDefaultCompressionResistancePriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    return NSLayoutPriorityDefaultHigh;
}

- (NSLayoutPriority)contentHuggingPriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    FinchViewLayout *s = state_if_any(self);
    int i = o ? 1 : 0;
    return s && s->hugSet[i] ? s->hug[i] : [self _finchDefaultHuggingPriorityForOrientation:o];
}

- (void)setContentHuggingPriority:(NSLayoutPriority)priority forOrientation:(NSLayoutConstraintOrientation)o
{
    FinchViewLayout *s = state(self);
    int i = o ? 1 : 0;
    s->hug[i] = priority;
    s->hugSet[i] = YES;
    mark_dirty(self, NO);
}

- (NSLayoutPriority)contentCompressionResistancePriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    FinchViewLayout *s = state_if_any(self);
    int i = o ? 1 : 0;
    return s && s->compressionSet[i] ? s->compression[i]
                                     : [self _finchDefaultCompressionResistancePriorityForOrientation:o];
}

- (void)setContentCompressionResistancePriority:(NSLayoutPriority)priority
                                 forOrientation:(NSLayoutConstraintOrientation)o
{
    FinchViewLayout *s = state(self);
    int i = o ? 1 : 0;
    s->compression[i] = priority;
    s->compressionSet[i] = YES;
    mark_dirty(self, NO);
}

- (BOOL)isHorizontalContentSizeConstraintActive
{
    FinchViewLayout *s = state_if_any(self);
    return !(s && s->contentInactive[0]);
}

- (void)setHorizontalContentSizeConstraintActive:(BOOL)active
{
    state(self)->contentInactive[0] = !active;
    mark_dirty(self, NO);
}

- (BOOL)isVerticalContentSizeConstraintActive
{
    FinchViewLayout *s = state_if_any(self);
    return !(s && s->contentInactive[1]);
}

- (void)setVerticalContentSizeConstraintActive:(BOOL)active
{
    state(self)->contentInactive[1] = !active;
    mark_dirty(self, NO);
}

@end

/* Controls hug their content vertically, as Apple's; labels a little more horizontally. */
@implementation NSControl (FinchLayoutDefaults)
- (NSLayoutPriority)_finchDefaultHuggingPriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    return o == NSLayoutConstraintOrientationVertical ? NSLayoutPriorityDefaultHigh : NSLayoutPriorityDefaultLow;
}
@end

@implementation NSTextField (FinchLayoutDefaults)
- (NSLayoutPriority)_finchDefaultHuggingPriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    if (o == NSLayoutConstraintOrientationHorizontal)
        return ![self isEditable] && ![self isBezeled] && ![self drawsBackground] ? 251 : NSLayoutPriorityDefaultLow;
    return NSLayoutPriorityDefaultHigh;
}
@end

@implementation NSStepper (FinchLayoutDefaults)
- (NSLayoutPriority)_finchDefaultHuggingPriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    return NSLayoutPriorityDefaultHigh;
}
@end

@implementation NSColorWell (FinchLayoutDefaults)
- (NSLayoutPriority)_finchDefaultHuggingPriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    return NSLayoutPriorityDefaultLow;
}
@end

@implementation NSProgressIndicator (FinchLayoutDefaults)
- (NSLayoutPriority)_finchDefaultHuggingPriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    return o == NSLayoutConstraintOrientationVertical ? NSLayoutPriorityDefaultHigh : NSLayoutPriorityDefaultLow;
}
@end

@implementation NSImageView (FinchLayoutDefaults)
- (NSLayoutPriority)_finchDefaultHuggingPriorityForOrientation:(NSLayoutConstraintOrientation)o
{
    return NSLayoutPriorityDefaultLow;
}
@end

#pragma mark - Fitting size

/* The smallest size the view's own subtree of constraints allows, solved apart from the window's engine. */
static void
gather_fitting(NSView *view, NSView *top, NSMutableArray *out)
{
    FinchViewLayout *s = state(view);
    if (view != top && [view translatesAutoresizingMaskIntoConstraints])
        update_autoresizing(view);
    update_content(view);
    for (NSLayoutConstraint *c in s->constraints) {
        BOOL inside = YES;
        for (id item in [c _finchItems]) {
            NSView *iv = [item isKindOfClass:[NSLayoutGuide class]] ? [(NSLayoutGuide *)item owningView] : item;
            if (![iv isKindOfClass:[NSView class]] || ![iv isDescendantOf:top]) {
                inside = NO;
                break;
            }
        }
        if (inside)
            [out addObject:c];
    }
    for (int o = 0; o < 2; o++)
        if (s->content[o])
            [out addObject:s->content[o]];
    for (NSView *sub in [view subviews])
        gather_fitting(sub, top, out);
}

@implementation NSView (NSConstraintBasedLayoutFittingSize)

- (NSSize)fittingSize
{
    [self updateConstraintsForSubtreeIfNeeded];
    NSMutableArray *cs = [NSMutableArray array];
    gather_fitting(self, self, cs);
    /* a separate engine: the view is its root, wanting to be as small as it can */
    FinchViewLayout *s = state(self);
    ItemVars savedVars = s->vars;
    FinchLayoutEngine *e = make_engine(self);
    NSMutableArray *saved = [NSMutableArray array];
    for (NSLayoutConstraint *c in cs) {
        [saved addObject:[NSValue valueWithPointer:[c _finchEngineData]]];
        [c _finchSetEngineData:NULL];
    }
    double one = 1;
    FinchLayoutSolverVariable w = e->rootVars.w, h = e->rootVars.h;
    FinchLayoutSolverAdd(e->solver, &w, &one, 1, 0, 0, NSLayoutPriorityFittingSizeCompression);
    FinchLayoutSolverAdd(e->solver, &h, &one, 1, 0, 0, NSLayoutPriorityFittingSizeCompression);
    for (NSLayoutConstraint *c in cs) {
        engine_add(e, c);
        [e->installed addObject:c];
    }
    NSEdgeInsets in = [self alignmentRectInsets];
    CGFloat scale = layout_scale(self);
    NSSize size = NSMakeSize(ceil((FinchLayoutSolverValue(e->solver, w) + in.left + in.right) * scale - 1e-6) / scale + 0.0,
                             ceil((FinchLayoutSolverValue(e->solver, h) + in.top + in.bottom) * scale - 1e-6) / scale + 0.0);
    size.width = MAX(0, size.width) + 0.0;
    size.height = MAX(0, size.height) + 0.0;
    [e release];
    for (NSUInteger i = 0; i < [cs count]; i++)
        [cs[i] _finchSetEngineData:[saved[i] pointerValue]];
    s->vars = savedVars;
    /* views under it got variables in the fitting engine; the next pass gives them their own back */
    mark_dirty(self, YES);
    return size;
}

@end

#pragma mark - Debugging

@implementation NSView (NSConstraintBasedLayoutDebugging)

- (NSArray<NSLayoutConstraint *> *)constraintsAffectingLayoutForOrientation:(NSLayoutConstraintOrientation)o
{
    FinchLayoutEngine *e = engine_for(self);
    if (!e)
        return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSLayoutConstraint *c in e->installed) {
        if (![[c _finchItems] containsObject:self])
            continue;
        NSLayoutAttribute a = [c firstAttribute];
        BOOL vertical = a == NSLayoutAttributeTop || a == NSLayoutAttributeBottom || a == NSLayoutAttributeCenterY ||
                        a == NSLayoutAttributeHeight || a == NSLayoutAttributeFirstBaseline ||
                        a == NSLayoutAttributeLastBaseline || a == FinchLayoutAttributeMinY;
        if (vertical == (o == NSLayoutConstraintOrientationVertical))
            [out addObject:c];
    }
    return out;
}

- (BOOL)hasAmbiguousLayout
{
    /* as Apple's, only meaningful in a window */
    if (![self window])
        return NO;
    [self layoutSubtreeIfNeeded];
    FinchLayoutEngine *e = engine_for(self);
    ItemVars *v = item_vars(self);
    if (!e || !v || v->engine != e->ident || self == e->root)
        return NO;
    return FinchLayoutSolverIsAmbiguous(e->solver, v->x) || FinchLayoutSolverIsAmbiguous(e->solver, v->y) ||
           FinchLayoutSolverIsAmbiguous(e->solver, v->w) || FinchLayoutSolverIsAmbiguous(e->solver, v->h);
}

- (void)exerciseAmbiguityInLayout
{
}

@end

#pragma mark - Windows

@implementation NSWindow (NSConstraintBasedLayoutCoreMethods)

- (void)updateConstraintsIfNeeded
{
    [[[self contentView] superview] ?: [self contentView] updateConstraintsForSubtreeIfNeeded];
}

- (void)layoutIfNeeded
{
    [[[self contentView] superview] ?: [self contentView] layoutSubtreeIfNeeded];
}

@end

@implementation NSWindow (NSConstraintBasedLayoutAnchoring)

- (NSLayoutAttribute)anchorAttributeForOrientation:(NSLayoutConstraintOrientation)o
{
    return o == NSLayoutConstraintOrientationHorizontal ? NSLayoutAttributeLeft : NSLayoutAttributeTop;
}

- (void)setAnchorAttribute:(NSLayoutAttribute)attr forOrientation:(NSLayoutConstraintOrientation)o
{
}

@end

@implementation NSWindow (NSConstraintBasedLayoutDebugging)
- (void)visualizeConstraints:(NSArray<NSLayoutConstraint *> *)constraints
{
}
@end

@implementation NSControl (NSConstraintBasedLayoutLayering)
- (void)invalidateIntrinsicContentSizeForCell:(NSCell *)cell
{
    [self invalidateIntrinsicContentSize];
}
@end

#pragma mark - Layout guides

@implementation NSLayoutGuide

- (void)dealloc
{
    [_identifier release];
    [_anchors release];
    [super dealloc];
}

- (NSView *)owningView { return _owningView; }
- (void)setOwningView:(NSView *)view { _owningView = view; }
- (NSUserInterfaceItemIdentifier)identifier { return _identifier ?: @""; }
- (void)setIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    [_identifier autorelease];
    _identifier = [identifier copy];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>", NSStringFromClass([self class]), self];
}

- (id)_finchLayoutSuperitem { return _owningView; }
- (id)_finchLayoutContainer { return _owningView; }

- (NSLayoutAnchor *)_finchAnchorForAttribute:(NSLayoutAttribute)attribute
{
    if (!_anchors)
        _anchors = [[NSMutableDictionary alloc] init];
    NSLayoutAnchor *a = _anchors[@(attribute)];
    if (!a) {
        a = [NSLayoutAnchor _finchNewAnchorWithItem:self attribute:attribute];
        _anchors[@(attribute)] = a;
    }
    return a;
}

- (NSLayoutXAxisAnchor *)leadingAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeLeading]; }
- (NSLayoutXAxisAnchor *)trailingAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeTrailing]; }
- (NSLayoutXAxisAnchor *)leftAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeLeft]; }
- (NSLayoutXAxisAnchor *)rightAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeRight]; }
- (NSLayoutYAxisAnchor *)topAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeTop]; }
- (NSLayoutYAxisAnchor *)bottomAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeBottom]; }
- (NSLayoutDimension *)widthAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeWidth]; }
- (NSLayoutDimension *)heightAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeHeight]; }
- (NSLayoutXAxisAnchor *)centerXAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeCenterX]; }
- (NSLayoutYAxisAnchor *)centerYAnchor { return (id)[self _finchAnchorForAttribute:NSLayoutAttributeCenterY]; }

/* In the owning view's coordinates. */
- (NSRect)frame
{
    NSView *owner = _owningView;
    if (!owner)
        return NSZeroRect;
    [owner layoutSubtreeIfNeeded];
    FinchLayoutEngine *e = engine_for(owner);
    if (!e || _vars.engine != e->ident)
        return NSZeroRect;
    double x = FinchLayoutSolverValue(e->solver, _vars.x), y = FinchLayoutSolverValue(e->solver, _vars.y);
    double w = FinchLayoutSolverValue(e->solver, _vars.w), h = FinchLayoutSolverValue(e->solver, _vars.h);
    NSRect b = [owner bounds];
    double fy = [owner isFlipped] ? y : b.size.height - y - h;
    return NSMakeRect(x, fy, w, h);
}

- (BOOL)hasAmbiguousLayout
{
    NSView *owner = _owningView;
    if (![owner window])
        return NO;
    [owner layoutSubtreeIfNeeded];
    FinchLayoutEngine *e = engine_for(owner);
    if (!e || _vars.engine != e->ident)
        return NO;
    return FinchLayoutSolverIsAmbiguous(e->solver, _vars.x) || FinchLayoutSolverIsAmbiguous(e->solver, _vars.y) ||
           FinchLayoutSolverIsAmbiguous(e->solver, _vars.w) || FinchLayoutSolverIsAmbiguous(e->solver, _vars.h);
}

- (NSArray<NSLayoutConstraint *> *)constraintsAffectingLayoutForOrientation:(NSLayoutConstraintOrientation)o
{
    return @[];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _owningView = [coder decodeObjectForKey:@"NSOwningView"];
        _identifier = [[coder decodeObjectForKey:@"NSIdentifier"] copy];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeConditionalObject:_owningView forKey:@"NSOwningView"];
    if (_identifier)
        [coder encodeObject:_identifier forKey:@"NSIdentifier"];
}

@end

@implementation NSView (NSLayoutGuideSupport)

- (void)addLayoutGuide:(NSLayoutGuide *)guide
{
    FinchViewLayout *s = state(self);
    if (!s->guides)
        s->guides = [[NSMutableArray alloc] init];
    if ([s->guides indexOfObjectIdenticalTo:guide] != NSNotFound)
        return;
    NSView *old = [guide owningView];
    if (old && old != self)
        [old removeLayoutGuide:guide];
    [s->guides addObject:guide];
    [guide setOwningView:self];
    mark_dirty(self, NO);
}

- (void)removeLayoutGuide:(NSLayoutGuide *)guide
{
    FinchViewLayout *s = state_if_any(self);
    if (!s || [s->guides indexOfObjectIdenticalTo:guide] == NSNotFound)
        return;
    [[guide retain] autorelease];
    /* constraints on the guide go with it */
    for (NSView *v = self; v; v = [v superview]) {
        FinchViewLayout *vs = state_if_any(v);
        for (NSLayoutConstraint *c in [[vs->constraints copy] autorelease])
            if ([[c _finchItems] indexOfObjectIdenticalTo:guide] != NSNotFound)
                [v removeConstraint:c];
    }
    [guide setOwningView:nil];
    [s->guides removeObjectIdenticalTo:guide];
    mark_dirty(self, NO);
}

- (NSArray<NSLayoutGuide *> *)layoutGuides
{
    FinchViewLayout *s = state_if_any(self);
    NSMutableArray *a = [NSMutableArray array];
    Class stackPrivate = NSClassFromString(@"_FinchStackIdealGuide");
    for (NSLayoutGuide *g in s ? s->guides : nil)
        if (![g isKindOfClass:stackPrivate])  /* a stack view's own isn't listed, as Apple's */
            [a addObject:g];
    return a;
}

@end

#pragma mark - Nibs

/* Called at the end of -[NSView initWithCoder:]: the view's constraints and priorities. */
void
FinchLayoutDecodeView(NSView *view, NSCoder *coder)
{
    if ([coder containsValueForKey:@"NSHuggingPriority"]) {
        NSSize p = NSSizeFromString([coder decodeObjectForKey:@"NSHuggingPriority"]);
        [view setContentHuggingPriority:p.width forOrientation:NSLayoutConstraintOrientationHorizontal];
        [view setContentHuggingPriority:p.height forOrientation:NSLayoutConstraintOrientationVertical];
    }
    if ([coder containsValueForKey:@"NSAntiCompressionPriority"]) {
        NSSize p = NSSizeFromString([coder decodeObjectForKey:@"NSAntiCompressionPriority"]);
        [view setContentCompressionResistancePriority:p.width forOrientation:NSLayoutConstraintOrientationHorizontal];
        [view setContentCompressionResistancePriority:p.height forOrientation:NSLayoutConstraintOrientationVertical];
    }
    for (NSLayoutGuide *g in [coder decodeObjectForKey:@"NSViewLayoutGuides"])
        if ([g isKindOfClass:[NSLayoutGuide class]])
            [view addLayoutGuide:g];
    for (NSLayoutConstraint *c in [coder decodeObjectForKey:@"NSViewConstraints"])
        if ([c isKindOfClass:[NSLayoutConstraint class]])
            [view addConstraint:c];
}
