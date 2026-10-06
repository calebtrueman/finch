/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Minimal <corecrypto/ccrng.h> for Finch: the system-RNG subset Libc's
 * arc4random uses (ccrng(), ccrng_generate(), ccrng_uniform()). It isn't
 * Apple's corecrypto, which is closed. This header-only version draws
 * directly from the kernel CSPRNG via getentropy(2), so nothing links
 * libcorecrypto. Every request is a system call; a userspace generator seeded
 * from the kernel would be faster (TODO), but this one is simple and correct.
 */

#ifndef _FINCH_CORECRYPTO_CCRNG_H_
#define _FINCH_CORECRYPTO_CCRNG_H_

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/random.h>

#define CCERR_OK 0
#define CCERR_INTERNAL -1
#define CCERR_PARAMETER -2

struct ccrng_state {
	int (*generate)(struct ccrng_state *rng, size_t outlen, void *out);
};

static inline int
_finch_ccrng_getentropy(struct ccrng_state *rng, size_t outlen, void *out)
{
	uint8_t *p = (uint8_t *)out;
	(void)rng;
	while (outlen > 0) {
		size_t n = outlen > 256 ? 256 : outlen;   /* getentropy(2) limit */
		if (getentropy(p, n) != 0) {
			return CCERR_INTERNAL;
		}
		p += n;
		outlen -= n;
	}
	return CCERR_OK;
}

/* The process-wide system RNG. */
static inline struct ccrng_state *
ccrng(int *error)
{
	static struct ccrng_state system_rng = { _finch_ccrng_getentropy };
	if (error) {
		*error = CCERR_OK;
	}
	return &system_rng;
}

#define ccrng_generate(rng, outlen, out) ((rng)->generate((rng), (outlen), (out)))

/* Uniform value in [0, bound), by rejection sampling (no modulo bias). */
static inline int
ccrng_uniform(struct ccrng_state *rng, uint64_t bound, uint64_t *rand)
{
	uint64_t r, threshold;
	int err;

	if (bound == 0) {
		return CCERR_PARAMETER;
	}
	threshold = (0 - bound) % bound;   /* 2^64 mod bound */
	do {
		if ((err = ccrng_generate(rng, sizeof(r), &r)) != CCERR_OK) {
			return err;
		}
	} while (r < threshold);
	*rand = r % bound;
	return CCERR_OK;
}

#endif /* _FINCH_CORECRYPTO_CCRNG_H_ */
