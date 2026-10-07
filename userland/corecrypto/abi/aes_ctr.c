/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
static size_t rounded(size_t n) { return (n + 7) & ~(size_t)7; }
static int setctr(const struct ccmode_ctr *m, void *ctx, const void *iv)
{
    (void)m;
    const struct ccmode_ecb *e; memcpy(&e, ctx, sizeof(e));
    memcpy((unsigned char *)ctx + 8, &e->block_size, 8);
    memcpy((unsigned char *)ctx + 16 + rounded(e->block_size), iv, e->block_size);
    return 0;
}
static int init(const struct ccmode_ctr *m, void *ctx, size_t n, const void *key, const void *iv)
{
    const struct ccmode_ecb *e = m->custom;
    memcpy(ctx, &e, 8);
    int r = e->init(e, (unsigned char *)ctx + 16 + 2 * rounded(e->block_size), n, key);
    m->setctr(m, ctx, iv);
    return r;
}
static int process(void *ctx, size_t n, const void *input, void *output, int ahead)
{
    const struct ccmode_ecb *e; size_t used;
    memcpy(&e, ctx, 8); memcpy(&used, (unsigned char *)ctx + 8, 8);
    size_t block = e->block_size, width = block < 8 ? block : 8;
    unsigned char *pad = (unsigned char *)ctx + 16, *counter = pad + rounded(block);
    const void *key = counter + rounded(block);
    const unsigned char *in = input; unsigned char *out = output;
    while (n) {
        if (used == block) {
            if (ahead) {
                while (n >= block) {
                    e->ecb(key, 1, counter, pad);
                    for (size_t i = block; i > block - width; i--) if (++counter[i-1]) break;
                    for (size_t i = 0; i < block; i++) out[i] = in[i] ^ pad[i];
                    in += block; out += block; n -= block;
                }
            }
            e->ecb(key, 1, counter, pad);
            for (size_t i = block; i > block - width; i--) if (++counter[i-1]) break;
            used = 0;
        }
        size_t take = block - used; if (take > n) take = n;
        for (size_t i = 0; i < take; i++) out[i] = in[i] ^ pad[used + i];
        in += take; out += take; n -= take; used += take;
    }
    memcpy((unsigned char *)ctx + 8, &used, 8);
    return 0;
}
static int crypt(void *ctx, size_t n, const void *in, void *out)
{ return process(ctx, n, in, out, 0); }
static int aes_crypt(void *ctx, size_t n, const void *in, void *out)
{ return process(ctx, n, in, out, 1); }
EXPORT void ccmode_factory_ctr_crypt(struct ccmode_ctr *m, const struct ccmode_ecb *e)
{
    m->size = 16 + 2 * rounded(e->block_size) + rounded(e->size);
    m->block_size = 1; m->ecb_block_size = e->block_size;
    m->init = init; m->setctr = setctr; m->ctr = crypt; m->custom = e;
}
EXPORT const struct ccmode_ctr *ccaes_ctr_crypt_mode(void)
{
    extern const struct ccmode_ecb ccaes_arm_ecb_encrypt_mode;
    static const struct ccmode_ctr mode = {296, 1, 16, init, setctr, aes_crypt, &ccaes_arm_ecb_encrypt_mode};
    return &mode;
}
EXPORT size_t ccctr_context_size(const struct ccmode_ctr *m) { return m->size; }
EXPORT size_t ccctr_block_size(const struct ccmode_ctr *m) { return m->block_size; }
EXPORT int ccctr_init(const struct ccmode_ctr *m, void *ctx, size_t n, const void *key, const void *iv)
{ return m->init(m, ctx, n, key, iv); }
EXPORT int ccctr_update(const struct ccmode_ctr *m, void *ctx, size_t n, const void *in, void *out)
{ return m->ctr(ctx, n, in, out); }
EXPORT int ccctr_one_shot(const struct ccmode_ctr *m, size_t key_size, const void *key,
    const void *iv, size_t n, const void *in, void *out)
{
    _Alignas(16) unsigned char ctx[m->size];
    int r = m->init(m, ctx, key_size, key, iv);
    if (!r) r = m->ctr(ctx, n, in, out);
    volatile unsigned char *p = ctx; for (size_t i = 0; i < sizeof(ctx); i++) p[i] = 0;
    return r;
}
