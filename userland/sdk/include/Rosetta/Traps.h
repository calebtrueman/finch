/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <Rosetta/Traps.h>: libRosetta's trap interface for the x86 translator.
 * libobjc includes it alongside <Rosetta/Rosetta.h>; it uses only
 * objc_thread_get_rip (Finch's libRosetta returns KERN_FAILURE).
 */
#ifndef FINCH_ROSETTA_TRAPS_H
#define FINCH_ROSETTA_TRAPS_H
#include <mach/mach_types.h>
#include <stdint.h>
#include <sys/cdefs.h>
__BEGIN_DECLS
__attribute__((weak_import)) kern_return_t objc_thread_get_rip(thread_t thread, uint64_t *rip);
__END_DECLS
#endif
