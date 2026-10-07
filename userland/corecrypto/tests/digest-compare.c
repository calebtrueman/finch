/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * digest-compare: Finch's SHA family against the host's CommonCrypto, for
 * every length 0..4096 (one-shot and in random-sized pieces) plus large
 * inputs, and the FIPS 180-4 "abc" vectors.
 */

#include <CommonCrypto/CommonDigest.h>
#include <corecrypto/ccsha1.h>
#include <corecrypto/ccsha2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long checks, failures;

typedef unsigned char *(*cc_fn)(const void *, CC_LONG, unsigned char *);

static void one(const char *name, const struct ccdigest_info *di, cc_fn ref, const unsigned char *buf, size_t len)
{
	unsigned char a[64], b[64];
	ref(buf, (CC_LONG)len, a);
	ccdigest(di, len, buf, b);
	checks++;
	if (memcmp(a, b, di->output_size)) {
		if (failures++ < 10) fprintf(stderr, "FAIL %s one-shot len %zu\n", name, len);
	}
	/* Same data in random pieces. */
	ccdigest_di_decl(di, ctx);
	ccdigest_init(di, ctx);
	size_t off = 0;
	while (off < len) {
		size_t n = (size_t)(arc4random_uniform(300));
		if (n > len - off) n = len - off;
		ccdigest_update(di, ctx, n, buf + off);
		off += n;
	}
	ccdigest_final(di, ctx, b);
	ccdigest_di_clear(di, ctx);
	checks++;
	if (memcmp(a, b, di->output_size)) {
		if (failures++ < 10) fprintf(stderr, "FAIL %s pieces len %zu\n", name, len);
	}
}

static unsigned char *cc_sha384(const void *d, CC_LONG l, unsigned char *o) { return CC_SHA384(d, l, o); }

int main(void)
{
	size_t big = 3 * 1024 * 1024 + 17;
	unsigned char *buf = malloc(big);
	arc4random_buf(buf, big);
	struct { const char *name; const struct ccdigest_info *di; cc_fn ref; } algs[] = {
		{ "sha1", ccsha1_di(), CC_SHA1 }, { "sha224", ccsha224_di(), CC_SHA224 },
		{ "sha256", ccsha256_di(), CC_SHA256 }, { "sha384", ccsha384_di(), cc_sha384 },
		{ "sha512", ccsha512_di(), CC_SHA512 },
	};
	for (size_t a = 0; a < sizeof(algs) / sizeof(algs[0]); a++) {
		for (size_t len = 0; len <= 4096; len++)
			one(algs[a].name, algs[a].di, algs[a].ref, buf, len);
		one(algs[a].name, algs[a].di, algs[a].ref, buf, big);
		one(algs[a].name, algs[a].di, algs[a].ref, (const unsigned char *)"abc", 3);
	}
	printf("digest-compare: %lu checks, %lu failures\n", checks, failures);
	return failures != 0;
}
