/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Check the arm64e build, its built-in providers, and rejection of a bad
 * authentication tag before using this backend behind Finch's interfaces.
 */
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
static void check(int success, const char *what)
{
	checks++;
	if (!success) {
		fprintf(stderr, "OpenSSL backend: %s failed\n", what);
		exit(1);
	}
}

int main(void)
{
	static const unsigned char expected_sha[] = {0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
	    0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17,
	    0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad};
	unsigned char digest[64];
	size_t digest_len = 0;
	check(EVP_Q_digest(NULL, "SHA256", NULL, "abc", 3, digest, &digest_len), "SHA256 call");
	check(digest_len == 32 && !memcmp(digest, expected_sha, 32), "SHA256 vector");

	static const unsigned char key[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
	static const unsigned char plain[] = {0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
	    0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
	static const unsigned char encrypted[] = {0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
	    0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a};
	EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
	check(ctx != NULL, "cipher context");
	check(EVP_EncryptInit_ex(ctx, EVP_aes_128_ecb(), NULL, key, NULL), "AES setup");
	check(EVP_CIPHER_CTX_set_padding(ctx, 0), "AES padding");
	unsigned char out[64];
	int count = 0, tail = 0;
	check(EVP_EncryptUpdate(ctx, out, &count, plain, sizeof(plain)), "AES encrypt");
	check(EVP_EncryptFinal_ex(ctx, out + count, &tail), "AES finish");
	check(count + tail == 16 && !memcmp(out, encrypted, 16), "AES vector");
	EVP_CIPHER_CTX_free(ctx);

	static const unsigned char gcm_tag[] = {0x58, 0xe2, 0xfc, 0xce, 0xfa, 0x7e, 0x30, 0x61,
	    0x36, 0x7f, 0x1d, 0x57, 0xa4, 0xe7, 0x45, 0x5a};
	unsigned char zero_key[16] = {0}, iv[12] = {0}, tag[16];
	for (int bad = 0; bad < 2; bad++) {
		ctx = EVP_CIPHER_CTX_new();
		check(ctx != NULL, "GCM context");
		check(EVP_DecryptInit_ex(ctx, EVP_aes_128_gcm(), NULL, zero_key, iv), "GCM setup");
		memcpy(tag, gcm_tag, 16);
		tag[0] ^= bad;
		check(EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag), "GCM tag setup");
		check(EVP_DecryptFinal_ex(ctx, out, &count) == !bad, "GCM authentication");
		EVP_CIPHER_CTX_free(ctx);
	}
	unsigned char random[32];
	check(RAND_bytes(random, sizeof(random)), "random bytes");
	EVP_PKEY *rsa = EVP_PKEY_Q_keygen(NULL, NULL, "RSA", (size_t)2048);
	check(rsa != NULL, "RSA key generation");
	EVP_MD_CTX *md = EVP_MD_CTX_new();
	check(md != NULL, "signature context");
	check(EVP_DigestSignInit(md, NULL, EVP_sha256(), NULL, rsa), "RSA signing setup");
	size_t signature_len = 0;
	check(EVP_DigestSign(md, NULL, &signature_len, plain, sizeof(plain)), "RSA signature size");
	unsigned char *signature = malloc(signature_len);
	check(signature != NULL, "signature allocation");
	check(EVP_DigestSign(md, signature, &signature_len, plain, sizeof(plain)), "RSA signing");
	check(EVP_DigestVerifyInit(md, NULL, EVP_sha256(), NULL, rsa), "RSA verification setup");
	check(EVP_DigestVerify(md, signature, signature_len, plain, sizeof(plain)) == 1,
	    "RSA verification");
	signature[0] ^= 1;
	check(EVP_DigestVerify(md, signature, signature_len, plain, sizeof(plain)) != 1,
	    "bad signature rejection");
	free(signature);
	EVP_MD_CTX_free(md);
	EVP_PKEY_free(rsa);
	printf("OpenSSL backend: %u checks passed\n", checks);
	return 0;
}
