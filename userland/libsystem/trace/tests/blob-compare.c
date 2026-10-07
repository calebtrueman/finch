/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../blob.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
struct frame {
	unsigned char uuid[16];
	uint32_t offset;
};
struct trace {
	struct frame *frames;
	int count;
};
typedef void (*write_fn)(struct trace *, void *);
static unsigned checks;
int main(int argc, char **argv)
{
	assert(argc == 2);
	void *h = dlopen("/usr/lib/system/libsystem_trace.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	assert(h && f);
	write_fn functions[2][2] = {{dlsym(h, "os_log_backtrace_print_to_blob"),
	                                dlsym(h, "os_log_backtrace_serialize_to_blob")},
	    {dlsym(f, "os_log_backtrace_print_to_blob"),
	        dlsym(f, "os_log_backtrace_serialize_to_blob")}};
	Dl_info info;
	assert(dladdr((void *)functions[1][0], &info) && strstr(info.dli_fname, argv[1]));
	struct frame frames[300];
	for (unsigned i = 0; i < 300; i++) {
		memset(&frames[i], 0, sizeof(frames[i]));
		if (i % 7) {
			frames[i].uuid[0] = i % 253 + 1;
			frames[i].uuid[1] = i % 11 + 1;
		}
		frames[i].offset = i * 381237;
	}
	const unsigned counts[] = {0, 1, 2, 3, 4, 5, 16, 63, 120, 220, 300};
	for (unsigned ni = 0; ni < sizeof(counts) / sizeof(*counts); ni++)
		for (unsigned capacity = 1; capacity <= 128; capacity = capacity * 2 + 1)
			for (unsigned room = 0; room < 4; room++)
				for (unsigned initial = 0; initial < 3; initial++)
					for (unsigned operation = 0; operation < 2; operation++)
						for (unsigned binary = 0; binary <= operation;
						    binary++)
							for (unsigned stopped = 0; stopped < 2;
							    stopped++) {
								unsigned char storage[2][256];
								memset(
								    storage, 0xa5, sizeof(storage));
								unsigned length = initial == 0 ? 0
								    : initial == 1 ? capacity / 2
								                   : capacity - 1;
								unsigned maximum = room == 0 ? 0
								    : room == 1 ? capacity
								    : room == 2 ? capacity * 2
								                : 16384;
								struct finch_trace_blob blob[2];
								struct trace trace = {
								    frames, counts[ni]};
								int errors[2];
								for (int j = 0; j < 2; j++) {
									blob[j] = (struct
									    finch_trace_blob){
									    storage[j], length,
									    capacity, maximum,
									    stopped ? 2 : 0, binary,
									    0};
									if (!binary)
										storage[j][length] =
										    0;
									errno = 123;
									functions[j][operation](
									    &trace, &blob[j]);
									errors[j] = errno;
								}
								if (memcmp((char *)&blob[0] + 8,
								        (char *)&blob[1] + 8, 16) ||
								    memcmp(blob[0].data,
								        blob[1].data,
								        blob[0].length + !binary) ||
								    errors[0] != errors[1]) {
									fprintf(stderr,
									    "blob mismatch n%u cap%u max%u start%u op%u bin%u stop%u state len%u/%u cap%u/%u flags%u/%u errno%d/%d\n",
									    trace.count, capacity,
									    maximum, length,
									    operation, binary,
									    stopped, blob[0].length,
									    blob[1].length,
									    blob[0].capacity,
									    blob[1].capacity,
									    blob[0].flags,
									    blob[1].flags,
									    errors[0], errors[1]);
									return 1;
								}
								assert(!memcmp(
								    storage[0] + capacity,
								    storage[1] + capacity,
								    sizeof(storage[0]) - capacity));
								/* Either side can keep writing to a buffer grown by the other side. */
								for (int j = 0; j < 2; j++)
									functions[1 - j][operation](
									    &trace, &blob[j]);
								assert(blob[0].length ==
								        blob[1].length &&
								    blob[0].capacity ==
								        blob[1].capacity &&
								    blob[0].flags == blob[1].flags);
								assert(!memcmp(blob[0].data,
								    blob[1].data,
								    blob[0].length + !binary));
								for (int j = 0; j < 2; j++)
									if (blob[j].flags & 1)
										free(blob[j].data);
								checks++;
							}
	puts("Host blob helpers are private; checks use the exported backtrace calls.");
	printf(
	    "blob: %u host comparisons passed, including mixed calls and buffer growth\n", checks);
	return 0;
}
