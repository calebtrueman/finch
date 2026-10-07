/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <os/thread_self_restrict.h>: per-thread RWX restriction for JIT memory
 * (backs pthread_jit_write_protect_np and friends), and TPRO, the per-thread
 * read-only toggle dyld uses for its own data.
 *
 * Apple publishes this header with its body removed. This reimplementation
 * follows the behaviour of macOS 26.4's libsystem_pthread:
 *
 *   commpage +0x10C (u8)   mode: 0 = unsupported, 1 = APRR, 2..3 = SPRR
 *   commpage +0x110 (u64)  permission value for "RW" (JIT writable)
 *   commpage +0x118 (u64)  permission value for "RX" (JIT executable)
 *
 *   commpage +0x0D0 (u64)  permission value for TPRO "RW" (dyld data writable)
 *   commpage +0x0D8 (u64)  permission value for TPRO "RO"
 *
 * TPRO is SPRR-only; macOS 26.4's dyld reads "writable" from bit 36 of the
 * permission register. The value is written to the per-thread permission register, which is
 * APRR_EL0 (S3_4_C15_C2_7) on APRR parts and SPRR_PERM_EL0 (S3_6_C15_C1_5)
 * on SPRR parts (M1 and later). Register names follow the Asahi Linux
 * documentation. After the write, the register is read back and the thread
 * traps if it doesn't match.
 */

#ifndef OS_THREAD_SELF_RESTRICT_H
#define OS_THREAD_SELF_RESTRICT_H

#include <stdbool.h>
#include <stdint.h>

#if defined(__arm64__)

#define _FINCH_COMMPAGE_BASE            0x0000000FFFFFC000ULL
#define _FINCH_COMMPAGE_RWX_MODE        (_FINCH_COMMPAGE_BASE + 0x10C)
#define _FINCH_COMMPAGE_RWX_RW_VALUE    (_FINCH_COMMPAGE_BASE + 0x110)
#define _FINCH_COMMPAGE_RWX_RX_VALUE    (_FINCH_COMMPAGE_BASE + 0x118)

#define _FINCH_COMMPAGE_TPRO_RW_VALUE   (_FINCH_COMMPAGE_BASE + 0x0D0)
#define _FINCH_COMMPAGE_TPRO_RO_VALUE   (_FINCH_COMMPAGE_BASE + 0x0D8)
#define _FINCH_TPRO_WRITABLE_BIT        36

#define _FINCH_RWX_MODE_APRR            1
#define _FINCH_RWX_MODE_SPRR_MIN        2
#define _FINCH_RWX_MODE_SPRR_MAX        3

static inline uint8_t
_os_thread_self_restrict_rwx_mode(void)
{
	return *(volatile const uint8_t *)_FINCH_COMMPAGE_RWX_MODE;
}

__attribute__((always_inline))
static inline bool
os_thread_self_restrict_rwx_is_supported(void)
{
	return _os_thread_self_restrict_rwx_mode() != 0;
}

__attribute__((always_inline))
static inline void
_os_thread_self_restrict_rwx_set(uintptr_t value_addr)
{
	uint8_t mode = _os_thread_self_restrict_rwx_mode();
	uint64_t want = *(volatile const uint64_t *)value_addr, have;

	__asm__ volatile ("dmb ishst" ::: "memory");
	if (mode >= _FINCH_RWX_MODE_SPRR_MIN && mode <= _FINCH_RWX_MODE_SPRR_MAX) {
		__asm__ volatile ("msr S3_6_C15_C1_5, %0\n\tisb" :: "r"(want) : "memory");
		__asm__ volatile ("mrs %0, S3_6_C15_C1_5" : "=r"(have));
	} else if (mode == _FINCH_RWX_MODE_APRR) {
		__asm__ volatile ("msr S3_4_C15_C2_7, %0\n\tisb" :: "r"(want) : "memory");
		__asm__ volatile ("mrs %0, S3_4_C15_C2_7" : "=r"(have));
	} else {
		__builtin_debugtrap();
		__builtin_unreachable();
	}
	if (have != want) {
		__builtin_debugtrap();
	}
}

/* JIT pages become writable (not executable) for this thread. */
__attribute__((always_inline))
static inline void
os_thread_self_restrict_rwx_to_rw(void)
{
	_os_thread_self_restrict_rwx_set(_FINCH_COMMPAGE_RWX_RW_VALUE);
}

/* JIT pages become executable (not writable) for this thread. */
__attribute__((always_inline))
static inline void
os_thread_self_restrict_rwx_to_rx(void)
{
	_os_thread_self_restrict_rwx_set(_FINCH_COMMPAGE_RWX_RX_VALUE);
}

/* TPRO: SPRR parts only. */
__attribute__((always_inline))
static inline bool
os_thread_self_restrict_tpro_is_supported(void)
{
	uint8_t mode = _os_thread_self_restrict_rwx_mode();
	return mode >= _FINCH_RWX_MODE_SPRR_MIN && mode <= _FINCH_RWX_MODE_SPRR_MAX;
}

__attribute__((always_inline))
static inline bool
os_thread_self_restrict_tpro_is_writable(void)
{
	uint64_t v;
	if (!os_thread_self_restrict_tpro_is_supported()) {
		__builtin_debugtrap();
		__builtin_unreachable();
	}
	__asm__ volatile ("mrs %0, S3_6_C15_C1_5" : "=r"(v));
	return (v >> _FINCH_TPRO_WRITABLE_BIT) & 1;
}

__attribute__((always_inline))
static inline void
_os_thread_self_restrict_tpro_set(uintptr_t value_addr)
{
	if (!os_thread_self_restrict_tpro_is_supported()) {
		__builtin_debugtrap();
		__builtin_unreachable();
	}
	_os_thread_self_restrict_rwx_set(value_addr);  /* SPRR path: write, isb, verify */
}

/* TPRO-protected pages become writable for this thread. */
__attribute__((always_inline))
static inline void
os_thread_self_restrict_tpro_to_rw(void)
{
	_os_thread_self_restrict_tpro_set(_FINCH_COMMPAGE_TPRO_RW_VALUE);
}

/* TPRO-protected pages become read-only for this thread. */
__attribute__((always_inline))
static inline void
os_thread_self_restrict_tpro_to_ro(void)
{
	_os_thread_self_restrict_tpro_set(_FINCH_COMMPAGE_TPRO_RO_VALUE);
}

#endif /* __arm64__ */

#endif /* OS_THREAD_SELF_RESTRICT_H */
