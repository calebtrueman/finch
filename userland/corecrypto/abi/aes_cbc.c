/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
static void wipe(void *p, size_t n) { volatile unsigned char *b = p; while (n--) *b++ = 0; }
static int enc_init(const struct ccmode_cbc *m, void *ctx, size_t n, const void *key)
{ (void)m; const struct ccmode_ecb *e = ccaes_ecb_encrypt_mode(); return e->init(e, ctx, n, key); }
static int dec_init(const struct ccmode_cbc *m, void *ctx, size_t n, const void *key)
{ (void)m; const struct ccmode_ecb *e = ccaes_ecb_decrypt_mode(); return e->init(e, ctx, n, key); }
static int blocks(const void *ctx, void *iv, size_t count, const void *input, void *output, int decrypt)
{
    const struct ccmode_ecb *e = decrypt ? ccaes_ecb_decrypt_mode() : ccaes_ecb_encrypt_mode();
    const unsigned char *in = input;
    unsigned char *out = output, *chain = iv, tmp[16], saved[16];
    int r = 0;
    while (count--) {
        if (decrypt) {
            memcpy(saved, in, 16);
            r = e->ecb(ctx, 1, in, tmp);
            if (r) break;
            for (size_t i = 0; i < 16; i++) out[i] = tmp[i] ^ chain[i];
            memcpy(chain, saved, 16);
        } else {
            for (size_t i = 0; i < 16; i++) tmp[i] = in[i] ^ chain[i];
            r = e->ecb(ctx, 1, tmp, out);
            if (r) break;
            memcpy(chain, out, 16);
        }
        in += 16; out += 16;
    }
    wipe(tmp, sizeof(tmp)); wipe(saved, sizeof(saved));
    return r;
}
static int encrypt(const void *ctx, void *iv, size_t n, const void *in, void *out)
{ return blocks(ctx, iv, n, in, out, 0); }
static int decrypt(const void *ctx, void *iv, size_t n, const void *in, void *out)
{ return blocks(ctx, iv, n, in, out, 1); }
EXPORT const struct ccmode_cbc ccaes_arm_cbc_encrypt_mode = {244, 16, enc_init, encrypt, NULL};
EXPORT const struct ccmode_cbc ccaes_arm_cbc_decrypt_mode = {244, 16, dec_init, decrypt, NULL};
EXPORT const struct ccmode_cbc *ccaes_cbc_encrypt_mode(void) { return &ccaes_arm_cbc_encrypt_mode; }
EXPORT const struct ccmode_cbc *ccaes_cbc_decrypt_mode(void) { return &ccaes_arm_cbc_decrypt_mode; }
EXPORT size_t cccbc_context_size(const struct ccmode_cbc *m) { return m->size; }
EXPORT size_t cccbc_block_size(const struct ccmode_cbc *m) { return m->block_size; }
EXPORT int cccbc_init(const struct ccmode_cbc *m, void *ctx, size_t n, const void *key)
{ return m->init(m, ctx, n, key); }
EXPORT int cccbc_copy_iv(void *out, const void *in, size_t n) { memcpy(out, in, n); return 0; }
EXPORT int cccbc_clear_iv(size_t n, void *iv) { wipe(iv, n); return 0; }
EXPORT int cccbc_set_iv(const struct ccmode_cbc *m, void *iv, const void *value)
{ if (value) memcpy(iv, value, m->block_size); else wipe(iv, m->block_size); return 0; }
EXPORT int cccbc_update(const struct ccmode_cbc *m, const void *ctx, void *iv, size_t n, const void *in, void *out)
{ return m->cbc(ctx, iv, n, in, out); }
EXPORT int cccbc_one_shot_explicit(const struct ccmode_cbc *m, size_t key_size, size_t iv_size,
    size_t block_size, size_t count, const void *key, const void *iv, const void *in, void *out)
{
    if (block_size != m->block_size || (iv_size && iv_size != block_size)) return -7;
    _Alignas(16) unsigned char ctx[m->size], chain[m->block_size];
    int r = m->init(m, ctx, key_size, key);
    if (!r) { cccbc_set_iv(m, chain, iv); r = m->cbc(ctx, chain, count, in, out); }
    wipe(ctx, sizeof(ctx)); wipe(chain, sizeof(chain));
    return r;
}
EXPORT int cccbc_one_shot(const struct ccmode_cbc *m, size_t key_size, const void *key,
    const void *iv, size_t count, const void *in, void *out)
{ return cccbc_one_shot_explicit(m, key_size, iv ? m->block_size : 0, m->block_size, count, key, iv, in, out); }

/* Factory-made CBC contexts put the ECB descriptor before its key state. */
static int generic_init(const struct ccmode_cbc *m, void *ctx, size_t n, const void *key)
{
    const struct ccmode_ecb *e = m->custom;
    memcpy(ctx, &e, sizeof(e));
    return e->init(e, (unsigned char *)ctx + sizeof(e), n, key);
}
static int generic_blocks(const void *ctx, void *iv, size_t count, const void *input, void *output, int decrypt)
{
    const struct ccmode_ecb *e;
    memcpy(&e, ctx, sizeof(e));
    size_t block = e->block_size;
    if (decrypt && block > 16) return -7;
    const void *key = (const unsigned char *)ctx + sizeof(e);
    const unsigned char *in = input;
    unsigned char *out = output, *chain = iv;
    unsigned char tmp[block ? block : 1], saved[block ? block : 1];
    while (count--) {
        if (decrypt) {
            memcpy(saved, in, block);
            e->ecb(key, 1, in, tmp);
            for (size_t i = 0; i < block; i++) out[i] = tmp[i] ^ chain[i];
            memcpy(chain, saved, block);
        } else {
            for (size_t i = 0; i < block; i++) out[i] = in[i] ^ chain[i];
            e->ecb(key, 1, out, out);
            memcpy(chain, out, block);
        }
        in += block; out += block;
    }
    wipe(tmp, sizeof(tmp)); wipe(saved, sizeof(saved));
    return 0;
}
static int generic_encrypt(const void *ctx, void *iv, size_t n, const void *in, void *out)
{ return generic_blocks(ctx, iv, n, in, out, 0); }
static int generic_decrypt(const void *ctx, void *iv, size_t n, const void *in, void *out)
{ return generic_blocks(ctx, iv, n, in, out, 1); }
static void factory(struct ccmode_cbc *m, const struct ccmode_ecb *e, int decrypt)
{
    m->size = 8 + ((e->size + 7) & ~(size_t)7) + ((e->block_size + 7) & ~(size_t)7);
    m->block_size = e->block_size;
    m->init = generic_init;
    m->cbc = decrypt ? generic_decrypt : generic_encrypt;
    m->custom = e;
}
EXPORT void ccmode_factory_cbc_encrypt(struct ccmode_cbc *m, const struct ccmode_ecb *e) { factory(m, e, 0); }
EXPORT void ccmode_factory_cbc_decrypt(struct ccmode_cbc *m, const struct ccmode_ecb *e) { factory(m, e, 1); }
