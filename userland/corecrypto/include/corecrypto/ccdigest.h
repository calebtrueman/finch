/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <corecrypto/ccdigest.h>: Finch's message-digest interface, source
 * compatible with the slice of corecrypto that dyld and other system code
 * call: a digest is named by a struct ccdigest_info (ccsha1_di() and so on),
 * its state is declared on the stack with ccdigest_di_decl(), and hashing
 * is ccdigest_init / ccdigest_update / ccdigest_final. Self-contained: no
 * libSystem calls, so dyld can link it statically.
 */

#ifndef _FINCH_CORECRYPTO_CCDIGEST_H_
#define _FINCH_CORECRYPTO_CCDIGEST_H_

#include <stddef.h>
#include <stdint.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

/* Large enough for any supported digest's state (SHA-512 family). */
#define CCDIGEST_MAX_STATE_SIZE 256

struct ccdigest_info {
	size_t output_size;
	size_t state_size;
	size_t block_size;
	void (*init)(void *state);
	void (*update)(void *state, size_t len, const void *data);
	void (*final)(void *state, unsigned char *digest);
};

typedef struct {
	_Alignas(16) unsigned char opaque[CCDIGEST_MAX_STATE_SIZE];
} ccdigest_ctx;

#define ccdigest_di_decl(_di_, _name_) ccdigest_ctx _name_[1]
#define ccdigest_di_clear(_di_, _name_) ccdigest_clear((_di_), (_name_))

void ccdigest_init(const struct ccdigest_info *di, ccdigest_ctx *ctx);
void ccdigest_update(const struct ccdigest_info *di, ccdigest_ctx *ctx, size_t len, const void *data);
void ccdigest_final(const struct ccdigest_info *di, ccdigest_ctx *ctx, unsigned char *digest);
void ccdigest_clear(const struct ccdigest_info *di, ccdigest_ctx *ctx);

/* One-shot. */
void ccdigest(const struct ccdigest_info *di, size_t len, const void *data, void *digest);

__END_DECLS

#endif
