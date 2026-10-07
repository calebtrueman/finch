/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct cmac_ctx {
    unsigned char subkey1[16], subkey2[16], pending[16];
    size_t used, processed;
    const struct ccmode_cbc *cbc;
    unsigned char key[];
};
static size_t context_size(const struct ccmode_cbc *cbc)
{ return 80 + cbc->size + cbc->block_size; }
static void wipe(void *p, size_t n)
{ volatile unsigned char *b = p; while(n--) *b++ = 0; }
static void double_block(const unsigned char in[16], unsigned char out[16])
{
    unsigned carry = 0, top = in[0] >> 7;
    for (size_t i = 16; i--;) { unsigned next = in[i] >> 7; out[i] = (in[i] << 1) | carry; carry = next; }
    out[15] ^= 0x87 & (0 - top);
}
EXPORT int cccmac_init(const struct ccmode_cbc *cbc, void *memory, size_t key_size, const void *key)
{
    if ((key_size != 16 && key_size != 24 && key_size != 32) || cbc->block_size != 16) return -7;
    struct cmac_ctx *ctx = memory;
    int result = cbc->init(cbc, ctx->key, key_size, key);
    if (result) return result;
    memset(ctx->key + cbc->size, 0, 16);
    ctx->used = 0; ctx->processed = 0; ctx->cbc = cbc;
    unsigned char zero[16] = {0}, iv[16] = {0}, block[16];
    result = cbc->cbc(ctx->key, iv, 1, zero, block);
    if (!result) { double_block(block, ctx->subkey1); double_block(ctx->subkey1, ctx->subkey2); }
    wipe(block, sizeof(block)); wipe(iv, sizeof(iv));
    return result;
}
EXPORT int cccmac_update(void *memory, size_t size, const void *input)
{
    struct cmac_ctx *ctx = memory;
    if (!size || !input) return 0;
    if (ctx->used > 16) return -1;
    const struct ccmode_cbc *cbc = ctx->cbc;
    const unsigned char *in = input;
    unsigned char output[256];
    if (ctx->used) {
        size_t take = 16 - ctx->used; if (take > size) take = size;
        memcpy(ctx->pending + ctx->used, in, take); ctx->used += take;
        in += take; size -= take; if (!size) return 0;
        int r = cbc->cbc(ctx->key, ctx->key + cbc->size, 1, ctx->pending, output);
        if (r) { wipe(output, sizeof(output)); return r; }
        /* This field counts blocks flushed from pending, matching the host. */
        ctx->processed += 16;
    }
    while (size > 16) {
        size_t blocks = (size - 1) / 16; if (blocks > 16) blocks = 16;
        int r = cbc->cbc(ctx->key, ctx->key + cbc->size, blocks, in, output);
        if (r) { wipe(output, sizeof(output)); return r; }
        in += blocks * 16; size -= blocks * 16;
    }
    memcpy(ctx->pending, in, size); ctx->used = size;
    wipe(output, sizeof(output));
    return 0;
}
EXPORT int cccmac_final_generate(void *memory, size_t tag_size, void *tag)
{
    struct cmac_ctx *ctx = memory;
    const struct ccmode_cbc *cbc = ctx->cbc;
    size_t bytes = context_size(cbc);
    ctx->processed += ctx->used;
    int result = -1;
    if (ctx->used <= 16 && tag_size && tag_size <= 16 && (ctx->used || !ctx->processed)) {
        const unsigned char *subkey = ctx->subkey1;
        if (ctx->used != 16) {
            subkey = ctx->subkey2;
            memset(ctx->pending + ctx->used, 0, 16 - ctx->used);
            ctx->pending[ctx->used] = 0x80;
        }
        for (size_t i = 0; i < 16; i++) ctx->pending[i] ^= subkey[i];
        unsigned char block[16];
        result = cbc->cbc(ctx->key, ctx->key + cbc->size, 1, ctx->pending, block);
        if (!result) memcpy(tag, block, tag_size);
        wipe(block, sizeof(block));
    }
    wipe(ctx, bytes);
    return result;
}
EXPORT int cccmac_final_verify(void *memory, size_t tag_size, const void *tag)
{
    unsigned char expected[16];
    int result = cccmac_final_generate(memory, 16, expected);
    if (result) return -1;
    unsigned difference = !tag_size;
    if (tag_size > 16) result = -1;
    else {
        const unsigned char *bytes = tag;
        for (size_t i = 0; i < tag_size; i++) difference |= expected[i] ^ bytes[i];
        result = difference ? -5 : 0;
    }
    wipe(expected, sizeof(expected));
    return result;
}
EXPORT int cccmac_one_shot_generate(const struct ccmode_cbc *cbc, size_t key_size,
    const void *key, size_t size, const void *input, size_t tag_size, void *tag)
{
    _Alignas(16) unsigned char ctx[context_size(cbc)];
    int result = cccmac_init(cbc, ctx, key_size, key);
    if (!result) result = cccmac_update(ctx, size, input);
    if (!result) result = cccmac_final_generate(ctx, tag_size, tag);
    wipe(ctx, sizeof(ctx)); return result;
}
EXPORT int cccmac_one_shot_verify(const struct ccmode_cbc *cbc, size_t key_size,
    const void *key, size_t size, const void *input, size_t tag_size, const void *tag)
{
    _Alignas(16) unsigned char ctx[context_size(cbc)];
    int result = cccmac_init(cbc, ctx, key_size, key);
    if (!result) result = cccmac_update(ctx, size, input);
    if (!result) result = cccmac_final_verify(ctx, tag_size, tag);
    wipe(ctx, sizeof(ctx)); return result;
}

EXPORT int ccnistkdf_ctr_cmac_fixed(const struct ccmode_cbc *cbc, unsigned counter_bits,
    size_t key_size, const void *key, size_t fixed_size, const void *fixed,
    size_t output_size, void *output)
{
    if (!output_size || !key_size || !key || !output || cbc->block_size != 16 ||
        (counter_bits != 8 && counter_bits != 16 && counter_bits != 24 && counter_bits != 32)) return -7;
    uint64_t blocks = output_size / 16 + !!(output_size % 16);
    if (blocks >> counter_bits) return -7;
    _Alignas(16) unsigned char base[context_size(cbc)], ctx[sizeof(base)];
    int result = cccmac_init(cbc, base, key_size, key);
    unsigned char *out = output, block[16];
    for (uint64_t counter = 1; !result && output_size; counter++) {
        unsigned char index[4];
        for (unsigned i = 0; i < 4; i++) index[i] = counter >> (24 - 8 * i);
        memcpy(ctx, base, sizeof(ctx));
        result = cccmac_update(ctx, counter_bits / 8, index + 4 - counter_bits / 8);
        if (!result) result = cccmac_update(ctx, fixed_size, fixed);
        if (!result) result = cccmac_final_generate(ctx, 16, block);
        if (!result) {
            size_t take = output_size < 16 ? output_size : 16;
            memcpy(out, block, take); out += take; output_size -= take;
        }
    }
    wipe(base, sizeof(base)); wipe(ctx, sizeof(ctx)); wipe(block, sizeof(block));
    return result;
}

#include <stdlib.h>
EXPORT int ccnistkdf_ctr_cmac(const struct ccmode_cbc *cbc, unsigned counter_bits,
    size_t key_size, const void *key, size_t label_size, const void *label,
    size_t context_bytes, const void *context, size_t output_size,
    size_t length_bytes, void *output)
{
    if (length_bytes > 4 || output_size > ((UINT64_C(1) << (length_bytes * 8)) - 1) / 8 ||
        label_size > SIZE_MAX - 5 ||
        context_bytes > SIZE_MAX - 5 - label_size) return -7;
    size_t fixed_size = label_size + context_bytes + 1 + length_bytes;
    unsigned char *fixed = calloc(1, fixed_size);
    if (!fixed) return -13;
    if (label_size && label) memcpy(fixed, label, label_size);
    if (context_bytes && context) memcpy(fixed + label_size + 1, context, context_bytes);
    for (size_t i = 0; i < length_bytes; i++)
        fixed[fixed_size - 1 - i] = (output_size * 8) >> (i * 8);
    int result = ccnistkdf_ctr_cmac_fixed(cbc, counter_bits, key_size, key, fixed_size, fixed, output_size, output);
    wipe(fixed, fixed_size); free(fixed);
    return result;
}
