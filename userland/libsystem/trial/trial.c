/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_trial: Apple's Trial experiment factors (server-assigned A/B
 * settings). Finch runs no experiments: no factor exists, booleans read
 * false and integers 0. (Nothing in the OS imports these.) The data exports keep Apple's values (from macOS
 * 26.4's library).
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

const size_t MAX_FACTOR_STRING_LENGTH = 2048;
const double libsystem_trialVersionNumber = 474.2;
const unsigned char libsystem_trialVersionString[] = "@(#)PROGRAM:libsystem_trial  PROJECT:trial-474.2.18\n";

bool _os_trial_factor_has_impl(const char *ns, const char *factor);
bool _os_trial_factor_get_bool_impl(const char *ns, const char *factor);
long _os_trial_factor_get_long_impl(const char *ns, const char *factor);

bool _os_trial_factor_has_impl(const char *ns, const char *f) { (void)ns; (void)f; return false; }
bool _os_trial_factor_get_bool_impl(const char *ns, const char *f) { (void)ns; (void)f; return false; }
long _os_trial_factor_get_long_impl(const char *ns, const char *f) { (void)ns; (void)f; return 0; }
