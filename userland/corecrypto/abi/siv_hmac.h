/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_SIV_HMAC_H
#define FINCH_SIV_HMAC_H
#include "ccmode.h"
#include "cchmac.h"
struct ccmode_siv_hmac {
	size_t size, block_size;
	int (*init)(const struct ccmode_siv_hmac *, void *, size_t, const void *, size_t);
	int (*nonce)(void *, size_t, const void *);
	int (*aad)(void *, size_t, const void *);
	int (*crypt)(void *, size_t, const void *, void *);
	int (*reset)(void *);
	const struct ccdigest_info *di;
	const struct ccmode_ctr *ctr;
};
#endif
