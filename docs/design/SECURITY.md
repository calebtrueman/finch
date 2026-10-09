# Security and SystemConfiguration

Finch builds both frameworks for arm64e using Apple's public SDK headers and
framework paths. Their build scripts accept `FINCH_OUTPUT_ROOT` and
`FINCH_OBJ_DIR` for separate test builds. Neither copies Apple's closed code.

## Security

`userland/Security` provides Finch's implementation. Its constants generator
reads the pinned `Security-61901.101.4` source and finds definitions for all 564
constants it emits. Key and certificate operations use OpenSSL from Finch's
existing corecrypto build. Build corecrypto first. Security hides OpenSSL's
symbols and links CoreFoundation and libSystem.

Supported operations include random bytes, DER certificates, certificate
names and serials, RSA and prime-curve EC keys, key import and export, signing
and signature checks, RSA encryption and decryption, and ECDH. Trust checks
use caller-supplied roots and check the chain, date, hostname and purpose.
Unknown algorithms and policies fail.

There is no system root store, network certificate fetching, keychain daemon,
authorization service, code-signing or CMS verification, requirement parser,
trust serialization, or assessment service yet. These calls return errors and
clear their outputs. Permanent and hardware key creation also fail. Certificate
value dictionaries currently expose only common name and serial. Some error
text and property dictionaries still differ from Apple's.

`finch-security-core-test` passes against the shared Finch frameworks on the
host. It checks RSA and EC keys, private-key round trips, signature tampering,
public-key signing rejection, RSA OAEP, trusted and untrusted roots, wrong
hosts, expired chains, and unavailable authorization and keychain calls. The
larger inherited `security-test.m` is a future comparison suite and does not
pass yet. All 83 names in the captured bundled-app import list are exported;
that count does not mean all 83 services work.

## SystemConfiguration

`userland/SystemConfiguration` combines Finch's `SCState.c` with `SCDKeys.c`
and schema constants generated from the pinned `configd-1405.100.8` source.
Its build collects the source notices under
`/usr/share/finch/licenses/SystemConfiguration`. It links CoreFoundation and
libSystem.

It reads preference files, local preference values, network sets and services,
hostnames, configured proxies, and the kernel's interfaces and addresses.
Dynamic-store reads can match keys and patterns. Synchronous reachability uses
DNS and a UDP route check; the route check connects a socket without sending a
packet.

Finch does not run configd yet. Store writes and subscriptions, preference
commit/apply/locking, reachability subscriptions and two-address reachability
return errors. There is no shared store or automatic change feed. Interface
classification and store keys are partial. Wi-Fi details, default-router and
DNS service keys, hardware addresses, and service editing remain unfinished.

`finch-sysconfig-core-test` passes against the shared Finch frameworks on the
host. It checks local preferences, refused writes, hostname, real interfaces
and addresses, pattern queries and the loopback route. The host route check
needs access outside the network sandbox. All 64 names in the captured
bundled-app import list are exported. These results were checked on 2026-10-09.
