/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <os/log_private.h>: the subset of os_log SPI used by libSystem components.
 * Apple doesn't publish this header (libsystem_trace is closed). The ABI
 * matches the calls macOS 26.4's libsystem_c makes into libsystem_trace:
 *
 *   char *_os_log_send_and_compose_impl(uint32_t flags, const char **fmtp,
 *           char *buf, size_t bufsize, void *dso, os_log_t log,
 *           os_log_type_t type, const char *format,
 *           uint8_t *pack, uint32_t pack_size);
 *
 * where pack/pack_size is the compiler-built __builtin_os_log_format buffer,
 * and OS_LOG_F_SEND is cleared when the log type isn't enabled. __dso_handle
 * comes from <os/log.h>.
 */

#ifndef __OS_LOG_PRIVATE_H__
#define __OS_LOG_PRIVATE_H__

#include <os/log.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

__BEGIN_DECLS

#define OS_LOG_F_SEND     0x1u   /* emit to the logging system */
#define OS_LOG_F_COMPOSE  0x2u   /* also format into the caller's buffer */

/*
 * A captured log message, as passed to os_log_pack_send_and_compose().
 * Layout as documented in earlier Apple sources; olp_format at offset 0x28 is
 * confirmed by macOS 26.4's libsystem_c (_os_crash_fmt).
 */
typedef struct os_log_pack_s {
	uint64_t        olp_continuous_time;
	struct timespec olp_wall_time;
	const void     *olp_mh;
	const void     *olp_pc;
	const char     *olp_format;
	uint8_t         olp_data[];
} os_log_pack_s, *os_log_pack_t;

char *_os_log_send_and_compose_impl(uint32_t flags, const char **fmtp,
    char *buf, size_t bufsize, void *dso, os_log_t log, os_log_type_t type,
    const char *format, uint8_t *pack, uint32_t pack_size);

char *os_log_pack_send_and_compose(os_log_pack_t pack, os_log_t log,
    os_log_type_t type, char *buf, size_t bufsize);

/*
 * syslog(3)/ASL shims into os_log (libsystem_asl calls them). Shapes from
 * macOS 26.4's libsystem_trace: os_log_shim_enabled(caller address) says
 * whether messages from that image go to os_log; os_log_with_args_4syslog
 * logs a printf-style message with a va_list on the caller's behalf.
 */
bool os_log_shim_enabled(void *addr);
void os_log_with_args_4syslog(os_log_t log, os_log_type_t type, const char *format, va_list args, void *addr);

__END_DECLS

#define os_log_send_and_compose(flags, fmtp, buf, bufsize, log, type, format, ...) \
	__extension__({ \
		os_log_t _osl_log = (log); \
		os_log_type_t _osl_type = (type); \
		uint32_t _osl_flags = (flags); \
		if (!os_log_type_enabled(_osl_log, _osl_type)) { \
			_osl_flags &= ~OS_LOG_F_SEND; \
		} \
		uint8_t _osl_pack[__builtin_os_log_format_buffer_size(format, ##__VA_ARGS__)] \
		    __attribute__((aligned(8))); \
		_os_log_send_and_compose_impl(_osl_flags, (fmtp), (buf), (bufsize), \
		    &__dso_handle, _osl_log, _osl_type, (format), \
		    (uint8_t *)__builtin_os_log_format(_osl_pack, format, ##__VA_ARGS__), \
		    (uint32_t)sizeof(_osl_pack)); \
	})

#endif /* __OS_LOG_PRIVATE_H__ */
