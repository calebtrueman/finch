/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into libdispatch (tools/build-oss.sh): declarations Apple's
 * internal headers provide but the published ones don't.
 */
#ifndef __ASSEMBLER__
#include <stddef.h>
#include <stdint.h>
#include <sys/work_interval.h>

/*
 * Work interval instances. Implemented by Finch's libsystem_kernel
 * (kernel/patches/0003); ABI as used by libdispatch's workgroup.c.
 */
struct work_interval_data {
	uint64_t wid_external_wakeups;
	uint64_t wid_total_wakeups;
	uint64_t wid_cycles;
	uint64_t wid_instructions;
	uint64_t wid_user_time_mach;
	uint64_t wid_system_time_mach;
};

work_interval_instance_t work_interval_instance_alloc(work_interval_t interval_handle);
void     work_interval_instance_free(work_interval_instance_t wii);
void     work_interval_instance_clear(work_interval_instance_t wii);
void     work_interval_instance_set_start(work_interval_instance_t wii, uint64_t start);
void     work_interval_instance_set_finish(work_interval_instance_t wii, uint64_t finish);
void     work_interval_instance_set_deadline(work_interval_instance_t wii, uint64_t deadline);
void     work_interval_instance_set_complexity(work_interval_instance_t wii, uint64_t complexity);
int      work_interval_instance_start(work_interval_instance_t wii);
int      work_interval_instance_update(work_interval_instance_t wii);
int      work_interval_instance_finish(work_interval_instance_t wii);
void     work_interval_instance_get_telemetry_data(work_interval_instance_t wii,
    work_interval_data_t data, size_t size);
#endif /* __ASSEMBLER__ */
