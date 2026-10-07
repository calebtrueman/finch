# Userland inventory (macOS 26.4.1 / 25E253 ramdisk)

This is what the VM's userland is made of today, and where each piece comes from.
"Published" is checked against Apple's
[macOS 26.4 source release](https://github.com/apple-oss-distributions/distribution-macOS/blob/macos-264/release.json).
The image has a **dyld shared cache built by Finch** (`docs/design/DYLD_CACHE.md`) from
its own dylibs, Apple's and Finch's. Pieces are still replaced one at a time: rebuilding
the image rebuilds the cache.

| Status | Meaning |
|---|---|
| OPEN | Apple publishes current source; build it |
| LLVM | Comes from upstream LLVM |
| STALE | Apple's source exists but hasn't been published in years; use an alternative |
| CLOSED | No source; Finch must provide an implementation |
| ? | Not yet verified |

## PID 1

| Binary | Source | Status | Finch |
|---|---|---|---|
| `/sbin/launchd` | launchd (Swift since macOS 26; last published as launchd-842, 2014) | CLOSED | **Replaced by `finch-init`** (`userland/finch-init`) |

## Daemons (run by finch-init; job plists in `userland/LaunchDaemons`)

| Daemon | Apple project | Status |
|---|---|---|
| `notifyd` (com.apple.notifyd) | Libnotify-348.100.7 | **Built by Finch**, started on demand. Without LaunchEvents, its event publisher has no subscribers. |

## libSystem (`/usr/lib/libSystem.B.dylib` + `/usr/lib/system/*`)

| Dylib | Apple project | Status |
|---|---|---|
| libSystem.B | Libsystem-1356 | OPEN |
| libsystem_kernel | xnu-12377.101.15 (libsyscall) | **Built by Finch** (plus Finch `work_interval_instance_*`; Apple ships unpublished additions) |
| libsystem_platform | libplatform-375.100.10 | **Built by Finch** (Apple ships no Xcode project; Finch adds 9 unpublished exports) |
| libsystem_pthread | libpthread-539.100.4 | **Built by Finch** (+2 unpublished exports; Finch JIT/SPRR header) |
| libsystem_malloc | libmalloc-812.100.31 | **Built by Finch** (no longer links libcorecrypto) |
| libsystem_c | Libc-1752.100.10 | **Built by Finch** (no longer links libcorecrypto) |
| libsystem_darwin | Libc-1752.100.10 (libdarwin) | **Built by Finch** (APFS dir-stats fast path compiled out; it was already unused) |
| libsystem_info | Libinfo-600 | **Built by Finch** (without the closed Darwin Directory module, which is feature-flagged off on macOS) |
| libsystem_notify | Libnotify-348.100.7 | **Built by Finch** |
| libsystem_blocks | libclosure-96 | **Built by Finch** |
| libdispatch | libdispatch-1542.100.32 | **Built by Finch** (build config reconstructed) |
| libdyld | dyld-1376.6 | OPEN |
| libcopyfile | copyfile-240 | OPEN |
| libremovefile | removefile-85.100.6 | OPEN |
| libkeymgr | keymgr-31 | OPEN |
| libcommonCrypto | CommonCrypto-600035 | OPEN |
| libsystem_configuration | configd-1405.100.8 | OPEN |
| libsystem_dnssd | mDNSResponder-2881.100.56.0.1 | OPEN |
| libsystem_asl | syslog-406 | OPEN |
| libcompiler_rt | compiler-rt | LLVM |
| libunwind | libunwind | LLVM |
| libmacho | cctools (not in the 26.4 release) | ? |
| libsystem_m | Libm | STALE: use FreeBSD msun or LLVM libc |
| libcorecrypto | corecrypto (source-viewable, non-OSS license) | CLOSED |
| libsystem_trace | os_log / os_activity | CLOSED |
| libxpc, liblaunch | XPC / launchd | CLOSED: **replaced by Finch libxpc** (`userland/libxpc`, ABI-compatible; bootstrap served by finch-init) |
| libquarantine | Quarantine | CLOSED |
| libsystem_sandbox, libsystem_secinit | Sandbox | CLOSED |
| libsystem_containermanager | Containers | CLOSED |
| libsystem_coreservices | CoreServices | CLOSED |
| libsystem_featureflags | Feature flags | CLOSED (Finch header `os/feature_private.h` matches its ABI; implementation TODO) |
| libsystem_networkextension | NetworkExtension | CLOSED |
| libsystem_symptoms | Symptoms | CLOSED |
| libsystem_trial | Trial | CLOSED |
| libsystem_eligibility | Eligibility | CLOSED |
| libsystem_darwindirectory | Darwin directory services | CLOSED |
| libsystem_collections | | ? |
| libsystem_sanitizers | | ? |
| libcache | | ? |
| libunc | | ? |

## Other

| Item | Source | Status |
|---|---|---|
| `/usr/lib/dyld` | dyld-1376.6 | OPEN |
| `/bin/launchctl` | launchd (closed) | **Replaced by Finch's** (`userland/launchctl`, talks to finch-init) |
| `bash`, `zsh` + modules | bash-144, zsh-118 | **Built by Finch** (zsh is the console shell) |
| `bc`, `dc` | bc-35 | **Built by Finch** |
| `sh` | Prebuilt by darwin-vm | TODO: macOS's `sh` is a small shim that execs bash/zsh/dash |
| `/usr/lib/i18n/*` (iconv modules) | libiconv-115.100.1 | Missing from the ramdisk; build it |
| file_cmds, shell_cmds, text_cmds, adv_cmds, system_cmds | Apple OSS (`userland/projects.txt`) | **Built by Finch**: 188 binaries via `tools/build-oss.sh` |
| `mount_*`, `fsck_*`, `newfs_*` (from the restore ramdisk) | diskdev_cmds / hfs; APFS tools are closed | Mixed |

## Deferred commands (don't build yet)

| Tool | Project | Blocker |
|---|---|---|
| mtree | file_cmds | APFS private headers (APFS is closed) |
| install | file_cmds | macOS libmd lacks the incremental SHA-512 API |
| ipcs | file_cmds | needs xnu kernel-private types |
| su, login, passwd, chpass | shell_cmds, system_cmds | `rootless.h` and other private SPI; wait for the Finch security model |
| md5 | text_cmds | sha224.h and the libmd incremental API |
| pkill | adv_cmds | `sysmon.h` (closed) |
| gencat | adv_cmds | `msgcat.h` |
| latency, sc_usage, lskq, gcore, zprint, nvram, … | system_cmds | kernel-private tracing / zone / kqueue interfaces |

## Static libraries Finch provides

| Library | Apple | Finch |
|---|---|---|
| libCrashReporterClient.a | Apple-internal | `userland/CrashReporterClient`: per-image `__crash_info` record (version 5), linked by Libc and notifyd |
