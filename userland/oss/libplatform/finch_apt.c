/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * os_apt_msg_async_task_stopped_4swift: declared in libplatform's
 * private/os/apt_private.h and imported by the Swift concurrency runtime, but
 * missing from the published apt_private.c. Its published siblings
 * (..._running_4swift, ..._waiting_on_4swift) are no-ops; so is this.
 */

#include <stdint.h>

void os_apt_msg_async_task_stopped_4swift(uint64_t task_id);

void
os_apt_msg_async_task_stopped_4swift(uint64_t task_id)
{
	(void)task_id;
}
