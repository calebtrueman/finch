/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <stddef.h>
#define EXPORT __attribute__((visibility("default")))
EXPORT void cc_clear(size_t size, void *ptr)
{
	volatile unsigned char *p = ptr;
	while (size--)
		*p++ = 0;
}
EXPORT int cc_cmp_safe(size_t size, const void *left, const void *right)
{
	if (!size)
		return 1;
	const volatile unsigned char *a = left, *b = right;
	unsigned difference = 0;
	for (size_t i = 0; i < size; i++)
		difference |= a[i] ^ b[i];
	return difference != 0;
}
