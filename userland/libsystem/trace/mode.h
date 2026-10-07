/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_MODE_H
#define FINCH_TRACE_MODE_H
#include <stdbool.h>
#include <stdint.h>
uint32_t os_trace_get_mode(void);
void os_trace_set_mode(uint32_t);
/* Safe while dispatch and the logging transport are still starting. */
uint32_t finch_trace_mode_peek(void);
uint32_t finch_trace_commpage(void);
bool finch_trace_lazy_initialized(void);
void finch_trace_mode_fork_child(void);
/* Low two bits: enable level. Next three bits: persist level. */
uint8_t finch_trace_process_levels(void);
#endif
