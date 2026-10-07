/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_SIV_H
#define FINCH_SIV_H
#include "ccmode.h"
struct ccmode_siv {
	size_t size, block_size;
	int (*init)(const struct ccmode_siv *, void *, size_t, const void *);
	int (*nonce)(void *, size_t, const void *);
	int (*aad)(void *, size_t, const void *);
	int (*crypt)(void *, size_t, const void *, void *);
	int (*reset)(void *);
	const struct ccmode_cbc *cbc;
	const struct ccmode_ctr *ctr;
};
#endif
