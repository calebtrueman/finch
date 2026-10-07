/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Fault and test callbacks through the built library: a fault reaches the fault
 * callback; an error reaches only the test callback. */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
struct info {
	uint32_t version, reserved;
	void *log;
	const char *subsystem, *category, *format, *message;
	const void *pc;
	uint8_t type;
};
static int calls;
static char seen[256];
static uint8_t seen_type;
static void cb(const struct info *i)
{
	calls++;
	strncpy(seen, i->message ? i->message : "", 255);
	seen_type = i->type;
}
int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: fault-callbacks libsystem_trace.dylib\n");
		return 2;
	}
	/* Let the host libdispatch set up its firehose with the host library first. */
	void *host = dlopen("/usr/lib/system/libsystem_trace.dylib", RTLD_NOW | RTLD_LOCAL);
	((void *(*)(const char *, const char *))dlsym(host, "os_log_create"))(
	    "org.finch.test", "warmup");
	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		puts(dlerror());
		return 2;
	}
	void *(*set_fault)(void *) = dlsym(h, "os_log_set_fault_callback");
	void *(*set_test)(void *) = dlsym(h, "os_log_set_test_callback");
	void *(*create)(const char *, const char *) = dlsym(h, "os_log_create");
	void (*impl)(void *, void *, uint8_t, const char *, uint8_t *, uint32_t) =
	    dlsym(h, "_os_log_impl");
	set_fault((void *)cb);
	void *log = create("org.finch.test", "fault");
	uint8_t buf[2] = {0, 0};
	impl(NULL, log, 17, "fault number one", buf, 2);
	int after_fault = calls;
	impl(NULL, log, 16, "an error", buf, 2);
	int after_error = calls;
	set_test((void *)cb);
	impl(NULL, log, 16, "an error", buf, 2);
	printf("fault cb=%d msg='%s' type=%u; error cb=%d (want 1); with test cb=%d (want 2)\n",
	    after_fault, seen, seen_type, after_error, calls);
	return !(after_fault == 1 && !strcmp(seen, "an error") && after_error == 1 && calls == 2);
}
