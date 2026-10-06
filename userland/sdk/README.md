# userland/sdk

- `BSD.xcconfig`: stand-in for Apple's unpublished CoreOS base build config.
- `include/`: Finch-written versions of headers that Apple publishes *redacted*
  (contents removed). `tools/mksdk.sh` copies them to `build/sdk/override`, which comes
  first in private-first builds.
  - `os/thread_self_restrict.h`: per-thread RWX (APRR/SPRR) toggles for JIT memory,
    reimplemented from the behaviour of macOS 26.4's libsystem_pthread.
  - `os/feature_private.h`: feature-flag queries, ABI-compatible with Apple's closed
    libsystem_featureflags.
  - `corecrypto/ccsha2.h`: header-only SHA-256 implementing the small ccdigest subset
    libSystem uses, so nothing needs to link Apple's closed libcorecrypto.
