/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonCMACSPI.h>
#include <CommonCrypto/CommonBigNum.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(x)                                                                                   \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(x)) {                                                                        \
			fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x);                            \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
#define LOAD(type, name, args)                                                                     \
	type(*f_##name[2]) args = {dlsym(h[0], #name), dlsym(h[1], #name)};                        \
	CHECK(f_##name[0] && f_##name[1])
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	void *h[2] = {dlopen("/usr/lib/system/libcommonCrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST)};
	if (!h[1])
		fprintf(stderr, "%s\n", dlerror());
	CHECK(h[0] && h[1]);
	unsigned char data[2048], key[80], out[2][2200], iv[16];
	for (size_t i = 0; i < sizeof data; i++)
		data[i] = i * 17;
	for (size_t i = 0; i < sizeof key; i++)
		key[i] = i * 3 + 5;
	memset(iv, 7, sizeof iv);
	const char *digests[] = {"CC_MD2", "CC_MD4", "CC_MD5", "CC_SHA1", "CC_SHA224", "CC_SHA256",
	    "CC_SHA384", "CC_SHA512"};
	size_t widths[] = {16, 16, 16, 20, 28, 32, 48, 64};
	for (unsigned k = 0; k < 8; k++) {
		unsigned char *(*hash[2])(const void *, CC_LONG, unsigned char *);
		for (int j = 0; j < 2; j++) {
			hash[j] = dlsym(h[j], digests[k]);
			CHECK(hash[j]);
		}
		for (size_t n = 0; n <= 1024; n += 7) {
			for (int j = 0; j < 2; j++) {
				memset(out[j], 0xa5, sizeof out[j]);
				CHECK(hash[j](data, n, out[j]) == out[j]);
			}
			CHECK(!memcmp(out[0], out[1], widths[k] + 8));
		}
	}
	LOAD(void, CCHmac, (CCHmacAlgorithm, const void *, size_t, const void *, size_t, void *));
	for (unsigned alg = 0; alg <= 5; alg++)
		for (size_t kn = 0; kn <= 80; kn += 16)
			for (size_t n = 0; n <= 512; n += 63) {
				for (int j = 0; j < 2; j++) {
					memset(out[j], 0xa5, sizeof out[j]);
					f_CCHmac[j](alg, key, kn, data, n, out[j]);
				}
				CHECK(!memcmp(out[0], out[1], 80));
			}
	LOAD(CCCryptorStatus, CCCrypt,
	    (CCOperation, CCAlgorithm, CCOptions, const void *, size_t, const void *, const void *,
	        size_t, void *, size_t, size_t *));
	CCAlgorithm algorithms[] = {kCCAlgorithmAES, kCCAlgorithmDES, kCCAlgorithm3DES,
	    kCCAlgorithmCAST, kCCAlgorithmRC4, kCCAlgorithmRC2, kCCAlgorithmBlowfish};
	size_t lengths[] = {16, 8, 24, 16, 16, 16, 32};
	for (unsigned alg = 0; alg < 7; alg++)
		for (unsigned options = 0; options < 4; options++)
			for (size_t n = 0; n <= 160; n++) {
				size_t used[2];
				int ret[2];
				for (int j = 0; j < 2; j++) {
					memset(out[j], 0xa5, sizeof out[j]);
					used[j] = 9999;
					ret[j] = f_CCCrypt[j](kCCEncrypt, algorithms[alg], options,
					    key, lengths[alg], iv, data, n, out[j], sizeof out[j],
					    &used[j]);
				}
				if (ret[0] != ret[1] || used[0] != used[1] ||
				    memcmp(out[0], out[1], sizeof out[0]))
					fprintf(stderr,
					    "cipher alg%u opts%u n%zu ret%d %d used%zu %zu\n", alg,
					    options, n, ret[0], ret[1], used[0], used[1]);
				CHECK(ret[0] == ret[1]);
				CHECK(used[0] == used[1]);
				CHECK(!memcmp(out[0], out[1], sizeof out[0]));
				if (!ret[0]) {
					unsigned char plain[2][2200];
					size_t moved[2];
					for (int j = 0; j < 2; j++) {
						memset(plain[j], 0xa5, sizeof plain[j]);
						CHECK(!f_CCCrypt[j](kCCDecrypt, algorithms[alg],
						    options, key, lengths[alg], iv, out[1 - j],
						    used[1 - j], plain[j], sizeof plain[j],
						    &moved[j]));
					}
					CHECK(moved[0] == n && moved[1] == n);
					CHECK(!memcmp(plain[0], data, n) &&
					    !memcmp(plain[1], data, n));
				}
			}
	LOAD(int, CCKeyDerivationPBKDF,
	    (CCPBKDFAlgorithm, const char *, size_t, const unsigned char *, size_t,
	        CCPseudoRandomAlgorithm, unsigned, unsigned char *, size_t));
	for (unsigned prf = 1; prf <= 5; prf++)
		for (unsigned rounds = 1; rounds <= 5; rounds++) {
			for (int j = 0; j < 2; j++) {
				memset(out[j], 0xa5, 100);
				CHECK(!f_CCKeyDerivationPBKDF[j](
				    kCCPBKDF2, "password", 8, key, 13, prf, rounds, out[j], 73));
			}
			CHECK(!memcmp(out[0], out[1], 100));
		}
	LOAD(CCBigNumRef, CCBigNumFromDecimalString, (CCStatus *, const char *));
	LOAD(char *, CCBigNumToDecimalString, (CCStatus *, const CCBigNumRef));
	LOAD(void, CCBigNumFree, (CCBigNumRef));
	const char *values[] = {
	    "0", "1", "-17", "999999999999999999999999999999999999999999999999999999"};
	for (unsigned v = 0; v < 4; v++) {
		char *text[2];
		for (int j = 0; j < 2; j++) {
			CCStatus status = 0;
			CCBigNumRef b = f_CCBigNumFromDecimalString[j](&status, values[v]);
			CHECK(b && status == 0);
			text[j] = f_CCBigNumToDecimalString[j](&status, b);
			CHECK(text[j] && status == 0);
			f_CCBigNumFree[j](b);
		}
		CHECK(!strcmp(text[0], text[1]));
		free(text[0]);
		free(text[1]);
	}
	printf("CommonCrypto: %u checks passed\n", checks);
}
