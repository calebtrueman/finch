/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_eligibility: Apple's per-feature eligibility answers (region,
 * device and account checks for features such as Apple Intelligence),
 * computed by a closed daemon. Finch has no eligibility service: every query
 * fails with ENOTSUP and writes nothing, which Apple's callers treat as "not
 * eligible". os_eligibility_get_domain_answer's five arguments (domain and
 * four out-parameters) were read from macOS 26.4's library; the rest aren't
 * imported by anything in the OS.
 */

#include <errno.h>
#include <stdint.h>

#define NOT_SUPPORTED(name) int name(void); int name(void) { return ENOTSUP; }

int os_eligibility_get_domain_answer(uint64_t domain, void *answer, void *source, void *status, void *context);

int
os_eligibility_get_domain_answer(uint64_t domain, void *answer, void *source, void *status, void *context)
{
	(void)domain; (void)answer; (void)source; (void)status; (void)context;
	return ENOTSUP;
}

/* Lookups that return a value: none (0 / NULL). */
uint64_t os_eligibility_domain_for_name(const char *name);
const char *os_eligibility_get_domain_notification_name(uint64_t domain);
const char *os_eligibility_get_error_description(int error);
void *os_eligibility_get_all_domain_answers(void);
void *os_eligibility_get_internal_state(void);
void *os_eligibility_get_state_dump(void);
void *load_eligibility_answers(void);

uint64_t os_eligibility_domain_for_name(const char *name) { (void)name; return 0; }
const char *os_eligibility_get_domain_notification_name(uint64_t domain) { (void)domain; return 0; }
const char *os_eligibility_get_error_description(int error) { (void)error; return "Eligibility isn't supported on Finch"; }
void *os_eligibility_get_all_domain_answers(void) { return 0; }
void *os_eligibility_get_internal_state(void) { return 0; }
void *os_eligibility_get_state_dump(void) { return 0; }
void *load_eligibility_answers(void) { return 0; }

/* Operations: not supported. */
NOT_SUPPORTED(os_eligibility_dump_sysdiagnose_data_to_dir)
NOT_SUPPORTED(os_eligibility_fetch_newest_policies)
NOT_SUPPORTED(os_eligibility_force_domain_answer)
NOT_SUPPORTED(os_eligibility_force_domain_set_answers)
NOT_SUPPORTED(os_eligibility_precise_locations)
NOT_SUPPORTED(os_eligibility_reset_all_domains)
NOT_SUPPORTED(os_eligibility_reset_domain)
NOT_SUPPORTED(os_eligibility_set_input)
NOT_SUPPORTED(os_eligibility_set_test_mode)
