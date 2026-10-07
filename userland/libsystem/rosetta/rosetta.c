/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libRosetta: queries about x86_64 translation, linked by libobjc (and so
 * loaded in every process), CoreSymbolication and the crash reporter. Finch
 * has no x86_64 translation yet: nothing is translated, translation is
 * unavailable, and thread/AOT queries fail. The data exports keep Apple's
 * values (from macOS 26.4's library).
 */

#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

const char *__crashreporter_info__ = 0;
const uint32_t kThreadContextExceptionPairOffset = 0x210;

/* libobjc's two calls. */
bool rosetta_is_current_process_translated(void);
kern_return_t objc_thread_get_rip(thread_t thread, uint64_t *rip);
bool rosetta_is_current_process_translated(void) { return false; }
kern_return_t objc_thread_get_rip(thread_t thread, uint64_t *rip) { (void)thread; (void)rip; return KERN_FAILURE; }

/* Everything else: not translated / not available / failure (0, NULL, false, or KERN_FAILURE). */
long aot_address_in_shared_cache(void);
long aot_address_in_shared_cache(void) { return 0; }
long aot_get_shared_cache_fragment_type(void);
long aot_get_shared_cache_fragment_type(void) { return 0; }
long aot_get_x86_address(void);
long aot_get_x86_address(void) { return 0; }
long aot_get_x86_address_shared_cache(void);
long aot_get_x86_address_shared_cache(void) { return 0; }
long aot_init_shared_cache_info(void);
long aot_init_shared_cache_info(void) { return 0; }
long aot_symbolication_session_create(void);
long aot_symbolication_session_create(void) { return 0; }
long aot_symbolication_session_destroy(void);
long aot_symbolication_session_destroy(void) { return 0; }
long oah_get_preferred_architecture_from_architectures(void);
long oah_get_preferred_architecture_from_architectures(void) { return 0; }
kern_return_t oah_get_rflags(void);
kern_return_t oah_get_rflags(void) { return KERN_FAILURE; }
long oah_get_runtime_location(void);
long oah_get_runtime_location(void) { return 0; }
long oah_get_runtime_version(void);
long oah_get_runtime_version(void) { return 0; }
kern_return_t oah_get_x86_thread_state(void);
kern_return_t oah_get_x86_thread_state(void) { return KERN_FAILURE; }
kern_return_t oah_invalidate_translation(void);
kern_return_t oah_invalidate_translation(void) { return KERN_FAILURE; }
long oah_is_current_process_translated(void);
long oah_is_current_process_translated(void) { return 0; }
long oah_is_process_translated(void);
long oah_is_process_translated(void) { return 0; }
long oah_is_translation_available(void);
long oah_is_translation_available(void) { return 0; }
kern_return_t oah_thread_create_running(void);
kern_return_t oah_thread_create_running(void) { return KERN_FAILURE; }
kern_return_t oah_translate_binaries(void);
kern_return_t oah_translate_binaries(void) { return KERN_FAILURE; }
long rosetta_convert_to_rosetta_absolute_time(void);
long rosetta_convert_to_rosetta_absolute_time(void) { return 0; }
long rosetta_convert_to_system_absolute_time(void);
long rosetta_convert_to_system_absolute_time(void) { return 0; }
long rosetta_create_exit_payload_string(void);
long rosetta_create_exit_payload_string(void) { return 0; }
long rosetta_get_expected_version(void);
long rosetta_get_expected_version(void) { return 0; }
long rosetta_get_preferred_architecture_from_architectures(void);
long rosetta_get_preferred_architecture_from_architectures(void) { return 0; }
kern_return_t rosetta_get_rflags(void);
kern_return_t rosetta_get_rflags(void) { return KERN_FAILURE; }
long rosetta_get_runtime_location(void);
long rosetta_get_runtime_location(void) { return 0; }
long rosetta_get_runtime_version(void);
long rosetta_get_runtime_version(void) { return 0; }
kern_return_t rosetta_get_x86_thread_state(void);
kern_return_t rosetta_get_x86_thread_state(void) { return KERN_FAILURE; }
long rosetta_has_been_previously_installed(void);
long rosetta_has_been_previously_installed(void) { return 0; }
long rosetta_has_been_previously_installed_on_volume(void);
long rosetta_has_been_previously_installed_on_volume(void) { return 0; }
long rosetta_has_platform_support(void);
long rosetta_has_platform_support(void) { return 0; }
kern_return_t rosetta_invalidate_translation(void);
kern_return_t rosetta_invalidate_translation(void) { return KERN_FAILURE; }
long rosetta_is_process_translated(void);
long rosetta_is_process_translated(void) { return 0; }
long rosetta_is_translation_available(void);
long rosetta_is_translation_available(void) { return 0; }
long rosetta_is_translation_available_on_volume(void);
long rosetta_is_translation_available_on_volume(void) { return 0; }
kern_return_t rosetta_thread_create_running(void);
kern_return_t rosetta_thread_create_running(void) { return KERN_FAILURE; }
kern_return_t rosetta_thread_get_rip(void);
kern_return_t rosetta_thread_get_rip(void) { return KERN_FAILURE; }
kern_return_t rosetta_thread_get_state(void);
kern_return_t rosetta_thread_get_state(void) { return KERN_FAILURE; }
kern_return_t rosetta_translate_binaries(void);
kern_return_t rosetta_translate_binaries(void) { return KERN_FAILURE; }
