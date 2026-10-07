/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCDRBG_H
#define FINCH_ABI_CCDRBG_H
#include "ccrng.h"
#include "ccdigest.h"
#include "ccmode.h"
#include <stdbool.h>
struct ccdrbg_custom_hmac {
	const struct ccdigest_info *di;
	int strict;
};
struct ccdrbg_df_input {
	const void *data;
	size_t size;
};
struct ccdrbg_df {
	int (*derive)(
	    const struct ccdrbg_df *, size_t, const struct ccdrbg_df_input *, size_t, void *);
	const struct ccmode_cbc *cbc;
	size_t key_size;
	unsigned char reserved[8];
	unsigned char ctx[512];
};
struct ccdrbg_custom_ctr {
	const struct ccmode_ctr *ctr;
	size_t key_size;
	int strict;
	const struct ccdrbg_df *df;
};
struct ccdrbg_hmac_state {
	const struct ccdrbg_custom_hmac *custom;
	unsigned char key[64], v[64];
	uint64_t counter;
	unsigned char reserved[16];
};
struct ccdrbg_ctr_state {
	unsigned char key[32], v[16];
	uint64_t counter;
	const struct ccmode_ctr *ctr;
	size_t key_size;
	int strict;
	unsigned char reserved[4];
	const struct ccdrbg_df *df;
};
void ccdrbg_factory_nisthmac(struct ccdrbg_info *, const struct ccdrbg_custom_hmac *);
void ccdrbg_factory_nistctr(struct ccdrbg_info *, const struct ccdrbg_custom_ctr *);
int ccdrbg_df_bc_init(struct ccdrbg_df *, const struct ccmode_cbc *, size_t);
int ccdrbg_init(const struct ccdrbg_info *, void *, size_t, const void *, size_t, const void *,
    size_t, const void *);
int ccdrbg_reseed(const struct ccdrbg_info *, void *, size_t, const void *, size_t, const void *);
int ccdrbg_generate(const struct ccdrbg_info *, void *, size_t, void *, size_t, const void *);
void ccdrbg_done(const struct ccdrbg_info *, void *);
bool ccdrbg_must_reseed(const struct ccdrbg_info *, void *);
#endif
