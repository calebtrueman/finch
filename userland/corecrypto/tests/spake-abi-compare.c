/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccspake.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int checks, fail;
#define CK(x)                                                                                      \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(x)) {                                                                        \
			fail++;                                                                    \
			fprintf(stderr, "line %d: %s (curve %u mac %u variant %u)\n", __LINE__,    \
			    #x, curve, mac_i, variant);                                            \
		}                                                                                  \
	} while (0)
#define LOAD(ret, name, args)                                                                      \
	ret(*h_##name) args = dlsym(h, #name);                                                     \
	ret(*f_##name) args = dlsym(f, #name);                                                     \
	if (!h_##name || !f_##name) {                                                              \
		puts(#name);                                                                       \
		return 2;                                                                          \
	}
static int random_(struct ccrng_state *r, size_t n, void *p)
{
	(void)r;
	memset(p, 0x59, n);
	return 0;
}
static int equal_context(const void *a, const void *b, size_t n)
{
	const unsigned char *x = a, *y = b;
	for (size_t i = 24; i < n; i++)
		if (x[i] != y[i]) {
			fprintf(stderr, "context mismatch offset=%zu host=%02x finch=%02x\n", i,
			    x[i], y[i]);
			return 0;
		}
	return 1;
}
int main(int argc, char **argv)
{
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", 2),
	     *f = dlopen(argc > 1 ? argv[1] : "build/userland/corecrypto/spake-test.dylib", 2);
	if (!h || !f) {
		puts(dlerror());
		return 2;
	}
	LOAD(size_t, ccspake_sizeof_ctx, (const struct ccspake_cp *));
	LOAD(size_t, ccspake_sizeof_w, (const struct ccspake_cp *));
	LOAD(size_t, ccspake_sizeof_point, (const struct ccspake_cp *));
	LOAD(int, ccspake_reduce_w,
	    (const struct ccspake_cp *, size_t, const void *, size_t, void *));
	LOAD(int, ccspake_reduce_w_RFC9383,
	    (const struct ccspake_cp *, size_t, const void *, size_t, void *));
	LOAD(int, ccspake_generate_L,
	    (const struct ccspake_cp *, size_t, const void *, size_t, void *,
	        struct ccrng_state *));
	LOAD(int, ccspake_prover_init,
	    (struct ccspake_ctx *, const struct ccspake_cp *, const struct ccspake_mac *,
	        struct ccrng_state *, size_t, const void *, size_t, const void *, const void *));
	LOAD(int, ccspake_verifier_init,
	    (struct ccspake_ctx *, const struct ccspake_cp *, const struct ccspake_mac *,
	        struct ccrng_state *, size_t, const void *, size_t, const void *, size_t,
	        const void *));
	LOAD(int, ccspake_prover_initialize,
	    (struct ccspake_ctx *, const struct ccspake_cp *, const struct ccspake_mac *,
	        struct ccrng_state *, size_t, const void *, size_t, const void *, size_t,
	        const void *, size_t, const void *, const void *));
	LOAD(int, ccspake_verifier_initialize,
	    (struct ccspake_ctx *, const struct ccspake_cp *, const struct ccspake_mac *,
	        struct ccrng_state *, size_t, const void *, size_t, const void *, size_t,
	        const void *, size_t, const void *, size_t, const void *));
	LOAD(int, ccspake_kex_generate, (struct ccspake_ctx *, size_t, void *));
	LOAD(int, ccspake_kex_process, (struct ccspake_ctx *, size_t, const void *));
	LOAD(int, ccspake_mac_compute, (struct ccspake_ctx *, size_t, void *));
	LOAD(int, ccspake_mac_verify_and_get_session_key,
	    (struct ccspake_ctx *, size_t, const void *, size_t, void *));
	LOAD(int, ccspake_get_session_key, (struct ccspake_ctx *, size_t, void *));
	const unsigned bits[] = {256, 384, 521};
	const char *mac_names[] = {"ccspake_mac_hkdf_hmac_sha256", "ccspake_mac_hkdf_hmac_sha512",
	    "ccspake_mac_hkdf_cmac_aes128_sha256"};
	struct ccrng_state rng = {random_};
	for (unsigned foreign = 0; foreign < 4; foreign++)
		for (unsigned curve = 0; curve < 3; curve++)
			for (unsigned mac_i = 0; mac_i < 3; mac_i++)
				for (unsigned variant = 0; variant < 2; variant++) {
					char name[80];
					sprintf(name, "ccspake_cp_%u%s", bits[curve],
					    variant ? "_rfc" : "");
					const struct ccspake_cp *(*hcp)(void) = dlsym(h, name),
					                        *(*fcp)(void) = dlsym(f, name);
					const struct ccspake_mac *(*hmac)(
					    void) = dlsym(h, mac_names[mac_i]),
				   *(*fmac)(void) = dlsym(f, mac_names[mac_i]);
					const struct ccspake_cp *hp = hcp(),
					                        *fp = foreign & 1 ? hp : fcp();
					const struct ccspake_mac *hm = hmac(),
					                         *fm = foreign & 2 ? hm : fmac();
					size_t n = h_ccspake_sizeof_ctx(hp),
					       wn = h_ccspake_sizeof_w(hp),
					       ln = h_ccspake_sizeof_point(hp),
					       kn = variant ? 32 : hm->digest()->output_size / 2;
					CK(n == f_ccspake_sizeof_ctx(fp));
					CK(wn == f_ccspake_sizeof_w(fp));
					CK(ln == f_ccspake_sizeof_point(fp));
					CK(hm->tag_size == fm->tag_size);
					CK(hm->key_size == fm->key_size);
					CK(!memcmp(hp->m, fp->m, hp->curve()->n * 16));
					CK(!memcmp(hp->n, fp->n, hp->curve()->n * 16));
					unsigned char w0[128], w1[128], entropy[128], hl[133],
					    fl[133], hpub[133], fpub[133], hvpub[133], fvpub[133],
					    htag[64], ftag[64], hvtag[64], fvtag[64], hk[64],
					    fk[64];
					for (unsigned j = 0; j < 128; j++) {
						w0[j] = j + 1;
						w1[j] = j + 7;
						entropy[j] = j * 3 + 1;
					}
					if (variant) {
						int a = h_ccspake_reduce_w(
						        hp, wn + 8, entropy, wn, w0),
						    b = f_ccspake_reduce_w(
						        fp, wn + 8, entropy, wn, w1);
						CK(a == b);
						CK(!memcmp(w0, w1, wn));
						a = h_ccspake_reduce_w_RFC9383(
						    hp, wn + 8, entropy, wn, w0);
						b = f_ccspake_reduce_w_RFC9383(
						    fp, wn + 8, entropy, wn, w1);
						CK(a == b);
						CK(!memcmp(w0, w1, wn));
						w1[wn - 1] ^= 1;
					}
					unsigned char zero[160] = {0};
					CK(h_ccspake_reduce_w(hp, wn + 7, entropy, wn, fl) ==
					    f_ccspake_reduce_w(fp, wn + 7, entropy, wn, hl));
					CK(h_ccspake_reduce_w_RFC9383(hp, wn + 8, zero, wn, fl) ==
					    f_ccspake_reduce_w_RFC9383(fp, wn + 8, zero, wn, hl));
					{
						int eh = h_ccspake_generate_L(
						        hp, wn, zero, ln, hl, &rng),
						    ef = f_ccspake_generate_L(
						        fp, wn, zero, ln, fl, &rng);
						if (eh != ef)
							fprintf(stderr, "zero L %d %d\n", eh, ef);
						CK(eh == ef);
					}
					int a = h_ccspake_generate_L(hp, wn, w1, ln, hl, &rng),
					    b = f_ccspake_generate_L(fp, wn, w1, ln, fl, &rng);
					if (a != b)
						fprintf(stderr, "L %d %d\n", a, b);
					CK(a == b);
					CK(!memcmp(hl, fl, ln));
					unsigned char hc[1024], fc[1024], hv[1024], fv[1024];
					struct ccspake_ctx *ch = (void *)hc, *cf = (void *)fc,
					                   *vh = (void *)hv, *vf = (void *)fv;
					if (!variant) {
						a = h_ccspake_prover_init(
						    ch, hp, hm, &rng, 4, "test", wn, w0, w1);
						b = f_ccspake_prover_init(
						    cf, fp, fm, &rng, 4, "test", wn, w0, w1);
					} else {
						a = h_ccspake_prover_initialize(ch, hp, hm, &rng, 4,
						    "test", 5, "alice", 3, "bob", wn, w0, w1);
						b = f_ccspake_prover_initialize(cf, fp, fm, &rng, 4,
						    "test", 5, "alice", 3, "bob", wn, w0, w1);
					}
					CK(a == b);
					CK(equal_context(ch, cf, n));
					if (!variant) {
						a = h_ccspake_verifier_init(
						    vh, hp, hm, &rng, 4, "test", wn, w0, ln, hl);
						b = f_ccspake_verifier_init(
						    vf, fp, fm, &rng, 4, "test", wn, w0, ln, fl);
					} else {
						a = h_ccspake_verifier_initialize(vh, hp, hm, &rng,
						    4, "test", 5, "alice", 3, "bob", wn, w0, ln,
						    hl);
						b = f_ccspake_verifier_initialize(vf, fp, fm, &rng,
						    4, "test", 5, "alice", 3, "bob", wn, w0, ln,
						    fl);
					}
					CK(a == b);
					CK(equal_context(vh, vf, n));
					CK(h_ccspake_get_session_key(ch, kn, hk) ==
					    f_ccspake_get_session_key(cf, kn, fk));
					{
						int eh = h_ccspake_kex_process(ch, ln, zero),
						    ef = f_ccspake_kex_process(cf, ln, zero);
						if (eh != ef)
							fprintf(
							    stderr, "zero peer %d %d\n", eh, ef);
						CK(eh == ef);
					}
					zero[0] = 4;
					{
						int eh = h_ccspake_kex_process(ch, ln, zero),
						    ef = f_ccspake_kex_process(cf, ln, zero);
						if (eh != ef)
							fprintf(stderr, "offcurve peer %d %d\n", eh,
							    ef);
						CK(eh == ef);
					}
					zero[0] = 0;
					CK(h_ccspake_mac_compute(ch, hm->tag_size, htag) ==
					    f_ccspake_mac_compute(cf, fm->tag_size, ftag));
					a = h_ccspake_kex_generate(ch, ln, hpub);
					b = f_ccspake_kex_generate(cf, ln, fpub);
					CK(a == b);
					CK(!memcmp(hpub, fpub, ln));
					CK(equal_context(ch, cf, n));
					a = h_ccspake_kex_generate(vh, ln, hvpub);
					b = f_ccspake_kex_generate(vf, ln, fvpub);
					CK(a == b);
					CK(!memcmp(hvpub, fvpub, ln));
					CK(equal_context(vh, vf, n));
					CK(h_ccspake_kex_generate(ch, ln, hpub) ==
					    f_ccspake_kex_generate(cf, ln, fpub));
					CK(h_ccspake_kex_process(ch, ln, hpub) ==
					    f_ccspake_kex_process(cf, ln, fpub));
					a = h_ccspake_kex_process(ch, ln, hvpub);
					b = f_ccspake_kex_process(cf, ln, fvpub);
					if (a != b)
						fprintf(stderr, "process %d %d\n", a, b);
					CK(a == b);
					CK(equal_context(ch, cf, n));
					a = h_ccspake_kex_process(vh, ln, hpub);
					b = f_ccspake_kex_process(vf, ln, fpub);
					CK(a == b);
					CK(equal_context(vh, vf, n));
					CK(h_ccspake_get_session_key(ch, kn, hk) ==
					    f_ccspake_get_session_key(cf, kn, fk));
					CK(!memcmp(hk, fk, kn));
					a = h_ccspake_mac_compute(ch, hm->tag_size, htag);
					b = f_ccspake_mac_compute(cf, fm->tag_size, ftag);
					CK(a == b);
					CK(!memcmp(htag, ftag, hm->tag_size));
					a = h_ccspake_mac_compute(vh, hm->tag_size, hvtag);
					b = f_ccspake_mac_compute(vf, fm->tag_size, fvtag);
					CK(a == b);
					CK(!memcmp(hvtag, fvtag, hm->tag_size));
					CK(h_ccspake_mac_compute(ch, hm->tag_size, htag) ==
					    f_ccspake_mac_compute(cf, fm->tag_size, ftag));
					fvtag[0] ^= 1;
					hvtag[0] ^= 1;
					CK(h_ccspake_mac_verify_and_get_session_key(
					       ch, hm->tag_size, fvtag, kn, hk) ==
					    f_ccspake_mac_verify_and_get_session_key(
					        cf, fm->tag_size, hvtag, kn, fk));
					fvtag[0] ^= 1;
					hvtag[0] ^= 1;
					a = h_ccspake_mac_verify_and_get_session_key(
					    ch, hm->tag_size, fvtag, kn, hk);
					b = f_ccspake_mac_verify_and_get_session_key(
					    cf, fm->tag_size, hvtag, kn, fk);
					if (a != b || a)
						fprintf(stderr, "verify %d %d\n", a, b);
					CK(a == b);
					CK(a == 0);
					CK(!memcmp(hk, fk, kn));
					CK(equal_context(ch, cf, n));
				}
	printf("SPAKE ABI: %d checks, %d failures\n", checks, fail);
	return !!fail;
}
