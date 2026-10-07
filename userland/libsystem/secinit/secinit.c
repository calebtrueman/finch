/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_secinit: App Sandbox initialization, run by libSystem's
 * initializer in every process (_libsecinit_initializer, Libsystem-1356
 * init.c), plus helpers for sandboxed apps' data containers. Finch has no App
 * Sandbox yet: initialization does nothing, and container operations fail
 * with EPERM.
 */

#include <errno.h>

void _libsecinit_initializer(void);
int libsecinit_delete_all_data_container_content_for_current_user(void);
int libsecinit_fileoperation_save(void);
int libsecinit_fileoperation_set_attributes(void);
int libsecinit_fileoperation_symlink(void);

void _libsecinit_initializer(void) {}
int libsecinit_delete_all_data_container_content_for_current_user(void) { return EPERM; }
int libsecinit_fileoperation_save(void) { return EPERM; }
int libsecinit_fileoperation_set_attributes(void) { return EPERM; }
int libsecinit_fileoperation_symlink(void) { return EPERM; }
