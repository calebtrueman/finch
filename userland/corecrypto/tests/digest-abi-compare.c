/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Mix host and Finch descriptors, updates and final callbacks. Matching
 * digests alone would miss an incompatible state layout between calls.
 */
#include "../abi/ccdigest.h"
#include "../abi/cchmac.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct api {
	void *handle;
	void (*init)(const struct ccdigest_info *, void *);
	void (*update)(const struct ccdigest_info *, void *, size_t, const void *);
	void (*digest)(const struct ccdigest_info *, size_t, const void *, void *);
	void (*hmac_init)(const struct ccdigest_info *, void *, size_t, const void *);
	void (*hmac_update)(const struct ccdigest_info *, void *, size_t, const void *);
	void (*hmac_final)(const struct ccdigest_info *, void *, void *);
	void (*hmac)(
	    const struct ccdigest_info *, size_t, const void *, size_t, const void *, void *);
};
static unsigned checks, failures;
static const char *algorithm;
static size_t length;

static void same(const char *what, const void *a, const void *b, size_t n)
{
	checks++;
	if (memcmp(a, b, n)) {
		if (failures++ < 12)
			fprintf(stderr, "%s len %zu: %s differs\n", algorithm, length, what);
	}
}

static void *symbol(void *h, const char *name)
{
	void *p = dlsym(h, name);
	if (!p) {
		fprintf(stderr, "%s: %s\n", name, dlerror());
		exit(2);
	}
	return p;
}

static struct api load(const char *path)
{
	struct api a = {0};
	a.handle = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
	if (!a.handle) {
		fprintf(stderr, "%s\n", dlerror());
		exit(2);
	}
	a.init = symbol(a.handle, "ccdigest_init");
	a.update = symbol(a.handle, "ccdigest_update");
	a.digest = symbol(a.handle, "ccdigest");
	a.hmac_init = symbol(a.handle, "cchmac_init");
	a.hmac_update = symbol(a.handle, "cchmac_update");
	a.hmac_final = symbol(a.handle, "cchmac_final");
	a.hmac = symbol(a.handle, "cchmac");
	return a;
}

static void hmac_cases(
    struct api a[2], const struct ccdigest_info *di[2], const unsigned char *data)
{
	const size_t keys[] = {0, 1, 63, 64, 65, 127, 128, 129, 511};
	const size_t lengths[] = {0, 1, 64, 65, 129, 511, 4097};
	for (size_t k = 0; k < sizeof(keys) / sizeof(*keys); k++) {
		for (size_t l = 0; l < sizeof(lengths) / sizeof(*lengths); l++) {
			length = lengths[l];
			unsigned char reference[64], out[64];
			a[0].hmac(di[0], keys[k], data, length, data, reference);
			for (int descriptor = 0; descriptor < 2; descriptor++) {
				for (int caller = 0; caller < 2; caller++) {
					a[caller].hmac(
					    di[descriptor], keys[k], data, length, data, out);
					same("HMAC one-shot", reference, out, di[0]->output_size);
				}
				for (int mix = 0; mix < 8; mix++) {
					_Alignas(16) unsigned char ctx[640], host[640];
					memset(ctx, 0xa5, sizeof(ctx));
					memset(host, 0xa5, sizeof(host));
					a[mix & 1].hmac_init(di[descriptor], ctx, keys[k], data);
					a[0].hmac_init(di[0], host, keys[k], data);
					same("HMAC initialized bytes", ctx, host, sizeof(ctx));
					size_t position = 0;
					while (position < length) {
						size_t piece = length - position;
						if (piece > 71)
							piece = 71;
						a[(mix >> 1) & 1].hmac_update(
						    di[descriptor], ctx, piece, data + position);
						a[0].hmac_update(
						    di[0], host, piece, data + position);
						same("HMAC updated bytes", ctx, host, sizeof(ctx));
						position += piece;
					}
					unsigned char host_output[64];
					a[(mix >> 2) & 1].hmac_final(di[descriptor], ctx, out);
					a[0].hmac_final(di[0], host, host_output);
					same(
					    "HMAC mixed final", reference, out, di[0]->output_size);
					same("HMAC finished bytes", ctx, host, sizeof(ctx));
				}
			}
		}
	}
}

int main(int argc, char **argv)
{
	if (argc != 2 && argc != 3)
		return 2;
	struct api a[2] = {load("/usr/lib/system/libcorecrypto.dylib"), load(argv[1])};
	if (a[0].digest == a[1].digest)
		return 2;
	const char *names[] = {
	    "ccsha1_di", "ccsha224_di", "ccsha256_di", "ccsha384_di", "ccsha512_di"};
	const char *extra_names[] = {"ccmd2_ltc_di", "ccmd4_ltc_di", "ccmd5_di", "ccrmd160_ltc_di",
	    "ccsha512_256_di", "ccsha3_224_di", "ccsha3_256_di", "ccsha3_384_di", "ccsha3_512_di"};
	const char *variants[] = {"ccsha1_eay_di", "ccsha1_ltc_di", "ccsha1_vng_arm_di",
	    "ccsha224_ltc_di", "ccsha224_vng_arm_di", "ccsha256_ltc_di",
	    "ccsha256_vng_arm64neon_di", "ccsha256_vng_arm_di", "ccsha384_ltc_di",
	    "ccsha384_vng_arm_di", "ccsha384_vng_arm_hw_di", "ccsha512_256_ltc_di",
	    "ccsha512_256_vng_arm_di", "ccsha512_256_vng_arm_hw_di", "ccsha512_ltc_di",
	    "ccsha512_vng_arm_di", "ccsha512_vng_arm_hw_di"};
	int use_variants = argc == 3 && !strcmp(argv[2], "variants");
	const char **chosen = argc == 3 ? extra_names : names;
	size_t count =
	    argc == 3 ? sizeof(extra_names) / sizeof(*extra_names) : sizeof(names) / sizeof(*names);
	if (use_variants) {
		chosen = variants;
		count = sizeof(variants) / sizeof(*variants);
	}
	unsigned char data[4097];
	for (size_t i = 0; i < sizeof(data); i++)
		data[i] = (unsigned char)(i * 113 + i / 251);
	const size_t extra[] = {511, 512, 513, 1023, 4095, 4096, 4097};
	for (size_t n = 0; n < count; n++) {
		algorithm = chosen[n];
		const struct ccdigest_info *(*get[2])(void) = {
		    symbol(a[0].handle, algorithm), symbol(a[1].handle, algorithm)};
		const struct ccdigest_info *di[2];
		for (int i = 0; i < 2; i++)
			di[i] = (use_variants || strstr(algorithm, "ltc_di"))
			    ? symbol(a[i].handle, algorithm)
			    : get[i]();
		same("sizes", di[0], di[1], 4 * sizeof(size_t));
		if (use_variants)
			same(
			    "implementation id", &di[0]->implementation, &di[1]->implementation, 8);
		same("OID", di[0]->oid, di[1]->oid, di[0]->oid_size);
		same(
		    "initial state", di[0]->initial_state, di[1]->initial_state, di[0]->state_size);
		for (int caller = 0; caller < 2; caller++) {
			int (*equal)(const void *, const void *) =
			    symbol(a[caller].handle, "ccoid_equal");
			size_t (*oid_size)(const void *) = symbol(a[caller].handle, "ccoid_size");
			const void *(*payload)(const void *) =
			    symbol(a[caller].handle, "ccoid_payload");
			int yes = 1, no = 0, value = equal(NULL, NULL);
			same("NULL OID equality", &value, &yes, sizeof(value));
			value = equal(di[0]->oid, NULL);
			same("one NULL OID", &value, &no, sizeof(value));
			value = equal(NULL, di[0]->oid);
			same("other NULL OID", &value, &no, sizeof(value));
			value = equal(di[0]->oid, di[1]->oid);
			same("equal OIDs", &value, &yes, sizeof(value));
			size_t bytes = oid_size(di[0]->oid);
			same("OID size", &bytes, &di[0]->oid_size, sizeof(bytes));
			const void *address = payload(di[0]->oid);
			same("OID payload address", &address, &di[0]->oid, sizeof(address));
			unsigned char bad[32];
			memcpy(bad, di[0]->oid, di[0]->oid_size);
			bad[0] ^= 1;
			value = equal(bad, di[0]->oid);
			same("OID tag differs", &value, &no, sizeof(value));
			bad[0] ^= 1;
			bad[di[0]->oid_size - 1] ^= 1;
			value = equal(bad, di[0]->oid);
			same("OID content differs", &value, &no, sizeof(value));
		}
		hmac_cases(a, di, data);
		typedef void (*parallel_fn)(const struct ccdigest_info *, size_t, const void *,
		    void *, const void *, void *);
		typedef const struct ccdigest_info *(*lookup_fn)(const void *, ...);
		for (int caller = 0; caller < 2; caller++)
			for (int descriptor = 0; descriptor < 2; descriptor++) {
				parallel_fn parallel =
				    symbol(a[caller].handle, "ccdigest_parallel");
				lookup_fn lookup = symbol(a[caller].handle, "ccdigest_oid_lookup");
				const struct ccdigest_info *found =
				    lookup(di[descriptor]->oid, di[0], di[1], NULL);
				same("OID lookup", &found, &di[0], sizeof(found));
				const unsigned char unknown[] = {6, 1, 0xff};
				found = lookup(unknown, di[0], di[1], NULL);
				const struct ccdigest_info *missing = NULL;
				same("OID lookup missing", &found, &missing, sizeof(found));
				for (size_t len = 0; len <= 513; len++) {
					unsigned char reference[2][80], out[2][80];
					memset(reference, 0xa5, sizeof(reference));
					memset(out, 0xa5, sizeof(out));
					a[0].digest(di[0], len, data, reference[0] + 8);
					a[0].digest(di[0], len, data + 513, reference[1] + 8);
					parallel(di[descriptor], len, data, out[0] + 8, data + 513,
					    out[1] + 8);
					same("parallel bytes and guards", reference, out,
					    sizeof(out));
				}
				if (di[descriptor]->compress_parallel) {
					for (size_t na = 0; na < 4; na++)
						for (size_t nb = 0; nb < 4; nb++) {
							_Alignas(
							    16) unsigned char reference[2][224],
							    out[2][224];
							memset(reference, 0xa5, sizeof(reference));
							memset(out, 0xa5, sizeof(out));
							for (int i = 0; i < 2; i++) {
								memcpy(reference[i],
								    di[0]->initial_state,
								    di[0]->state_size);
								memcpy(out[i], di[0]->initial_state,
								    di[0]->state_size);
							}
							di[0]->compress(reference[0], na, data);
							di[0]->compress(
							    reference[1], na, data + 513);
							di[descriptor]->compress_parallel(out[0],
							    na, data, out[1], nb, data + 513);
							same("parallel block state", reference, out,
							    sizeof(out));
						}
				}
			}
		for (size_t l = 0; l < 258 + sizeof(extra) / sizeof(*extra); l++) {
			length = l < 258 ? l : extra[l - 258];
			unsigned char reference[64], out[64];
			a[0].digest(di[0], length, data, reference);
			for (int descriptor = 0; descriptor < 2; descriptor++) {
				for (int caller = 0; caller < 2; caller++) {
					a[caller].digest(di[descriptor], length, data, out);
					same("one-shot", reference, out, di[0]->output_size);
				}
				for (int mix = 0; mix < 8; mix++) {
					_Alignas(16) unsigned char ctx[640], host[640], before[640];
					memset(ctx, 0xa5, sizeof(ctx));
					memset(host, 0xa5, sizeof(host));
					a[mix & 1].init(di[descriptor], ctx);
					a[0].init(di[0], host);
					same("initialized bytes", ctx, host, sizeof(ctx));
					size_t position = 0;
					a[(mix >> 1) & 1].update(di[descriptor], ctx, 0, NULL);
					while (position < length) {
						size_t piece = 1 + (position * 71 + length) % 197;
						if (piece > length - position)
							piece = length - position;
						a[(mix >> 1) & 1].update(
						    di[descriptor], ctx, piece, data + position);
						a[0].update(di[0], host, piece, data + position);
						same("updated bytes", ctx, host, sizeof(ctx));
						position += piece;
					}
					memcpy(before, ctx, sizeof(ctx));
					di[(mix >> 2) & 1]->final(di[descriptor], ctx, out);
					same("mixed final", reference, out, di[0]->output_size);
					same("final keeps context", ctx, before, sizeof(ctx));
				}
			}
		}
	}
	printf("digest and HMAC ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
