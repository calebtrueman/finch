/* SPDX-License-Identifier: MIT OR Apache-2.0
 * HMAC keeps the digest context first, followed at an eight-byte boundary
 * by the precomputed outer chaining state. Both halves use the supplied
 * descriptor, so host and Finch callers can share a context.
 */
#include "cchmac.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))

static void wipe(void *memory, size_t size)
{ volatile unsigned char *p = memory; while (size--) *p++ = 0; }
static void *outer(const struct ccdigest_info *di, void *ctx)
{ return (unsigned char *)ctx + ((ccdigest_di_size(di) + 7) & ~(size_t)7); }
static uint32_t *used(const struct ccdigest_info *di, void *ctx)
{ return (uint32_t *)(ccdigest_data(di, ctx) + di->block_size); }

EXPORT void cchmac_init(const struct ccdigest_info *di, void *ctx, size_t key_size, const void *key)
{
    unsigned char reduced[di->output_size];
    if (key_size > di->block_size) {
        ccdigest(di, key_size, key, reduced);
        key = reduced;
        key_size = di->output_size;
    }
    unsigned char *buffer = ccdigest_data(di, ctx);
    const unsigned char *bytes = key;
    for (size_t i = 0; i < di->block_size; i++) buffer[i] = (i < key_size ? bytes[i] : 0) ^ 0x5c;
    memcpy(outer(di, ctx), di->initial_state, di->state_size);
    di->compress(outer(di, ctx), 1, buffer);
    for (size_t i = 0; i < di->block_size; i++) buffer[i] ^= 0x6a;
    memcpy(ccdigest_state_u8(di, ctx), di->initial_state, di->state_size);
    di->compress(ccdigest_state_u8(di, ctx), 1, buffer);
    *(uint64_t *)ctx = di->block_size * 8;
    *used(di, ctx) = 0;
    wipe(reduced, sizeof(reduced));
}

EXPORT void cchmac_update(const struct ccdigest_info *di, void *ctx, size_t size, const void *input)
{ ccdigest_update(di, ctx, size, input); }

EXPORT void cchmac_final(const struct ccdigest_info *di, void *ctx, void *output)
{
    di->final(di, ctx, ccdigest_data(di, ctx));
    *used(di, ctx) = (uint32_t)di->output_size;
    *(uint64_t *)ctx = di->block_size * 8;
    memcpy(ccdigest_state_u8(di, ctx), outer(di, ctx), di->state_size);
    di->final(di, ctx, output);
}

EXPORT void cchmac(const struct ccdigest_info *di, size_t key_size, const void *key,
    size_t size, const void *input, void *output)
{
    size_t context_size = cchmac_di_size(di);
    _Alignas(16) unsigned char context[context_size];
    cchmac_init(di, context, key_size, key);
    cchmac_update(di, context, size, input);
    cchmac_final(di, context, output);
    wipe(context, sizeof(context));
}
