/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <energytrace.h>: Apple's energy-tracing points (libenergytrace, closed).
 * Finch records no energy trace, so the calls compile to nothing; the
 * constants IOKit's power management passes are kept so its code is
 * unchanged.
 */
#ifndef FINCH_ENERGYTRACE_H
#define FINCH_ENERGYTRACE_H

#include <stdint.h>

enum {
    kEnTrCompSysPower = 2,
    kEnTrActSPPMAssertion = 1,
    kEnTrModSPRetain = 1,
    kEnTrModSPRelease = 2,
    kEnTrQualNone = 0,
    kEnTrQualSPKeepSystemAwake = 1,
    kEnTrValNone = 0,
};

#define entr_act_begin(component, opcode, id, quality, value)   ((void)(id), (void)(quality))
#define entr_act_modify(component, opcode, id, quality, value)  ((void)(id), (void)(quality))
#define entr_act_end(component, opcode, id, quality, value)     ((void)(id), (void)(quality))

#endif
