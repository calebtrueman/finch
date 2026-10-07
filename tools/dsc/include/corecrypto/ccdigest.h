/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The slice of corecrypto's digest API that the cache builder uses (code
 * directory hashes), implemented on CommonCrypto. Host-tool use only.
 */

#ifndef _FINCH_CCDIGEST_H_
#define _FINCH_CCDIGEST_H_

#include <CommonCrypto/CommonDigest.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum finch_ccdigest_alg { FINCH_CC_SHA1, FINCH_CC_SHA256, FINCH_CC_SHA384 };

struct ccdigest_info {
	size_t output_size;
	enum finch_ccdigest_alg alg;
};

union finch_ccdigest_ctx {
	CC_SHA1_CTX sha1;
	CC_SHA256_CTX sha256;
	CC_SHA512_CTX sha384;   /* SHA-384 uses the SHA-512 context */
};

typedef union finch_ccdigest_ctx *ccdigest_ctx_t;

/* Declares a digest context named `name` on the stack. */
#define ccdigest_di_decl(_di, _name) union finch_ccdigest_ctx _name[1]
#define ccdigest_di_clear(_di, _name) memset((_name), 0, sizeof(union finch_ccdigest_ctx))

static inline void
ccdigest_init(const struct ccdigest_info *di, union finch_ccdigest_ctx *ctx)
{
	switch (di->alg) {
	case FINCH_CC_SHA1: CC_SHA1_Init(&ctx->sha1); break;
	case FINCH_CC_SHA256: CC_SHA256_Init(&ctx->sha256); break;
	case FINCH_CC_SHA384: CC_SHA384_Init(&ctx->sha384); break;
	}
}

static inline void
ccdigest_update(const struct ccdigest_info *di, union finch_ccdigest_ctx *ctx, size_t len, const void *data)
{
	switch (di->alg) {
	case FINCH_CC_SHA1: CC_SHA1_Update(&ctx->sha1, data, (CC_LONG)len); break;
	case FINCH_CC_SHA256: CC_SHA256_Update(&ctx->sha256, data, (CC_LONG)len); break;
	case FINCH_CC_SHA384: CC_SHA384_Update(&ctx->sha384, data, (CC_LONG)len); break;
	}
}

static inline void
ccdigest_final(const struct ccdigest_info *di, union finch_ccdigest_ctx *ctx, unsigned char *out)
{
	switch (di->alg) {
	case FINCH_CC_SHA1: CC_SHA1_Final(out, &ctx->sha1); break;
	case FINCH_CC_SHA256: CC_SHA256_Final(out, &ctx->sha256); break;
	case FINCH_CC_SHA384: CC_SHA384_Final(out, &ctx->sha384); break;
	}
}

#endif
