/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCZP_H
#define FINCH_ABI_CCZP_H
#include "ccn.h"
struct cczp;
struct cczp_funcs {
	void (*add)(void *, const struct cczp *, cc_unit *, const cc_unit *, const cc_unit *);
	void (*sub)(void *, const struct cczp *, cc_unit *, const cc_unit *, const cc_unit *);
	void (*mul)(void *, const struct cczp *, cc_unit *, const cc_unit *, const cc_unit *);
	void (*sqr)(void *, const struct cczp *, cc_unit *, const cc_unit *);
	void (*mod)(void *, const struct cczp *, cc_unit *, const cc_unit *);
	int (*inv)(void *, const struct cczp *, cc_unit *, const cc_unit *);
	int (*sqrt)(void *, const struct cczp *, cc_unit *, const cc_unit *);
	void (*to)(void *, const struct cczp *, cc_unit *, const cc_unit *);
	void (*from)(void *, const struct cczp *, cc_unit *, const cc_unit *);
};
struct cczp {
	size_t n, bitlen;
	const struct cczp_funcs *funcs;
	cc_unit data[];
};
size_t cczp_n(const struct cczp *);
size_t cczp_bitlen(const struct cczp *);
cc_unit *cczp_prime(const struct cczp *);
int cczp_add(const struct cczp *, cc_unit *, const cc_unit *, const cc_unit *);
int cczp_sub(const struct cczp *, cc_unit *, const cc_unit *, const cc_unit *);
int cczp_mul(const struct cczp *, cc_unit *, const cc_unit *, const cc_unit *);
int cczp_mod(const struct cczp *, cc_unit *, const cc_unit *);
int cczp_inv(const struct cczp *, cc_unit *, const cc_unit *);
/* Private Finch helpers. Context storage is 32 + 16*n bytes. */
int finch_cczp_init(struct cczp *, int montgomery);
#endif
