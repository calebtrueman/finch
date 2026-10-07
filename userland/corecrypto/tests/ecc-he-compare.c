/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "../abi/cche.h"
#include "he-symbol-owner.h"
static int tests;
#define CHECK(x)                                                                                   \
	do {                                                                                       \
		tests++;                                                                           \
		if (!(x)) {                                                                        \
			fprintf(stderr, "line%d %s\n", __LINE__, #x);                              \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
struct api {
	size_t (*size)(unsigned);
	int (*init)(void *, unsigned, unsigned);
	int (*ep)(void *, void *, uint32_t, const void *);
	int (*dp)(uint32_t, void *, void *);
	int (*es)(void *, void *, uint32_t, const void *);
	int (*ds)(void *, uint32_t, void *, void *);
	int (*fwd)(void *), (*inv)(void *);
	int (*pack)(size_t, void *, size_t, const void *, unsigned),
	    (*unpack)(size_t, void *, size_t, const void *, unsigned);
};
static void load(void *h, struct api *a)
{
	a->size = dlsym(h, "cche_param_ctx_sizeof");
	a->init = dlsym(h, "cche_param_ctx_init");
	a->ep = dlsym(h, "cche_encode_poly_uint64");
	a->dp = dlsym(h, "cche_decode_poly_uint64");
	a->es = dlsym(h, "cche_encode_simd_uint64");
	a->ds = dlsym(h, "cche_decode_simd_uint64");
	a->fwd = dlsym(h, "cche_ciphertext_fwd_ntt");
	a->inv = dlsym(h, "cche_ciphertext_inv_ntt");
	a->pack = dlsym(h, "cche_coeffs_to_bytes");
	a->unpack = dlsym(h, "cche_bytes_to_coeffs");
}
int main(int argc, char **argv)
{
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", 2),
	     *f = dlopen(argc > 1 ? argv[1] : "/tmp/ecc-he-test.dylib", 2);
	CHECK(h && f);
	finch_test_set_local(f, argc > 1 ? argv[1] : "/tmp/ecc-he-test.dylib");
	struct api a[2];
	load(h, a);
	load(f, a + 1);
	for (unsigned id = 0; id < 17; id++) {
		CHECK(a[0].size(id) == a[1].size(id));
		struct he_params *p[2] = {calloc(1, a[0].size(id)), calloc(1, a[1].size(id))};
		for (int i = 0; i < 2; i++)
			CHECK(a[i].init(p[i], 1, id) == 0);
		CHECK(!memcmp(p[0], p[1], 32 + 8 * p[0]->l));
		size_t ps = 8 + 8 * p[0]->n;
		void *poly[2] = {calloc(1, ps), calloc(1, ps)};
		uint64_t *values = malloc(p[0]->n * 8), *out = malloc(p[0]->n * 8);
		for (unsigned j = 0; j < p[0]->n; j++)
			values[j] = (7 * j + 3) % p[0]->t;
		for (int context = 0; context < 2; context++) {
			for (int i = 0; i < 2; i++)
				CHECK(a[i].ep(poly[i], p[context], p[context]->n, values) == 0);
			CHECK(!memcmp(poly[0], poly[1], ps));
			for (int i = 0; i < 2; i++) {
				CHECK(a[i].dp(p[context]->n, out, poly[1 - i]) == 0);
				CHECK(!memcmp(out, values, 8 * p[context]->n));
			}
			if (p[context]->t % (2 * p[context]->n) == 1) {
				for (int i = 0; i < 2; i++)
					CHECK(a[i].es(poly[i], p[context], p[context]->n, values) ==
					    0);
				if (memcmp(poly[0], poly[1], ps)) {
					fprintf(stderr, "SIMD id%u ctx%d mismatch\n", id, context);
					return 1;
				}
				CHECK(!memcmp(poly[0], poly[1], ps));
				for (int i = 0; i < 2; i++) {
					CHECK(a[i].ds(p[context], p[context]->n, out,
					          poly[1 - i]) == 0);
					CHECK(!memcmp(out, values, 8 * p[context]->n));
				}
			}
			size_t cs = 24 + 2 * (8 + 8 * (size_t)p[context]->n * p[context]->l);
			unsigned char *ct[2] = {calloc(1, cs), calloc(1, cs)};
			for (int i = 0; i < 2; i++) {
				struct he_cipher *c = (void *)ct[i];
				c->params = p[context];
				c->npolys = 2;
				c->correction = 1;
				struct he_ring *r =
				    (void *)((char *)p[context] + 40 + 8 * p[context]->l);
				for (unsigned pol = 0; pol < 2; pol++) {
					struct he_poly *cp =
					    (void *)(c->data + pol * (8 + 8 * (size_t)r->n * r->l));
					cp->ctx = r;
					for (unsigned j = 0; j < r->n * r->l; j++)
						cp->data[j] = j + 1;
				}
				CHECK(a[i].fwd(c) == 0);
			}
			CHECK(!memcmp(ct[0], ct[1], cs));
			for (int i = 0; i < 2; i++)
				CHECK(a[i].inv(ct[i]) == 0);
			CHECK(!memcmp(ct[0], ct[1], cs));
			free(ct[0]);
			free(ct[1]);
		}
		free(values);
		free(out);
		free(poly[0]);
		free(poly[1]);
		free(p[0]);
		free(p[1]);
	}
	for (unsigned bits = 1; bits <= 64; bits++) {
		uint64_t c[16], d0[16] = {0}, d1[16] = {0};
		for (unsigned j = 0; j < 16; j++)
			c[j] = ((uint64_t)j * 0x19239485abcde) & (~(uint64_t)0 >> (64 - bits));
		unsigned char b0[128] = {0}, b1[128] = {0};
		size_t bn = (bits * 16 + 7) / 8;
		CHECK(a[0].pack(bn, b0, 16, c, bits) == 0);
		CHECK(a[1].pack(bn, b1, 16, c, bits) == 0);
		CHECK(!memcmp(b0, b1, bn));
		CHECK(a[0].unpack(16, d0, bn, b0, bits) == 0);
		CHECK(a[1].unpack(16, d1, bn, b0, bits) == 0);
		CHECK(!memcmp(d0, d1, sizeof d0));
	}
	void *libs[2] = {h, f};
	int (*crt[2])(size_t, void *, const void *, unsigned, const void *);
	for (unsigned i = 0; i < 2; i++)
		crt[i] = dlsym(libs[i], "cche_crt_compose");
	uint64_t moduli[3] = {17, 37, 11};
	int64_t residues[30], composed[2][10];
	for (unsigned k = 0; k < 3; k++)
		for (int j = 0; j < 10; j++)
			residues[k * 10 + j] = ((int64_t)j * 817 - 993) % (int64_t)moduli[k];
	for (unsigned l = 1; l <= 3; l++) {
		CHECK(crt[0](10, composed[0], residues, l, moduli) == 0);
		CHECK(crt[1](10, composed[1], residues, l, moduli) == 0);
		CHECK(!memcmp(composed[0], composed[1], 80));
	}
	void *params = calloc(1, a[1].size(0));
	CHECK(a[1].init(params, 1, 0) == 0);
	for (unsigned x = 0; x < 35; x++) {
		int (*iv[2])(void *, void *, uint64_t);
		uint64_t z[2] = {0};
		int rc[2];
		for (unsigned i = 0; i < 2; i++) {
			iv[i] = dlsym(libs[i], "cche_param_ctx_plaintext_modulus_inverse");
			rc[i] = iv[i](z + i, params, x);
		}
		CHECK(rc[0] == rc[1]);
		if (!rc[0])
			CHECK(z[0] == z[1]);
	}
	free(params);
	for (unsigned n = 8; n <= 8192; n *= 2)
		for (int step = -5; step <= 5; step++)
			for (unsigned direction = 0; direction < 2; direction++) {
				uint32_t g[2] = {0};
				int rc[2];
				for (unsigned i = 0; i < 2; i++) {
					int (*rot)(void *, int, unsigned) = dlsym(libs[i],
					    direction
					        ? "cche_ciphertext_galois_elt_rotate_rows_left"
					        : "cche_ciphertext_galois_elt_rotate_rows_right");
					rc[i] = rot(g + i, step, n);
				}
				CHECK(rc[0] == rc[1]);
				if (!rc[0])
					CHECK(g[0] == g[1]);
			}
	printf("HE foundations: %d checks passed\n", tests);
}
