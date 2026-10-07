/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The cache builder only uses sandbox_check() with SANDBOX_FILTER_PATH, which
 * Finch's <sandbox.h> overlay (userland/sdk/include) declares with verified
 * values.
 */
#include <sandbox.h>
