/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <Rosetta/Rosetta.h>: the libRosetta query libobjc makes (Finch's libRosetta,
 * userland/libsystem/rosetta, answers "not translated").
 */
#ifndef FINCH_ROSETTA_ROSETTA_H
#define FINCH_ROSETTA_ROSETTA_H
#include <stdbool.h>
#include <sys/cdefs.h>
__BEGIN_DECLS
__attribute__((weak_import)) bool rosetta_is_current_process_translated(void);
__END_DECLS
#endif
