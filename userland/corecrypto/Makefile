# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's corecrypto pieces. libcorecrypto_static.a: the digests dyld links
# statically (installed where dyld's archive list expects it).
OUT  ?= ../../build/userland/corecrypto
ROOT ?= ../../build/root
CC   := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -Os -Wall -Wextra -Werror -Iinclude \
          -fno-stack-protector -fno-builtin -fvisibility=hidden

all: $(ROOT)/usr/local/lib/libcorecrypto_static.a

$(OUT)/digest.o: digest.c include/corecrypto/*.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@

$(ROOT)/usr/local/lib/libcorecrypto_static.a: $(OUT)/digest.o
	@mkdir -p $(dir $@)
	rm -f $@ && xcrun libtool -static -o $@ $^

check: $(OUT)/digest.o
	$(CC) -arch arm64e -O1 -Wall -Wextra -Werror -Iinclude -o $(OUT)/digest-compare tests/digest-compare.c $(OUT)/digest.o
	$(OUT)/digest-compare

.PHONY: all check

# Work on the shared-library layout separately from dyld's static helpers.
# This partial library is a test artifact and is never installed in the image.
$(OUT)/abi-digest.dylib: abi/digest.c abi/hmac.c abi/ccdigest.h abi/cchmac.h digest.c include/corecrypto/*.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -dynamiclib abi/digest.c abi/hmac.c -o $@
	codesign -f -s - $@

abi-digest: $(OUT)/abi-digest.dylib

$(OUT)/digest-abi-compare: tests/digest-abi-compare.c abi/ccdigest.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-abi: $(OUT)/abi-digest.dylib $(OUT)/digest-abi-compare
	$(OUT)/digest-abi-compare $(OUT)/abi-digest.dylib

.PHONY: abi-digest check-abi

openssl-backend:
	./build-openssl.sh

check-openssl: openssl-backend
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror \
	    -I../../build/obj/corecrypto-openssl/include -I../../build/src/openssl/include \
	    tests/openssl-backend.c ../../build/obj/corecrypto-openssl/libcrypto.a -o $(OUT)/openssl-backend-check
	$(OUT)/openssl-backend-check

.PHONY: openssl-backend check-openssl

OPENSSL_ARCHIVE := ../../build/obj/corecrypto-openssl/libcrypto.a
$(OPENSSL_ARCHIVE): build-openssl.sh openssl-arm64e.conf
	./build-openssl.sh

ABI_SOURCES := abi/digest.c abi/hmac.c abi/aes_ecb.c abi/aes_cbc.c abi/aes_ctr.c abi/aes_gcm.c abi/aes_xts.c abi/aes_feedback.c abi/aes_ccm.c abi/rng.c abi/kdf.c abi/cmac.c abi/digest_extra.c abi/shake.c abi/ccn.c abi/der.c abi/ccz.c abi/chacha.c abi/common.c abi/legacy_ciphers.c abi/padding.c abi/keywrap.c abi/cczp.c abi/ecc.c abi/curve25519.c abi/ed25519.c abi/dh.c abi/rsa.c abi/rsa_der.c abi/drbg.c abi/pq.c abi/pq_mldsa.c abi/srp.c abi/kdf_extra.c abi/ccckg.c abi/spake.c abi/cch2c.c abi/siv.c abi/ascon.c abi/siv_hmac.c abi/secret_sharing.c abi/aes_alternate.c abi/entropy.c abi/rng_test.c abi/sae.c abi/cchpke.c abi/ccecies.c abi/ccapsic.c abi/lr.c abi/post.c abi/support.c abi/sigma.c abi/vrf.c abi/fips.c abi/cche.c abi/cche_context.c abi/cche_crypto.c abi/cche_compose.c abi/cche_keys.c abi/cche_serial.c
ABI_HEADERS := $(wildcard abi/*.h)
OPENSSL_INCLUDES := -I../../build/obj/corecrypto-openssl/include -I../../build/src/openssl/include
$(OUT)/abi-crypto.dylib: $(ABI_SOURCES) $(ABI_HEADERS) digest.c $(OPENSSL_ARCHIVE) Makefile tools/seal-corecrypto.py
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(OPENSSL_INCLUDES) -dynamiclib $(ABI_SOURCES) $(OPENSSL_ARCHIVE) -o $@
	python3 tools/seal-corecrypto.py seal $@
	codesign -f -s - $@

abi-crypto: $(OUT)/abi-crypto.dylib

$(OUT)/aes-abi-compare: tests/aes-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-aes-abi: $(OUT)/abi-crypto.dylib $(OUT)/aes-abi-compare
	$(OUT)/aes-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: abi-crypto check-aes-abi

$(OUT)/cbc-abi-compare: tests/cbc-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-cbc-abi: $(OUT)/abi-crypto.dylib $(OUT)/cbc-abi-compare
	$(OUT)/cbc-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-cbc-abi

$(OUT)/ctr-abi-compare: tests/ctr-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ctr-abi: $(OUT)/abi-crypto.dylib $(OUT)/ctr-abi-compare
	$(OUT)/ctr-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ctr-abi

$(OUT)/gcm-abi-compare: tests/gcm-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-gcm-abi: $(OUT)/abi-crypto.dylib $(OUT)/gcm-abi-compare
	$(OUT)/gcm-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-gcm-abi

$(OUT)/rng-abi-compare: tests/rng-abi-compare.c abi/ccrng.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

$(OUT)/rng-entropy: tests/rng-entropy.c abi/rng.c abi/ccrng.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-rng-abi: $(OUT)/abi-crypto.dylib $(OUT)/rng-abi-compare $(OUT)/rng-entropy
	$(OUT)/rng-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
	$(OUT)/rng-entropy

.PHONY: check-rng-abi

$(OUT)/xts-abi-compare: tests/xts-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-xts-abi: $(OUT)/abi-crypto.dylib $(OUT)/xts-abi-compare
	$(OUT)/xts-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-xts-abi

$(OUT)/feedback-abi-compare: tests/feedback-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-feedback-abi: $(OUT)/abi-crypto.dylib $(OUT)/feedback-abi-compare
	$(OUT)/feedback-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-feedback-abi

$(OUT)/ccm-abi-compare: tests/ccm-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ccm-abi: $(OUT)/abi-crypto.dylib $(OUT)/ccm-abi-compare
	$(OUT)/ccm-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ccm-abi

$(OUT)/kdf-abi-compare: tests/kdf-abi-compare.c abi/ccdigest.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-kdf-abi: $(OUT)/abi-crypto.dylib $(OUT)/kdf-abi-compare
	$(OUT)/kdf-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-kdf-abi

$(OUT)/cmac-abi-compare: tests/cmac-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-cmac-abi: $(OUT)/abi-crypto.dylib $(OUT)/cmac-abi-compare
	$(OUT)/cmac-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-cmac-abi

check-extra-digests: $(OUT)/abi-crypto.dylib $(OUT)/digest-abi-compare
	$(OUT)/digest-abi-compare $(abspath $(OUT)/abi-crypto.dylib) extra

.PHONY: check-extra-digests

check-digest-variants: $(OUT)/abi-crypto.dylib $(OUT)/digest-abi-compare
	$(OUT)/digest-abi-compare $(abspath $(OUT)/abi-crypto.dylib) variants

.PHONY: check-digest-variants

$(OUT)/shake-abi-compare: tests/shake-abi-compare.c abi/ccxof.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-shake-abi: $(OUT)/abi-crypto.dylib $(OUT)/shake-abi-compare
	$(OUT)/shake-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-shake-abi

$(OUT)/ccn-abi-compare: tests/ccn-abi-compare.c abi/ccn.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ccn-abi: $(OUT)/abi-crypto.dylib $(OUT)/ccn-abi-compare
	$(OUT)/ccn-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ccn-abi

$(OUT)/der-abi-compare: tests/der-abi-compare.c abi/ccder.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-der-abi: $(OUT)/abi-crypto.dylib $(OUT)/der-abi-compare
	$(OUT)/der-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-der-abi

$(OUT)/der-values-compare: tests/der-values-compare.c abi/ccder.h abi/ccn.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-der-values: $(OUT)/abi-crypto.dylib $(OUT)/der-values-compare
	$(OUT)/der-values-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-der-values

$(OUT)/der-eckey-compare: tests/der-eckey-compare.c abi/ccder.h abi/ccn.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-der-eckey: $(OUT)/abi-crypto.dylib $(OUT)/der-eckey-compare
	$(OUT)/der-eckey-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-der-eckey

$(OUT)/ccz-abi-compare: tests/ccz-abi-compare.c abi/ccz.h abi/ccn.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ccz-abi: $(OUT)/abi-crypto.dylib $(OUT)/ccz-abi-compare
	$(OUT)/ccz-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ccz-abi

$(OUT)/ccz-math-compare: tests/ccz-math-compare.c abi/ccz.h abi/ccn.h abi/ccrng.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ccz-math: $(OUT)/abi-crypto.dylib $(OUT)/ccz-math-compare
	$(OUT)/ccz-math-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ccz-math

$(OUT)/chacha-abi-compare: tests/chacha-abi-compare.c abi/chacha.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-chacha-abi: $(OUT)/abi-crypto.dylib $(OUT)/chacha-abi-compare
	$(OUT)/chacha-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-chacha-abi

$(OUT)/legacy-abi-compare: tests/legacy-abi-compare.c abi/ccmode.h abi/legacy_ciphers.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-legacy-abi: $(OUT)/abi-crypto.dylib $(OUT)/legacy-abi-compare
	$(OUT)/legacy-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-legacy-abi

$(OUT)/padding-abi-compare: tests/padding-abi-compare.c abi/ccmode.h abi/legacy_ciphers.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-padding-abi: $(OUT)/abi-crypto.dylib $(OUT)/padding-abi-compare
	$(OUT)/padding-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-padding-abi

$(OUT)/keywrap-abi-compare: tests/keywrap-abi-compare.c abi/ccmode.h abi/legacy_ciphers.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-keywrap-abi: $(OUT)/abi-crypto.dylib $(OUT)/keywrap-abi-compare
	$(OUT)/keywrap-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-keywrap-abi

$(OUT)/ecc-abi-compare: tests/ecc-abi-compare.c abi/ccec.h abi/ccrng.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-abi: $(OUT)/abi-crypto.dylib $(OUT)/ecc-abi-compare
	$(OUT)/ecc-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ecc-abi

$(OUT)/curve-abi-compare: tests/curve-abi-compare.c abi/ccec.h abi/ccrng.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-curve-abi: $(OUT)/abi-crypto.dylib $(OUT)/curve-abi-compare
	$(OUT)/curve-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-curve-abi

$(OUT)/rsa-abi-compare: tests/rsa-abi-compare.c abi/ccrsa.h abi/ccrng.h abi/cczp.h abi/ccdh.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-rsa-abi: $(OUT)/abi-crypto.dylib $(OUT)/rsa-abi-compare
	$(OUT)/rsa-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-rsa-abi

$(OUT)/rsa-blind-abi-compare: tests/rsa-blind-abi-compare.c abi/ccrsa.h abi/ccrng.h abi/cczp.h abi/ccdh.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-rsa-blind-abi: $(OUT)/abi-crypto.dylib $(OUT)/rsa-blind-abi-compare
	$(OUT)/rsa-blind-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-rsa-blind-abi

$(OUT)/rsa-drbg-abi-compare: tests/rsa-drbg-abi-compare.c abi/ccrsa.h abi/ccrng.h abi/cczp.h abi/ccdh.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-rsa-drbg-abi: $(OUT)/abi-crypto.dylib $(OUT)/rsa-drbg-abi-compare
	$(OUT)/rsa-drbg-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-rsa-drbg-abi

$(OUT)/rsa-keygen-abi-compare: tests/rsa-keygen-abi-compare.c abi/ccrsa.h abi/ccrng.h abi/cczp.h abi/ccdh.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-rsa-keygen-abi: $(OUT)/abi-crypto.dylib $(OUT)/rsa-keygen-abi-compare
	$(OUT)/rsa-keygen-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-rsa-keygen-abi

$(OUT)/zp-abi-compare: tests/zp-abi-compare.c abi/ccrsa.h abi/ccrng.h abi/cczp.h abi/ccdh.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-zp-abi: $(OUT)/abi-crypto.dylib $(OUT)/zp-abi-compare
	$(OUT)/zp-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-zp-abi

$(OUT)/dh-abi-compare: tests/dh-abi-compare.c abi/ccrsa.h abi/ccrng.h abi/cczp.h abi/ccdh.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-dh-abi: $(OUT)/abi-crypto.dylib $(OUT)/dh-abi-compare
	$(OUT)/dh-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-dh-abi

$(OUT)/pq-kem-compare: tests/pq-kem-compare.c abi/ccpq.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-pq-kem: $(OUT)/abi-crypto.dylib $(OUT)/pq-kem-compare
	$(OUT)/pq-kem-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-pq-kem

$(OUT)/pq-mldsa-compare: tests/pq-mldsa-compare.c abi/ccpq.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-pq-mldsa: $(OUT)/abi-crypto.dylib $(OUT)/pq-mldsa-compare
	$(OUT)/pq-mldsa-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-pq-mldsa

$(OUT)/srp-abi-compare: tests/srp-abi-compare.c abi/ccsrp.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-srp-abi: $(OUT)/abi-crypto.dylib $(OUT)/srp-abi-compare
	$(OUT)/srp-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-srp-abi

$(OUT)/kdf-extra-compare: tests/kdf-extra-compare.c abi/ccec.h abi/ccspake.h abi/ccdigest.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-kdf-extra: $(OUT)/abi-crypto.dylib $(OUT)/kdf-extra-compare
	$(OUT)/kdf-extra-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-kdf-extra

$(OUT)/ecc-ckg-compare: tests/ecc-ckg-compare.c abi/ccec.h abi/ccspake.h abi/ccdigest.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-ckg: $(OUT)/abi-crypto.dylib $(OUT)/ecc-ckg-compare
	$(OUT)/ecc-ckg-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ecc-ckg

$(OUT)/spake-abi-compare: tests/spake-abi-compare.c abi/ccec.h abi/ccspake.h abi/ccdigest.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-spake-abi: $(OUT)/abi-crypto.dylib $(OUT)/spake-abi-compare
	$(OUT)/spake-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-spake-abi

$(OUT)/ecc-h2c-compare: tests/ecc-h2c-compare.c abi/cch2c.h abi/siv.h abi/ascon.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-h2c: $(OUT)/abi-crypto.dylib $(OUT)/ecc-h2c-compare
	$(OUT)/ecc-h2c-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ecc-h2c

$(OUT)/siv-abi-compare: tests/siv-abi-compare.c abi/cch2c.h abi/siv.h abi/ascon.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-siv-abi: $(OUT)/abi-crypto.dylib $(OUT)/siv-abi-compare
	$(OUT)/siv-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-siv-abi

$(OUT)/ascon-abi-compare: tests/ascon-abi-compare.c abi/cch2c.h abi/siv.h abi/ascon.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ascon-abi: $(OUT)/abi-crypto.dylib $(OUT)/ascon-abi-compare
	$(OUT)/ascon-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-ascon-abi

$(OUT)/siv-hmac-abi-compare: tests/siv-hmac-abi-compare.c abi/siv_hmac.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-siv-hmac-abi: $(OUT)/abi-crypto.dylib $(OUT)/siv-hmac-abi-compare
	$(OUT)/siv-hmac-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

commoncrypto: abi-crypto
	./build-commoncrypto.sh

$(OUT)/commoncrypto-compare: tests/commoncrypto-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations -I../../build/obj/CommonCrypto-finch/include $< -o $@

$(OUT)/commoncrypto-keys-compare: tests/commoncrypto-keys-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations -I../../build/obj/CommonCrypto-finch/include $< -o $@

check-commoncrypto: commoncrypto $(OUT)/commoncrypto-compare $(OUT)/commoncrypto-keys-compare
	$(OUT)/commoncrypto-compare $(abspath ../../build/userland/CommonCrypto/libcommonCrypto.dylib)
	$(OUT)/commoncrypto-keys-compare $(abspath ../../build/userland/CommonCrypto/libcommonCrypto.dylib)

.PHONY: check-siv-hmac-abi commoncrypto check-commoncrypto

$(OUT)/secret-sharing-compare: tests/secret-sharing-compare.c abi/ccss.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-secret-sharing: $(OUT)/abi-crypto.dylib $(OUT)/secret-sharing-compare
	$(OUT)/secret-sharing-compare $(abspath $(OUT)/abi-crypto.dylib)

$(OUT)/aes-alternate-abi-compare: tests/aes-alternate-abi-compare.c abi/ccmode.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-aes-alternate: $(OUT)/abi-crypto.dylib $(OUT)/aes-alternate-abi-compare
	$(OUT)/aes-alternate-abi-compare $(abspath $(OUT)/abi-crypto.dylib)

.PHONY: check-secret-sharing check-aes-alternate

$(OUT)/entropy-abi-compare: tests/entropy-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@
check-entropy-abi: $(OUT)/abi-crypto.dylib $(OUT)/entropy-abi-compare
	$(OUT)/entropy-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
$(OUT)/rng-extra-abi-compare: tests/rng-extra-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@
check-rng-extra: $(OUT)/abi-crypto.dylib $(OUT)/rng-extra-abi-compare
	$(OUT)/rng-extra-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
$(OUT)/sae-abi-compare: tests/sae-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@
check-sae-abi: $(OUT)/abi-crypto.dylib $(OUT)/sae-abi-compare
	$(OUT)/sae-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
$(OUT)/ecc-hpke-compare: tests/ecc-hpke-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@
check-ecc-hpke: $(OUT)/abi-crypto.dylib $(OUT)/ecc-hpke-compare
	$(OUT)/ecc-hpke-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-entropy-abi check-rng-extra check-sae-abi check-ecc-hpke

$(OUT)/ecc-ecies-compare: tests/ecc-ecies-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-ecies-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-ecies-compare
	$(OUT)/ecc-ecies-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-ecies-compare

$(OUT)/ecc-apsic-compare: tests/ecc-apsic-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-apsic-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-apsic-compare
	$(OUT)/ecc-apsic-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-apsic-compare

$(OUT)/lr-abi-compare: tests/lr-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-lr-abi-compare: $(OUT)/abi-crypto.dylib $(OUT)/lr-abi-compare
	$(OUT)/lr-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-lr-abi-compare

$(OUT)/support-abi-compare: tests/support-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-support-abi-compare: $(OUT)/abi-crypto.dylib $(OUT)/support-abi-compare
	$(OUT)/support-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-support-abi-compare

$(OUT)/sigma-abi-compare: tests/sigma-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-sigma-abi-compare: $(OUT)/abi-crypto.dylib $(OUT)/sigma-abi-compare
	$(OUT)/sigma-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-sigma-abi-compare

$(OUT)/ecc-seeded-abi-compare: tests/ecc-seeded-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-seeded-abi-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-seeded-abi-compare
	$(OUT)/ecc-seeded-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-seeded-abi-compare

$(OUT)/vrf-abi-compare: tests/vrf-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-vrf-abi-compare: $(OUT)/abi-crypto.dylib $(OUT)/vrf-abi-compare
	$(OUT)/vrf-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-vrf-abi-compare

$(OUT)/kem-abi-compare: tests/kem-abi-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-kem-abi-compare: $(OUT)/abi-crypto.dylib $(OUT)/kem-abi-compare
	$(OUT)/kem-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-kem-abi-compare

$(OUT)/ecc-he-compare: tests/ecc-he-compare.c tests/he-symbol-owner.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-he-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-he-compare
	$(OUT)/ecc-he-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-he-compare

$(OUT)/ecc-he-crypto-compare: tests/ecc-he-crypto-compare.c tests/he-symbol-owner.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-he-crypto-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-he-crypto-compare
	$(OUT)/ecc-he-crypto-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-he-crypto-compare

$(OUT)/ecc-he-serial-compare: tests/ecc-he-serial-compare.c tests/he-symbol-owner.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-he-serial-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-he-serial-compare
	$(OUT)/ecc-he-serial-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-he-serial-compare

$(OUT)/ecc-he-keys-compare: tests/ecc-he-keys-compare.c tests/he-symbol-owner.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-he-keys-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-he-keys-compare
	$(OUT)/ecc-he-keys-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-he-keys-compare

$(OUT)/ecc-extra-compare: tests/ecc-extra-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-extra-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-extra-compare
	$(OUT)/ecc-extra-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-extra-compare

$(OUT)/ecc-wrap-compare: tests/ecc-wrap-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-wrap-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-wrap-compare
	$(OUT)/ecc-wrap-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-wrap-compare

$(OUT)/ecc-helpers-compare: tests/ecc-helpers-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-ecc-helpers-compare: $(OUT)/abi-crypto.dylib $(OUT)/ecc-helpers-compare
	$(OUT)/ecc-helpers-compare $(abspath $(OUT)/abi-crypto.dylib)
.PHONY: check-ecc-helpers-compare

$(OUT)/fips-abi-compare: tests/fips-abi-compare.c tests/he-symbol-owner.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

check-fips: $(OUT)/abi-crypto.dylib $(OUT)/fips-abi-compare
	$(OUT)/fips-abi-compare $(abspath $(OUT)/abi-crypto.dylib)
	python3 tests/fips-seal-check.py $(OUT)/abi-crypto.dylib
.PHONY: check-fips

# Link the installed library to individual libSystem parts. Linking the
# umbrella here would make startup depend on its own unfinished initializer.
SDKROOT := $(shell xcrun --sdk macosx --show-sdk-path)
BOOT_LIB := $(ROOT)/usr/lib/system/libcorecrypto.dylib
BOOT_LIBS := -lsystem_kernel -lsystem_platform -lsystem_malloc -lsystem_c -lsystem_blocks -lsystem_pthread -lsystem_trace -ldispatch -lcompiler_rt
$(BOOT_LIB): $(ABI_SOURCES) $(ABI_HEADERS) digest.c $(OPENSSL_ARCHIVE) exports.txt Makefile tools/seal-corecrypto.py
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(OPENSSL_INCLUDES) -dynamiclib -nostdlib $(ABI_SOURCES) $(OPENSSL_ARCHIVE) \
	 -L$(SDKROOT)/usr/lib/system -L$(SDKROOT)/usr/lib $(BOOT_LIBS) \
	 -install_name /usr/lib/system/libcorecrypto.dylib -current_version 1922.101.2 -compatibility_version 1 \
	 -umbrella System -Wl,-exported_symbols_list,exports.txt -o $@
	python3 tools/seal-corecrypto.py seal $@
	codesign -f -s - $@

# OpenSSL is Apache-2.0: its licence travels with the binary that embeds it.
NOTICES := $(ROOT)/usr/share/finch/licenses/OpenSSL
$(NOTICES)/LICENSE.txt: $(OPENSSL_ARCHIVE)
	@mkdir -p $(dir $@)
	cp ../../build/src/openssl/LICENSE.txt ../../build/src/openssl/AUTHORS.md $(dir $@)

install: $(BOOT_LIB) $(NOTICES)/LICENSE.txt
.PHONY: install
