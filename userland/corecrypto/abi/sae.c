/* SPDX-License-Identifier: MIT OR Apache-2.0
 * SAE password exchange, implemented with independent curve arithmetic.
 */
#include "ccsae.h"
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/obj_mac.h>
#include <openssl/crypto.h>
#include <stdlib.h>
#include <string.h>
#define API __attribute__((visibility("default")))
extern void cchmac(
    const struct ccdigest_info *, size_t, const void *, size_t, const void *, void *);
static size_t width(const struct ccsae_ctx *s)
{
	return (s->cp->bitlen + 7) / 8;
}
static cc_unit *part(const struct ccsae_ctx *s, unsigned i)
{
	return (cc_unit *)s->data + i * s->cp->n;
}
struct sae_ws {
	cc_unit *mem;
	size_t count, used;
	cc_unit *(*alloc)(struct sae_ws *, size_t);
	void (*free)(struct sae_ws *);
};
static cc_unit *ws_alloc(struct sae_ws *w, size_t n)
{
	if (n > w->count - w->used)
		abort();
	cc_unit *p = w->mem + w->used;
	w->used += n;
	return p;
}
static void ws_free(struct sae_ws *w)
{
	w->used = 0;
}
static void field_convert(const struct ccsae_ctx *s, cc_unit *out, const cc_unit *in, int to)
{
	cc_unit mem[4096];
	struct sae_ws w = {mem, 4096, 0, ws_alloc, ws_free};
	if (to)
		s->cp->funcs->to(&w, s->cp, out, in);
	else
		s->cp->funcs->from(&w, s->cp, out, in);
	OPENSSL_cleanse(mem, sizeof mem);
}
static EC_GROUP *group(const struct ccsae_ctx *s)
{
	size_t b = s->cp->bitlen;
	return EC_GROUP_new_by_curve_name(b == 192 ? NID_X9_62_prime192v1
	        : b == 224                         ? NID_secp224r1
	        : b == 256                         ? NID_X9_62_prime256v1
	        : b == 384                         ? NID_secp384r1
	        : b == 521                         ? NID_secp521r1
	                                           : NID_undef);
}
static BIGNUM *readnum(const struct ccsae_ctx *s, unsigned i)
{
	return BN_lebin2bn((void *)part(s, i), (int)s->cp->n * 8, NULL);
}
static void savenum(const struct ccsae_ctx *s, unsigned i, const BIGNUM *x)
{
	BN_bn2lebinpad(x, (void *)part(s, i), (int)s->cp->n * 8);
}
static EC_POINT *readpoint(const struct ccsae_ctx *s, const EC_GROUP *g, unsigned i, BN_CTX *c)
{
	BIGNUM *x = readnum(s, i), *y = readnum(s, i + 1);
	EC_POINT *p = EC_POINT_new(g);
	if (!x || !y || !p || !EC_POINT_set_affine_coordinates(g, p, x, y, c)) {
		EC_POINT_free(p);
		p = NULL;
	}
	BN_free(x);
	BN_free(y);
	return p;
}
static int savepoint(
    const struct ccsae_ctx *s, const EC_GROUP *g, unsigned i, const EC_POINT *p, BN_CTX *c)
{
	BIGNUM *x = BN_new(), *y = BN_new();
	int ok = x && y && EC_POINT_get_affine_coordinates(g, p, x, y, c);
	if (ok) {
		savenum(s, i, x);
		savenum(s, i + 1, y);
	}
	BN_clear_free(x);
	BN_clear_free(y);
	return ok ? 0 : -7;
}
API size_t ccsae_sizeof_ctx(const struct cczp *cp)
{
	return 144 + 72 * cp->n;
}
API size_t ccsae_sizeof_commitment(const struct ccsae_ctx *s)
{
	return 3 * width(s);
}
API size_t ccsae_sizeof_confirmation(const struct ccsae_ctx *s)
{
	return s->di->output_size;
}
API size_t ccsae_sizeof_pt(const struct cch2c_info *i)
{
	return 1 + 2 * ((i->cp()->bitlen + 7) / 8);
}
API size_t ccsae_sizeof_kck(const struct ccsae_ctx *s)
{
	(void)s;
	return 32;
}
API size_t ccsae_sizeof_kck_h2c(const struct ccsae_ctx *s)
{
	return s->di->output_size;
}
static size_t kcklen(const struct ccsae_ctx *s)
{
	return s->mode == 1 ? 32 : s->mode == 2 ? s->di->output_size : 0;
}
API int ccsae_init(struct ccsae_ctx *s, const struct cczp *cp, struct ccrng_state *r,
    const struct ccdigest_info *d)
{
	memset(s, 0, ccsae_sizeof_ctx(cp));
	s->cp = cp;
	s->rng = r;
	s->di = d;
	s->state = 1;
	s->maxloops = 40;
	s->keys_label = "SAE KCK and PMK";
	s->hunt_label = "SAE Hunting and Pecking";
	return 0;
}
API int ccsae_init_p256_sha256(struct ccsae_ctx *s, struct ccrng_state *r)
{
	return ccsae_init(s, ccec_cp_256(), r, ccsha256_di());
}
API int ccsae_init_p384_sha384(struct ccsae_ctx *s, struct ccrng_state *r)
{
	return ccsae_init(s, ccec_cp_384(), r, ccsha384_di());
}
API void ccsae_lexographic_order_key(const void *a, size_t an, const void *b, size_t bn, void *out)
{
	int v = memcmp(a, b, an < bn ? an : bn);
	if (!v)
		v = an > bn ? 1 : an < bn ? -1 : 0;
	if (v > 0) {
		memcpy(out, a, an);
		memcpy((char *)out + an, b, bn);
	} else {
		memcpy(out, b, bn);
		memcpy((char *)out + bn, a, an);
	}
}
static void kdf(const struct ccsae_ctx *s, const unsigned char *key, const char *label,
    const BIGNUM *x, unsigned bits, size_t on, unsigned char *out)
{
	unsigned char input[160], mac[64];
	size_t l = strlen(label), f = width(s), n = 2 + l + f + 2;
	memcpy(input + 2, label, l);
	BN_bn2binpad(x, input + 2 + l, (int)f);
	input[n - 2] = bits;
	input[n - 1] = bits >> 8;
	for (unsigned counter = 1; on; counter++) {
		input[0] = counter;
		input[1] = counter >> 8;
		cchmac(s->di, s->di->output_size, key, n, input, mac);
		size_t take = on < s->di->output_size ? on : s->di->output_size;
		memcpy(out, mac, take);
		out += take;
		on -= take;
	}
	OPENSSL_cleanse(mac, sizeof mac);
}
API int ccsae_generate_commitment_init(struct ccsae_ctx *s)
{
	if (s->state != 1)
		return -86;
	s->kck[0] = 0;
	s->kck[1] = 1;
	s->kck[2] = 255;
	s->state |= 3;
	return 0;
}
API int ccsae_generate_commitment_partial(struct ccsae_ctx *s, const void *a, size_t an,
    const void *b, size_t bn, const void *password, size_t pn, const void *id, size_t idn,
    unsigned char iterations)
{
	if (s->state != 3 && s->state != 7)
		return -86;
	if (!iterations || an > 16 || bn > 16 || pn > 64 || idn > 64)
		return -7;
	unsigned remaining = s->maxloops - (s->kck[1] - 1);
	if (!remaining)
		return 0;
	if (iterations > remaining)
		iterations = remaining;
	BN_CTX *c = BN_CTX_new();
	EC_GROUP *g = group(s);
	BIGNUM *p = BN_new(), *aa = BN_new(), *bb = BN_new(), *x = BN_new(), *y2 = BN_new(),
	       *y = BN_new(), *r = BN_new();
	int ret = -13;
	unsigned char key[32], msg[129], seed[64], candidate[72];
	if (!c || !g || !p || !aa || !bb || !x || !y2 || !y || !r)
		goto done;
	EC_GROUP_get_curve(g, p, aa, bb, c);
	ccsae_lexographic_order_key(a, an, b, bn, key);
	memcpy(msg, password, pn);
	if (id && idn)
		memcpy(msg + pn, id, idn);
	else
		idn = 0;
	BN_one(r);
	BN_lshift(r, r, (int)s->cp->n * 64);
	BN_nnmod(r, r, p, c);
	for (unsigned i = 0; i < iterations; i++) {
		msg[pn + idn] = s->kck[1];
		cchmac(s->di, an + bn, key, pn + idn + 1, msg, seed);
		memcpy(part(s, 5), seed, s->di->output_size);
		kdf(s, seed, s->hunt_label, p, (unsigned)s->cp->bitlen, width(s), candidate);
		BN_bin2bn(candidate, (int)width(s), x);
		if (s->cp->bitlen % 8)
			BN_rshift(x, x, 8 - (int)(s->cp->bitlen % 8));
		savenum(s, 8, x);
		BN_mod_sqr(y2, x, p, c);
		BN_mod_mul(y2, y2, x, p, c);
		BN_mod_mul(y, aa, x, p, c);
		BN_mod_add(y2, y2, y, p, c);
		BN_mod_add(y2, y2, bb, p, c);
		if (BN_cmp(x, p) < 0 && BN_mod_sqrt(y, y2, p, c) && s->kck[2]) {
			savenum(s, 0, x);
			savenum(s, 1, y2);
			field_convert(s, part(s, 1), part(s, 1), 1);
			s->kck[0] = seed[s->di->output_size - 1] & 1;
			s->kck[2] = 0;
		}
		s->kck[1]++;
	}
	s->state |= 7;
	ret = s->kck[1] > s->maxloops ? 0 : -133;
done:
	BN_CTX_free(c);
	EC_GROUP_free(g);
	BN_clear_free(p);
	BN_clear_free(aa);
	BN_clear_free(bb);
	BN_clear_free(x);
	BN_clear_free(y2);
	BN_clear_free(y);
	BN_clear_free(r);
	OPENSSL_cleanse(seed, sizeof seed);
	return ret;
}
static int random_scalar(const struct ccsae_ctx *s, const EC_GROUP *g, BIGNUM *x)
{
	unsigned char b[72];
	BIGNUM *q = BN_dup(EC_GROUP_get0_order(g));
	if (!q)
		return -13;
	BN_sub_word(q, 1);
	int ret = -15;
	for (unsigned i = 0; i < 100; i++) {
		ret = s->rng->generate(s->rng, s->cp->n * 8, b);
		if (ret)
			break;
		BN_lebin2bn(b, (int)s->cp->n * 8, x);
		BN_mask_bits(x, BN_num_bits(q));
		if (BN_cmp(x, q) < 0) {
			BN_add_word(x, 1);
			ret = 0;
			break;
		}
		ret = -15;
	}
	BN_free(q);
	OPENSSL_cleanse(b, sizeof b);
	return ret;
}
static int multiply(const struct ccsae_ctx *s, const EC_GROUP *g, EC_POINT *out, const EC_POINT *p,
    const BIGNUM *x, BN_CTX *c)
{
	unsigned char b[32];
	int ret = s->rng->generate(s->rng, sizeof b, b);
	if (ret)
		return ret;
	BIGNUM *r = BN_bin2bn(b, sizeof b, NULL), *k = BN_new();
	OPENSSL_cleanse(b, sizeof b);
	int ok = r && k && BN_mul(k, r, EC_GROUP_get0_order(g), c) && BN_add(k, k, x);
	if (ok) {
		BN_set_flags(k, BN_FLG_CONSTTIME);
		ok = EC_POINT_mul(g, out, NULL, p, k, c);
	}
	BN_clear_free(r);
	BN_clear_free(k);
	return ok ? 0 : -7;
}
static int commit_shared(struct ccsae_ctx *s, void *out)
{
	BN_CTX *c = BN_CTX_new();
	EC_GROUP *g = group(s);
	EC_POINT *p = g ? readpoint(s, g, 0, c) : NULL;
	BIGNUM *r = BN_new(), *mask = BN_new(), *sum = BN_new();
	int ret = -7;
	if (!c || !g || !p || !r || !mask || !sum)
		goto done;
	if (random_scalar(s, g, r) || random_scalar(s, g, mask))
		goto done;
	savenum(s, 4, r);
	if (multiply(s, g, p, p, mask, c))
		goto done;
	EC_POINT_invert(g, p, c);
	if (savepoint(s, g, 5, p, c))
		goto done;
	BN_mod_add(sum, r, mask, EC_GROUP_get0_order(g), c);
	savenum(s, 3, sum);
	if (BN_is_zero(sum) || BN_is_one(sum))
		goto done;
	unsigned char *o = out;
	ccn_write_uint_padded_ct(s->cp->n, part(s, 3), width(s), o);
	ccn_write_uint_padded_ct(s->cp->n, part(s, 5), width(s), o + width(s));
	ccn_write_uint_padded_ct(s->cp->n, part(s, 6), width(s), o + 2 * width(s));
	ret = 0;
done:
	BN_CTX_free(c);
	EC_GROUP_free(g);
	EC_POINT_free(p);
	BN_clear_free(r);
	BN_clear_free(mask);
	BN_clear_free(sum);
	return ret;
}
API int ccsae_generate_commitment_finalize(struct ccsae_ctx *s, void *out)
{
	if (s->state != 7)
		return -86;
	if (s->kck[1] <= s->maxloops)
		return -132;
	if (s->kck[2])
		return -85;
	BN_CTX *c = BN_CTX_new();
	EC_GROUP *g = group(s);
	BIGNUM *p = BN_new(), *r = BN_new(), *y2 = readnum(s, 1), *y = BN_new();
	int ret = -13;
	if (!c || !g || !p || !r || !y2 || !y)
		goto done;
	EC_GROUP_get_curve(g, p, NULL, NULL, c);
	BN_one(r);
	BN_lshift(r, r, (int)s->cp->n * 64);
	cc_unit plain[9];
	field_convert(s, plain, part(s, 1), 0);
	BN_lebin2bn((void *)plain, (int)s->cp->n * 8, y2);
	if (!BN_mod_sqrt(y, y2, p, c)) {
		ret = -7;
		goto done;
	}
	if (BN_is_odd(y) != s->kck[0])
		BN_sub(y, p, y);
	savenum(s, 1, y);
	ret = commit_shared(s, out);
	if (!ret) {
		s->mode = 1;
		s->state |= 15;
	}
done:
	BN_CTX_free(c);
	EC_GROUP_free(g);
	BN_free(p);
	BN_clear_free(r);
	BN_clear_free(y2);
	BN_clear_free(y);
	return ret;
}
API int ccsae_generate_commitment(struct ccsae_ctx *s, const void *a, size_t an, const void *b,
    size_t bn, const void *p, size_t pn, const void *i, size_t in, void *out)
{
	int r = ccsae_generate_commitment_init(s);
	if (!r)
		r = ccsae_generate_commitment_partial(s, a, an, b, bn, p, pn, i, in, s->maxloops);
	if (!r)
		r = ccsae_generate_commitment_finalize(s, out);
	return r;
}
API int ccsae_generate_h2c_pt(const struct cch2c_info *i, const void *ssid, size_t sn,
    const void *p, size_t pn, const void *id, size_t in, void *out)
{
	if (pn > 64 || in > 64)
		return -7;
	unsigned char msg[128];
	memcpy(msg, p, pn);
	if (in)
		memcpy(msg + pn, id, in);
	struct ccec_ctx *q = calloc(1, 16 + 24 * i->cp()->n);
	if (!q)
		return -13;
	int ret = cch2c(i, sn, ssid, pn + in, msg, q);
	if (!ret)
		ret = ccec_export_pub(q, out);
	OPENSSL_cleanse(msg, sizeof msg);
	free(q);
	return ret;
}
API int ccsae_generate_h2c_commit_init(struct ccsae_ctx *s, const void *a, size_t an, const void *b,
    size_t bn, const void *pt, size_t n)
{
	if (s->state != 1)
		return -86;
	if (an > 16 || bn > 16)
		return -7;
	unsigned char key[32], zero[64] = {0}, hash[64];
	ccsae_lexographic_order_key(a, an, b, bn, key);
	cchmac(s->di, s->di->output_size, zero, an + bn, key, hash);
	BN_CTX *c = BN_CTX_new();
	EC_GROUP *g = group(s);
	EC_POINT *p = g ? EC_POINT_new(g) : NULL;
	BIGNUM *x = BN_bin2bn(hash, (int)s->di->output_size, NULL),
	       *q = g ? BN_dup(EC_GROUP_get0_order(g)) : NULL;
	int ret = -7;
	if (!c || !g || !p || !x || !q)
		goto done;
	if (n != 1 + 2 * width(s) || !pt || *(const unsigned char *)pt != 4 ||
	    !EC_POINT_oct2point(g, p, pt, n, c) || EC_POINT_is_at_infinity(g, p))
		goto done;
	BN_sub_word(q, 1);
	BN_nnmod(x, x, q, c);
	BN_add_word(x, 1);
	ret = multiply(s, g, p, p, x, c);
	if (!ret)
		ret = savepoint(s, g, 0, p, c);
	if (!ret) {
		field_convert(s, part(s, 0), part(s, 0), 1);
		field_convert(s, part(s, 1), part(s, 1), 1);
		memset(part(s, 2), 0, s->cp->n * 8);
		part(s, 2)[0] = 1;
		field_convert(s, part(s, 2), part(s, 2), 1);
		s->state |= 7;
	}
done:
	BN_CTX_free(c);
	EC_GROUP_free(g);
	EC_POINT_free(p);
	BN_clear_free(x);
	BN_free(q);
	OPENSSL_cleanse(hash, sizeof hash);
	return ret;
}
API int ccsae_generate_h2c_commit_finalize(struct ccsae_ctx *s, void *out)
{
	if (s->state != 7)
		return -86;
	cc_unit xy[27];
	for (unsigned i = 0; i < 3; i++)
		field_convert(s, xy + i * s->cp->n, part(s, i), 0);
	BN_CTX *c = BN_CTX_new();
	EC_GROUP *g = group(s);
	BIGNUM *x = BN_lebin2bn((void *)xy, (int)s->cp->n * 8, NULL),
	       *y = BN_lebin2bn((void *)(xy + s->cp->n), (int)s->cp->n * 8, NULL),
	       *z = BN_lebin2bn((void *)(xy + 2 * s->cp->n), (int)s->cp->n * 8, NULL),
	       *p = BN_new(), *zi = BN_new();
	int ok = c && g && x && y && z && p && zi && EC_GROUP_get_curve(g, p, NULL, NULL, c) &&
	    BN_mod_inverse(z, z, p, c) && BN_mod_sqr(zi, z, p, c) && BN_mod_mul(x, x, zi, p, c) &&
	    BN_mod_mul(zi, zi, z, p, c) && BN_mod_mul(y, y, zi, p, c);
	if (ok) {
		savenum(s, 0, x);
		savenum(s, 1, y);
	}
	BN_CTX_free(c);
	EC_GROUP_free(g);
	BN_clear_free(x);
	BN_clear_free(y);
	BN_clear_free(z);
	BN_free(p);
	BN_clear_free(zi);
	if (!ok)
		return -7;
	int r = commit_shared(s, out);
	if (!r) {
		s->mode = 2;
		s->state |= 15;
	}
	return r;
}
API int ccsae_generate_h2c_commit(struct ccsae_ctx *s, const void *a, size_t an, const void *b,
    size_t bn, const void *pt, size_t n, void *out)
{
	int r = ccsae_generate_h2c_commit_init(s, a, an, b, bn, pt, n);
	if (!r)
		r = ccsae_generate_h2c_commit_finalize(s, out);
	return r;
}
API int ccsae_verify_commitment_with_rejected_groups(
    struct ccsae_ctx *s, const void *in, size_t rn, const void *rejected)
{
	if (s->state != 15)
		return -86;
	size_t f = width(s);
	const unsigned char *b = in;
	ccn_read_uint(s->cp->n, part(s, 2), f, b);
	ccn_read_uint(s->cp->n, part(s, 7), f, b + f);
	ccn_read_uint(s->cp->n, part(s, 8), f, b + 2 * f);
	BN_CTX *c = BN_CTX_new();
	EC_GROUP *g = group(s);
	EC_POINT *p = g ? readpoint(s, g, 0, c) : NULL, *peer = g ? readpoint(s, g, 7, c) : NULL;
	BIGNUM *x = readnum(s, 2), *r = readnum(s, 4), *own = readnum(s, 3), *sum = BN_new(),
	       *shared = BN_new();
	int ret = -7;
	unsigned char seed[64], zero[64] = {0}, xb[72], keys[96];
	if (!c || !g || !p || !peer || !x || !r || !own || !sum || !shared)
		goto done;
	if (BN_is_zero(x) || BN_cmp(x, EC_GROUP_get0_order(g)) >= 0) {
		ret = -1;
		goto done;
	}
	if (BN_is_one(x) || !memcmp(part(s, 2), part(s, 3), s->cp->n * 8) ||
	    !memcmp(part(s, 7), part(s, 5), s->cp->n * 8) ||
	    !memcmp(part(s, 8), part(s, 6), s->cp->n * 8))
		goto done;
	if (multiply(s, g, p, p, x, c) || !EC_POINT_add(g, p, p, peer, c) ||
	    multiply(s, g, p, p, r, c) || !EC_POINT_get_affine_coordinates(g, p, shared, NULL, c))
		goto done;
	BN_bn2binpad(shared, xb, (int)f);
	cchmac(s->di, rn && rejected ? rn : s->di->output_size, rn && rejected ? rejected : zero, f,
	    xb, seed);
	BN_mod_add(sum, x, own, EC_GROUP_get0_order(g), c);
	size_t kn = kcklen(s);
	kdf(s, seed, s->keys_label, sum, (unsigned)(kn + 32) * 8, kn + 32, keys);
	memcpy(s->kck, keys, kn);
	memcpy(s->pmk, keys + kn, 32);
	s->state |= 23;
	ret = 0;
done:
	BN_CTX_free(c);
	EC_GROUP_free(g);
	EC_POINT_free(p);
	EC_POINT_free(peer);
	BN_clear_free(x);
	BN_clear_free(r);
	BN_clear_free(own);
	BN_clear_free(sum);
	BN_clear_free(shared);
	OPENSSL_cleanse(seed, sizeof seed);
	OPENSSL_cleanse(keys, sizeof keys);
	return ret;
}
API int ccsae_verify_commitment(struct ccsae_ctx *s, const void *in)
{
	return ccsae_verify_commitment_with_rejected_groups(s, in, 0, NULL);
}
static void confirmation(struct ccsae_ctx *s, const void *counter, int peer, void *out)
{
	unsigned char msg[398];
	memcpy(msg, counter, 2);
	unsigned order[6] = {3, 5, 6, 2, 7, 8};
	size_t f = width(s);
	for (unsigned i = 0; i < 6; i++)
		ccn_write_uint_padded_ct(
		    s->cp->n, part(s, order[(i + (peer ? 3 : 0)) % 6]), f, msg + 2 + i * f);
	cchmac(s->di, kcklen(s), s->kck, 2 + 6 * f, msg, out);
}
API int ccsae_generate_confirmation(struct ccsae_ctx *s, const void *counter, void *out)
{
	if (s->state < 31)
		return -86;
	confirmation(s, counter, 0, out);
	s->state |= 63;
	return 0;
}
API int ccsae_verify_confirmation(struct ccsae_ctx *s, const void *counter, const void *in)
{
	if (s->state != 31 && s->state != 63)
		return -86;
	unsigned char mac[64];
	confirmation(s, counter, 1, mac);
	s->state |= 95;
	int r = CRYPTO_memcmp(mac, in, s->di->output_size) ? 1 : 0;
	OPENSSL_cleanse(mac, sizeof mac);
	return r;
}
API int ccsae_get_keys(struct ccsae_ctx *s, void *kck, void *pmk, void *pmkid)
{
	if (s->state < 31)
		return -86;
	BN_CTX *c = BN_CTX_new();
	EC_GROUP *g = group(s);
	BIGNUM *a = readnum(s, 2), *b = readnum(s, 3);
	int ret = -13;
	unsigned char sum[72];
	if (!c || !g || !a || !b)
		goto done;
	BN_mod_add(a, a, b, EC_GROUP_get0_order(g), c);
	BN_bn2binpad(a, sum, (int)width(s));
	memcpy(kck, s->kck, kcklen(s));
	memcpy(pmk, s->pmk, 32);
	memcpy(pmkid, sum, 16);
	ret = 0;
done:
	BN_CTX_free(c);
	EC_GROUP_free(g);
	BN_clear_free(a);
	BN_clear_free(b);
	return ret;
}
