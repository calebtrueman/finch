/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccder.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
static void same(const char *n, const void *a, const void *b, size_t z)
{
	checks++;
	if (memcmp(a, b, z) && failures++ < 20)
		fprintf(stderr, "%s differs\n", n);
}
static void num(const char *n, ptrdiff_t a, ptrdiff_t b)
{
	same(n, &a, &b, sizeof(a));
}
static void *sym(void *h, const char *n)
{
	void *p = dlsym(h, n);
	if (!p) {
		fprintf(stderr, "%s\n", dlerror());
		exit(2);
	}
	return p;
}
static ptrdiff_t off(const unsigned char *p, const unsigned char *base)
{
	return p ? p - base : -1;
}
#define NUMBER(X, n)                                                                               \
	X(sizeof_implicit_##n)                                                                     \
	X(sizeof_##n) X(blob_encode_implicit_##n) X(blob_encode_##n) X(encode_implicit_##n)        \
	    X(encode_##n)
#define ALL(X)                                                                                     \
	X(blob_decode_seqii)                                                                       \
	X(blob_decode_seqii_strict) X(decode_seqii) X(decode_seqii_strict) NUMBER(X, integer)      \
	    NUMBER(X, octet_string) NUMBER(X, uint64) NUMBER(X, raw_octet_string)                  \
	        X(sizeof_implicit_raw_octet_string_overflow) X(sizeof_oid) X(blob_encode_oid)      \
	            X(encode_oid) X(blob_decode_oid) X(decode_oid) X(blob_decode_bitstring)        \
	                X(decode_bitstring) X(blob_decode_uint) X(blob_decode_uint_strict)         \
	                    X(decode_uint) X(decode_uint_strict) X(blob_decode_uint_n)             \
	                        X(decode_uint_n) X(blob_decode_uint64) X(decode_uint64)
#define FIELD(n) __typeof__(&ccder_##n) fn_##n;
struct api {
	ALL(FIELD)
};
static void decode(struct api *f, const unsigned char *data, size_t size)
{
	struct ccder_read_blob b[2], v[2];
	bool ok[2];
	const unsigned char *p[2], *value[2];
	size_t n[2];
	uint64_t x[2];
	for (int strict = 0; strict < 2; strict++)
		for (size_t limbs = 0; limbs < 5; limbs++) {
			cc_unit out[2][6];
			memset(out, 0xa5, sizeof(out));
			for (int i = 0; i < 2; i++) {
				b[i] = (struct ccder_read_blob){data, data ? data + size : NULL};
				ok[i] =
				    (strict ? f[i].fn_blob_decode_uint_strict
				            : f[i].fn_blob_decode_uint)(b + i, limbs, out[i] + 1);
			}
			num("uint result", ok[0], ok[1]);
			same("uint progress", b, b + 1, sizeof(b[0]));
			same("uint output", out, out + 1, sizeof(out[0]));
			memset(out, 0xa5, sizeof(out));
			for (int i = 0; i < 2; i++)
				p[i] = (strict ? f[i].fn_decode_uint_strict : f[i].fn_decode_uint)(
				    limbs, out[i] + 1, data, data ? data + size : NULL);
			same("uint wrapper pointer", p, p + 1, sizeof(p[0]));
			same("uint wrapper output", out, out + 1, sizeof(out[0]));
		}
	for (int strict = 0; strict < 2; strict++)
		for (size_t limbs = 0; limbs < 5; limbs++) {
			cc_unit r[2][6], t[2][6];
			memset(r, 0xa5, sizeof(r));
			memset(t, 0x5a, sizeof(t));
			for (int i = 0; i < 2; i++) {
				b[i] = (struct ccder_read_blob){data, data ? data + size : NULL};
				ok[i] = (strict ? f[i].fn_blob_decode_seqii_strict
				                : f[i].fn_blob_decode_seqii)(
				    b + i, limbs, r[i] + 1, t[i] + 1);
			}
			num("seqii result", ok[0], ok[1]);
			same("seqii progress", b, b + 1, sizeof(b[0]));
			same("seqii r", r, r + 1, sizeof(r[0]));
			same("seqii s", t, t + 1, sizeof(t[0]));
			memset(r, 0xa5, sizeof(r));
			memset(t, 0x5a, sizeof(t));
			for (int i = 0; i < 2; i++)
				p[i] =
				    (strict ? f[i].fn_decode_seqii_strict : f[i].fn_decode_seqii)(
				        limbs, r[i] + 1, t[i] + 1, data, data ? data + size : NULL);
			same("seqii wrapper pointer", p, p + 1, sizeof(p[0]));
			same("seqii wrapper r", r, r + 1, sizeof(r[0]));
			same("seqii wrapper s", t, t + 1, sizeof(t[0]));
		}
	for (int i = 0; i < 2; i++) {
		b[i] = (struct ccder_read_blob){data, data ? data + size : NULL};
		n[i] = 999;
		ok[i] = f[i].fn_blob_decode_uint_n(b + i, n + i);
	}
	num("uint_n result", ok[0], ok[1]);
	same("uint_n output", n, n + 1, sizeof(n[0]));
	same("uint_n progress", b, b + 1, sizeof(b[0]));
	for (int i = 0; i < 2; i++) {
		n[i] = 999;
		p[i] = f[i].fn_decode_uint_n(n + i, data, data ? data + size : NULL);
	}
	same("uint_n wrapper pointer", p, p + 1, sizeof(p[0]));
	same("uint_n wrapper value", n, n + 1, sizeof(n[0]));
	for (int null = 0; null < 2; null++) {
		for (int i = 0; i < 2; i++) {
			b[i] = (struct ccder_read_blob){data, data ? data + size : NULL};
			x[i] = 999;
			ok[i] = f[i].fn_blob_decode_uint64(b + i, null ? NULL : x + i);
		}
		num("uint64 result", ok[0], ok[1]);
		same("uint64 value", x, x + 1, sizeof(x[0]));
		same("uint64 progress", b, b + 1, sizeof(b[0]));
		for (int i = 0; i < 2; i++) {
			x[i] = 999;
			p[i] = f[i].fn_decode_uint64(
			    null ? NULL : x + i, data, data ? data + size : NULL);
		}
		same("uint64 wrapper pointer", p, p + 1, sizeof(p[0]));
		same("uint64 wrapper value", x, x + 1, sizeof(x[0]));
	}
	for (int i = 0; i < 2; i++) {
		b[i] = (struct ccder_read_blob){data, data ? data + size : NULL};
		ok[i] = f[i].fn_blob_decode_oid(b + i, value + i);
	}
	num("oid result", ok[0], ok[1]);
	same("oid value", value, value + 1, sizeof(value[0]));
	same("oid progress", b, b + 1, sizeof(b[0]));
	for (int i = 0; i < 2; i++)
		p[i] = f[i].fn_decode_oid(value + i, data, data ? data + size : NULL);
	same("oid wrapper pointer", p, p + 1, sizeof(p[0]));
	same("oid wrapper value", value, value + 1, sizeof(value[0]));
	for (int i = 0; i < 2; i++) {
		b[i] = (struct ccder_read_blob){data, data ? data + size : NULL};
		n[i] = 999;
		ok[i] = f[i].fn_blob_decode_bitstring(b + i, v + i, n + i);
	}
	num("bitstring result", ok[0], ok[1]);
	same("bitstring progress", b, b + 1, sizeof(b[0]));
	same("bitstring range", v, v + 1, sizeof(v[0]));
	same("bitstring bits", n, n + 1, sizeof(n[0]));
	for (int i = 0; i < 2; i++) {
		n[i] = 999;
		value[i] = data;
		p[i] = f[i].fn_decode_bitstring(value + i, n + i, data, data ? data + size : NULL);
	}
	same("bitstring wrapper pointer", p, p + 1, sizeof(p[0]));
	same("bitstring wrapper value", value, value + 1, sizeof(value[0]));
	same("bitstring wrapper bits", n, n + 1, sizeof(n[0]));
}
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	void *h[2] = {
	    dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL | RTLD_FIRST),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST)};
	if (!h[0] || !h[1])
		return 2;
	struct api f[2];
	for (int i = 0; i < 2; i++) {
#define LOAD1(n) f[i].fn_##n = sym(h[i], "ccder_" #n);
#define LOAD(n) LOAD1(n)
		ALL(LOAD)
	}
	unsigned char data[128], out[2][160];
	cc_unit limbs[8];
	uint64_t state = 7;
	for (size_t words = 0; words <= 8; words++)
		for (size_t trial = 0; trial < 40; trial++) {
			for (size_t j = 0; j < 8; j++) {
				state ^= state << 13;
				state ^= state >> 7;
				state ^= state << 17;
				limbs[j] = trial == 0 ? 0
				    : trial == 1      ? UINT64_MAX
				    : trial == 2      ? 128
				                      : state;
			}
			for (size_t capacity = 0; capacity < 70; capacity++)
				for (int kind = 0; kind < 3; kind++) {
					/* System octet encoding writes outside the body for zero; test that
             * safety difference below instead of requiring the overrun. */
					if (kind == 1 && (!words || trial == 0))
						continue;
					ccder_tag tag =
					    trial & 1 ? 4 : UINT64_C(0xa000000000000023);
					struct ccder_blob b[2];
					bool ok[2];
					unsigned char *p[2];
					for (int implicit = 0; implicit < 2; implicit++) {
						size_t sizes[2];
						memset(out, 0xa5, sizeof(out));
						for (int i = 0; i < 2; i++) {
							b[i] = (struct ccder_blob){
							    out[i] + 8, out[i] + 8 + capacity};
							if (kind == 0) {
								sizes[i] = implicit
								    ? f[i].fn_sizeof_implicit_integer(
								          tag, words, limbs)
								    : f[i].fn_sizeof_integer(
								          words, limbs);
								ok[i] = implicit
								    ? f[i].fn_blob_encode_implicit_integer(
								          b + i, tag, words, limbs)
								    : f[i].fn_blob_encode_integer(
								          b + i, words, limbs);
							} else if (kind == 1) {
								sizes[i] = implicit
								    ? f[i].fn_sizeof_implicit_octet_string(
								          tag, words, limbs)
								    : f[i].fn_sizeof_octet_string(
								          words, limbs);
								ok[i] = implicit
								    ? f[i].fn_blob_encode_implicit_octet_string(
								          b + i, tag, words, limbs)
								    : f[i].fn_blob_encode_octet_string(
								          b + i, words, limbs);
							} else {
								sizes[i] = implicit
								    ? f[i].fn_sizeof_implicit_uint64(
								          tag, limbs[0])
								    : f[i].fn_sizeof_uint64(
								          limbs[0]);
								ok[i] = implicit
								    ? f[i].fn_blob_encode_implicit_uint64(
								          b + i, tag, limbs[0])
								    : f[i].fn_blob_encode_uint64(
								          b + i, limbs[0]);
							}
						}
						same("encode size", sizes, sizes + 1,
						    sizeof(sizes[0]));
						num("encode result", ok[0], ok[1]);
						num("encode position", off(b[0].end, out[0]),
						    off(b[1].end, out[1]));
						same("encode data", out, out + 1, sizeof(out[0]));
						memset(out, 0xa5, sizeof(out));
						for (int i = 0; i < 2; i++) {
							unsigned char *start = out[i] + 8,
							              *end = start + capacity;
							if (kind == 0)
								p[i] = implicit
								    ? f[i].fn_encode_implicit_integer(
								          tag, words, limbs, start,
								          end)
								    : f[i].fn_encode_integer(
								          words, limbs, start, end);
							else if (kind == 1)
								p[i] = implicit
								    ? f[i].fn_encode_implicit_octet_string(
								          tag, words, limbs, start,
								          end)
								    : f[i].fn_encode_octet_string(
								          words, limbs, start, end);
							else
								p[i] = implicit
								    ? f[i].fn_encode_implicit_uint64(
								          tag, limbs[0], start, end)
								    : f[i].fn_encode_uint64(
								          limbs[0], start, end);
						}
						num("encode wrapper pointer", off(p[0], out[0]),
						    off(p[1], out[1]));
						same("encode wrapper data", out, out + 1,
						    sizeof(out[0]));
					}
				}
		}
	for (size_t size = 0; size < 100; size++)
		for (size_t capacity = 0; capacity < 105; capacity++)
			for (int implicit = 0; implicit < 2; implicit++)
				for (int null = 0; null < 2; null++) {
					memset(data, 0x3c, sizeof(data));
					const void *input = null ? NULL : data;
					ccder_tag tag = UINT64_C(0xa000000000000023);
					struct ccder_blob b[2];
					bool ok[2];
					unsigned char *p[2];
					size_t sizes[2];
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++) {
						sizes[i] = implicit
						    ? f[i].fn_sizeof_implicit_raw_octet_string(
						          tag, size)
						    : f[i].fn_sizeof_raw_octet_string(size);
						b[i] = (struct ccder_blob){
						    out[i] + 8, out[i] + 8 + capacity};
						ok[i] = implicit
						    ? f[i].fn_blob_encode_implicit_raw_octet_string(
						          b + i, tag, size, input)
						    : f[i].fn_blob_encode_raw_octet_string(
						          b + i, size, input);
					}
					same("raw size", sizes, sizes + 1, sizeof(sizes[0]));
					num("raw result", ok[0], ok[1]);
					num("raw progress", off(b[0].end, out[0]),
					    off(b[1].end, out[1]));
					same("raw data", out, out + 1, sizeof(out[0]));
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++)
						p[i] = implicit
						    ? f[i].fn_encode_implicit_raw_octet_string(tag,
						          size, input, out[i] + 8,
						          out[i] + 8 + capacity)
						    : f[i].fn_encode_raw_octet_string(size, input,
						          out[i] + 8, out[i] + 8 + capacity);
					num("raw wrapper pointer", off(p[0], out[0]),
					    off(p[1], out[1]));
					same("raw wrapper data", out, out + 1, sizeof(out[0]));
					if (null)
						continue; /* The system OID helper requires a nonnull pointer. */
					data[0] = 6;
					data[1] = (unsigned char)size;
					input = data;
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++) {
						sizes[i] = f[i].fn_sizeof_oid(input);
						b[i] = (struct ccder_blob){
						    out[i] + 8, out[i] + 8 + capacity};
						ok[i] = f[i].fn_blob_encode_oid(b + i, input);
					}
					same("oid size", sizes, sizes + 1, sizeof(sizes[0]));
					num("oid encode result", ok[0], ok[1]);
					num("oid encode progress", off(b[0].end, out[0]),
					    off(b[1].end, out[1]));
					same("oid encode data", out, out + 1, sizeof(out[0]));
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++)
						p[i] = f[i].fn_encode_oid(
						    input, out[i] + 8, out[i] + 8 + capacity);
					num("oid encode wrapper pointer", off(p[0], out[0]),
					    off(p[1], out[1]));
					same("oid encode wrapper data", out, out + 1,
					    sizeof(out[0]));
				}
	size_t lengths[] = {0, 1, 127, 128, UINT32_MAX, SIZE_MAX - 9, SIZE_MAX - 2, SIZE_MAX};
	for (size_t j = 0; j < sizeof(lengths) / sizeof(lengths[0]); j++)
		for (int already = 0; already < 2; already++) {
			bool overflow[2] = {already, already};
			size_t sizes[2];
			for (int i = 0; i < 2; i++)
				sizes[i] = f[i].fn_sizeof_implicit_raw_octet_string_overflow(
				    4, lengths[j], overflow + i);
			same("raw overflow size", sizes, sizes + 1, sizeof(sizes[0]));
			same("raw overflow flag", overflow, overflow + 1, sizeof(overflow[0]));
		}
	for (unsigned first = 0; first < 35; first++)
		for (unsigned second = 0; second < 35; second++)
			for (int extra = 0; extra < 3; extra++) {
				memset(data, 0x81, sizeof(data));
				size_t size = 6 + first + second + extra;
				data[0] = 0x30;
				data[1] = (unsigned char)(size - 2);
				data[2] = 2;
				data[3] = (unsigned char)first;
				data[4] = 0;
				data[4 + first] = 2;
				data[5 + first] = (unsigned char)second;
				data[6 + first] = 0;
				decode(f, data, size);
				decode(f, data, size - 1);
			}
	decode(f, NULL, 0);
	for (unsigned trial = 0; trial < 4000; trial++) {
		for (size_t j = 0; j < sizeof(data); j++) {
			state ^= state << 13;
			state ^= state >> 7;
			state ^= state << 17;
			data[j] = (unsigned char)state;
		}
		size_t length = trial % 80;
		data[0] = (unsigned char)(2 + trial % 5);
		data[1] = (unsigned char)length;
		if (trial % 3 == 0) {
			data[2] = 0;
			data[3] = (unsigned char)(trial % 256);
		}
		for (size_t size = length; size <= length + 3; size++)
			decode(f, data, size);
		data[1] = 0x81;
		data[2] = (unsigned char)length;
		decode(f, data, length + 3);
	}
	memset(out, 0xa5, sizeof(out));
	struct ccder_blob b = {out[1] + 8, out[1] + 10};
	cc_unit zero = 0;
	num("safe zero octet result", f[1].fn_blob_encode_octet_string(&b, 1, &zero), 1);
	out[0][8] = 4;
	out[0][9] = 0;
	same("safe zero octet guard", out, out + 1, sizeof(out[0]));
	printf("DER values: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
