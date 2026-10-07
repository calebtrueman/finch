/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_sanitizers: the ASan ABI entry points that code built with
 * Apple's stable AddressSanitizer ABI calls, plus libSystem's initializer
 * hook (_sanitizers_init, Libsystem-1356 init.c) and crash-report helpers.
 * Finch ships no sanitizer runtime: checks and poisoning do nothing, reports
 * are empty, and the memory functions do what they're named for, so
 * instrumented code runs uninstrumented.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Data: 24 bytes, zero (from macOS 26.4's library). */
uint64_t sanitizers_report_globals[3];

void _sanitizers_init(const char *envp[], const char *apple[]);
void _sanitizers_init(const char *envp[], const char *apple[]) { (void)envp; (void)apple; }

void *__asan_abi_memcpy(void *dst, const void *src, size_t n);
void *__asan_abi_memmove(void *dst, const void *src, size_t n);
void *__asan_abi_memset(void *dst, int c, size_t n);
void *__asan_abi_memcpy(void *dst, const void *src, size_t n) { return memcpy(dst, src, n); }
void *__asan_abi_memmove(void *dst, const void *src, size_t n) { return memmove(dst, src, n); }
void *__asan_abi_memset(void *dst, int c, size_t n) { return memset(dst, c, n); }

/* Everything else: no sanitizer runtime, so nothing to check, poison or report (0 / NULL / false). */
long __asan_abi_addr_is_in_fake_stack(void);
long __asan_abi_addr_is_in_fake_stack(void) { return 0; }
long __asan_abi_address_is_poisoned(void);
long __asan_abi_address_is_poisoned(void) { return 0; }
long __asan_abi_after_dynamic_init(void);
long __asan_abi_after_dynamic_init(void) { return 0; }
long __asan_abi_alloca_poison(void);
long __asan_abi_alloca_poison(void) { return 0; }
long __asan_abi_allocas_unpoison(void);
long __asan_abi_allocas_unpoison(void) { return 0; }
long __asan_abi_before_dynamic_init(void);
long __asan_abi_before_dynamic_init(void) { return 0; }
long __asan_abi_exp_load_n(void);
long __asan_abi_exp_load_n(void) { return 0; }
long __asan_abi_exp_store_n(void);
long __asan_abi_exp_store_n(void) { return 0; }
long __asan_abi_get_current_fake_stack(void);
long __asan_abi_get_current_fake_stack(void) { return 0; }
long __asan_abi_handle_no_return(void);
long __asan_abi_handle_no_return(void) { return 0; }
long __asan_abi_init(void);
long __asan_abi_init(void) { return 0; }
long __asan_abi_load_cxx_array_cookie(void);
long __asan_abi_load_cxx_array_cookie(void) { return 0; }
long __asan_abi_load_n(void);
long __asan_abi_load_n(void) { return 0; }
long __asan_abi_poison_cxx_array_cookie(void);
long __asan_abi_poison_cxx_array_cookie(void) { return 0; }
long __asan_abi_poison_intra_object_redzone(void);
long __asan_abi_poison_intra_object_redzone(void) { return 0; }
long __asan_abi_poison_memory_region(void);
long __asan_abi_poison_memory_region(void) { return 0; }
long __asan_abi_poison_stack_memory(void);
long __asan_abi_poison_stack_memory(void) { return 0; }
long __asan_abi_region_is_poisoned(void);
long __asan_abi_region_is_poisoned(void) { return 0; }
long __asan_abi_register_elf_globals(void);
long __asan_abi_register_elf_globals(void) { return 0; }
long __asan_abi_register_globals(void);
long __asan_abi_register_globals(void) { return 0; }
long __asan_abi_register_image_globals(void);
long __asan_abi_register_image_globals(void) { return 0; }
long __asan_abi_report_exp_load_n(void);
long __asan_abi_report_exp_load_n(void) { return 0; }
long __asan_abi_report_exp_store_n(void);
long __asan_abi_report_exp_store_n(void) { return 0; }
long __asan_abi_report_load_n(void);
long __asan_abi_report_load_n(void) { return 0; }
long __asan_abi_report_store_n(void);
long __asan_abi_report_store_n(void) { return 0; }
long __asan_abi_set_shadow_xx_n(void);
long __asan_abi_set_shadow_xx_n(void) { return 0; }
long __asan_abi_stack_free_n(void);
long __asan_abi_stack_free_n(void) { return 0; }
long __asan_abi_stack_malloc_always_n(void);
long __asan_abi_stack_malloc_always_n(void) { return 0; }
long __asan_abi_stack_malloc_n(void);
long __asan_abi_stack_malloc_n(void) { return 0; }
long __asan_abi_store_n(void);
long __asan_abi_store_n(void) { return 0; }
long __asan_abi_unpoison_intra_object_redzone(void);
long __asan_abi_unpoison_intra_object_redzone(void) { return 0; }
long __asan_abi_unpoison_memory_region(void);
long __asan_abi_unpoison_memory_region(void) { return 0; }
long __asan_abi_unpoison_stack_memory(void);
long __asan_abi_unpoison_stack_memory(void) { return 0; }
long __asan_abi_unregister_elf_globals(void);
long __asan_abi_unregister_elf_globals(void) { return 0; }
long __asan_abi_unregister_globals(void);
long __asan_abi_unregister_globals(void) { return 0; }
long __asan_abi_unregister_image_globals(void);
long __asan_abi_unregister_image_globals(void) { return 0; }
long __asan_get_alloc_stack(void);
long __asan_get_alloc_stack(void) { return 0; }
long __asan_get_free_stack(void);
long __asan_get_free_stack(void) { return 0; }
long __asan_get_report_access_size(void);
long __asan_get_report_access_size(void) { return 0; }
long __asan_get_report_access_type(void);
long __asan_get_report_access_type(void) { return 0; }
long __asan_get_report_address(void);
long __asan_get_report_address(void) { return 0; }
long __asan_get_report_bp(void);
long __asan_get_report_bp(void) { return 0; }
long __asan_get_report_description(void);
long __asan_get_report_description(void) { return 0; }
long __asan_get_report_pc(void);
long __asan_get_report_pc(void) { return 0; }
long __asan_get_report_sp(void);
long __asan_get_report_sp(void) { return 0; }
long __asan_get_shadow_mapping(void);
long __asan_get_shadow_mapping(void) { return 0; }
long __asan_locate_address(void);
long __asan_locate_address(void) { return 0; }
long __asan_report_present(void);
long __asan_report_present(void) { return 0; }
long sanitizers_address_on_report(void);
long sanitizers_address_on_report(void) { return 0; }
long sanitizers_diagnose_memory_error(void);
long sanitizers_diagnose_memory_error(void) { return 0; }
long sanitizers_testonly_diagnose_error(void);
long sanitizers_testonly_diagnose_error(void) { return 0; }
long sanitizers_testonly_get_shadow_address(void);
long sanitizers_testonly_get_shadow_address(void) { return 0; }
