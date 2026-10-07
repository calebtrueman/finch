/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Key derivation built from Finch's digest/HMAC calls. The calling convention
 * and error values were checked against the local system library.
 */
#include "cchmac.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
static void wipe(void *p, size_t n)
{ volatile unsigned char *b = p; while (n--) *b++ = 0; }
static void counter_bytes(uint32_t value, unsigned char bytes[4])
{ for (unsigned i = 0; i < 4; i++) bytes[i] = value >> (24 - 8 * i); }

EXPORT int cchkdf_extract(const struct ccdigest_info *di, size_t salt_size,
    const void *salt, size_t input_size, const void *input, void *output)
{
    /* An empty HMAC key and a hash-sized zero key have identical padding. */
    cchmac(di, salt_size, salt, input_size, input, output);
    return 0;
}

EXPORT int cchkdf_expand(const struct ccdigest_info *di, size_t key_size,
    const void *key, size_t info_size, const void *info, size_t output_size, void *output)
{
    size_t hash_size = di->output_size;
    if (!hash_size || key_size < hash_size || output_size / hash_size > 255 ||
        (output_size / hash_size == 255 && output_size % hash_size)) return -7;
    _Alignas(16) unsigned char base[cchmac_di_size(di)], ctx[sizeof(base)];
    unsigned char block[hash_size], *out = output;
    size_t previous_size = 0;
    cchmac_init(di, base, key_size, key);
    for (unsigned counter = 1; output_size; counter++) {
        unsigned char byte = counter;
        memcpy(ctx, base, sizeof(ctx));
        cchmac_update(di, ctx, previous_size, block);
        cchmac_update(di, ctx, info_size, info);
        cchmac_update(di, ctx, 1, &byte);
        cchmac_final(di, ctx, block);
        size_t take = output_size < hash_size ? output_size : hash_size;
        memcpy(out, block, take); out += take; output_size -= take;
        previous_size = hash_size;
    }
    wipe(base, sizeof(base)); wipe(ctx, sizeof(ctx)); wipe(block, sizeof(block));
    return 0;
}

EXPORT int cchkdf(const struct ccdigest_info *di, size_t input_size, const void *input,
    size_t salt_size, const void *salt, size_t info_size, const void *info,
    size_t output_size, void *output)
{
    unsigned char key[di->output_size];
    cchkdf_extract(di, salt_size, salt, input_size, input, key);
    int result = cchkdf_expand(di, sizeof(key), key, info_size, info, output_size, output);
    wipe(key, sizeof(key));
    return result;
}

EXPORT int ccpbkdf2_hmac(const struct ccdigest_info *di, size_t password_size,
    const void *password, size_t salt_size, const void *salt, uint64_t rounds,
    size_t output_size, void *output)
{
    size_t hash_size = di->output_size;
    if (!hash_size || output_size / hash_size > UINT32_MAX ||
        (output_size / hash_size == UINT32_MAX && output_size % hash_size)) return -1;
    _Alignas(16) unsigned char base[cchmac_di_size(di)], ctx[sizeof(base)];
    unsigned char u[hash_size], block[hash_size], *out = output;
    cchmac_init(di, base, password_size, password);
    for (uint64_t counter = 1; output_size; counter++) {
        unsigned char index[4]; counter_bytes((uint32_t)counter, index);
        memcpy(ctx, base, sizeof(ctx));
        cchmac_update(di, ctx, salt_size, salt);
        cchmac_update(di, ctx, sizeof(index), index);
        cchmac_final(di, ctx, u); memcpy(block, u, sizeof(block));
        /* The host treats zero rounds as one. */
        for (uint64_t round = 1; round < rounds; round++) {
            memcpy(ctx, base, sizeof(ctx));
            cchmac_update(di, ctx, hash_size, u); cchmac_final(di, ctx, u);
            for (size_t i = 0; i < hash_size; i++) block[i] ^= u[i];
        }
        size_t take = output_size < hash_size ? output_size : hash_size;
        memcpy(out, block, take); out += take; output_size -= take;
    }
    wipe(base, sizeof(base)); wipe(ctx, sizeof(ctx));
    wipe(u, sizeof(u)); wipe(block, sizeof(block));
    return 0;
}

EXPORT int ccansikdf_x963(const struct ccdigest_info *di, size_t secret_size,
    const void *secret, size_t info_size, const void *info, size_t output_size, void *output)
{
    size_t hash_size = di->output_size;
    if (!hash_size || output_size / hash_size > UINT32_MAX - 1 ||
        (output_size / hash_size == UINT32_MAX - 1 && output_size % hash_size)) return -7;
    _Alignas(16) unsigned char base[ccdigest_di_size(di)], ctx[sizeof(base)];
    unsigned char block[hash_size], *out = output;
    ccdigest_init(di, base); ccdigest_update(di, base, secret_size, secret);
    for (uint64_t counter = 1; output_size; counter++) {
        unsigned char index[4]; counter_bytes((uint32_t)counter, index);
        memcpy(ctx, base, sizeof(ctx));
        ccdigest_update(di, ctx, sizeof(index), index);
        ccdigest_update(di, ctx, info_size, info); di->final(di, ctx, block);
        size_t take = output_size < hash_size ? output_size : hash_size;
        memcpy(out, block, take); out += take; output_size -= take;
    }
    wipe(base, sizeof(base)); wipe(ctx, sizeof(ctx)); wipe(block, sizeof(block));
    return 0;
}

EXPORT int ccnistkdf_ctr_hmac_fixed(const struct ccdigest_info *di, size_t key_size,
    const void *key, size_t fixed_size, const void *fixed, size_t output_size, void *output)
{
    size_t hash_size = di->output_size;
    if (!hash_size || !output_size || !key_size || !key || !output ||
        output_size / hash_size > UINT32_MAX ||
        (output_size / hash_size == UINT32_MAX && output_size % hash_size)) return -7;
    _Alignas(16) unsigned char base[cchmac_di_size(di)], ctx[sizeof(base)];
    unsigned char block[hash_size], *out = output;
    cchmac_init(di, base, key_size, key);
    for (uint64_t counter = 1; output_size; counter++) {
        unsigned char index[4]; counter_bytes((uint32_t)counter, index);
        memcpy(ctx, base, sizeof(ctx));
        cchmac_update(di, ctx, sizeof(index), index);
        cchmac_update(di, ctx, fixed_size, fixed); cchmac_final(di, ctx, block);
        size_t take = output_size < hash_size ? output_size : hash_size;
        memcpy(out, block, take); out += take; output_size -= take;
    }
    wipe(base, sizeof(base)); wipe(ctx, sizeof(ctx)); wipe(block, sizeof(block));
    return 0;
}

#include <stdlib.h>
EXPORT int ccnistkdf_ctr_hmac(const struct ccdigest_info *di, size_t key_size,
    const void *key, size_t label_size, const void *label, size_t context_size,
    const void *context, size_t output_size, void *output)
{
    if (output_size > UINT32_MAX / 8 || label_size > SIZE_MAX - 5 ||
        context_size > SIZE_MAX - 5 - label_size) return -7;
    size_t fixed_size = label_size + context_size + 5;
    unsigned char *fixed = calloc(1, fixed_size);
    if (!fixed) return -13;
    if (label_size && label) memcpy(fixed, label, label_size);
    if (context_size && context) memcpy(fixed + label_size + 1, context, context_size);
    counter_bytes((uint32_t)(output_size * 8), fixed + fixed_size - 4);
    int result = ccnistkdf_ctr_hmac_fixed(di, key_size, key, fixed_size, fixed, output_size, output);
    wipe(fixed, fixed_size); free(fixed);
    return result;
}
