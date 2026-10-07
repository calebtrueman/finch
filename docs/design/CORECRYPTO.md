# Corecrypto replacement: work in progress

Finch still uses Apple's shared corecrypto library in the boot image.
`make -C userland/corecrypto install` builds Finch's replacement,
`/usr/lib/system/libcorecrypto.dylib`, into `build/root`, but the image build
doesn't run it yet: the library hasn't booted in the VM. The test library
(`abi-crypto.dylib`) is built from the same sources and is what the comparison
checks load. The older SHA helpers used by dyld stay separate because their
layout differs from the shared library's layout.

## Source boundary

The replacement uses Finch's SHA code and OpenSSL's AES, MD4, MD5, RIPEMD-160,
and Keccak block code. MD2 is written from the algorithm in RFC 1319. No Apple
corecrypto reference source was used. Layouts and call behavior were measured
against the host library and the local test image.

The OpenSSL build script pins release 3.5.9, commit
`45e844fa2a14ec92d146bd8f5778ac130b6625fb`. OpenSSL uses the Apache 2.0 license.
The script checks the source revision and tracked changes, builds outside its
source tree, and does not install anything on the host. Its source and compiled
files live under the ignored `build` directory. A future image install must
include the required OpenSSL license notices.

- [OpenSSL release](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9)
- [OpenSSL license](https://github.com/openssl/openssl/blob/openssl-3.5.9/LICENSE.txt)

## Pieces checked so far

The checks load the host and Finch libraries separately. They compare output,
error results, saved state, and bytes outside the expected write area. They also
create state with one library and continue with the other.

| Piece | Check target | Passing checks |
| --- | --- | ---: |
| SHA-1, SHA-224, SHA-256, SHA-384, SHA-512 and HMAC | `check-abi` | 192,735 |
| MD2, MD4, MD5, RIPEMD-160, SHA-512/256 and SHA-3 | `check-extra-digests` | 347,179 |
| Named SHA implementation descriptors | `check-digest-variants` | 655,316 |
| SHAKE-128, SHAKE-256 and XOF callbacks | `check-shake-abi` | 35,274 |
| AES ECB | `check-aes-abi` | 2,138 |
| AES CBC and CBC factories | `check-cbc-abi` | 8,738 |
| AES CTR | `check-ctr-abi` | 10,837 |
| AES XTS | `check-xts-abi` | 4,752 |
| AES CFB, CFB8 and OFB | `check-feedback-abi` | 87,982 |
| AES CCM | `check-ccm-abi` | 218,540 |
| AES GCM, including valid and altered tags | `check-gcm-abi` | 270,366 |
| Hash-based key derivation (HKDF, PBKDF2, X9.63, NIST counter mode) | `check-kdf-abi` | 31,862 |
| AES CMAC and CMAC counter-mode key derivation | `check-cmac-abi` | 39,494 |
| Random-number helpers and DRBG call wrappers | `check-rng-abi` | 7,244 |
| Fixed-width number helpers | `check-ccn-abi` | 999,196 |
| DER headers and ranges | `check-der-abi` | 1,476,255 |
| DER integers, strings, identifiers and integer pairs | `check-der-values` | 5,265,511 |
| DER EC key files and key-size readers | `check-der-eckey` | 610,408 |
| Growable numbers: storage, decimal and hex input/output | `check-ccz-abi` | 1,312,005 |
| Growable numbers: arithmetic, powers and random bits | `check-ccz-math` | 42,245 |
| ChaCha20, Poly1305 and authenticated ChaCha20 | `check-chacha-abi` | 30,192 |
| Legacy ciphers, padding and key wrap | `check-legacy-abi`, `check-padding-abi`, `check-keywrap-abi` | All cases pass |
| RSA encoding, encryption and signatures | `check-rsa-abi` | 1,342 |
| Blind RSA | `check-rsa-blind-abi` | 51 |
| Hash and counter-mode random generators | `check-rsa-drbg-abi` | 1,750 |
| Seeded RSA key generation | `check-rsa-keygen-abi` | 72 |
| Prime-field arithmetic and callback tables | `check-zp-abi` | 1,481 |
| Five elliptic curves, key formats, signing and key exchange | `check-ecc-abi` | 337 |
| Curve25519/448 and Ed25519/448 | `check-curve-abi` | 38 |
| Diffie–Hellman groups, imports and key exchange | `check-dh-abi` | 16,008 |
| ML-KEM, Kyber and X-Wing | `check-pq-kem` | All five types pass |
| ML-DSA signatures | `check-pq-mldsa` | Both types pass |
| Scrypt and mask generation | `check-kdf-extra` | 19,652 |
| SRP password exchange | `check-srp-abi` | 3,168 |
| SPAKE password exchange | `check-spake-abi` | 648 |
| Combined key creation | `check-ecc-ckg` | 310 |
| Hashing to curve points | `check-ecc-h2c` | 257 |
| AES-SIV, ASCON and SIV-HMAC | `check-siv-abi`, `check-ascon-abi`, `check-siv-hmac-abi` | All cases pass |
| CommonCrypto public calls | `check-commoncrypto` | 28,726 |
| CommonCrypto RSA, EC and DH key exchange | `check-commoncrypto` | 116 |
| OpenSSL build smoke checks | `check-openssl` | 26 |

Run these targets from `userland/corecrypto`. The counts above describe the
current tests, not the amount of the full library that has been replaced.

AES uses OpenSSL's ARM AES instruction routines. The wrapper adjusts round-key
ordering and round counts to match the host. It also preserves the two extra
expanded words visible in an AES-192 context. CBC supports input and output in
the same buffer. Its factory contexts store an ECB descriptor pointer before
the key state.

CTR stores an ECB descriptor, the number of used pad bytes, the pad, the counter,
and the key state. It increments the final eight counter bytes. The AES callback
prepares the next pad after processing complete blocks; the generic factory
callback prepares pads only when needed. This distinction changes saved state
without changing the stream of output bytes. The AES tests cover full blocks,
partial blocks, split calls, wraparound, and continued calls across libraries.
The generic CTR factory still needs a dedicated comparison test.

The host's AES-CBC callback leaves the return register unchanged when asked to
process zero blocks. The resulting value can depend on a temporary address.
Finch returns zero. Tests compare untouched output for empty calls and compare
return values for calls that process data or reject a key.

GCM preserves the host's authentication state, including its table of GHASH
powers, key pointers, and state transitions. The multiplication uses fixed loops
and masks. Its tests include a known AES-GCM vector, altered ciphertext and tags,
empty verification tags, in-place calls, nonstandard IV lengths, IV increments,
length limits, and factory-made descriptors. A failed tag check returns the
host's error code. Like the host, this low-level API has already written the
plaintext when the tag is checked; callers must honor the result before using it.
Finch rejects invalid AES key lengths during GCM initialization. The host's
GCM initializer ignores the ECB setup error; that unsafe edge case is not copied.

The main random source uses kernel `getentropy` in chunks of at most 256 bytes.
It keeps no process-local random state. It retries interrupted reads and clears
the entire output on any other read failure. Separate tests inject interruptions
and failures. The comparison tests cover bounded draws with rejection and error
handling, sequence contexts, DRBG callback arguments, and live random output
bounds. The DRBG functions added so far are call wrappers for supplied
descriptors; the actual DRBG algorithms and the seeded test generators remain
unfinished. The host's unavailable hardware-random entry point returns NULL and
error -173, which Finch also does.

XTS has two ECB key states and a separate tweak buffer containing a block count
and the current tweak. Tests cover matching-key rejection, all host-supported
AES key lengths, the block-count limit, split calls, in-place calls, and factory
contexts. Finch rejects a block-count overflow instead of allowing the count to
wrap around. It also reports an invalid key setup rather than ignoring it.

CFB and OFB reserve more context space in the native AES descriptors than their
factories reserve. Finch matches both sizes and leaves unused bytes alone.
CFB's full-block AES path leaves the old pad buffer unchanged; the generic
factory path saves its latest pad. Tests cover both paths. The host's CFB8
initializer can crash after an invalid key setup because it still calls AES
with an uninitialized round count. Finch rejects that failed setup. The host
comparison excludes invalid CFB8 keys rather than deliberately crashing it.

CCM uses separate key and nonce contexts. Tests compare both, including message
state transitions, byte counts, full and partial blocks, tag sizes, IV sizes,
and the length encoding at the extended-AAD boundary. Full AES blocks leave the
stream-pad buffer unchanged, unlike the factory path; both are checked. Valid
and altered tags, in-place encryption and decryption, and the published
[RFC 3610 packet vector 1](https://www.rfc-editor.org/rfc/rfc3610.html#section-8)
pass. As with GCM, Finch reports invalid key setup instead of ignoring the error.

Key derivation uses the supplied digest descriptor, including descriptors from
Apple's library. The tests cover empty inputs, partial output blocks, long HMAC
keys, zero PBKDF2 rounds (the host treats this as one), and size limits. HKDF also
passes [RFC 5869 test case 1](https://www.rfc-editor.org/rfc/rfc5869.html#appendix-A.1).
Finch uses overflow-safe size checks. Its X9.63 call leaves a zero-length output
untouched; the host's last-block calculation can write a whole hash for that
request. PBKDF2 rejects partial blocks beyond its 32-bit block-counter limit.
Intermediate keys and saved hash state are cleared before returning.

CMAC matches the subkeys, pending block, counters, CBC pointer, key state, and
IV stored by the host. Finalization clears the entire caller context, including
on invalid tag lengths. Tests cover split updates across both implementations,
shortened tags, altered tags, and the empty-message case. All four published
[RFC 4493 examples](https://www.rfc-editor.org/rfc/rfc4493.html#section-4) pass. Finch rejects verification
tags longer than one block rather than reading beyond a temporary tag buffer.
The CMAC key derivation calls support 8-, 16-, 24-, and 32-bit counters and
variable-length output-size fields. Unlike the host, Finch reports a failed key
setup instead of continuing with an uninitialized context.

The extra hash checks cover the full saved state for MD2, MD4, MD5,
RIPEMD-160, SHA-512/256, and all four SHA-3 sizes, including HMAC and calls
that start with one library and finish with the other. The last digest descriptor
field is a paired compression callback, not spare data. SHA-3 provides this
callback. Like the host, it processes the first supplied block count for both
inputs. The generic paired-hash call also works when the callback is absent.
The named SHA descriptors preserve their measured numeric identifiers while
sharing Finch's compression functions. OID helpers and descriptor lookup are
checked against the host, including missing matches and NULL equality.

SHAKE uses a separate 48-byte descriptor. Its context holds two 32-bit counters,
a rate-sized buffer, and the 200-byte Keccak state. Initializing clears the state
but leaves the buffer untouched. The first output call pads the input even when
zero output bytes are requested. The tests compare the whole context after each
split input and output call, including callbacks used directly and across
libraries. SHAKE-128 uses a 168-byte rate; SHAKE-256 uses 136 bytes.

The number helpers cover all 20 exported `ccn` calls: addition, subtraction,
comparison, bit lengths, bit setting, byte order, printing, and integer input
and output. Tests include carries, borrows, overlapping buffers, unequal word
counts, truncation, and buffer guards. Finch leaves zero-length output alone
where the host's integer writer can write one byte, and treats setting a
zero-word number as a no-op rather than writing past the buffer.

DER readers and writers cover headers, lengths, ranges, unsigned integers,
raw strings, integer-backed strings, object identifiers, bit strings, and
pairs of integers. Tests cover malformed headers, negative integers, redundant
leading zeroes, truncated data, strict length checks, partial progress on
failure, and output bounds. The integer-backed octet-string writer preserves
the host's signed-writer truncation, but never writes outside an empty body.
The system OID size helper requires a nonnull pointer; Finch returns zero for
NULL. EC key files preserve the version, private bytes, optional curve identifier,
and optional public bits. Tests mutate every byte of complete files, check
truncated files, and cover a shared input/output range object. RSA and DH
key-size readers are also checked, including RSA public keys inside X.509
wrappers. Full RSA and DH key import and export still need implementation.

All 44 `ccz` exports are present. Their 32-byte object holds a word count,
allocator-class pointer, signed capacity, and word pointer. Storage tests compare
allocator calls and buffer contents. Arithmetic tests cover either input used as
the output, signs, carry and borrow, division, shifts, primes, and random-source
errors. Larger operations use OpenSSL BIGNUM and clear temporary numbers.
Allocation patterns for temporary arithmetic buffers are not required to match.
Decimal and hexadecimal conversion preserve partial values on invalid input.

A few host edge cases are deliberately not copied. Modular powers return one for
exponent zero and work when the result shares the exponent object; the host can
return a different value in those cases. Subtracting the immediate value zero
from an empty number is safe. Zero-bit random draws do not touch a preceding word.
The fixed-width writer tests also preserve the host's short-truncation behavior:
a result shorter than a word does not continue reading the next source word.

The installable library exports exactly Apple's 1,092 symbols (no more, no
fewer) and depends on exactly the same nine libraries. That shows the
exports are present, not that their behavior is complete. Two OpenSSL details
were needed to get there. OpenSSL is configured with `no-sock`, since its
address helpers would otherwise pull in `getaddrinfo` from libsystem_info. On
Apple platforms OpenSSL also seeds itself through CommonCrypto's
`CCRandomGenerateBytes`, which sits on top of this library. A hidden definition
in `abi/rng.c` satisfies that reference from the kernel source the rest of the
library uses. The image seal locates its own Mach-O header through
`__dso_handle`, not `dladdr`, so there is no libdyld dependency.

OpenSSL's ARM capability probe (`armcap.o`) is a static initializer. It runs
before libSystem's initializer, so the VM boot test must confirm that it is safe
there.

## Still required

- Boot the installed library in the VM, then add it to the image build.
- Confirm the OpenSSL initializer above is safe that early.
- Rebuild CommonCrypto against the installed library and boot-test it.
- Install OpenSSL's license notice alongside the library.
- Reformat the dense sources in `abi/` to the repository's style before
  further work on them.

CommonCrypto now builds from its published source with Finch's source-facing
headers in `compat/corecrypto`. Its export list matches all 245 host symbols.
`build-commoncrypto.sh` produces a local library linked to Finch's crypto test
library, and preserves the published CommonCrypto source without edits. The
public tests compare digests, HMAC, seven ciphers, PBKDF2, and big numbers. The
key tests exchange RSA, EC, and DH keys and signatures with the system library.
These checks prove host use; a Finch boot test is still required.

Ed25519/448 signatures use OpenSSL's standard deterministic signing. The host
uses additional random input for its signatures, so exact signature bytes need
not match; each side verifies the other's signatures. PQ wrappers depend on the
pinned OpenSSL version, including internal polynomial helpers for ML-DSA's
verification canary. Those dependencies must be retested when OpenSSL changes.

Diffie–Hellman groups preserve the host's number layout and use OpenSSL for the
math. The Apple 768-bit group uses its observed public prime; RFC groups come
from OpenSSL. Private operations use constant-time powers. Shared-secret powers
also randomize the modulus and base, and key creation checks that the public and
private values agree. The tests compare all eleven built-in groups, shared
contexts, generated key bytes, and custom group initialization.

SIV-HMAC with a 32-byte master key matches the host's saved state and output.
Repeated host calls with 48-byte keys can produce different output because its
temporary AES key has unwritten bytes. Finch fills the whole key for 48- and
64-byte master keys and checks stable round trips, rather than reading unset
memory. Exact host output is not asserted for those two sizes.
