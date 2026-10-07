/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCMODE_H
#define FINCH_ABI_CCMODE_H
#include <stddef.h>
struct ccmode_ecb {
    size_t size, block_size;
    int (*init)(const struct ccmode_ecb *, void *, size_t, const void *);
    int (*ecb)(const void *, size_t, const void *, void *);
};
const struct ccmode_ecb *ccaes_ecb_encrypt_mode(void);
const struct ccmode_ecb *ccaes_ecb_decrypt_mode(void);
int ccecb_init(const struct ccmode_ecb *, void *, size_t, const void *);
int ccecb_update(const struct ccmode_ecb *, const void *, size_t, const void *, void *);
int ccecb_one_shot(const struct ccmode_ecb *, size_t, const void *, size_t, const void *, void *);
int ccecb_one_shot_explicit(const struct ccmode_ecb *, size_t, size_t, size_t, const void *, const void *, void *);
struct ccmode_cbc {
    size_t size, block_size;
    int (*init)(const struct ccmode_cbc *, void *, size_t, const void *);
    int (*cbc)(const void *, void *, size_t, const void *, void *);
    const void *custom;
};
struct ccmode_ctr {
    size_t size, block_size, ecb_block_size;
    int (*init)(const struct ccmode_ctr *, void *, size_t, const void *, const void *);
    int (*setctr)(const struct ccmode_ctr *, void *, const void *);
    int (*ctr)(void *, size_t, const void *, void *);
    const struct ccmode_ecb *custom;
};
struct ccmode_gcm {
    size_t size, direction, block_size;
    int (*init)(const struct ccmode_gcm *, void *, size_t, const void *);
    int (*set_iv)(void *, size_t, const void *);
    int (*aad)(void *, size_t, const void *);
    int (*gcm)(void *, size_t, const void *, void *);
    int (*finalize)(void *, size_t, void *);
    int (*reset)(void *);
    const struct ccmode_ecb *custom;
};
struct ccmode_xts {
    size_t size, tweak_size, block_size;
    int (*init)(const struct ccmode_xts *, void *, size_t, const void *, const void *);
    int (*key_sched)(const struct ccmode_xts *, void *, size_t, const void *, const void *);
    int (*set_tweak)(const void *, void *, const void *);
    void *(*xts)(const void *, void *, size_t, const void *, void *);
    const struct ccmode_ecb *custom, *custom_tweak;
    size_t implementation;
};
/* CFB, CFB8 and OFB share this descriptor layout. */
struct ccmode_stream {
    size_t size, block_size;
    int (*init)(const struct ccmode_stream *, void *, size_t, const void *, const void *);
    int (*crypt)(void *, size_t, const void *, void *);
    const struct ccmode_ecb *custom;
};
struct ccmode_ccm {
    size_t size, nonce_size, block_size;
    int (*init)(const struct ccmode_ccm *, void *, size_t, const void *);
    int (*set_iv)(const void *, void *, size_t, const void *, size_t, size_t, size_t);
    int (*aad)(const void *, void *, size_t, const void *);
    int (*ccm)(const void *, void *, size_t, const void *, void *);
    int (*finalize)(const void *, void *, void *);
    int (*reset)(const void *, void *);
    const struct ccmode_ecb *custom;
    unsigned char encdec, reserved[7];
};
#endif
