/* SPDX-License-Identifier: MIT OR Apache-2.0
 * NIST SP800-90A state machines using caller-supplied digest/cipher callbacks.
 * The exposed state and callback layouts were measured on the local system.
 */
#include "ccdrbg.h"
#include "cchmac.h"
#include <stdlib.h>
#include <string.h>
#define API __attribute__((visibility("default")))
#define MAX_INPUT 65536u
#define RESEED_LIMIT UINT64_C(0x1000000000000)
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}
static int hupdate(struct ccdrbg_hmac_state *s, size_t count, const struct ccdrbg_df_input *inputs)
{
	const struct ccdigest_info *di = s->custom->di;
	size_t h = di->output_size, total = 0;
	for (size_t i = 0; i < count; i++) {
		if (inputs[i].size > SIZE_MAX - total)
			return -63;
		total += inputs[i].size;
	}
	void *ctx = malloc(cchmac_di_size(di));
	if (!ctx)
		return -13;
	for (unsigned pass = 0; pass < (total ? 2u : 1u); pass++) {
		unsigned char b = (unsigned char)pass;
		cchmac_init(di, ctx, h, s->key);
		cchmac_update(di, ctx, h, s->v);
		cchmac_update(di, ctx, 1, &b);
		for (size_t i = 0; i < count; i++)
			if (inputs[i].size)
				cchmac_update(di, ctx, inputs[i].size, inputs[i].data);
		cchmac_final(di, ctx, s->key);
		cchmac(di, h, s->key, h, s->v, s->v);
	}
	wipe(ctx, cchmac_di_size(di));
	free(ctx);
	return 0;
}
static int hinit(const struct ccdrbg_info *info, void *state, size_t en, const void *e, size_t nn,
    const void *n, size_t pn, const void *p)
{
	struct ccdrbg_hmac_state *s = state;
	s->custom = info->custom;
	size_t h = s->custom->di->output_size;
	if (en > MAX_INPUT || pn > MAX_INPUT || h > 64 || !h || en < h / 2)
		return -63;
	memset(s->key, 0, h);
	memset(s->v, 1, h);
	struct ccdrbg_df_input input[] = {{e, en}, {n, nn}, {p, pn}};
	int ret = hupdate(s, 3, input);
	if (!ret)
		s->counter = 1;
	return ret;
}
static bool hmust(void *state)
{
	struct ccdrbg_hmac_state *s = state;
	return s->custom->strict && s->counter > RESEED_LIMIT;
}
static int hgenerate(void *state, size_t n, void *out, size_t an, const void *a)
{
	struct ccdrbg_hmac_state *s = state;
	const struct ccdigest_info *di = s->custom->di;
	size_t h = di->output_size;
	if (n > MAX_INPUT || an > MAX_INPUT)
		return -63;
	if (hmust(s))
		return -62;
	struct ccdrbg_df_input input = {a, an};
	int ret = an ? hupdate(s, 1, &input) : 0;
	unsigned char *o = out;
	while (!ret && n) {
		unsigned char prev[64];
		memcpy(prev, s->v, h);
		cchmac(di, h, s->key, h, s->v, s->v);
		if (!memcmp(prev, s->v, h)) {
			wipe(s->key, 64);
			wipe(s->v, 64);
			s->counter = UINT64_MAX;
			return -64;
		}
		size_t z = n < h ? n : h;
		memcpy(o, s->v, z);
		o += z;
		n -= z;
	}
	if (!ret)
		ret = hupdate(s, 1, &input);
	if (!ret)
		s->counter++;
	return ret;
}
static int hreseed(void *state, size_t en, const void *e, size_t an, const void *a)
{
	struct ccdrbg_hmac_state *s = state;
	if (en > MAX_INPUT || an > MAX_INPUT || en < s->custom->di->output_size / 2)
		return -63;
	struct ccdrbg_df_input inputs[] = {{e, en}, {a, an}};
	int ret = hupdate(s, 2, inputs);
	if (!ret)
		s->counter = 1;
	return ret;
}
static void hdone(void *state)
{
	struct ccdrbg_hmac_state *s = state;
	wipe(s->key, 64);
	wipe(s->v, 64);
	s->counter = UINT64_MAX;
}
API void ccdrbg_factory_nisthmac(struct ccdrbg_info *i, const struct ccdrbg_custom_hmac *c)
{
	*i = (struct ccdrbg_info){
	    sizeof(struct ccdrbg_hmac_state), hinit, hreseed, hgenerate, hdone, c, hmust};
}
static int df_derive(const struct ccdrbg_df *df, size_t count, const struct ccdrbg_df_input *in,
    size_t out_n, void *out)
{
	size_t total = 0;
	for (size_t i = 0; i < count; i++) {
		if (in[i].size > UINT32_MAX - total)
			return -63;
		total += in[i].size;
	}
	if (out_n > UINT32_MAX)
		return -63;
	size_t n = (24 + total + 1 + 15) & ~(size_t)15;
	unsigned char *b = calloc(1, n), *enc = malloc(n), *ctx = calloc(1, df->cbc->size);
	if (!b || !enc || !ctx) {
		free(b);
		free(enc);
		free(ctx);
		return -13;
	}
	uint32_t l = __builtin_bswap32((uint32_t)total), r = __builtin_bswap32((uint32_t)out_n);
	memcpy(b + 16, &l, 4);
	memcpy(b + 20, &r, 4);
	size_t off = 24;
	for (size_t i = 0; i < count; i++) {
		if (in[i].size)
			memcpy(b + off, in[i].data, in[i].size);
		off += in[i].size;
	}
	b[off] = 0x80;
	unsigned char temp[48] = {0}, iv[16], x[16];
	int ret = 0;
	for (size_t i = 0; i < df->key_size + 16; i += 16) {
		uint32_t counter = __builtin_bswap32((uint32_t)(i / 16));
		memcpy(b, &counter, 4);
		memset(iv, 0, 16);
		ret = df->cbc->cbc(df->ctx, iv, n / 16, b, enc);
		if (ret)
			goto done;
		memcpy(temp + i, enc + n - 16, 16);
	}
	ret = df->cbc->init(df->cbc, ctx, df->key_size, temp);
	if (ret)
		goto done;
	memcpy(x, temp + df->key_size, 16);
	unsigned char *o = out;
	while (out_n) {
		memset(iv, 0, 16);
		ret = df->cbc->cbc(ctx, iv, 1, x, x);
		if (ret)
			goto done;
		size_t z = out_n < 16 ? out_n : 16;
		memcpy(o, x, z);
		o += z;
		out_n -= z;
	}
done:
	wipe(temp, sizeof(temp));
	wipe(x, sizeof(x));
	wipe(ctx, df->cbc->size);
	wipe(b, n);
	wipe(enc, n);
	free(b);
	free(enc);
	free(ctx);
	return ret;
}
API int ccdrbg_df_bc_init(struct ccdrbg_df *df, const struct ccmode_cbc *cbc, size_t key_size)
{
	if (key_size > 32 || cbc->size > 512 || cbc->block_size != 16)
		return -5;
	unsigned char key[32];
	for (unsigned i = 0; i < 32; i++)
		key[i] = (unsigned char)i;
	df->derive = df_derive;
	df->cbc = cbc;
	df->key_size = key_size;
	return cbc->init(cbc, df->ctx, key_size, key);
}
static void increment(unsigned char *v)
{
	for (int i = 15; i >= 8; i--)
		if (++v[i])
			break;
}
static int ctr_start(struct ccdrbg_ctr_state *s, void *ctx)
{
	increment(s->v);
	return s->ctr->init(s->ctr, ctx, s->key_size, s->key, s->v);
}
static int ctr_finish(struct ccdrbg_ctr_state *s, void *ctx, const unsigned char *seed)
{
	unsigned char zero[48] = {0}, temp[48];
	int ret = s->ctr->ctr(ctx, s->key_size + 16, seed ? seed : zero, temp);
	if (!ret) {
		memcpy(s->key, temp, s->key_size);
		memcpy(s->v, temp + s->key_size, 16);
	}
	wipe(temp, sizeof(temp));
	return ret;
}
static int cupdate(struct ccdrbg_ctr_state *s, const unsigned char *seed)
{
	void *ctx = calloc(1, s->ctr->size);
	if (!ctx)
		return -13;
	int ret = ctr_start(s, ctx);
	if (!ret)
		ret = ctr_finish(s, ctx, seed);
	wipe(ctx, s->ctr->size);
	free(ctx);
	return ret;
}
static void cdone(void *state)
{
	struct ccdrbg_ctr_state *s = state;
	wipe(s->key, 32);
	wipe(s->v, 16);
	s->counter = UINT64_MAX;
}
static int cinit(const struct ccdrbg_info *info, void *state, size_t en, const void *e, size_t nn,
    const void *n, size_t pn, const void *p)
{
	struct ccdrbg_ctr_state *s = state;
	const struct ccdrbg_custom_ctr *c = info->custom;
	memset(s, 0, sizeof(*s));
	s->ctr = c->ctr;
	s->key_size = c->key_size;
	s->strict = c->strict;
	s->df = c->df;
	unsigned char seed[48] = {0};
	int ret = -63;
	if (s->key_size > 32 || s->ctr->ecb_block_size != 16)
		goto done;
	if (s->df) {
		if (en < 16 || en > MAX_INPUT || pn > MAX_INPUT)
			goto done;
		struct ccdrbg_df_input inputs[] = {{e, en}, {n, nn}, {p, pn}};
		ret = s->df->derive(s->df, 3, inputs, s->key_size + 16, seed);
		if (ret)
			goto done;
	} else {
		if (en != s->key_size + 16 || pn > en)
			goto done;
		memcpy(seed, e, en);
		for (size_t i = 0; i < pn; i++)
			seed[i] ^= ((const unsigned char *)p)[i];
	}
	ret = cupdate(s, seed);
	if (!ret)
		s->counter = 1;
done:
	if (ret)
		cdone(s);
	wipe(seed, sizeof(seed));
	return ret;
}
static bool cmust(void *state)
{
	struct ccdrbg_ctr_state *s = state;
	return s->strict && s->counter > RESEED_LIMIT;
}
static int cgenerate(void *state, size_t n, void *out, size_t an, const void *a)
{
	struct ccdrbg_ctr_state *s = state;
	if (n > MAX_INPUT || (s->df ? an > MAX_INPUT : an > s->key_size + 16))
		return -63;
	if (cmust(s))
		return -62;
	unsigned char seed[48] = {0}, zero[128] = {0}, tail[16];
	int ret = 0;
	if (an) {
		if (s->df) {
			struct ccdrbg_df_input input = {a, an};
			ret = s->df->derive(s->df, 1, &input, s->key_size + 16, seed);
		} else
			memcpy(seed, a, an);
		if (!ret)
			ret = cupdate(s, seed);
		if (ret)
			goto done;
	}
	void *ctx = calloc(1, s->ctr->size);
	if (!ctx) {
		ret = -13;
		goto done;
	}
	ret = ctr_start(s, ctx);
	unsigned char *o = out;
	size_t rem = n;
	while (!ret && rem) {
		size_t z = rem < 128 ? rem : 128;
		ret = s->ctr->ctr(ctx, z, zero, o);
		o += z;
		rem -= z;
	}
	if (!ret)
		ret = s->ctr->ctr(ctx, (-n) & 15, zero, tail);
	if (!ret)
		ret = ctr_finish(s, ctx, seed);
	wipe(ctx, s->ctr->size);
	free(ctx);
	if (!ret)
		s->counter++;
done:
	wipe(seed, sizeof(seed));
	wipe(tail, sizeof(tail));
	return ret;
}
static int creseed(void *state, size_t en, const void *e, size_t an, const void *a)
{
	struct ccdrbg_ctr_state *s = state;
	unsigned char seed[48] = {0};
	int ret = -63;
	if (s->df) {
		if (en < 16 || en > MAX_INPUT || an > MAX_INPUT)
			goto done;
		struct ccdrbg_df_input inputs[] = {{e, en}, {a, an}};
		ret = s->df->derive(s->df, 2, inputs, s->key_size + 16, seed);
		if (ret)
			goto done;
	} else {
		if (en != s->key_size + 16 || an > en)
			goto done;
		memcpy(seed, e, en);
		for (size_t i = 0; i < an; i++)
			seed[i] ^= ((const unsigned char *)a)[i];
	}
	ret = cupdate(s, seed);
	if (!ret)
		s->counter = 1;
done:
	wipe(seed, sizeof(seed));
	return ret;
}
API void ccdrbg_factory_nistctr(struct ccdrbg_info *i, const struct ccdrbg_custom_ctr *c)
{
	*i = (struct ccdrbg_info){
	    sizeof(struct ccdrbg_ctr_state), cinit, creseed, cgenerate, cdone, c, cmust};
}
API bool ccdrbg_must_reseed(const struct ccdrbg_info *i, void *s)
{
	return i->must_reseed(s);
}
