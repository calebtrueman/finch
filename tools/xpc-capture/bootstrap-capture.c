/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * bootstrap-capture: record the requests Apple's libxpc sends to the
 * bootstrap port for bootstrap_look_up / look_up2 / check_in (launchd's
 * protocol), as ground truth for finch-init's bootstrap server
 * (docs/design/XPC.md, X4). The bootstrap API is pointed at a port this
 * program owns; each request is decoded with Apple's deserializer and printed.
 */

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

xpc_object_t xpc_create_from_serialization(const void *data, size_t len);
kern_return_t bootstrap_look_up2(mach_port_t bp, const name_t name, mach_port_t *sp,
    pid_t target_pid, uint64_t flags);

static mach_port_t fake;

static int
dump_one(int timeout_ms)
{
	union { mach_msg_header_t h; uint8_t b[16384]; } m;

	if (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(m), fake,
	        (mach_msg_timeout_t)timeout_ms, 0) != 0) {
		return 0;
	}
	const uint8_t *p = (const uint8_t *)(&m.h + 1);
	unsigned ndesc = 0;
	if (m.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
		ndesc = ((const mach_msg_body_t *)p)->msgh_descriptor_count;
		p += sizeof(mach_msg_body_t) + ndesc * sizeof(mach_msg_port_descriptor_t);
	}
	size_t n = (size_t)((const uint8_t *)&m.h + m.h.msgh_size - p);
	printf("[request] id=0x%x bits=0x%08x reply=%s descriptors=%u payload=%zu\n",
	    m.h.msgh_id, m.h.msgh_bits,
	    MACH_MSGH_BITS_REMOTE(m.h.msgh_bits) == MACH_MSG_TYPE_PORT_SEND_ONCE ? "send-once" : "other",
	    ndesc, n);
	uint8_t buf[16384];
	memcpy(buf, p, n);
	if (n >= 4 && memcmp(buf, "CPX@", 4) == 0) {
		memcpy(buf, "\x42\x37\x13\x42", 4);   /* message magic -> serialization magic */
	}
	xpc_object_t o = ndesc ? NULL : xpc_create_from_serialization(buf, n);
	if (o) {
		char *d = xpc_copy_description(o);
		printf("%s\n", d);
	} else {
		for (size_t i = 0; i < n; i++) printf("%02x", p[i]);
		printf("\n");
	}
	fflush(stdout);
	mach_msg_destroy(&m.h);   /* drop the reply right: the caller gets an error */
	return 1;
}

int
main(int argc, char **argv)
{
	if (argc > 1) {
		/* Child: our bootstrap port is the parent's fake one. */
		mach_port_t sp = MACH_PORT_NULL;
		printf("child: look_up -> 0x%x\n", bootstrap_look_up(bootstrap_port, "org.finch.test.service", &sp));
		fflush(stdout);
		printf("child: look_up2 -> 0x%x\n", bootstrap_look_up2(bootstrap_port, "org.finch.test.service", &sp, 0, 0));
		fflush(stdout);
		printf("child: check_in -> 0x%x\n", bootstrap_check_in(bootstrap_port, "org.finch.test.service", &sp));
		fflush(stdout);
		return 0;
	}
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &fake);
	mach_port_insert_right(mach_task_self(), fake, fake, MACH_MSG_TYPE_MAKE_SEND);
	/* Children inherit the bootstrap port: they'll talk to us, not launchd. */
	task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, fake);
	pid_t pid = fork();
	if (pid == 0) {
		execl(argv[0], argv[0], "child", (char *)NULL);
		_exit(127);
	}
	while (dump_one(3000)) {
	}
	int status;
	waitpid(pid, &status, 0);
	return 0;
}
