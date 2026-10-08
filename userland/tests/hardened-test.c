/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-hardened-test: signed with com.apple.developer.hardened-process (and the
 * hardened heap), as Apple daemons are. Each step prints before it runs, so a
 * crash shows which piece of the stack trips a hardened-process mitigation
 * (docs/design/HARDENED-PROCESS.md).
 */
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#define STEP(name) do { printf("step: %s\n", name); fflush(stdout); } while (0)

int
main(void)
{
	STEP("started");
	STEP("malloc");
	for (int i = 1; i < 4096; i *= 2) {
		char *p = malloc((size_t)i * 16);
		memset(p, 1, (size_t)i * 16);
		free(p);
	}
	STEP("dispatch");
	dispatch_queue_t q = dispatch_queue_create("t", NULL);
	dispatch_sync(q, ^{ });
	STEP("os_log");
	os_log(OS_LOG_DEFAULT, "hardened test %d", 1);
	STEP("xpc object");
	xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(d, "k", "v");
	xpc_release(d);
	STEP("xpc connection");
	xpc_connection_t c = xpc_connection_create_mach_service("com.apple.system.notification_center",
	    NULL, 0);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(c);
	xpc_connection_cancel(c);
	STEP("done");
	printf("finch-hardened-test: 0 failures\n");
	return 0;
}
