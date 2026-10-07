# Phase 1 exit: no closed-source binaries above the kernel

Phase 1 ends when the VM boots to a shell, and everything that boot path loads above the
kernel is built from source or is Finch's own code. The list below is measured, not
guessed. `finch-images` (`userland/devtools`) prints every image a minimal libSystem
program loads: 45 images, of which 12 were Finch-built when this plan was written
(2026-10-06), plus dyld itself.

Each closed library's effort is sized by how many of its exports anything in the stock
image imports. A Finch replacement (`userland/libsystem/<name>`) exports exactly Apple's
symbol list (`exports.txt`, linked as an exported-symbols list) under Apple's install
name and version. It implements what is used and fails honestly where a feature doesn't
exist on Finch yet. Where Apple's behavior can be observed, a differential test compares
the two libraries on the host (`make -C userland/libsystem test`). Argument shapes that
no published source shows were read from the entry points of macOS 26.4's libraries.

## Closed: Finch implementations (`userland/libsystem/`)

| Library | Exports | Imported | Plan |
|---|---|---|---|
| libsystem_featureflags | 2 | 2 | Reads `/System/Library/FeatureFlags`, with no allocation (libmalloc asks during malloc init) |
| libsystem_darwindirectory | 3 | 3 | Record store: no records (Libinfo is built without it) |
| libsystem_eligibility | 17 | 1 | Eligibility domains answer "not eligible" |
| libsystem_symptoms | 10 | 7 | Network symptom reporting: accepted, dropped |
| libsystem_trial | 6 | 0 | Trial experiment factors: none |
| libsystem_secinit | 5 | 0 | App sandbox initializer: no-op until Finch has an app sandbox |
| libsystem_sanitizers | 57 | 1 | ASan ABI entry points: report "no sanitizer" |
| libsystem_coreservices | 18 | 10 | `sysdir` search paths and per-user dirhelper directories |
| libRosetta | 42 | 14 | No x86 translation: report "not translated" |
| libquarantine | 78 | 40 | Quarantine xattrs via the kernel's Quarantine kext interface |
| libsystem_containermanager | 422 | 25 | No container daemon yet: lookups answer as macOS answers an unsandboxed, unentitled process (26,971 checks against Apple's) |
| libsystem_networkextension | 187 | 34 | No network extension daemon or configurations yet: sessions stay disconnected (2,435 checks against Apple's) |
| libsystem_trace | 197 | 83 | Finch logging (os_log, os_signpost, os_activity) and a log store |
| libsystem_sandbox | 166 | 55 | Finch's client and file-trust calls; 389 host comparisons and 1,060 request checks. Nine unused manifest/GPU helpers return unsupported errors |
| libcorecrypto | 1,092 | 1,063 | corecrypto ABI on an open crypto library |
| libcache | 34 | 16 | Finch's, from `<cache.h>`'s documentation (Apple doesn't publish libcache) |

## Open source: build it

libSystem.B (Libsystem), libdyld and dyld (dyld), libobjc (objc4), libc++, libc++abi,
libunwind and libcompiler_rt (LLVM), libcommonCrypto (CommonCrypto), libcopyfile,
libremovefile, libkeymgr, libcache, libmacho, libsystem_asl (syslog),
libsystem_configuration (configd), libsystem_dnssd (mDNSResponder),
libsystem_collections, libsystem_m (Apple's Libm source is stale: CORE-MATH and FreeBSD
msun, see `userland/libm/README.md`).

Apple builds libc++, libc++abi, libunwind and libcompiler_rt from its own LLVM fork, which it doesn't
publish. Finch builds them from upstream LLVM 22.1.8, the first release with
Apple's arm64e (pointer authentication) unwinding, which matches Apple's ABI in both
directions. `tools/build-llvm-runtimes.sh` links them with Apple's install names, versions and
export lists (`userland/llvm/exports`). Finch code fills the gaps upstream leaves: typed
`operator new`/`delete` (backed by `malloc_type`), the hardening-failure hook,
`numpunct_byname::__init`, the `$ld$previous`/`$ld$hide` markers, and a patch that keeps two
`__time_get_storage` helpers exported.

## Needs the user at the machine

- Bare-metal boot (Phase 0): `docs/BARE_METAL.md` gives the steps. They touch only a new
  Finch APFS container, never the main macOS boot policy.
- Root-owned files in images: building the image with `sudo`.

## Progress

| Date | Finch-built images (of 45) | Landed |
|---|---|---|
| 2026-10-06 | 12 | (start) |
| 2026-10-06 | 21 | featureflags (3,303/3,303 features match Apple's), coreservices (2,408/2,408 sysdir cases and per-user directories match; `/var/folders` now works in the VM), darwindirectory, eligibility, symptoms, trial, secinit, sanitizers, libRosetta |
| 2026-10-06 | 22 | libSystem.B from Libsystem-1356 (same re-exports, exports and version as Apple's) |
| 2026-10-06 | 24 | libkeymgr (keymgr-31, 11/11 exports), libremovefile (removefile-85.100.6, 14/14; APFS purgeable-clear constants read from Apple's library) |
| 2026-10-07 | 26 | libquarantine (Finch's: 281,800 differential checks against Apple's, covering parsing, serializing, setters, limits, errors and reading real attributes; applying skips the closed kernel policy's restamping), libcopyfile (copyfile-240, 11/11; `cp` keeps quarantine in the VM) |
| 2026-10-07 | 29 | libc++ (2,354/2,354 exports, same 384 re-exports from libc++abi), libc++abi (388/388), libunwind (43/43): LLVM 22.1.8 plus Finch additions. C++ and Objective-C exceptions, RTTI, iostreams, `std::format` and threads work in the VM (`finch-cxx-test`) and on the host, with either half of the libc++abi/libunwind pair swapped for Apple's |
| 2026-10-07 | 30 | libcompiler_rt (compiler-rt builtins from LLVM 22.1.8; 392/392 exports including the 318 `$ld$hide` markers and the `___chkstk_darwin` alias; 1,216,103 differential checks against Apple's covering 128-bit division, float/half conversions, complex multiply, `powi` and atomics, with 16-byte atomics locked as in Apple's) |
| 2026-10-07 | 31 | libobjc (objc4-951.7: 439/439 exports, same dependencies and version 228). The shared cache's Objective-C pre-optimizations (version 16) are honored. Apple's Foundation runs on it on the host, and `plutil` runs on it in the VM; `finch-objc-test` passes 23/23. libswiftCore stays a delay-loaded dependency, as in Apple's build, so it loads only for Swift code |
| 2026-10-07 | 33 | dyld and libdyld (dyld-1376.6, built with dyld's own Xcode project). dyld has the same layout as Apple's (load commands, segments, exports); libdyld matches 218/218 exports. Both share PREBUILTLOADER_VERSION with Finch's cache builder, so the cache's prebuilt loaders are used (48 ms to `main()`, down from 61). What dyld links statically from Apple's closed archives, Finch provides: SHA-1/2 digests (`userland/corecrypto`, checked against CommonCrypto), the AMFI dyld-policy query and the `syscall-unix` sandbox check (`userland/dyld`, from how macOS 26.4's dyld calls the kernel), and the TPRO register toggles (`<os/thread_self_restrict.h>`). libplatform and libpthread now also build their dyld variants |
| 2026-10-07 | 38 | libsystem_collections (Libc), libsystem_asl (syslog-406), libsystem_configuration (configd), libsystem_dnssd (mDNSResponder's client sources, plus the 15 exports from Apple's unpublished macOS files, written from macOS 26.4's library), libmacho (cctools-1035.1.102; 1,066 checks against Apple's 1040), libcache (Finch's; 300,600 checks against Apple's covering hashes, return codes and every callback). All match Apple's exports, versions and umbrellas exactly. `check-exports.sh` now also checks versions and umbrellas, and the audit fixed libkeymgr, libremovefile, libsystem_info, libsystem_notify and libsystem_kernel |
| 2026-10-07 | 39 | libsystem_m: CORE-MATH (correctly rounded) for the real functions, FreeBSD msun for the rest of C99, Finch code for Apple's interfaces (444/444 exports, depends only on libdyld and libcompiler_rt). 8.9 million checks against Apple's; the real functions are more accurate than Apple's (Apple up to 291 ulp off for `tgamma`). Every geometry-predicate disagreement is confirmed exactly in Finch's favour. Complex special values follow C's Annex G where Apple's don't |
| 2026-10-07 | 40 | libsystem_containermanager (Finch's: 422/422 exports). Finch has no container daemon yet, so lookups give the answers macOS gives an unsandboxed, unentitled process: nothing found, entitlement-gated requests refused, and app group paths computed under the home directory. Error codes, error objects and their descriptions, class helpers, entitlement parsing and the seam tables match Apple's. 26,971 differential checks against Apple's library; Foundation (`plutil`) runs on it in the VM |
| 2026-10-07 | 41 | libsystem_networkextension (Finch's: 187/187 exports). With no network extension daemon or configurations yet, sessions answer as macOS does for a configuration that doesn't exist: disconnected, no info, canceled on request; no configuration is present and nothing is blocked. Name tables, constants, logging switches, the configuration generation (from the same notification state) and the functions macOS implements as constants match Apple's: 2,435 differential checks |
| 2026-10-07 | 42 | Local sandbox replacement: 166/166 exports, matching version and umbrella. Trust queries, protected directories, storage-class removal and temporary names now build alongside the client. The rebuilt QEMU image reaches the shell and runs `plutil`. The missing dispatch queue-thread query also passes six host checks. Trace, corecrypto and CommonCrypto still need replacements |
| 2026-10-07 | 43 | Finch's libcorecrypto is in the image. It is built on OpenSSL 3.5.9 with Apple's exact 1,092 exports and nine dependencies, and passes 67 host comparison targets. It boots under finch-init, where `finch-crypto-test` confirms the loaded library is Finch's and passes CommonCrypto known-answer and P-256 checks. OpenSSL's notice installs to `/usr/share/finch/licenses`. Kernel patch 0006 keeps UTF-8 console output intact; finch-init sets the console to 8-bit |
| 2026-10-07 | 44 | CommonCrypto (`CommonCrypto-600035`, unmodified published source) is in the image on Finch's corecrypto, linked as Apple's: 245/245 exports, identical dependencies and version. 28,842 host comparisons; 14/14 in-VM checks with both libraries confirmed as Finch's builds by UUID. libm now installs CORE-MATH and msun licence notices |
