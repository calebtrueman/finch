/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Checks the kernel request without changing any trust cache. */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static int operation, result, error;
static unsigned calls;
static uint8_t expected[56];
int __sandbox_ms(const char *policy, int op, void *p)
{
	assert(!strcmp(policy, "AMFI") && op == operation);
	calls++;
	if (op == 90 || op == 91) {
		uint64_t flags;
		uint64_t *out;
		memcpy(&flags, p, 8);
		memcpy(&out, (char *)p + 8, 8);
		assert(flags == 123);
		assert(*out == UINT64_C(0xaaaaaaaaaaaaaaaa));
		if (op == 91) {
			int pid;
			memcpy(&pid, (char *)p + 16, 4);
			assert(pid == 456);
		}
		if (!result)
			*out = 789;
	} else
		assert(!memcmp(p, expected, op == 105 ? 8 : 56));
	errno = error;
	return result;
}
#include "../amfi.c"
int main(void)
{
	uint64_t out;
	assert(amfi_check_dyld_policy_self(123, NULL) == EINVAL);
	assert(amfi_check_dyld_policy_for_pid(456, 123, NULL) == EINVAL);
	assert(!calls);
	for (int fail = 0; fail < 2; fail++) {
		result = fail ? -1 : 0;
		error = EPERM;
		operation = 90;
		assert(amfi_check_dyld_policy_self(123, &out) == (fail ? EPERM : 0));
		assert(out == (fail ? UINT64_C(0xaaaaaaaaaaaaaaaa) : 789));
		operation = 91;
		assert(amfi_check_dyld_policy_for_pid(456, 123, &out) == (fail ? EPERM : 0));
		assert(out == (fail ? UINT64_C(0xaaaaaaaaaaaaaaaa) : 789));
	}
	memset(expected, 0xaa, 56);
	expected[0] = 3;
	const void *a = (void *)0x1230, *b = (void *)0x4560;
	void *c = (void *)0x7890;
	uint32_t an = 12, bn = 45, f = 67;
	memcpy(expected + 8, &a, 8);
	memcpy(expected + 16, &an, 4);
	memcpy(expected + 24, &b, 8);
	memcpy(expected + 32, &bn, 4);
	memcpy(expected + 40, &c, 8);
	memcpy(expected + 48, &f, 4);
	operation = 101;
	assert(amfi_load_trust_cache(3, a, an, b, bn, c, f) == -1);
	uint64_t id = 987;
	memcpy(expected, &id, 8);
	operation = 105;
	assert(amfi_unload_trust_cache(id) == -1);
	assert(calls == 6);
	puts("AMFI: kernel requests and error handling passed (mock kernel)");
}
