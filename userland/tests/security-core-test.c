/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <Security/Security.h>
#include <Security/Authorization.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "security-test-certs.inc"
static void keyRoundTrip(CFStringRef type, SecKeyAlgorithm sign)
{
	const void *keys[] = {kSecAttrKeyType};
	const void *values[] = {type};
	CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	SecKeyRef key = SecKeyCreateRandomKey(attrs, NULL);
	assert(key);
	SecKeyRef pub = SecKeyCopyPublicKey(key);
	assert(pub);
	CFDataRef message = CFDataCreate(NULL, (const UInt8 *)"Finch", 5);
	CFDataRef sig = SecKeyCreateSignature(key, sign, message, NULL);
	assert(sig);
	assert(SecKeyVerifySignature(pub, sign, message, sig, NULL));
	CFDataRef bad = CFDataCreate(NULL, (const UInt8 *)"Wrong", 5);
	assert(!SecKeyVerifySignature(pub, sign, bad, sig, NULL));
	assert(!SecKeyCreateSignature(pub, sign, message, NULL));
	CFDataRef encoded = SecKeyCopyExternalRepresentation(key, NULL);
	assert(encoded);
	CFMutableDictionaryRef import = CFDictionaryCreateMutableCopy(NULL, 0, attrs);
	CFDictionarySetValue(import, kSecAttrKeyClass, kSecAttrKeyClassPrivate);
	SecKeyRef decoded = SecKeyCreateWithData(encoded, import, NULL);
	assert(decoded);
	CFDataRef decodedSig = SecKeyCreateSignature(decoded, sign, message, NULL);
	assert(decodedSig && SecKeyVerifySignature(pub, sign, message, decodedSig, NULL));
	if (CFEqual(type, kSecAttrKeyTypeRSA)) {
		CFDataRef ciphertext = SecKeyCreateEncryptedData(
		    pub, kSecKeyAlgorithmRSAEncryptionOAEPSHA256, message, NULL);
		assert(ciphertext);
		CFDataRef plaintext = SecKeyCreateDecryptedData(
		    key, kSecKeyAlgorithmRSAEncryptionOAEPSHA256, ciphertext, NULL);
		assert(plaintext && CFEqual(plaintext, message));
		CFRelease(plaintext);
		CFRelease(ciphertext);
	}
	CFRelease(decodedSig);
	CFRelease(decoded);
	CFRelease(import);
	CFRelease(encoded);
	CFRelease(bad);
	CFRelease(sig);
	CFRelease(message);
	CFRelease(pub);
	CFRelease(key);
	CFRelease(attrs);
}
int main(void)
{
	unsigned char a[32], b[32];
	assert(!SecRandomCopyBytes(kSecRandomDefault, sizeof(a), a));
	assert(!SecRandomCopyBytes(kSecRandomDefault, sizeof(b), b));
	assert(memcmp(a, b, sizeof(a)));
	keyRoundTrip(kSecAttrKeyTypeRSA, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256);
	keyRoundTrip(
	    kSecAttrKeyTypeECSECPrimeRandom, kSecKeyAlgorithmECDSASignatureMessageX962SHA256);
	CFDataRef rd = CFDataCreate(NULL, kRootCert, sizeof(kRootCert)),
	          ld = CFDataCreate(NULL, kLeafCert, sizeof(kLeafCert));
	SecCertificateRef root = SecCertificateCreateWithData(NULL, rd),
	                  leaf = SecCertificateCreateWithData(NULL, ld);
	assert(root && leaf);
	const void *certs[] = {leaf, root};
	CFArrayRef chain = CFArrayCreate(NULL, certs, 2, &kCFTypeArrayCallBacks),
	           anchors = CFArrayCreate(NULL, certs + 1, 1, &kCFTypeArrayCallBacks);
	SecPolicyRef policy = SecPolicyCreateSSL(true, CFSTR("test.finch.example"));
	SecTrustRef trust = NULL;
	assert(!SecTrustCreateWithCertificates(chain, policy, &trust));
	CFDateRef date = CFDateCreate(NULL, 820454400);
	assert(!SecTrustSetVerifyDate(trust, date));
	assert(!SecTrustEvaluateWithError(trust, NULL));
	assert(!SecTrustSetAnchorCertificates(trust, anchors));
	assert(SecTrustEvaluateWithError(trust, NULL));
	SecPolicyRef wrong = SecPolicyCreateSSL(true, CFSTR("wrong.example"));
	assert(!SecTrustSetPolicies(trust, wrong));
	assert(!SecTrustEvaluateWithError(trust, NULL));
	assert(!SecTrustSetPolicies(trust, policy));
	CFDateRef late = CFDateCreate(NULL, 1000000000);
	assert(!SecTrustSetVerifyDate(trust, late));
	assert(!SecTrustEvaluateWithError(trust, NULL));
	AuthorizationRef auth = (AuthorizationRef)1;
	assert(AuthorizationCreate(NULL, NULL, 0, &auth) != 0 && auth == NULL);
	CFTypeRef output = (CFTypeRef)1;
	CFDictionaryRef query = CFDictionaryCreate(
	    NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	assert(SecItemCopyMatching(query, &output) == errSecNotAvailable && output == NULL);
	CFRelease(query);
	CFRelease(late);
	CFRelease(wrong);
	CFRelease(date);
	CFRelease(trust);
	CFRelease(policy);
	CFRelease(anchors);
	CFRelease(chain);
	CFRelease(root);
	CFRelease(leaf);
	CFRelease(rd);
	CFRelease(ld);
	puts("security-core: PASS (RSA, EC, tampering, trust, denied rights)");
	return 0;
}
