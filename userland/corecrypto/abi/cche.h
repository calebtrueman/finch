/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_CCHE_H
#define FINCH_CCHE_H
#include <stdint.h>
#include <stddef.h>
struct he_params {
	uint32_t scheme, pad;
	uint64_t t;
	uint32_t n, skip[2], l;
	uint64_t q[];
};
struct he_ring {
	uint32_t n, l;
	uint64_t ntt;
	uint64_t mod[6], inv_last[3], inv_n[3];
	struct he_ring *next;
	unsigned char data[];
};
struct he_poly {
	struct he_ring *ctx;
	uint64_t data[];
};
struct he_cipher {
	const struct he_params *params;
	uint32_t npolys, pad;
	uint64_t correction;
	unsigned char data[];
};
size_t finch_he_ring_size(uint32_t n);
struct he_ring *finch_he_ring(const struct he_params *, uint32_t l);
struct he_ring *finch_he_plain_ring(const struct he_params *);
struct he_poly *finch_he_poly(struct he_cipher *, uint32_t);
uint64_t finch_he_modulus(const struct he_ring *, uint32_t);
uint64_t finch_he_mul(uint64_t, uint64_t, uint64_t);
uint64_t finch_he_pow(uint64_t, uint64_t, uint64_t);
int finch_he_ntt(struct he_poly *, int inverse);
int finch_he_pack(size_t, void *, size_t, const uint64_t *, unsigned, unsigned);
int finch_he_unpack(size_t, uint64_t *, size_t, const void *, unsigned, unsigned);
#endif
