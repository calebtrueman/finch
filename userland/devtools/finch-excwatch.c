/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-excwatch: run a command as the handler of its Mach exceptions and
 * report the first one: exception type, codes, and the faulting thread's pc,
 * lr, sp and far, with the image each pc/lr falls in. For crashes the VM
 * otherwise reports only as "killed by signal N" (no crash reports there).
 *
 *   finch-excwatch command [args...]
 */

#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld_images.h>
#include <signal.h>
#include <mach/thread_status.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/*
 * The task's shared cache slide, from its dyld_all_image_infos. Unslid
 * addresses resolve offline against the image's cache map
 * (build/vm/dyld_shared_cache_arm64e.map).
 */
static uint64_t
cache_slide(task_t task)
{
	struct task_dyld_info dinfo;
	mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
	struct dyld_all_image_infos infos;
	mach_vm_size_t got = 0;

	if (task_info(task, TASK_DYLD_INFO, (task_info_t)&dinfo, &count) != KERN_SUCCESS ||
	    mach_vm_read_overwrite(task, dinfo.all_image_info_addr, sizeof(infos),
	        (mach_vm_address_t)&infos, &got) != KERN_SUCCESS)
		return UINT64_MAX;
	return infos.sharedCacheSlide;
}
int posix_spawnattr_setexceptionports_np(posix_spawnattr_t *, exception_mask_t, mach_port_t,
    exception_behavior_t, thread_state_flavor_t);

static const char *
type_name(exception_type_t type)
{
	static const char *const names[] = { "0", "EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION",
		"EXC_ARITHMETIC", "EXC_EMULATION", "EXC_SOFTWARE", "EXC_BREAKPOINT", "EXC_SYSCALL",
		"EXC_MACH_SYSCALL", "EXC_RPC_ALERT", "EXC_CRASH", "EXC_RESOURCE", "EXC_GUARD",
		"EXC_CORPSE_NOTIFY" };
	return type < (int)(sizeof(names) / sizeof(names[0])) ? names[type] : "?";
}

/* The exception message with MACH_EXCEPTION_CODES | EXCEPTION_STATE_IDENTITY
 * (packed to 4 bytes, as MIG lays it out). */
#pragma pack(push, 4)
typedef struct {
	mach_msg_header_t head;
	mach_msg_body_t body;
	mach_msg_port_descriptor_t thread;
	mach_msg_port_descriptor_t task;
	NDR_record_t ndr;
	exception_type_t exception;
	mach_msg_type_number_t code_count;
	int64_t code[2];
	int flavor;
	mach_msg_type_number_t state_count;
	natural_t state[ARM_THREAD_STATE64_COUNT + 16];
	mach_msg_trailer_t trailer;
} exc_message_t;
#pragma pack(pop)

int
main(int argc, char **argv)
{
	mach_port_t port;
	posix_spawnattr_t attr;
	pid_t pid;
	exc_message_t msg;
	kern_return_t kr;
	int status;

	if (argc < 2) {
		fprintf(stderr, "usage: finch-excwatch command [args...]\n");
		return 2;
	}
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
	mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
	posix_spawnattr_init(&attr);
	posix_spawnattr_setexceptionports_np(&attr,
	    EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_SOFTWARE |
	        EXC_MASK_BREAKPOINT | EXC_MASK_GUARD | EXC_MASK_CRASH,
	    port, (exception_behavior_t)(EXCEPTION_STATE_IDENTITY | MACH_EXCEPTION_CODES),
	    ARM_THREAD_STATE64);
	if ((errno = posix_spawnp(&pid, argv[1], NULL, &attr, argv + 1, environ)) != 0) {
		perror(argv[1]);
		return 1;
	}

	memset(&msg, 0, sizeof(msg));
	kr = mach_msg(&msg.head, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg), port, 30000,
	    MACH_PORT_NULL);
	if (kr != KERN_SUCCESS) {
		waitpid(pid, &status, 0);
		printf("excwatch: no exception (exit status %#x)\n", status);
		return 0;
	}
	printf("excwatch: pid %d %s (%d) code %#llx subcode %#llx\n", pid, type_name(msg.exception),
	    msg.exception, (unsigned long long)msg.code[0], (unsigned long long)msg.code[1]);
	if (msg.flavor == ARM_THREAD_STATE64) {
		arm_thread_state64_t *ts = (void *)msg.state;
		printf("excwatch: pc %#llx lr %#llx sp %#llx\n",
		    (unsigned long long)__darwin_arm_thread_state64_get_pc(*ts),
		    (unsigned long long)__darwin_arm_thread_state64_get_lr(*ts),
		    (unsigned long long)__darwin_arm_thread_state64_get_sp(*ts));
		uint64_t slide = cache_slide(msg.task.name);
		if (slide != UINT64_MAX) {
			printf("excwatch: cache slide %#llx; unslid pc %#llx lr %#llx", (unsigned long long)slide,
			    (unsigned long long)((__darwin_arm_thread_state64_get_pc(*ts) & 0xfffffffffULL) - slide),
			    (unsigned long long)((__darwin_arm_thread_state64_get_lr(*ts) & 0xfffffffffULL) - slide));
			if (msg.exception == EXC_BAD_ACCESS)
				printf(" fault %#llx", (unsigned long long)((uint64_t)msg.code[1] - slide));
			printf("\n");
		}
		for (int i = 0; i < 29; i += 4)
			printf("excwatch: x%-2d %#18llx %#18llx %#18llx %#18llx\n", i,
			    (unsigned long long)ts->__x[i], (unsigned long long)ts->__x[i + 1],
			    (unsigned long long)ts->__x[i + 2], (unsigned long long)ts->__x[i + 3]);
	}
	/* Let the default handling continue so the process dies as it would have. */
	kill(pid, SIGKILL);
	waitpid(pid, &status, 0);
	return 1;
}
