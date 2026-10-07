/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_symptoms: network symptom reporting to Apple's closed
 * symptomsd. Finch has no symptoms daemon, so symptom_framework_init()
 * returns NULL, and every call on a NULL framework or symptom fails, the
 * path Apple's own library takes when it can't reach symptomsd (argument
 * and NULL behavior read from macOS 26.4's library).
 */

#include <stdbool.h>
#include <stdint.h>

typedef void *symptom_framework_t;
typedef void *symptom_t;

symptom_framework_t symptom_framework_init(uint32_t framework_id, const char *name);
int symptom_framework_set_version(symptom_framework_t framework, ...);
symptom_t symptom_new(symptom_framework_t framework, uint32_t code);
int symptom_set_qualifier(symptom_t symptom, uint64_t value, uint32_t index);
int symptom_set_additional_qualifier(symptom_t symptom, uint32_t index, uint64_t length, const void *data);
int symptom_send(symptom_t symptom);
int symptom_send_immediate(symptom_t symptom);
int _symptoms_daemon_fallback_initial_disposition(void);
int _symptoms_daemon_fallback_subseq_disposition(void);
bool _symptoms_is_daemon_fallback_blacklisted(void);

symptom_framework_t symptom_framework_init(uint32_t id, const char *name) { (void)id; (void)name; return 0; }
int symptom_framework_set_version(symptom_framework_t f, ...) { (void)f; return -1; }
symptom_t symptom_new(symptom_framework_t f, uint32_t code) { (void)f; (void)code; return 0; }
int symptom_set_qualifier(symptom_t s, uint64_t v, uint32_t i) { (void)s; (void)v; (void)i; return -1; }
int symptom_set_additional_qualifier(symptom_t s, uint32_t i, uint64_t len, const void *d) { (void)s; (void)i; (void)len; (void)d; return -1; }
int symptom_send(symptom_t s) { (void)s; return -1; }
int symptom_send_immediate(symptom_t s) { (void)s; return -1; }
int _symptoms_daemon_fallback_initial_disposition(void) { return 0; }
int _symptoms_daemon_fallback_subseq_disposition(void) { return 0; }
bool _symptoms_is_daemon_fallback_blacklisted(void) { return false; }
