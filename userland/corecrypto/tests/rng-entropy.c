/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Exercise failure and interruption paths without weakening the live source.
 */
#define getentropy test_getentropy
#include "../abi/rng.c"
#include <stdio.h>
static size_t calls, fail_at, interrupt_at;
int test_getentropy(void *out, size_t n)
{
	calls++;
	if (n > 256)
		return -1;
	if (calls == interrupt_at) {
		errno = EINTR;
		return -1;
	}
	if (calls == fail_at) {
		errno = EIO;
		return -1;
	}
	memset(out, 0x37, n);
	return 0;
}
int main(void)
{
	unsigned char data[1025];
	int failures = 0;
	memset(data, 0xa5, sizeof(data));
	calls = 0;
	interrupt_at = 1;
	if (system_generate(NULL, 1024, data) || calls != 5)
		failures++;
	for (size_t i = 0; i < 1024; i++)
		if (data[i] != 0x37)
			failures++;
	if (data[1024] != 0xa5)
		failures++;
	memset(data, 0xa5, sizeof(data));
	calls = 0;
	interrupt_at = 0;
	fail_at = 3;
	if (system_generate(NULL, 1024, data) != -1 || calls != 3)
		failures++;
	for (size_t i = 0; i < 1024; i++)
		if (data[i])
			failures++;
	if (data[1024] != 0xa5)
		failures++;
	calls = 0;
	if (system_generate(NULL, 0, NULL) || calls)
		failures++;
	printf("RNG entropy: %d failures\n", failures);
	return failures ? 1 : 0;
}
