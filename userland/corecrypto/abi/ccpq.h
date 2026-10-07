/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_CCPQ_H
#define FINCH_CCPQ_H
#include <stddef.h>
#include <stdint.h>
#include "ccrng.h"
struct cckem_info;
struct cckem_ctx {
	const struct cckem_info *info;
	unsigned char key[];
};
struct cckem_info {
	size_t full_size, private_size, public_size, ciphertext_size, shared_size, seed_size;
	int (*generate)(struct cckem_ctx *, struct ccrng_state *);
	int (*generate_seed)(struct cckem_ctx *, void *, struct ccrng_state *);
	int (*derive)(struct cckem_ctx *, const void *, struct ccrng_state *);
	int (*encapsulate)(const struct cckem_ctx *, void *, void *, struct ccrng_state *);
	int (*decapsulate)(const struct cckem_ctx *, const void *, void *);
	int (*export_public)(const struct cckem_ctx *, size_t *, void *);
	int (*import_public)(const struct cckem_info *, size_t, const void *, struct cckem_ctx *);
	int (*export_private)(const struct cckem_ctx *, size_t *, void *);
	int (*import_private)(const struct cckem_info *, size_t, const void *, struct cckem_ctx *);
};
struct ccmldsa_params {
	uint32_t version, k, l, tau, strength, beta, omega, eta_bytes;
	void (*pack_eta)(unsigned char *, const int32_t *);
	void (*unpack_eta)(int32_t *, const unsigned char *);
	unsigned (*sample_eta)(const unsigned char *, int32_t *, unsigned);
	size_t full_size, private_size, public_size, signature_size;
};
struct ccmldsa_ctx {
	const struct ccmldsa_params *params;
	unsigned char key[];
};
#endif
