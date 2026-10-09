/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's constraint solver: the Cassowary incremental simplex (Badros,
 * Borning and Stuckey, "The Cassowary Linear Arithmetic Constraint Solving
 * Algorithm", 2001), written for Finch from the paper.
 *
 * Constraints are linear: sum(coefficient * variable) + constant {<=, ==, >=} 0,
 * each with a priority. Priority 1000 is required; lower priorities are
 * satisfied as well as they can be, a higher priority strictly before any
 * number of lower ones (the objective is lexicographic, one row per
 * priority), and errors at one priority are weighed equally (so three
 * conflicting equalities settle on their median, as Apple's engine does).
 *
 * Constraints are added and removed incrementally; changing a constraint's
 * constant (an edit variable is an optional equality whose constant moves)
 * re-solves with the dual simplex from the previous solution.
 */
#ifndef FINCH_LAYOUT_SOLVER_H
#define FINCH_LAYOUT_SOLVER_H

#include <stdint.h>
#include <stdbool.h>

#define FLS_EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FinchLayoutSolver FinchLayoutSolver;
typedef struct FinchLayoutSolverConstraint FinchLayoutSolverConstraint;
typedef uint32_t FinchLayoutSolverVariable;

enum { FinchLayoutSolverLessOrEqual = -1, FinchLayoutSolverEqual = 0, FinchLayoutSolverGreaterOrEqual = 1 };

FLS_EXPORT FinchLayoutSolver *FinchLayoutSolverCreate(void);
FLS_EXPORT void FinchLayoutSolverDestroy(FinchLayoutSolver *solver);
FLS_EXPORT FinchLayoutSolverVariable FinchLayoutSolverNewVariable(FinchLayoutSolver *solver);
FLS_EXPORT double FinchLayoutSolverValue(FinchLayoutSolver *solver, FinchLayoutSolverVariable variable);

/*
 * Add sum(coefficients[i] * variables[i]) + constant RELATION 0 at a
 * priority (1000: required). Returns NULL when a required constraint
 * can't be satisfied with the others; the solver is then as it was.
 */
FLS_EXPORT FinchLayoutSolverConstraint *FinchLayoutSolverAdd(FinchLayoutSolver *solver,
                                                             const FinchLayoutSolverVariable *variables,
                                                             const double *coefficients, int count, double constant,
                                                             int relation, float priority);
FLS_EXPORT void FinchLayoutSolverRemove(FinchLayoutSolver *solver, FinchLayoutSolverConstraint *constraint);
/* Change a constraint's constant, re-solving incrementally. Returns false if a required one no longer fits. */
FLS_EXPORT bool FinchLayoutSolverSetConstant(FinchLayoutSolver *solver, FinchLayoutSolverConstraint *constraint,
                                             double constant);
/* Whether the variable could take another value without making the solution worse. */
FLS_EXPORT bool FinchLayoutSolverIsAmbiguous(FinchLayoutSolver *solver, FinchLayoutSolverVariable variable);
FLS_EXPORT int FinchLayoutSolverConstraintCount(FinchLayoutSolver *solver);

#ifdef __cplusplus
}
#endif

#endif
