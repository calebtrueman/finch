/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into libmalloc (tools/build-oss.sh).
 *
 * OS_VARIANT_RESOLVED / OS_VARIANT_NOTRESOLVED come from Apple's internal
 * headers. On iOS-family platforms libmalloc is built as separate "resolved"
 * and "not resolved" variants that are linked together. On macOS a single
 * build provides both halves, so both are 1.
 */
#ifndef OS_VARIANT_RESOLVED
#define OS_VARIANT_RESOLVED 1
#endif
#ifndef OS_VARIANT_NOTRESOLVED
#define OS_VARIANT_NOTRESOLVED 1
#endif
