/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CHACHA_H
#define FINCH_ABI_CHACHA_H
#include <stddef.h>
#include <stdint.h>
struct ccchacha20_ctx {
	uint32_t state[16];
	unsigned char pad[64];
	uint64_t used;
};
struct ccpoly1305_ctx {
	uint32_t r[5], r5[4], h[5];
	unsigned char buffer[16];
	uint64_t used;
	unsigned char key[16];
};
struct ccchacha20poly1305_ctx {
	struct ccchacha20_ctx chacha;
	struct ccpoly1305_ctx poly;
	uint64_t aad_size, text_size;
	unsigned char state;
	unsigned char reserved[7];
};
struct ccchacha20poly1305_info {
	unsigned char reserved;
};
int ccchacha20_init(struct ccchacha20_ctx *, const void *);
int ccchacha20_reset(struct ccchacha20_ctx *);
int ccchacha20_setnonce(struct ccchacha20_ctx *, const void *);
int ccchacha20_setcounter(struct ccchacha20_ctx *, uint32_t);
int ccchacha20_update(struct ccchacha20_ctx *, size_t, const void *, void *);
int ccchacha20_final(struct ccchacha20_ctx *);
int ccchacha20(const void *, const void *, uint32_t, size_t, const void *, void *);
int ccpoly1305_init(struct ccpoly1305_ctx *, const void *);
int ccpoly1305_update(struct ccpoly1305_ctx *, size_t, const void *);
int ccpoly1305_final(struct ccpoly1305_ctx *, void *);
int ccpoly1305(const void *, size_t, const void *, void *);
const struct ccchacha20poly1305_info *ccchacha20poly1305_info(void);
int ccchacha20poly1305_init(
    const struct ccchacha20poly1305_info *, struct ccchacha20poly1305_ctx *, const void *);
int ccchacha20poly1305_reset(
    const struct ccchacha20poly1305_info *, struct ccchacha20poly1305_ctx *);
int ccchacha20poly1305_setnonce(
    const struct ccchacha20poly1305_info *, struct ccchacha20poly1305_ctx *, const void *);
int ccchacha20poly1305_incnonce(
    const struct ccchacha20poly1305_info *, struct ccchacha20poly1305_ctx *, void *);
int ccchacha20poly1305_aad(
    const struct ccchacha20poly1305_info *, struct ccchacha20poly1305_ctx *, size_t, const void *);
int ccchacha20poly1305_encrypt(const struct ccchacha20poly1305_info *,
    struct ccchacha20poly1305_ctx *, size_t, const void *, void *);
int ccchacha20poly1305_decrypt(const struct ccchacha20poly1305_info *,
    struct ccchacha20poly1305_ctx *, size_t, const void *, void *);
int ccchacha20poly1305_finalize(
    const struct ccchacha20poly1305_info *, struct ccchacha20poly1305_ctx *, void *);
int ccchacha20poly1305_verify(
    const struct ccchacha20poly1305_info *, struct ccchacha20poly1305_ctx *, const void *);
int ccchacha20poly1305_encrypt_oneshot(const struct ccchacha20poly1305_info *, const void *,
    const void *, size_t, const void *, size_t, const void *, void *, void *);
int ccchacha20poly1305_decrypt_oneshot(const struct ccchacha20poly1305_info *, const void *,
    const void *, size_t, const void *, size_t, const void *, void *, const void *);
#endif
