/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Cassowary incremental simplex (see FinchLayoutSolver.h).
 *
 * The tableau is a set of rows, one per basic symbol: basic = constant +
 * sum(coefficient * parametric symbol). Symbols are the caller's variables
 * (external, unrestricted), slacks (>= 0, for inequalities), errors (>= 0,
 * for optional constraints; they appear in the objective) and dummies
 * (markers of required equalities; always 0, never enter the basis).
 *
 * The objective is one row per priority, highest first; a symbol's cost is
 * the vector of its coefficients, compared lexicographically. The primal
 * simplex keeps the tableau optimal after adds and removes; the dual simplex
 * restores feasibility after a constant changes. Ties pick the lowest symbol
 * (Bland's rule), so the solver doesn't cycle.
 */
#include "FinchLayoutSolver.h"
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define EPS 1.0e-8
#define NONE 0u

enum { SYM_EXTERNAL = 1, SYM_SLACK, SYM_ERROR, SYM_DUMMY };

typedef struct {
    uint32_t sym;
    double c;
} Term;

typedef struct {
    Term *t;
    int n, cap;
    double k;
} Row;

typedef struct {
    float priority;
    Row row;
} Level;

struct FinchLayoutSolverConstraint {
    uint32_t marker, other;  /* other: the second error of an optional equality */
    double mu;               /* the marker's coefficient in the constraint as written */
    double constant;
    float priority;
    int relation;
    bool required;
    FinchLayoutSolverConstraint *next, *prev;
};

struct FinchLayoutSolver {
    uint8_t *types;     /* by symbol */
    Row **rows;         /* by symbol: its row when basic */
    uint32_t *basics;   /* the basic symbols */
    uint32_t *basicIndex;  /* by symbol: its index in basics */
    uint32_t nbasics, nsyms, capsyms;
    Level *levels;
    int nlevels;
    Row *artificial;    /* while adding with an artificial variable */
    uint32_t *infeasible;
    int ninfeasible, capinfeasible;
    FinchLayoutSolverConstraint *constraints;
    int nconstraints;
};

#pragma mark - Rows

static bool
near_zero(double v)
{
    return fabs(v) < EPS;
}

static Row *
row_new(double k)
{
    Row *r = calloc(1, sizeof(Row));
    r->k = k;
    return r;
}

static void
row_free(Row *r)
{
    if (r) {
        free(r->t);
        free(r);
    }
}

static Row *
row_copy(const Row *r)
{
    Row *c = row_new(r->k);
    if (r->n) {
        c->t = malloc(sizeof(Term) * r->n);
        memcpy(c->t, r->t, sizeof(Term) * r->n);
        c->n = c->cap = r->n;
    }
    return c;
}

static int
row_find(const Row *r, uint32_t sym)
{
    int lo = 0, hi = r->n - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (r->t[mid].sym == sym)
            return mid;
        if (r->t[mid].sym < sym)
            lo = mid + 1;
        else
            hi = mid - 1;
    }
    return -(lo + 1);
}

static double
row_coeff(const Row *r, uint32_t sym)
{
    int i = row_find(r, sym);
    return i >= 0 ? r->t[i].c : 0;
}

static void
row_remove(Row *r, uint32_t sym)
{
    int i = row_find(r, sym);
    if (i < 0)
        return;
    memmove(&r->t[i], &r->t[i + 1], sizeof(Term) * (r->n - i - 1));
    r->n--;
}

static void
row_add_sym(Row *r, uint32_t sym, double c)
{
    int i = row_find(r, sym);
    if (i >= 0) {
        r->t[i].c += c;
        if (near_zero(r->t[i].c))
            row_remove(r, sym);
        return;
    }
    if (near_zero(c))
        return;
    i = -i - 1;
    if (r->n == r->cap) {
        r->cap = r->cap ? r->cap * 2 : 8;
        r->t = realloc(r->t, sizeof(Term) * r->cap);
    }
    memmove(&r->t[i + 1], &r->t[i], sizeof(Term) * (r->n - i));
    r->t[i].sym = sym;
    r->t[i].c = c;
    r->n++;
}

static void
row_add_row(Row *r, const Row *other, double c)
{
    r->k += other->k * c;
    for (int i = 0; i < other->n; i++)
        row_add_sym(r, other->t[i].sym, other->t[i].c * c);
}

static void
row_negate(Row *r)
{
    r->k = -r->k;
    for (int i = 0; i < r->n; i++)
        r->t[i].c = -r->t[i].c;
}

/* 0 = k + sum(c s) becomes sym = ...: take sym out and divide by -its coefficient. */
static void
row_solve_for(Row *r, uint32_t sym)
{
    double c = -1.0 / row_coeff(r, sym);
    row_remove(r, sym);
    r->k *= c;
    for (int i = 0; i < r->n; i++)
        r->t[i].c *= c;
}

/* lhs = ... + a rhs + ... becomes rhs = ... */
static void
row_solve_for_ex(Row *r, uint32_t lhs, uint32_t rhs)
{
    row_add_sym(r, lhs, -1.0);
    row_solve_for(r, rhs);
}

/* Replace sym in r by the expression it equals. */
static void
row_substitute(Row *r, uint32_t sym, const Row *by)
{
    int i = row_find(r, sym);
    if (i < 0)
        return;
    double c = r->t[i].c;
    row_remove(r, sym);
    row_add_row(r, by, c);
}

#pragma mark - Symbols and the basis

static uint32_t
new_symbol(FinchLayoutSolver *s, uint8_t type)
{
    if (s->nsyms + 1 >= s->capsyms) {
        uint32_t cap = s->capsyms ? s->capsyms * 2 : 64;
        s->types = realloc(s->types, cap);
        s->rows = realloc(s->rows, sizeof(Row *) * cap);
        s->basics = realloc(s->basics, sizeof(uint32_t) * cap);
        s->basicIndex = realloc(s->basicIndex, sizeof(uint32_t) * cap);
        memset(s->types + s->capsyms, 0, cap - s->capsyms);
        memset(s->rows + s->capsyms, 0, sizeof(Row *) * (cap - s->capsyms));
        s->capsyms = cap;
    }
    uint32_t sym = ++s->nsyms;  /* 0 is NONE */
    s->types[sym] = type;
    s->rows[sym] = NULL;
    return sym;
}

static bool
is_restricted(FinchLayoutSolver *s, uint32_t sym)
{
    return s->types[sym] != SYM_EXTERNAL;
}

static void
set_basic(FinchLayoutSolver *s, uint32_t sym, Row *r)
{
    s->rows[sym] = r;
    s->basicIndex[sym] = s->nbasics;
    s->basics[s->nbasics++] = sym;
}

static Row *
take_basic(FinchLayoutSolver *s, uint32_t sym)
{
    Row *r = s->rows[sym];
    if (!r)
        return NULL;
    uint32_t i = s->basicIndex[sym], last = s->basics[--s->nbasics];
    s->basics[i] = last;
    s->basicIndex[last] = i;
    s->rows[sym] = NULL;
    return r;
}

static void
note_infeasible(FinchLayoutSolver *s, uint32_t sym)
{
    if (s->ninfeasible == s->capinfeasible) {
        s->capinfeasible = s->capinfeasible ? s->capinfeasible * 2 : 16;
        s->infeasible = realloc(s->infeasible, sizeof(uint32_t) * s->capinfeasible);
    }
    s->infeasible[s->ninfeasible++] = sym;
}

/* sym leaves the parameters: every row (and the objective) gets its expression instead. */
static void
substitute(FinchLayoutSolver *s, uint32_t sym, const Row *by)
{
    for (uint32_t i = 0; i < s->nbasics; i++) {
        uint32_t b = s->basics[i];
        Row *r = s->rows[b];
        if (row_find(r, sym) < 0)
            continue;
        row_substitute(r, sym, by);
        if (is_restricted(s, b) && r->k < 0)
            note_infeasible(s, b);
    }
    for (int i = 0; i < s->nlevels; i++)
        row_substitute(&s->levels[i].row, sym, by);
    if (s->artificial)
        row_substitute(s->artificial, sym, by);
}

static void
pivot(FinchLayoutSolver *s, uint32_t entering, uint32_t leaving)
{
    Row *r = take_basic(s, leaving);
    row_solve_for_ex(r, leaving, entering);
    substitute(s, entering, r);
    set_basic(s, entering, r);
}

static Row *
level_for(FinchLayoutSolver *s, float priority)
{
    int i = 0;
    while (i < s->nlevels && s->levels[i].priority > priority)
        i++;
    if (i < s->nlevels && s->levels[i].priority == priority)
        return &s->levels[i].row;
    s->levels = realloc(s->levels, sizeof(Level) * (s->nlevels + 1));
    memmove(&s->levels[i + 1], &s->levels[i], sizeof(Level) * (s->nlevels - i));
    memset(&s->levels[i], 0, sizeof(Level));
    s->levels[i].priority = priority;
    s->nlevels++;
    return &s->levels[i].row;
}

#pragma mark - Optimizing

/* -1, 0 or 1: the sign of a symbol's cost, compared from the highest priority down. */
static int
cost_sign(Row *const *objective, int n, uint32_t sym)
{
    for (int i = 0; i < n; i++) {
        double c = row_coeff(objective[i], sym);
        if (!near_zero(c))
            return c < 0 ? -1 : 1;
    }
    return 0;
}

/* The primal simplex on an objective (rows, highest priority first). */
static bool
optimize(FinchLayoutSolver *s, Row *const *objective, int n)
{
    for (int guard = 0; guard < 100000; guard++) {
        uint32_t entering = NONE;
        for (int l = 0; l < n && entering == NONE; l++) {
            Row *o = objective[l];
            for (int i = 0; i < o->n; i++) {
                uint32_t sym = o->t[i].sym;
                if (s->types[sym] == SYM_DUMMY || o->t[i].c >= -EPS)
                    continue;
                if (cost_sign(objective, n, sym) < 0 && (entering == NONE || sym < entering))
                    entering = sym;
            }
        }
        if (entering == NONE)
            return true;
        uint32_t leaving = NONE;
        double best = DBL_MAX;
        for (uint32_t i = 0; i < s->nbasics; i++) {
            uint32_t b = s->basics[i];
            if (!is_restricted(s, b))
                continue;
            Row *r = s->rows[b];
            double c = row_coeff(r, entering);
            if (c >= -EPS)
                continue;
            double ratio = -r->k / c;
            if (ratio < best - EPS || (ratio < best + EPS && b < leaving)) {
                best = ratio;
                leaving = b;
            }
        }
        if (leaving == NONE)
            return false;  /* unbounded: can't happen with a bounded objective */
        pivot(s, entering, leaving);
    }
    return false;
}

static Row *const *
objective_rows(FinchLayoutSolver *s, Row **buffer)
{
    for (int i = 0; i < s->nlevels; i++)
        buffer[i] = &s->levels[i].row;
    return buffer;
}

static bool
optimize_objective(FinchLayoutSolver *s)
{
    Row *buffer[s->nlevels + 1];
    return optimize(s, objective_rows(s, buffer), s->nlevels);
}

/* Is a's cost / ca lexicographically less than b's / cb? */
static bool
ratio_less(FinchLayoutSolver *s, uint32_t a, double ca, uint32_t b, double cb)
{
    for (int i = 0; i < s->nlevels; i++) {
        double ra = row_coeff(&s->levels[i].row, a) / ca, rb = row_coeff(&s->levels[i].row, b) / cb;
        if (ra < rb - EPS)
            return true;
        if (ra > rb + EPS)
            return false;
    }
    return a < b;
}

/* The dual simplex: rows whose restricted symbol went negative pivot until all are feasible. */
static bool
dual_optimize(FinchLayoutSolver *s)
{
    while (s->ninfeasible) {
        uint32_t leaving = s->infeasible[--s->ninfeasible];
        Row *r = s->rows[leaving];
        if (!r || r->k >= -EPS)
            continue;
        uint32_t entering = NONE;
        double ce = 0;
        for (int i = 0; i < r->n; i++) {
            uint32_t sym = r->t[i].sym;
            double c = r->t[i].c;
            if (c <= EPS || s->types[sym] == SYM_DUMMY)
                continue;
            if (entering == NONE || ratio_less(s, sym, c, entering, ce)) {
                entering = sym;
                ce = c;
            }
        }
        if (entering == NONE) {
            s->ninfeasible = 0;
            return false;
        }
        pivot(s, entering, leaving);
    }
    return true;
}

#pragma mark - Adding and removing

static Row *
create_row(FinchLayoutSolver *s, FinchLayoutSolverConstraint *con, const FinchLayoutSolverVariable *vars,
           const double *coeffs, int count, double constant)
{
    Row *r = row_new(constant);
    for (int i = 0; i < count; i++) {
        if (vars[i] == NONE || vars[i] > s->nsyms)
            continue;
        Row *basic = s->rows[vars[i]];
        if (basic)
            row_add_row(r, basic, coeffs[i]);
        else
            row_add_sym(r, vars[i], coeffs[i]);
    }
    if (con->relation != FinchLayoutSolverEqual) {
        double c = con->relation == FinchLayoutSolverLessOrEqual ? 1.0 : -1.0;
        uint32_t slack = new_symbol(s, SYM_SLACK);
        con->marker = slack;
        con->mu = c;
        row_add_sym(r, slack, c);
        if (!con->required) {
            uint32_t err = new_symbol(s, SYM_ERROR);
            con->other = err;
            row_add_sym(r, err, -c);
            Row *level = level_for(s, con->priority);
            row_add_sym(level, err, 1.0);
        }
    } else if (con->required) {
        uint32_t dummy = new_symbol(s, SYM_DUMMY);
        con->marker = dummy;
        con->mu = 1;
        row_add_sym(r, dummy, 1.0);
    } else {
        uint32_t plus = new_symbol(s, SYM_ERROR), minus = new_symbol(s, SYM_ERROR);
        con->marker = plus;
        con->other = minus;
        con->mu = -1;
        row_add_sym(r, plus, -1.0);
        row_add_sym(r, minus, 1.0);
        Row *level = level_for(s, con->priority);
        row_add_sym(level, plus, 1.0);
        row_add_sym(level, minus, 1.0);
    }
    if (r->k < 0)
        row_negate(r);
    return r;
}

static uint32_t
choose_subject(FinchLayoutSolver *s, Row *r, FinchLayoutSolverConstraint *con)
{
    for (int i = 0; i < r->n; i++)
        if (s->types[r->t[i].sym] == SYM_EXTERNAL)
            return r->t[i].sym;
    uint32_t m[2] = {con->marker, con->other};
    for (int i = 0; i < 2; i++) {
        uint8_t t = m[i] ? s->types[m[i]] : 0;
        if ((t == SYM_SLACK || t == SYM_ERROR) && row_coeff(r, m[i]) < 0)
            return m[i];
    }
    return NONE;
}

static bool
all_dummies(FinchLayoutSolver *s, Row *r)
{
    for (int i = 0; i < r->n; i++)
        if (s->types[r->t[i].sym] != SYM_DUMMY)
            return false;
    return true;
}

static uint32_t
any_pivotable(FinchLayoutSolver *s, Row *r)
{
    for (int i = 0; i < r->n; i++) {
        uint8_t t = s->types[r->t[i].sym];
        if (t == SYM_SLACK || t == SYM_ERROR)
            return r->t[i].sym;
    }
    return NONE;
}

static void
remove_symbol_everywhere(FinchLayoutSolver *s, uint32_t sym)
{
    for (uint32_t i = 0; i < s->nbasics; i++)
        row_remove(s->rows[s->basics[i]], sym);
    for (int i = 0; i < s->nlevels; i++)
        row_remove(&s->levels[i].row, sym);
}

/* No symbol can take the row as its own: minimize an artificial variable equal to it, as the paper does. */
static bool
add_with_artificial(FinchLayoutSolver *s, Row *r)
{
    uint32_t art = new_symbol(s, SYM_SLACK);
    set_basic(s, art, row_copy(r));
    s->artificial = row_copy(r);
    Row *objective[1] = {s->artificial};
    optimize(s, objective, 1);
    bool ok = near_zero(s->artificial->k);
    row_free(s->artificial);
    s->artificial = NULL;
    Row *ar = take_basic(s, art);
    if (ar) {
        if (ar->n == 0) {
            row_free(ar);
            row_free(r);
            return ok;
        }
        uint32_t entering = any_pivotable(s, ar);
        if (entering == NONE) {
            row_free(ar);
            row_free(r);
            return false;
        }
        row_solve_for_ex(ar, art, entering);
        substitute(s, entering, ar);
        set_basic(s, entering, ar);
    }
    remove_symbol_everywhere(s, art);
    row_free(r);
    return ok;
}

/* A copy of the tableau, to put back if a required constraint doesn't fit. */
typedef struct {
    Row **rows;
    uint32_t *basics;
    uint32_t nbasics;
    Level *levels;
    int nlevels;
} Saved;

static void
save(FinchLayoutSolver *s, Saved *v)
{
    v->nbasics = s->nbasics;
    v->basics = malloc(sizeof(uint32_t) * (s->nbasics + 1));
    v->rows = malloc(sizeof(Row *) * (s->nbasics + 1));
    for (uint32_t i = 0; i < s->nbasics; i++) {
        v->basics[i] = s->basics[i];
        v->rows[i] = row_copy(s->rows[s->basics[i]]);
    }
    v->nlevels = s->nlevels;
    v->levels = malloc(sizeof(Level) * (s->nlevels + 1));
    for (int i = 0; i < s->nlevels; i++) {
        v->levels[i].priority = s->levels[i].priority;
        Row *c = row_copy(&s->levels[i].row);
        v->levels[i].row = *c;
        free(c);
    }
}

static void
discard(Saved *v, bool rowsToo)
{
    if (rowsToo) {
        for (uint32_t i = 0; i < v->nbasics; i++)
            row_free(v->rows[i]);
        for (int i = 0; i < v->nlevels; i++)
            free(v->levels[i].row.t);
    }
    free(v->rows);
    free(v->basics);
    free(v->levels);
}

static void
restore(FinchLayoutSolver *s, Saved *v)
{
    while (s->nbasics)
        row_free(take_basic(s, s->basics[0]));
    for (uint32_t i = 0; i < v->nbasics; i++)
        set_basic(s, v->basics[i], v->rows[i]);
    for (int i = 0; i < s->nlevels; i++)
        free(s->levels[i].row.t);
    free(s->levels);
    s->levels = v->levels;
    s->nlevels = v->nlevels;
    v->levels = NULL;
    s->ninfeasible = 0;
    discard(v, false);
}

FinchLayoutSolverConstraint *
FinchLayoutSolverAdd(FinchLayoutSolver *s, const FinchLayoutSolverVariable *vars, const double *coeffs, int count,
                     double constant, int relation, float priority)
{
    FinchLayoutSolverConstraint *con = calloc(1, sizeof(*con));
    con->relation = relation;
    con->priority = priority;
    con->required = priority >= 1000;
    con->constant = constant;
    Saved saved;
    bool saving = con->required;
    if (saving)
        save(s, &saved);
    Row *r = create_row(s, con, vars, coeffs, count, constant);
    uint32_t subject = choose_subject(s, r, con);
    bool ok = true;
    if (subject == NONE && all_dummies(s, r)) {
        if (!near_zero(r->k)) {
            row_free(r);
            ok = false;
        } else {
            subject = con->marker;
        }
    }
    if (ok && subject == NONE) {
        ok = add_with_artificial(s, r);
    } else if (ok) {
        row_solve_for(r, subject);
        substitute(s, subject, r);
        set_basic(s, subject, r);
    }
    if (ok)
        ok = optimize_objective(s) || !con->required;
    if (!ok) {
        if (saving)
            restore(s, &saved);
        free(con);
        return NULL;
    }
    if (saving)
        discard(&saved, true);
    con->next = s->constraints;
    if (s->constraints)
        s->constraints->prev = con;
    s->constraints = con;
    s->nconstraints++;
    return con;
}

/* The row the marker should pivot into, to take the constraint out (the paper's rules). */
static uint32_t
marker_leaving_row(FinchLayoutSolver *s, uint32_t marker)
{
    double r1 = DBL_MAX, r2 = DBL_MAX;
    uint32_t first = NONE, second = NONE, third = NONE;
    for (uint32_t i = 0; i < s->nbasics; i++) {
        uint32_t b = s->basics[i];
        Row *r = s->rows[b];
        double c = row_coeff(r, marker);
        if (c == 0)
            continue;
        if (!is_restricted(s, b)) {
            if (third == NONE || b < third)
                third = b;
        } else if (c < 0) {
            double ratio = -r->k / c;
            if (ratio < r1 || (ratio == r1 && b < first)) {
                r1 = ratio;
                first = b;
            }
        } else {
            double ratio = r->k / c;
            if (ratio < r2 || (ratio == r2 && b < second)) {
                r2 = ratio;
                second = b;
            }
        }
    }
    return first != NONE ? first : second != NONE ? second : third;
}

static void
remove_error_effect(FinchLayoutSolver *s, FinchLayoutSolverConstraint *con, uint32_t err)
{
    if (!err || s->types[err] != SYM_ERROR)
        return;
    Row *level = level_for(s, con->priority);
    Row *basic = s->rows[err];
    if (basic)
        row_add_row(level, basic, -1.0);
    else
        row_add_sym(level, err, -1.0);
}

void
FinchLayoutSolverRemove(FinchLayoutSolver *s, FinchLayoutSolverConstraint *con)
{
    if (!con)
        return;
    remove_error_effect(s, con, con->marker);
    remove_error_effect(s, con, con->other);
    Row *r = take_basic(s, con->marker);
    if (r) {
        row_free(r);
    } else {
        uint32_t leaving = marker_leaving_row(s, con->marker);
        if (leaving != NONE) {
            Row *lr = take_basic(s, leaving);
            row_solve_for_ex(lr, leaving, con->marker);
            substitute(s, con->marker, lr);
            row_free(lr);
        }
    }
    /* the second error, if basic, is only that constraint's */
    if (con->other && s->rows[con->other])
        row_free(take_basic(s, con->other));
    remove_symbol_everywhere(s, con->marker);
    if (con->other)
        remove_symbol_everywhere(s, con->other);
    optimize_objective(s);
    if (con->prev)
        con->prev->next = con->next;
    else
        s->constraints = con->next;
    if (con->next)
        con->next->prev = con->prev;
    s->nconstraints--;
    free(con);
}

/*
 * The constraint as written is E + c + mu * marker = 0, so with the
 * constant c + delta the old marker equals the new one plus delta / mu:
 * substituting that shifts the constants of the rows the marker is in.
 */
bool
FinchLayoutSolverSetConstant(FinchLayoutSolver *s, FinchLayoutSolverConstraint *con, double constant)
{
    double delta = constant - con->constant;
    if (delta == 0)
        return true;
    con->constant = constant;
    double shift = delta / con->mu;
    uint32_t m = con->marker;
    Row *basic = s->rows[m];
    if (basic) {
        basic->k -= shift;
        if (s->types[m] == SYM_DUMMY)
            return near_zero(basic->k);
        if (basic->k < 0)
            note_infeasible(s, m);
    } else {
        for (uint32_t i = 0; i < s->nbasics; i++) {
            uint32_t b = s->basics[i];
            Row *r = s->rows[b];
            double c = row_coeff(r, m);
            if (c == 0)
                continue;
            r->k += c * shift;
            if (is_restricted(s, b) && r->k < 0)
                note_infeasible(s, b);
        }
    }
    return dual_optimize(s);
}

#pragma mark - Queries

double
FinchLayoutSolverValue(FinchLayoutSolver *s, FinchLayoutSolverVariable v)
{
    if (v == NONE || v > s->nsyms)
        return 0;
    Row *r = s->rows[v];
    return r ? r->k : 0;
}

static bool
zero_cost(FinchLayoutSolver *s, uint32_t sym)
{
    for (int i = 0; i < s->nlevels; i++)
        if (!near_zero(row_coeff(&s->levels[i].row, sym)))
            return false;
    return true;
}

/* Can a parametric symbol move in a direction without a restricted basic symbol going negative? */
static bool
movable(FinchLayoutSolver *s, uint32_t sym, double dir)
{
    if (s->types[sym] == SYM_DUMMY || (is_restricted(s, sym) && dir < 0))
        return false;
    for (uint32_t i = 0; i < s->nbasics; i++) {
        uint32_t b = s->basics[i];
        if (!is_restricted(s, b))
            continue;
        double c = row_coeff(s->rows[b], sym) * dir;
        if (c < -EPS && s->rows[b]->k / -c < EPS)
            return false;
    }
    return true;
}

bool
FinchLayoutSolverIsAmbiguous(FinchLayoutSolver *s, FinchLayoutSolverVariable v)
{
    if (v == NONE || v > s->nsyms)
        return false;
    Row *r = s->rows[v];
    if (!r)
        return zero_cost(s, v) && (movable(s, v, 1) || movable(s, v, -1));
    for (int i = 0; i < r->n; i++) {
        uint32_t sym = r->t[i].sym;
        if (zero_cost(s, sym) && (movable(s, sym, 1) || movable(s, sym, -1)))
            return true;
    }
    return false;
}

int
FinchLayoutSolverConstraintCount(FinchLayoutSolver *s)
{
    return s->nconstraints;
}

FinchLayoutSolver *
FinchLayoutSolverCreate(void)
{
    return calloc(1, sizeof(FinchLayoutSolver));
}

FinchLayoutSolverVariable
FinchLayoutSolverNewVariable(FinchLayoutSolver *s)
{
    return new_symbol(s, SYM_EXTERNAL);
}

void
FinchLayoutSolverDestroy(FinchLayoutSolver *s)
{
    if (!s)
        return;
    while (s->nbasics)
        row_free(take_basic(s, s->basics[0]));
    for (int i = 0; i < s->nlevels; i++)
        free(s->levels[i].row.t);
    free(s->levels);
    while (s->constraints) {
        FinchLayoutSolverConstraint *n = s->constraints->next;
        free(s->constraints);
        s->constraints = n;
    }
    free(s->types);
    free(s->rows);
    free(s->basics);
    free(s->basicIndex);
    free(s->infeasible);
    free(s);
}
