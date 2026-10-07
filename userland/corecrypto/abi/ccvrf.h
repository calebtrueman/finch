/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_CCVRF_H
#define FINCH_CCVRF_H
#include "ccdigest.h"
struct ccvrf_info {
	size_t public_key_size, secret_key_size, proof_size, hash_size, group_size;
	const struct ccdigest_info *di;
	void *reserved;
	int (*derive_public_key)(const struct ccvrf_info *, const void *, void *);
	int (*prove)(const struct ccvrf_info *, const void *, const void *, size_t, void *);
	int (*verify)(const struct ccvrf_info *, const void *, const void *, size_t, const void *);
	int (*proof_to_hash)(const struct ccvrf_info *, const void *, void *);
};
#endif
