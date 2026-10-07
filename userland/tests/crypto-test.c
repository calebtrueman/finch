/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-crypto-test: run inside the VM. Known-answer tests through
 * CommonCrypto (which sits on corecrypto), an EC key round trip straight
 * through corecrypto, and a report of which libcorecrypto is loaded, so a
 * pass can't come from Apple's copy by accident.
 */
#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonRandom.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* corecrypto has no public header; these are its exported signatures. */
struct ccrng_state;
struct ccrng_state *ccrng(int *error);
const void *ccec_get_cp(size_t bits);
int ccec_generate_key(const void *cp, struct ccrng_state *rng, void *key);
int ccec_sign(const void *key, size_t digest_len, const void *digest,
    size_t *sig_len, void *sig, struct ccrng_state *rng);
int ccec_verify(const void *key, size_t digest_len, const void *digest,
    size_t sig_len, const void *sig, bool *valid);

static int failures;

static void
check(bool ok, const char *what)
{
	printf("%s %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		failures++;
	}
}

static bool
equals_hex(const uint8_t *bytes, size_t len, const char *hex)
{
	char buf[2 * 64 + 1];

	for (size_t i = 0; i < len; i++) {
		snprintf(buf + 2 * i, 3, "%02x", bytes[i]);
	}
	return strlen(hex) == 2 * len && memcmp(buf, hex, 2 * len) == 0;
}

/* Print a loaded library's UUID; returns its header, or NULL if not loaded. */
static const struct mach_header_64 *
report_library(const char *path)
{
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const struct mach_header_64 *mh;
		const struct load_command *lc;

		if (strcmp(_dyld_get_image_name(i), path) != 0) {
			continue;
		}
		mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
		lc = (const struct load_command *)(mh + 1);
		for (uint32_t c = 0; c < mh->ncmds; c++) {
			if (lc->cmd == LC_UUID) {
				const uint8_t *u = ((const struct uuid_command *)lc)->uuid;
				printf("%s ", strrchr(path, '/') + 1);
				for (int b = 0; b < 16; b++) {
					printf("%02X%s", u[b], (b == 3 || b == 5 || b == 7 || b == 9) ? "-" : "");
				}
				printf("\n");
			}
			lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
		}
		return mh;
	}
	return NULL;
}

int
main(void)
{
	uint8_t out[64], out2[64];
	size_t moved;

	const struct mach_header_64 *cc = report_library("/usr/lib/system/libcorecrypto.dylib");
	unsigned long seal = 0;
	check(cc != NULL && getsectiondata(cc, "__TEXT", "__finch_seal", &seal) != NULL && seal == 32,
	    "libcorecrypto is Finch's (has __TEXT,__finch_seal)");
	check(report_library("/usr/lib/system/libcommonCrypto.dylib") != NULL,
	    "libcommonCrypto is loaded");

	/* FIPS 180-2 B.1 */
	CC_SHA256("abc", 3, out);
	check(equals_hex(out, 32,
	    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
	    "SHA-256 (FIPS 180-2)");

	/* FIPS 180-2 C.1 */
	CC_SHA512("abc", 3, out);
	check(equals_hex(out, 64,
	    "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
	    "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"),
	    "SHA-512 (FIPS 180-2)");

	/* RFC 4231 test case 1 */
	uint8_t key[20];
	memset(key, 0x0b, sizeof(key));
	CCHmac(kCCHmacAlgSHA256, key, sizeof(key), "Hi There", 8, out);
	check(equals_hex(out, 32,
	    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
	    "HMAC-SHA-256 (RFC 4231 case 1)");

	/* FIPS 197 C.1 */
	const uint8_t aes_key[16] = { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
		                      0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
	const uint8_t plain[16] = { 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
		                    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
	check(CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, aes_key, 16, NULL,
	    plain, 16, out, sizeof(out), &moved) == kCCSuccess && moved == 16 &&
	    equals_hex(out, 16, "69c4e0d86a7b0430d8cdb78070b4c55a"), "AES-128 encrypt (FIPS 197)");
	check(CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionECBMode, aes_key, 16, NULL,
	    out, 16, out2, sizeof(out2), &moved) == kCCSuccess && memcmp(out2, plain, 16) == 0,
	    "AES-128 decrypt");

	/* SP 800-38A F.2.1, first block */
	const uint8_t cbc_key[16] = { 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
		                      0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c };
	const uint8_t cbc_plain[16] = { 0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
		                        0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a };
	check(CCCrypt(kCCEncrypt, kCCAlgorithmAES, 0, cbc_key, 16, aes_key,
	    cbc_plain, 16, out, sizeof(out), &moved) == kCCSuccess && moved == 16 &&
	    equals_hex(out, 16, "7649abac8119b246cee98e9b12e9197d"), "AES-128-CBC (SP 800-38A)");

	/* A streaming CCCryptor with PKCS#7 padding round-trips a 23-byte message. */
	const char *msg = "Darwin's finches adapt.";
	uint8_t sealed[48], opened[48];
	size_t n1 = 0, n2 = 0, m1 = 0, m2 = 0;
	CCCryptorRef enc = NULL, dec = NULL;
	bool round = CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, cbc_key, 16,
	    aes_key, &enc) == kCCSuccess &&
	    CCCryptorUpdate(enc, msg, 23, sealed, sizeof(sealed), &n1) == kCCSuccess &&
	    CCCryptorFinal(enc, sealed + n1, sizeof(sealed) - n1, &n2) == kCCSuccess &&
	    n1 + n2 == 32 &&
	    CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, cbc_key, 16,
	    aes_key, &dec) == kCCSuccess &&
	    CCCryptorUpdate(dec, sealed, n1 + n2, opened, sizeof(opened), &m1) == kCCSuccess &&
	    CCCryptorFinal(dec, opened + m1, sizeof(opened) - m1, &m2) == kCCSuccess &&
	    m1 + m2 == 23 && memcmp(opened, msg, 23) == 0;
	CCCryptorRelease(enc);
	CCCryptorRelease(dec);
	check(round, "AES-CBC PKCS#7 CCCryptor round trip");

	/* RFC 6070 case 2 */
	check(CCKeyDerivationPBKDF(kCCPBKDF2, "password", 8, (const uint8_t *)"salt", 4,
	    kCCPRFHmacAlgSHA1, 2, out, 20) == kCCSuccess &&
	    equals_hex(out, 20, "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957"), "PBKDF2-SHA-1 (RFC 6070)");

	memset(out, 0, sizeof(out));
	memset(out2, 0, sizeof(out2));
	check(CCRandomGenerateBytes(out, 32) == kCCSuccess &&
	    CCRandomGenerateBytes(out2, 32) == kCCSuccess && memcmp(out, out2, 32) != 0,
	    "random bytes (two draws differ)");

	/* P-256 through corecrypto: generate, sign, verify, reject a changed digest. */
	uint64_t ec_key[64] = { 0 };
	uint8_t sig[80];
	size_t sig_len = sizeof(sig);
	bool valid = false;
	int err = 0;
	struct ccrng_state *rng = ccrng(&err);
	const void *cp = ccec_get_cp(256);

	CC_SHA256("finch", 5, out);
	check(rng != NULL && err == 0 && cp != NULL &&
	    ccec_generate_key(cp, rng, ec_key) == 0, "P-256 key generation");
	check(ccec_sign(ec_key, 32, out, &sig_len, sig, rng) == 0 &&
	    ccec_verify(ec_key, 32, out, sig_len, sig, &valid) == 0 && valid,
	    "P-256 sign and verify");
	out[0] ^= 1;
	valid = true;
	check(ccec_verify(ec_key, 32, out, sig_len, sig, &valid) == 0 && !valid,
	    "P-256 rejects a changed digest");

	printf("finch-crypto-test: %d failure%s\n", failures, failures == 1 ? "" : "s");
	return failures != 0;
}
