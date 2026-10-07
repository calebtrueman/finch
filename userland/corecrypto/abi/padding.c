/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
/* This legacy call checks only the final length byte, as the host does. */
EXPORT size_t ccpad_pkcs7_decode(size_t b, const void *p)
{
	if (!b)
		return 0;
	unsigned n = ((const unsigned char *)p)[b - 1];
	return n && n <= b ? n : 0;
}
EXPORT size_t ccpad_pkcs7_encrypt(
    const struct ccmode_cbc *m, const void *c, void *iv, size_t n, const void *in, void *out)
{
	size_t b = m->block_size, whole = n / b * b, tail = n - whole;
	unsigned char *o = out;
	m->cbc(c, iv, n / b, in, out);
	memmove(o + whole, (const unsigned char *)in + whole, tail);
	memset(o + n, (int)(b - tail), b - tail);
	m->cbc(c, iv, 1, o + whole, o + whole);
	return whole + b;
}
EXPORT size_t ccpad_pkcs7_decrypt(
    const struct ccmode_cbc *m, const void *c, void *iv, size_t n, const void *in, void *out)
{
	size_t b = m->block_size;
	if (n < b)
		return n;
	m->cbc(c, iv, n / b, in, out);
	return n - ccpad_pkcs7_decode(b, (unsigned char *)out + (n / b - 1) * b);
}
EXPORT size_t ccpad_pkcs7_ecb_encrypt(
    const struct ccmode_ecb *m, const void *c, size_t n, const void *in, void *out)
{
	size_t b = m->block_size, whole = n / b * b, tail = n - whole;
	unsigned char *o = out;
	m->ecb(c, n / b, in, out);
	memmove(o + whole, (const unsigned char *)in + whole, tail);
	memset(o + n, (int)(b - tail), b - tail);
	m->ecb(c, 1, o + whole, o + whole);
	return whole + b;
}
EXPORT size_t ccpad_pkcs7_ecb_decrypt(
    const struct ccmode_ecb *m, const void *c, size_t n, const void *in, void *out)
{
	size_t b = m->block_size;
	if (n < b)
		return n;
	m->ecb(c, n / b, in, out);
	return n - ccpad_pkcs7_decode(b, (unsigned char *)out + (n / b - 1) * b);
}
static size_t cts_encrypt(const struct ccmode_cbc *m, const void *c, void *iv, size_t n,
    const void *input, void *output, int kind)
{
	size_t b = m->block_size;
	if (n < b)
		return 0;
	if (n == b) {
		unsigned char pair[2 * b];
		memcpy(pair, input, b);
		memset(pair + b, 0, b);
		m->cbc(c, iv, 2, pair, pair);
		memcpy(output, pair + b, b);
		return n;
	}
	const unsigned char *in = input;
	unsigned char *out = output;
	size_t tail = n % b;
	if (!tail && kind != 3) {
		m->cbc(c, iv, n / b, in, out);
		return n;
	}
	if (!tail)
		tail = b;
	size_t prefix = n - b - tail;
	unsigned char a[b], last[b];
	m->cbc(c, iv, prefix / b, in, out);
	memcpy(last, in + prefix + b, tail);
	memset(last + tail, 0, b - tail);
	m->cbc(c, iv, 1, in + prefix, a);
	m->cbc(c, iv, 1, last, last);
	if (kind == 1) {
		memcpy(out + prefix, a, tail);
		memcpy(out + prefix + tail, last, b);
	} else {
		memcpy(out + prefix, last, b);
		memcpy(out + prefix + b, a, tail);
	}
	return n;
}
static size_t cts_decrypt(const struct ccmode_cbc *m, const void *c, void *iv, size_t n,
    const void *input, void *output, int kind)
{
	size_t b = m->block_size;
	if (n < b)
		return 0;
	if (n == b) {
		unsigned char zero[b], a[b];
		memset(zero, 0, b);
		m->cbc(c, zero, 1, input, a);
		m->cbc(c, iv, 1, a, output);
		return n;
	}
	const unsigned char *in = input;
	unsigned char *out = output;
	size_t tail = n % b;
	if (!tail && kind != 3) {
		m->cbc(c, iv, n / b, in, out);
		return n;
	}
	if (!tail)
		tail = b;
	size_t prefix = n - b - tail;
	unsigned char a[b], last[b], zero[b], saved[b], chain[b];
	memcpy(last, in + prefix + (kind == 1 ? tail : 0), b);
	memcpy(a, in + prefix + (kind == 1 ? 0 : b), tail);
	m->cbc(c, iv, prefix / b, in, out);
	memcpy(saved, iv, b);
	memset(chain, 0, b);
	m->cbc(c, chain, 1, last, zero);
	memcpy(a + tail, zero + tail, b - tail);
	for (size_t i = 0; i < tail; i++)
		zero[i] ^= a[i];
	m->cbc(c, saved, 1, a, out + prefix);
	memcpy(out + prefix + b, zero, tail);
	memcpy(iv, tail == b ? last : a, b);
	return n;
}
#define CTS(N)                                                                                     \
	EXPORT size_t ccpad_cts##N##_encrypt(                                                      \
	    const struct ccmode_cbc *m, const void *c, void *v, size_t n, const void *i, void *o)  \
	{                                                                                          \
		return cts_encrypt(m, c, v, n, i, o, N);                                           \
	}                                                                                          \
	EXPORT size_t ccpad_cts##N##_decrypt(                                                      \
	    const struct ccmode_cbc *m, const void *c, void *v, size_t n, const void *i, void *o)  \
	{                                                                                          \
		return cts_decrypt(m, c, v, n, i, o, N);                                           \
	}
CTS(1) CTS(2) CTS(3) static void xts_alpha(unsigned char *t)
{
	unsigned carry = 0;
	for (int i = 0; i < 16; i++) {
		unsigned v = ((unsigned)t[i] << 1) | carry;
		t[i] = (unsigned char)v;
		carry = v >> 8;
	}
	t[0] ^= (unsigned char)((0u - carry) & 0x87);
}
EXPORT void ccpad_xts_encrypt(
    const struct ccmode_xts *m, const void *c, void *t, size_t n, const void *input, void *output)
{
	const unsigned char *in = input;
	unsigned char *out = output;
	size_t tail = n % 16;
	if (!tail) {
		m->xts(c, t, n / 16, in, out);
		return;
	}
	if (n < 16)
		return;
	size_t prefix = n - tail - 16;
	unsigned char a[16], last[16];
	m->xts(c, t, prefix / 16, in, out);
	memcpy(last, in + prefix + 16, tail);
	m->xts(c, t, 1, in + prefix, a);
	memcpy(last + tail, a + tail, 16 - tail);
	memcpy(out + prefix + 16, a, tail);
	m->xts(c, t, 1, last, out + prefix);
}
EXPORT size_t ccpad_xts_decrypt(
    const struct ccmode_xts *m, const void *c, void *t, size_t n, const void *input, void *output)
{
	const unsigned char *in = input;
	unsigned char *out = output;
	size_t tail = n % 16;
	if (!tail) {
		m->xts(c, t, n / 16, in, out);
		return n;
	}
	if (n < 16)
		return 0;
	size_t prefix = n - tail - 16;
	unsigned char a[16], last[16], saved[16];
	unsigned char *value = m->xts(c, t, prefix / 16, in, out);
	if (!value)
		return 0;
	memcpy(saved, value, 16);
	xts_alpha(value);
	memcpy(last, in + prefix + 16, tail);
	m->xts(c, t, 1, in + prefix, a);
	memcpy(value, saved, 16);
	memcpy(last + tail, a + tail, 16 - tail);
	memcpy(out + prefix + 16, a, tail);
	m->xts(c, t, 1, last, out + prefix);
	return n;
}
