/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccsae.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define FN(N) __typeof__(&N) h_##N = dlsym(h, #N), f_##N = dlsym(f, #N)
static int checks, failures;
#define CHECK(X)                                                                                   \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(X)) {                                                                        \
			fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #X);                       \
			failures++;                                                                \
		}                                                                                  \
	} while (0)
struct rng {
	struct ccrng_state r;
	unsigned seed;
};
static int random_bytes(struct ccrng_state *r, size_t n, void *out)
{
	unsigned seed = ((struct rng *)r)->seed;
	for (size_t i = 0; i < n; i++)
		((unsigned char *)out)[i] = (unsigned char)(seed + i * 13);
	return 0;
}
int main(int argc, char **argv)
{
	setbuf(stdout, NULL);
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argc > 1 ? argv[1] : "build/userland/corecrypto/sae-test.dylib",
	         RTLD_NOW | RTLD_LOCAL);
	if (!h || !f) {
		fprintf(stderr, "%s\n", dlerror());
		return 2;
	}
	FN(ccsae_init);
	FN(ccsae_sizeof_ctx);
	FN(ccsae_sizeof_commitment);
	FN(ccsae_sizeof_confirmation);
	FN(ccsae_sizeof_kck);
	FN(ccsae_sizeof_kck_h2c);
	FN(ccsae_generate_commitment);
	FN(ccsae_generate_commitment_init);
	FN(ccsae_generate_commitment_partial);
	FN(ccsae_generate_commitment_finalize);
	FN(ccsae_verify_commitment);
	FN(ccsae_generate_confirmation);
	FN(ccsae_verify_confirmation);
	FN(ccsae_get_keys);
	FN(ccsae_generate_h2c_pt);
	FN(ccsae_generate_h2c_commit);
	FN(ccsae_sizeof_pt);
	FN(ccsae_generate_h2c_commit_init);
	FN(ccsae_generate_h2c_commit_finalize);
	FN(ccsae_verify_commitment_with_rejected_groups);
	(void)f_ccsae_generate_commitment;
	(void)f_ccsae_generate_h2c_commit;
	const char *curves[] = {"ccec_cp_256", "ccec_cp_384", "ccec_cp_521"},
	           *digests[] = {"ccsha256_di", "ccsha384_di", "ccsha512_di"},
	           *h2c[] = {
	               "cch2c_p256_sha256_sae_compat_info", "cch2c_p384_sha384_sae_compat_info"};
	for (unsigned cross = 0; cross < 4; cross++)
		for (unsigned which = 0; which < 3; which++)
			for (unsigned mode = 0; mode < (which < 2 ? 2u : 1u); mode++) {
				const struct cczp *cp = ((const struct cczp *(*)(void))dlsym(
				    (cross & 1) ? f : h, curves[which]))();
				const struct ccdigest_info *di =
				    ((const struct ccdigest_info *(*)(void))dlsym(
				        (cross & 2) ? f : h, digests[which]))();
				size_t sz = h_ccsae_sizeof_ctx(cp);
				CHECK(sz == f_ccsae_sizeof_ctx(cp));
				struct ccsae_ctx *a = calloc(1, sz), *b = calloc(1, sz),
				                 *peer = calloc(1, sz);
				struct rng ra = {{random_bytes}, 7}, rb = {{random_bytes}, 7},
				           rp = {{random_bytes}, 55};
				CHECK(!h_ccsae_init(a, cp, &ra.r, di));
				CHECK(!f_ccsae_init(b, cp, &rb.r, di));
				CHECK(!h_ccsae_init(peer, cp, &rp.r, di));
				CHECK(!strcmp(a->keys_label, b->keys_label));
				CHECK(!strcmp(a->hunt_label, b->hunt_label));
				CHECK(h_ccsae_sizeof_commitment(a) == f_ccsae_sizeof_commitment(b));
				CHECK(h_ccsae_sizeof_confirmation(a) ==
				    f_ccsae_sizeof_confirmation(b));
				CHECK(h_ccsae_sizeof_kck(a) == f_ccsae_sizeof_kck(b));
				CHECK(h_ccsae_sizeof_kck_h2c(a) == f_ccsae_sizeof_kck_h2c(b));
				unsigned char ca[200], cb[200], pc[200], pt[140], ft[140];
				int x, y, z;
				unsigned char states[] = {0, 1, 3, 7, 15, 23, 31, 63, 95, 127};
				for (unsigned si = 0; si < sizeof states; si++) {
					struct ccsae_ctx *ta = malloc(sz), *tb = malloc(sz);
					memcpy(ta, a, sz);
					memcpy(tb, b, sz);
					ta->state = tb->state = states[si];
					CHECK(h_ccsae_generate_commitment_init(ta) ==
					    f_ccsae_generate_commitment_init(tb));
					CHECK(ta->state == tb->state);
					memcpy(ta, a, sz);
					memcpy(tb, b, sz);
					ta->state = tb->state = states[si];
					CHECK(h_ccsae_generate_commitment_partial(
					          ta, "a", 1, "b", 1, "p", 1, NULL, 0, 0) ==
					    f_ccsae_generate_commitment_partial(
					        tb, "a", 1, "b", 1, "p", 1, NULL, 0, 0));
					CHECK(h_ccsae_generate_commitment_finalize(ta, ca) ==
					    f_ccsae_generate_commitment_finalize(tb, cb));
					free(ta);
					free(tb);
				}
				if (!mode) {
					CHECK(!h_ccsae_generate_commitment_init(a));
					CHECK(!f_ccsae_generate_commitment_init(b));
					for (unsigned j = 0; j < 4; j++) {
						x = h_ccsae_generate_commitment_partial(a, "alpha",
						    5, "beta", 4, "password", 8, "id", 2, 10);
						y = f_ccsae_generate_commitment_partial(b, "alpha",
						    5, "beta", 4, "password", 8, "id", 2, 10);
						CHECK(x == y);
						CHECK(!memcmp(a->data, b->data, cp->n * 8 * 2));
						CHECK(!memcmp(a->kck, b->kck, 64));
						CHECK(a->state == b->state);
					}
					x = h_ccsae_generate_commitment_finalize(a, ca);
					y = f_ccsae_generate_commitment_finalize(b, cb);
					z = h_ccsae_generate_commitment(peer, "beta", 4, "alpha", 5,
					    "password", 8, "id", 2, pc);
				} else {
					const struct cch2c_info *i =
					    dlsym((cross & 1) ? f : h, h2c[which]);
					CHECK(h_ccsae_sizeof_pt(i) == f_ccsae_sizeof_pt(i));
					CHECK(!h_ccsae_generate_h2c_pt(
					    i, "ssid", 4, "password", 8, "id", 2, pt));
					CHECK(!f_ccsae_generate_h2c_pt(
					    i, "ssid", 4, "password", 8, "id", 2, ft));
					CHECK(!memcmp(pt, ft, h_ccsae_sizeof_pt(i)));
					CHECK(!h_ccsae_generate_h2c_commit_init(
					    a, "alpha", 5, "beta", 4, pt, h_ccsae_sizeof_pt(i)));
					CHECK(!f_ccsae_generate_h2c_commit_init(
					    b, "alpha", 5, "beta", 4, pt, h_ccsae_sizeof_pt(i)));
					x = f_ccsae_generate_h2c_commit_finalize(a, ca);
					y = h_ccsae_generate_h2c_commit_finalize(b, cb);
					z = h_ccsae_generate_h2c_commit(peer, "beta", 4, "alpha", 5,
					    pt, h_ccsae_sizeof_pt(i), pc);
				}
				CHECK(x == y);
				CHECK(!x);
				CHECK(!z);
				CHECK(!memcmp(ca, cb, h_ccsae_sizeof_commitment(a)));
				for (unsigned part = 0; part < 9; part++)
					if (part != 2 && part != 7)
						CHECK(!memcmp(a->data + part * cp->n,
						    b->data + part * cp->n, cp->n * 8));
				struct ccsae_ctx *ea = malloc(sz), *eb = malloc(sz);
				unsigned char bad[200];
				for (unsigned invalid = 0; invalid < 6; invalid++) {
					memcpy(ea, a, sz);
					memcpy(eb, b, sz);
					memcpy(bad, pc, h_ccsae_sizeof_commitment(a));
					size_t field = h_ccsae_sizeof_commitment(a) / 3;
					if (invalid == 0)
						memset(bad, 0, field);
					if (invalid == 1) {
						memset(bad, 0, field);
						bad[field - 1] = 1;
					}
					if (invalid == 2)
						memset(bad, 255, field);
					if (invalid == 3)
						memcpy(bad, ca, h_ccsae_sizeof_commitment(a));
					if (invalid == 4)
						memset(bad + field, 0, 2 * field);
					if (invalid == 5)
						bad[2 * field] ^= 1;
					int hr = h_ccsae_verify_commitment(ea, bad),
					    fr = f_ccsae_verify_commitment(eb, bad);
					if (hr != fr)
						fprintf(stderr, "bad %u host%d finch%d\n", invalid,
						    hr, fr);
					CHECK(hr == fr);
				}
				for (unsigned rn = 0; rn < 5; rn++) {
					memcpy(ea, a, sz);
					memcpy(eb, b, sz);
					CHECK(h_ccsae_verify_commitment_with_rejected_groups(
					          ea, pc, rn, "abcd") ==
					    f_ccsae_verify_commitment_with_rejected_groups(
					        eb, pc, rn, "abcd"));
					CHECK(!memcmp(ea->kck, eb->kck, 64));
					CHECK(!memcmp(ea->pmk, eb->pmk, 32));
				}
				free(ea);
				free(eb);
				x = h_ccsae_verify_commitment(a, pc);
				y = f_ccsae_verify_commitment(b, pc);
				z = h_ccsae_verify_commitment(peer, cb);
				CHECK(x == y);
				CHECK(!x);
				CHECK(!z);
				CHECK(!memcmp(a->kck, b->kck, 64));
				CHECK(!memcmp(a->pmk, b->pmk, 32));
				CHECK(!memcmp(a->data, b->data, cp->n * 8 * 9));
				unsigned char ka[128] = {0}, kb[128] = {0}, ma[64], mb[64], mp[64],
				              counter[2] = {1, 0};
				CHECK(h_ccsae_get_keys(a, ka, ka + 64, ka + 96) ==
				    f_ccsae_get_keys(b, kb, kb + 64, kb + 96));
				CHECK(!memcmp(ka, kb, 128));
				CHECK(!h_ccsae_generate_confirmation(a, counter, ma));
				CHECK(!f_ccsae_generate_confirmation(b, counter, mb));
				CHECK(!memcmp(ma, mb, di->output_size));
				CHECK(!h_ccsae_generate_confirmation(peer, counter, mp));
				ea = malloc(sz);
				eb = malloc(sz);
				memcpy(ea, a, sz);
				memcpy(eb, b, sz);
				mp[0] ^= 1;
				CHECK(h_ccsae_verify_confirmation(ea, counter, mp) ==
				    f_ccsae_verify_confirmation(eb, counter, mp));
				CHECK(ea->state == eb->state);
				mp[0] ^= 1;
				free(ea);
				free(eb);
				CHECK(h_ccsae_verify_confirmation(a, counter, mp) ==
				    f_ccsae_verify_confirmation(b, counter, mp));
				CHECK(a->state == b->state);
				free(a);
				free(b);
				free(peer);
			}
	printf("SAE ABI: %d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
}
