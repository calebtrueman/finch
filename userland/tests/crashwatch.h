/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* crashwatch: report a spawned child's crash with a backtrace (crashwatch.c). */
#ifndef CRASHWATCH_H
#define CRASHWATCH_H

#include <spawn.h>

/* Spawn with this attribute to have the child's crash reported on standard output. */
void crashwatch_spawnattr(posix_spawnattr_t *attr);
/* The child it was spawned as, for reading its memory when the exception's token can't. */
void crashwatch_child(pid_t pid);

#endif
