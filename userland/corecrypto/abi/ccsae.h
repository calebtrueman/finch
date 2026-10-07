/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCSAE_H
#define FINCH_ABI_CCSAE_H
#include "cch2c.h"
struct ccsae_ctx {
	const struct cczp *cp;
	struct ccrng_state *rng;
	const struct ccdigest_info *di;
	unsigned char state, maxloops, pad[2];
	unsigned mode;
	const char *keys_label, *hunt_label;
	unsigned char kck[64], pmk[32];
	cc_unit data[];
};
size_t ccsae_sizeof_ctx(const struct cczp *);
size_t ccsae_sizeof_commitment(const struct ccsae_ctx *);
size_t ccsae_sizeof_confirmation(const struct ccsae_ctx *);
size_t ccsae_sizeof_pt(const struct cch2c_info *);
size_t ccsae_sizeof_kck(const struct ccsae_ctx *);
size_t ccsae_sizeof_kck_h2c(const struct ccsae_ctx *);
int ccsae_init(
    struct ccsae_ctx *, const struct cczp *, struct ccrng_state *, const struct ccdigest_info *);
int ccsae_init_p256_sha256(struct ccsae_ctx *, struct ccrng_state *);
int ccsae_init_p384_sha384(struct ccsae_ctx *, struct ccrng_state *);
void ccsae_lexographic_order_key(const void *, size_t, const void *, size_t, void *);
int ccsae_generate_commitment_init(struct ccsae_ctx *);
int ccsae_generate_commitment_partial(struct ccsae_ctx *, const void *, size_t, const void *,
    size_t, const void *, size_t, const void *, size_t, unsigned char);
int ccsae_generate_commitment_finalize(struct ccsae_ctx *, void *);
int ccsae_generate_commitment(struct ccsae_ctx *, const void *, size_t, const void *, size_t,
    const void *, size_t, const void *, size_t, void *);
int ccsae_generate_h2c_pt(const struct cch2c_info *, const void *, size_t, const void *, size_t,
    const void *, size_t, void *);
int ccsae_generate_h2c_commit_init(
    struct ccsae_ctx *, const void *, size_t, const void *, size_t, const void *, size_t);
int ccsae_generate_h2c_commit_finalize(struct ccsae_ctx *, void *);
int ccsae_generate_h2c_commit(
    struct ccsae_ctx *, const void *, size_t, const void *, size_t, const void *, size_t, void *);
int ccsae_verify_commitment(struct ccsae_ctx *, const void *);
int ccsae_verify_commitment_with_rejected_groups(
    struct ccsae_ctx *, const void *, size_t, const void *);
int ccsae_generate_confirmation(struct ccsae_ctx *, const void *, void *);
int ccsae_verify_confirmation(struct ccsae_ctx *, const void *, const void *);
int ccsae_get_keys(struct ccsae_ctx *, void *, void *, void *);
#endif
