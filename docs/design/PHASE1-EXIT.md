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
| libsystem_containermanager | 422 | 25 | Data containers: none yet |
| libsystem_networkextension | 187 | 34 | No network extensions yet |
| libsystem_trace | 197 | 83 | Finch logging (os_log, os_signpost, os_activity) and a log store |
| libsystem_sandbox | 166 | 55 | Sandbox userspace: profile compilation and checks |
| libcorecrypto | 1,092 | 1,063 | corecrypto ABI on an open crypto library |

## Open source: build it

libSystem.B (Libsystem), libdyld and dyld (dyld), libobjc (objc4), libc++, libc++abi,
libunwind and libcompiler_rt (LLVM), libcommonCrypto (CommonCrypto), libcopyfile,
libremovefile, libkeymgr, libcache, libmacho, libsystem_asl (syslog),
libsystem_configuration (configd), libsystem_dnssd (mDNSResponder),
libsystem_collections, libsystem_m (Apple's Libm source is stale: use an open libm).

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
