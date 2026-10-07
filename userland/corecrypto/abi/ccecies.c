/* SPDX-License-Identifier: MIT OR Apache-2.0
 * ECIES wire format measured against the system library. */
#include "ccec.h"
#include "ccdigest.h"
#include "ccmode.h"
#include <stdlib.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct ccecies {
	const struct ccdigest_info *di;
	struct ccrng_state *rng;
	const struct ccmode_gcm *gcm;
	uint32_t key_size, tag_size, options;
};
extern struct ccrng_state *ccrng(int *);
extern int ccansikdf_x963(
    const struct ccdigest_info *, size_t, const void *, size_t, const void *, size_t, void *);
extern int ccec_compact_export_pub(void *, const struct ccec_ctx *);
extern int ccec_compact_import_pub(ccec_const_cp_t, size_t, const void *, struct ccec_ctx *);
extern int ccecdh_compute_shared_secret(
    const struct ccec_ctx *, const struct ccec_ctx *, size_t *, void *, struct ccrng_state *);
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}
static int setup(struct ccecies *c, const struct ccdigest_info *d, struct ccrng_state *r,
    const struct ccmode_gcm *g, size_t k, size_t t, uint32_t o, size_t direction)
{
	*c = (struct ccecies){d, r, g, (uint32_t)k, (uint32_t)t, o};
	return (k == 16 || k == 24 || k == 32) && t >= 12 && t <= 16 && g &&
	        g->direction == direction
	    ? 0
	    : -5;
}
EXPORT int ccecies_encrypt_gcm_setup(struct ccecies *c, const struct ccdigest_info *d,
    struct ccrng_state *r, const struct ccmode_gcm *g, size_t k, size_t t, uint32_t o)
{
	return setup(c, d, r, g, k, t, o, 0x3e29db);
}
EXPORT int ccecies_decrypt_gcm_setup(struct ccecies *c, const struct ccdigest_info *d,
    const struct ccmode_gcm *g, size_t k, size_t t, uint32_t o)
{
	return setup(c, d, ccrng(NULL), g, k, t, o, 0x13337);
}
EXPORT size_t ccecies_pub_key_size_cp(ccec_const_cp_t cp, const struct ccecies *c)
{
	size_t w = (cp->bitlen + 7) / 8;
	return c->options & 2 ? 2 * w + 1 : c->options & 4 ? w : 0;
}
EXPORT size_t ccecies_pub_key_size(const struct ccec_ctx *k, const struct ccecies *c)
{
	return ccecies_pub_key_size_cp(k->cp, c);
}
EXPORT size_t ccecies_encrypt_gcm_ciphertext_size(
    const struct ccec_ctx *k, const struct ccecies *c, size_t n)
{
	size_t p = ccecies_pub_key_size(k, c);
	return p && n <= SIZE_MAX - p - c->tag_size ? p + n + c->tag_size : 0;
}
EXPORT size_t ccecies_decrypt_gcm_plaintext_size_cp(
    ccec_const_cp_t cp, const struct ccecies *c, size_t n)
{
	size_t p = ccecies_pub_key_size_cp(cp, c);
	return p && n >= p + c->tag_size ? n - p - c->tag_size : 0;
}
EXPORT size_t ccecies_decrypt_gcm_plaintext_size(
    const struct ccec_ctx *k, const struct ccecies *c, size_t n)
{
	return ccecies_decrypt_gcm_plaintext_size_cp(k->cp, c, n);
}
EXPORT int ccecies_import_eph_pub(
    ccec_const_cp_t cp, const struct ccecies *c, size_t n, const void *in, struct ccec_ctx *k)
{
	return c->options & 2 ? ccec_x963_import_pub(cp, n, in, k)
	    : c->options & 4  ? ccec_compact_import_pub(cp, n, in, k)
	                      : -7;
}
static int export_pub(const struct ccecies *c, const struct ccec_ctx *k, void *out)
{
	return c->options & 2 ? ccec_export_pub(k, out)
	    : c->options & 4  ? ccec_compact_export_pub(out, k)
	                      : -7;
}
static int derive(const struct ccecies *c, size_t zn, const void *z, size_t sn, const void *s,
    size_t en, const void *e, unsigned char *out)
{
	unsigned o = c->options;
	int include = o & 0x21;
	if ((o & 0x21) == 0x21 || ((o & 1) && sn) || ((o & 32) && !sn))
		return -7;
	if (en > SIZE_MAX - sn)
		return -7;
	size_t n = sn + (include ? en : 0);
	unsigned char *info = malloc(n ? n : 1);
	if (!info)
		return -13;
	if (include)
		memcpy(info, e, en);
	if (sn)
		memcpy(info + (include ? en : 0), s, sn);
	memset(out, 0, 48);
	int rc = ccansikdf_x963(c->di, zn, z, n, info, c->key_size + ((o & 16) ? 0 : 16), out);
	free(info);
	return rc;
}
static int crypt(const struct ccecies *c, int enc, const unsigned char *key, size_t an,
    const void *a, size_t n, const void *in, void *out, void *tag)
{
	const struct ccmode_gcm *g = c->gcm;
	if (g->direction != (enc ? 0x3e29db : 0x13337))
		return -5;
	void *ctx = calloc(1, g->size);
	if (!ctx)
		return -13;
	int rc = g->init(g, ctx, c->key_size, key);
	if (!rc)
		rc = g->set_iv(ctx, 16, key + c->key_size);
	if (!rc && an && a)
		rc = g->aad(ctx, an, a);
	if (!rc)
		rc = g->gcm(ctx, n, in, out);
	unsigned char t[16];
	if (!enc)
		memcpy(t, tag, c->tag_size);
	if (!rc)
		rc = g->finalize(ctx, c->tag_size, enc ? tag : t);
	wipe(ctx, g->size);
	free(ctx);
	return rc;
}
EXPORT int ccecies_encrypt_gcm_from_shared_secret_composite(const struct ccec_ctx *pub,
    const struct ccecies *c, const struct ccec_ctx *eph, size_t zn, const void *z, size_t n,
    const void *in, size_t sn, const void *s, size_t an, const void *a, void *ep, void *out,
    void *tag)
{
	unsigned char key[48];
	int rc = pub->cp == eph->cp ? export_pub(c, eph, ep) : -7;
	if (!rc)
		rc = derive(c, zn, z, sn, s, ccecies_pub_key_size(eph, c), ep, key);
	if (!rc)
		rc = crypt(c, 1, key, an, a, n, in, out, tag);
	wipe(key, sizeof(key));
	return rc;
}
EXPORT int ccecies_decrypt_gcm_from_shared_secret_composite(ccec_const_cp_t cp,
    const struct ccecies *c, size_t zn, const void *z, size_t n, const void *ep, const void *in,
    const void *tag, size_t sn, const void *s, size_t an, const void *a, void *out)
{
	unsigned char key[48];
	int rc = derive(c, zn, z, sn, s, ccecies_pub_key_size_cp(cp, c), ep, key);
	if (!rc)
		rc = crypt(c, 0, key, an, a, n, in, out, (void *)tag);
	if (rc)
		wipe(out, n);
	wipe(key, sizeof(key));
	return rc;
}
EXPORT int ccecies_encrypt_gcm_composite(const struct ccec_ctx *pub, const struct ccecies *c,
    void *ep, void *out, void *tag, size_t n, const void *in, size_t sn, const void *s, size_t an,
    const void *a)
{
	unsigned char keybuf[16 + 4 * 9 * 8], z[66];
	struct ccec_ctx *eph = (void *)keybuf;
	size_t zn = sizeof(z);
	int rc = ccec_generate_key(pub->cp, c->rng, eph);
	if (!rc)
		rc = ccecdh_compute_shared_secret(eph, pub, &zn, z, c->rng);
	if (!rc)
		rc = ccecies_encrypt_gcm_from_shared_secret_composite(
		    pub, c, eph, zn, z, n, in, sn, s, an, a, ep, out, tag);
	wipe(keybuf, sizeof(keybuf));
	wipe(z, sizeof(z));
	return rc;
}
EXPORT int ccecies_decrypt_gcm_composite(const struct ccec_ctx *full, const struct ccecies *c,
    void *out, size_t sn, const void *s, size_t an, const void *a, size_t n, const void *in,
    const void *ep, const void *tag)
{
	unsigned char keybuf[16 + 3 * 9 * 8], z[66];
	struct ccec_ctx *eph = (void *)keybuf;
	size_t zn = sizeof(z);
	int rc = ccecies_import_eph_pub(full->cp, c, ccecies_pub_key_size(full, c), ep, eph);
	if (!rc)
		rc = ccecdh_compute_shared_secret(full, eph, &zn, z, c->rng);
	if (!rc)
		rc = ccecies_decrypt_gcm_from_shared_secret_composite(
		    full->cp, c, zn, z, n, ep, in, tag, sn, s, an, a, out);
	if (rc)
		wipe(out, n);
	wipe(keybuf, sizeof(keybuf));
	wipe(z, sizeof(z));
	return rc;
}
EXPORT int ccecies_encrypt_gcm(const struct ccec_ctx *pub, const struct ccecies *c, size_t n,
    const void *in, size_t sn, const void *s, size_t an, const void *a, size_t *outn, void *out)
{
	size_t need = ccecies_encrypt_gcm_ciphertext_size(pub, c, n),
	       p = ccecies_pub_key_size(pub, c);
	int rc = !need || *outn < need ? -7
	                               : ccecies_encrypt_gcm_composite(pub, c, out, (char *)out + p,
	                                     (char *)out + p + n, n, in, sn, s, an, a);
	if (rc)
		wipe(out, *outn);
	else
		*outn = need;
	return rc;
}
EXPORT int ccecies_decrypt_gcm(const struct ccec_ctx *full, const struct ccecies *c, size_t n,
    const void *in, size_t sn, const void *s, size_t an, const void *a, size_t *outn, void *out)
{
	size_t need = ccecies_decrypt_gcm_plaintext_size(full, c, n),
	       p = ccecies_pub_key_size(full, c);
	int rc = !need || *outn < need
	    ? -7
	    : ccecies_decrypt_gcm_composite(full, c, out, sn, s, an, a, need, (const char *)in + p,
	          in, (const char *)in + p + need);
	if (rc)
		wipe(out, *outn);
	else
		*outn = need;
	return rc;
}
EXPORT int ccecies_encrypt_gcm_from_shared_secret(const struct ccec_ctx *pub,
    const struct ccecies *c, const struct ccec_ctx *eph, size_t zn, const void *z, size_t n,
    const void *in, size_t sn, const void *s, size_t an, const void *a, size_t *outn, void *out)
{
	size_t need = ccecies_encrypt_gcm_ciphertext_size(eph, c, n),
	       p = ccecies_pub_key_size(eph, c);
	int rc = !(c->options & 0x21) ? -5
	    : !need || *outn < need
	    ? -7
	    : ccecies_encrypt_gcm_from_shared_secret_composite(pub, c, eph, zn, z, n, in, sn, s, an,
	          a, out, (char *)out + p, (char *)out + p + n);
	if (rc)
		wipe(out, *outn);
	else
		*outn = need;
	return rc;
}
EXPORT int ccecies_decrypt_gcm_from_shared_secret(ccec_const_cp_t cp, const struct ccecies *c,
    size_t zn, const void *z, size_t n, const void *in, size_t sn, const void *s, size_t an,
    const void *a, size_t *outn, void *out)
{
	size_t need = ccecies_decrypt_gcm_plaintext_size_cp(cp, c, n),
	       p = ccecies_pub_key_size_cp(cp, c);
	int rc = !(c->options & 0x21) ? -5
	    : !need || *outn < need
	    ? -7
	    : ccecies_decrypt_gcm_from_shared_secret_composite(cp, c, zn, z, need, in,
	          (const char *)in + p, (const char *)in + p + need, sn, s, an, a, out);
	if (rc)
		wipe(out, *outn);
	else
		*outn = need;
	return rc;
}
