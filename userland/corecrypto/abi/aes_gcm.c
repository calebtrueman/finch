/* SPDX-License-Identifier: MIT OR Apache-2.0
 * GCM state layout measured from the host library. AES comes from the ECB
 * descriptor. GHASH below uses fixed loops and masks, never secret-indexed
 * memory or secret-dependent branches.
 */
#include "ccmode.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
#define GCM_ENCRYPT 0x3e29dbu
#define GCM_DECRYPT 0x13337u
struct gcm_context {
    unsigned char h[16], x[16], counter[16], initial[16], pad[16];
    uint16_t state, flags;
    uint32_t reserved;
    uint64_t aad_bytes, text_bytes;
    const struct ccmode_ecb *ecb;
    void *key;
    uint32_t direction, padding;
    unsigned char table[256];
    unsigned char key_bytes[];
};
_Static_assert(offsetof(struct gcm_context, key_bytes) == 384, "GCM key offset");
static void wipe(void *p, size_t n) { volatile unsigned char *b = p; while (n--) *b++ = 0; }
static void multiply(unsigned char value[16], const unsigned char h[16])
{
    unsigned char v[16], out[16] = {0};
    memcpy(v, h, 16);
    for (size_t bit = 0; bit < 128; bit++) {
        unsigned char mask = (unsigned char)(0u - ((value[bit / 8] >> (7 - bit % 8)) & 1));
        for (size_t j = 0; j < 16; j++) out[j] ^= v[j] & mask;
        unsigned char carry = (unsigned char)(0u - (v[15] & 1));
        for (size_t j = 15; j; j--) v[j] = (unsigned char)((v[j] >> 1) | (v[j-1] << 7));
        v[0] = (unsigned char)((v[0] >> 1) ^ (carry & 0xe1));
    }
    memcpy(value, out, 16); wipe(v, 16); wipe(out, 16);
}
static void build_table(struct gcm_context *ctx)
{
    unsigned char power[16]; memcpy(power, ctx->h, 16);
    for (size_t k = 0; k < 8; k++) {
        unsigned char *entry = ctx->table + 16 * k;
        unsigned char mask = (unsigned char)(0u - (power[0] >> 7));
        for (size_t i = 0; i < 16; i++) {
            size_t j = 15 - i;
            entry[i] = (unsigned char)((power[j] << 1) | (j < 15 ? power[j+1] >> 7 : 0));
        }
        entry[0] ^= mask & 1; entry[15] ^= mask & 0xc2;
        for (size_t i = 0; i < 8; i++) {
            unsigned char both = entry[i] ^ entry[8+i];
            ctx->table[128 + 16*k + i] = both;
            ctx->table[136 + 16*k + i] = both;
        }
        multiply(power, ctx->h);
    }
    wipe(power, 16);
}
static int reset(void *context)
{
    struct gcm_context *ctx = context;
    wipe(ctx->x, 16); wipe(ctx->pad, 16);
    ctx->reserved = 0; ctx->state = 1; ctx->aad_bytes = 0; ctx->text_bytes = 0;
    return 0;
}
static int init(const struct ccmode_gcm *m, void *context, size_t n, const void *key)
{
    if (m->custom->block_size != 16) return -1;
    struct gcm_context *ctx = context;
    ctx->ecb = m->custom; ctx->key = ctx->key_bytes; ctx->direction = (uint32_t)m->direction;
    int r = ctx->ecb->init(ctx->ecb, ctx->key, n, key);
    if (r) return r;
    ctx->flags = 0; reset(ctx);
    r = ctx->ecb->ecb(ctx->key, 1, ctx->x, ctx->h);
    if (r) return r;
    build_table(ctx);
    return 0;
}
static void increment(unsigned char *p, size_t n)
{ while (n) { n--; if (++p[n]) break; } }
static void update_pad(struct gcm_context *ctx)
{
    increment(ctx->counter + 12, 4);
    ctx->ecb->ecb(ctx->key, 1, ctx->counter, ctx->pad);
}
static void big64(unsigned char *p, uint64_t n)
{ for (size_t i = 0; i < 8; i++) p[7-i] = (unsigned char)(n >> (8*i)); }
static int set_iv(void *context, size_t n, const void *value)
{
    struct gcm_context *ctx = context;
    if (ctx->state != 1 || (ctx->flags & 1) || !n || !value) return -68;
    const unsigned char *iv = value;
    if (n == 12) { memcpy(ctx->counter, iv, 12); memset(ctx->counter + 12, 0, 3); ctx->counter[15] = 1; }
    else {
        memset(ctx->counter, 0, 16);
        size_t left = n;
        while (left) {
            size_t take = left < 16 ? left : 16;
            for (size_t i = 0; i < take; i++) ctx->counter[i] ^= iv[i];
            multiply(ctx->counter, ctx->h); left -= take; iv += take;
        }
        unsigned char length[8]; big64(length, (uint64_t)n * 8);
        for (size_t i = 0; i < 8; i++) ctx->counter[8+i] ^= length[i];
        multiply(ctx->counter, ctx->h);
    }
    memcpy(ctx->initial, ctx->counter, 16); update_pad(ctx); ctx->state = 2;
    return 0;
}
static int aad(void *context, size_t n, const void *input)
{
    struct gcm_context *ctx = context;
    if (ctx->state != 2) return -68;
    const unsigned char *in = input;
    while (n--) {
        ctx->x[ctx->aad_bytes % 16] ^= *in++;
        if (++ctx->aad_bytes % 16 == 0) multiply(ctx->x, ctx->h);
    }
    return 0;
}
static void finish_aad(struct gcm_context *ctx)
{
    if (ctx->state == 2) {
        if (ctx->aad_bytes % 16) multiply(ctx->x, ctx->h);
        ctx->state = 3;
    }
}
static int crypt(void *context, size_t n, const void *input, void *output, int decrypt)
{
    struct gcm_context *ctx = context;
    finish_aad(ctx);
    if (ctx->state != 3) return -68;
    if (n > UINT64_MAX - ctx->text_bytes || ctx->text_bytes + n > UINT64_C(0xfffffffe0)) return -67;
    const unsigned char *in = input; unsigned char *out = output;
    while (n--) {
        size_t used = ctx->text_bytes % 16;
        unsigned char source = *in++, dest = source ^ ctx->pad[used];
        ctx->x[used] ^= decrypt ? source : dest; *out++ = dest;
        if (++ctx->text_bytes % 16 == 0) { multiply(ctx->x, ctx->h); update_pad(ctx); }
    }
    return 0;
}
static int encrypt(void *ctx, size_t n, const void *in, void *out) { return crypt(ctx, n, in, out, 0); }
static int decrypt(void *ctx, size_t n, const void *in, void *out) { return crypt(ctx, n, in, out, 1); }
static int finalize(void *context, size_t n, void *output)
{
    struct gcm_context *ctx = context;
    finish_aad(ctx);
    if (ctx->state != 3) return -68;
    if (ctx->text_bytes % 16) multiply(ctx->x, ctx->h);
    big64(ctx->pad, ctx->aad_bytes * 8); big64(ctx->pad + 8, ctx->text_bytes * 8);
    for (size_t i = 0; i < 16; i++) ctx->x[i] ^= ctx->pad[i];
    multiply(ctx->x, ctx->h);
    ctx->ecb->ecb(ctx->key, 1, ctx->initial, ctx->pad);
    unsigned char tag[16], diff = 0, *out = output;
    for (size_t i = 0; i < 16; i++) tag[i] = ctx->x[i] ^ ctx->pad[i];
    if (n > 16) n = 16;
    if (ctx->direction == GCM_DECRYPT) {
        diff = n == 0;
        for (size_t i = 0; i < n; i++) diff |= out[i] ^ tag[i];
    }
    memcpy(out, tag, n); wipe(tag, 16); ctx->state = 4;
    return diff ? -69 : 0;
}
extern const struct ccmode_ecb ccaes_arm_ecb_encrypt_mode;
static const struct ccmode_gcm enc = {712, GCM_ENCRYPT, 1, init, set_iv, aad, encrypt, finalize, reset, &ccaes_arm_ecb_encrypt_mode};
static const struct ccmode_gcm dec = {712, GCM_DECRYPT, 1, init, set_iv, aad, decrypt, finalize, reset, &ccaes_arm_ecb_encrypt_mode};
EXPORT const struct ccmode_gcm *ccaes_gcm_encrypt_mode(void) { return &enc; }
EXPORT const struct ccmode_gcm *ccaes_gcm_decrypt_mode(void) { return &dec; }
EXPORT void ccmode_factory_gcm_encrypt(struct ccmode_gcm *m, const struct ccmode_ecb *e)
{ *m = enc; m->size = 384 + 5*((e->block_size+7)&~(size_t)7) + ((e->size+7)&~(size_t)7); m->custom = e; }
EXPORT void ccmode_factory_gcm_decrypt(struct ccmode_gcm *m, const struct ccmode_ecb *e)
{ ccmode_factory_gcm_encrypt(m, e); m->direction = GCM_DECRYPT; m->gcm = decrypt; }
EXPORT size_t ccgcm_context_size(const struct ccmode_gcm *m) { return m->size; }
EXPORT size_t ccgcm_block_size(const struct ccmode_gcm *m) { return m->block_size; }
EXPORT int ccgcm_init(const struct ccmode_gcm *m, void *ctx, size_t n, const void *key) { return m->init(m, ctx, n, key); }
EXPORT int ccgcm_set_iv(const struct ccmode_gcm *m, void *ctx, size_t n, const void *iv) { return m->set_iv(ctx, n, iv); }
EXPORT int ccgcm_aad(const struct ccmode_gcm *m, void *ctx, size_t n, const void *in) { return m->aad(ctx, n, in); }
EXPORT int ccgcm_gmac(const struct ccmode_gcm *m, void *ctx, size_t n, const void *in) { return m->aad(ctx, n, in); }
EXPORT int ccgcm_update(const struct ccmode_gcm *m, void *ctx, size_t n, const void *in, void *out) { return m->gcm(ctx, n, in, out); }
EXPORT int ccgcm_finalize(const struct ccmode_gcm *m, void *ctx, size_t n, void *tag) { return m->finalize(ctx, n, tag); }
EXPORT int ccgcm_reset(const struct ccmode_gcm *m, void *ctx) { return m->reset(ctx); }
EXPORT int ccgcm_set_iv_legacy(const struct ccmode_gcm *m, void *context, size_t n, const void *iv)
{
    if (n && iv) return m->set_iv(context, n, iv);
    struct gcm_context *ctx = context;
    if (ctx->state != 1) return -1;
    memset(ctx->counter, 0, 16); update_pad(ctx); memset(ctx->initial, 0, 16); ctx->state = 2;
    return 0;
}
EXPORT int ccgcm_init_with_iv(const struct ccmode_gcm *m, void *context, size_t n, const void *key, const void *iv)
{
    int r = m->init(m, context, n, key);
    if (!r) r = m->set_iv(context, 12, iv);
    if (!r) ((struct gcm_context *)context)->flags |= 1;
    return r;
}
EXPORT int ccgcm_inc_iv(const struct ccmode_gcm *m, void *context, void *iv)
{
    (void)m; struct gcm_context *ctx = context;
    if (ctx->state != 1 || !(ctx->flags & 1)) return -68;
    increment(ctx->initial + 4, 8); memcpy(iv, ctx->initial, 12);
    memcpy(ctx->counter, ctx->initial, 16); update_pad(ctx); ctx->state = 2;
    return 0;
}
static int one_shot(const struct ccmode_gcm *m, size_t key_size, const void *key,
    size_t iv_size, const void *iv, size_t aad_size, const void *auth,
    size_t n, const void *in, void *out, size_t tag_size, void *tag, int legacy)
{
    _Alignas(16) unsigned char ctx[m->size];
    int r = m->init(m, ctx, key_size, key);
    if (!r) r = legacy ? ccgcm_set_iv_legacy(m, ctx, iv_size, iv) : m->set_iv(ctx, iv_size, iv);
    if (!r) r = m->aad(ctx, aad_size, auth);
    if (!r) r = m->gcm(ctx, n, in, out);
    if (!r) r = m->finalize(ctx, tag_size, tag);
    wipe(ctx, sizeof(ctx)); return r;
}
EXPORT int ccgcm_one_shot(const struct ccmode_gcm *m, size_t key_size, const void *key,
    size_t iv_size, const void *iv, size_t aad_size, const void *auth,
    size_t n, const void *in, void *out, size_t tag_size, void *tag)
{ return one_shot(m, key_size, key, iv_size, iv, aad_size, auth, n, in, out, tag_size, tag, 0); }
EXPORT int ccgcm_one_shot_legacy(const struct ccmode_gcm *m, size_t key_size, const void *key,
    size_t iv_size, const void *iv, size_t aad_size, const void *auth,
    size_t n, const void *in, void *out, size_t tag_size, void *tag)
{ return one_shot(m, key_size, key, iv_size, iv, aad_size, auth, n, in, out, tag_size, tag, 1); }
