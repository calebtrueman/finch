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
| `syslogd` (com.apple.syslogd) | syslog-406 | **Built by Finch**, kept alive. As on macOS, syslog(3) and asl(3) go to os_log (finch-logd), so its ASL store stays mostly empty. |
| `aslmanager` (com.apple.aslmanager) | syslog-406 | **Built by Finch**, started on demand by syslogd's trigger (`VPROC_GSK_IS_MANAGED` tells it it's a job) |
| `newsyslog` (com.apple.newsyslog) | syslog-406 | **Built by Finch**, every hour at :30; Apple's `/etc/newsyslog.conf` |
| `dynamic_pager` (com.apple.dynamic_pager) | system_cmds-1042.100.6.0.1 | **Built by Finch**, runs once at boot |
| `logd` (com.apple.logd) | closed | **Replaced by `finch-logd`** (`userland/logd`, on libdispatch's open firehose server; `docs/design/LOGD.md`), with Finch's `log(1)` |
| CoreFoundation.framework | swift-corelibs-foundation (Apache 2.0) | **Built by Finch** (`userland/CoreFoundation`; `docs/design/COREFOUNDATION.md`) |
| libicucore | ICU-76142.4.7 | **Built by Finch** |
| libz, libbz2, libedit, libresolv | zlib-100, bzip2-47, libedit-65, libresolv-96 | **Built by Finch**, Apple's exports exactly (patches in `userland/patches/{zlib,libedit}`) |
| libxml2 | libxml2-39.10 (MIT) | **Built by Finch** (`userland/oss/libxml2.build.sh`), Apple's version and exports exactly; Foundation's NSXMLParser uses it |
| liblzma, libxo, libsbuf | XZ Utils 5.4.3, libxo 1.6.0, FreeBSD 14.5 sbuf (upstream; Apple doesn't publish its copies for 26.4) | **Built by Finch** (`userland/{xz,libxo,libsbuf}`), Apple's versions, install names and exports exactly |
| IOKit.framework | IOKitUser-100231.100.18.0.1 | **Built by Finch** (`userland/IOKit`): IOKitLib, pwr_mgt, ps, platform; 500 of Apple's 2,372 exports, every one Finch's binaries import. HID, graphics, display, USB and kext parts come as something needs them. |
| libswiftCore | swift (Apache 2.0) | **Built by Finch** (`userland/swift`) |
| `cron`, `configd`, `mDNSResponder`, `diskarbitrationd` | cron-52, configd-1405.100.8, mDNSResponder-2881.100.56.0.1, DiskArbitration | OPEN, but they link closed frameworks (CoreFoundation, IOKit, and for cron BackgroundTaskManagement and CoreAnalytics), which Finch builds or writes first (`docs/design/COREFOUNDATION.md`). Apple doesn't publish mDNSResponder's macOS daemon for 26.4; Finch will run the portable `mDNSPosix` one. |

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
| libdyld | dyld-1376.6 | **Built by Finch** |
| libcopyfile | copyfile-240 | **Built by Finch** |
| libremovefile | removefile-85.100.6 | **Built by Finch** |
| libkeymgr | keymgr-31 | **Built by Finch** |
| libcommonCrypto | CommonCrypto-600035 | **Built by Finch** (unmodified source, on Finch libcorecrypto) |
| libsystem_configuration | configd-1405.100.8 | **Built by Finch** |
| libsystem_dnssd | mDNSResponder-2881.100.56.0.1 | **Built by Finch** |
| libsystem_asl | syslog-406 | **Built by Finch** |
| libcompiler_rt | compiler-rt | **Built by Finch** (LLVM 22.1.8) |
| libunwind | libunwind | **Built by Finch** (LLVM 22.1.8) |
| libmacho | cctools-1035.1.102 | **Built by Finch** |
| libsystem_m | Libm (stale) | **Finch's**: CORE-MATH + FreeBSD msun (`userland/libm`) |
| libcorecrypto | corecrypto (source-viewable, non-OSS license) | CLOSED: **Finch's** on OpenSSL 3.5.9 (`userland/corecrypto`, 1,092/1,092) |
| libsystem_trace | os_log / os_activity | CLOSED: **Finch's** (`userland/libsystem/trace`, 197/197) |
| libxpc, liblaunch | XPC / launchd | CLOSED: **replaced by Finch libxpc** (`userland/libxpc`, ABI-compatible; bootstrap served by finch-init) |
| libquarantine | Quarantine | CLOSED: **Finch's** (`userland/libsystem`) |
| libsystem_sandbox, libsystem_secinit | Sandbox | CLOSED: **Finch's** (`userland/libsystem`) |
| libsystem_containermanager | Containers | CLOSED: **Finch's** |
| libsystem_coreservices | CoreServices | CLOSED: **Finch's** |
| libsystem_featureflags | Feature flags | CLOSED: **Finch's** |
| libsystem_networkextension | NetworkExtension | CLOSED: **Finch's** |
| libsystem_symptoms | Symptoms | CLOSED: **Finch's** |
| libsystem_trial | Trial | CLOSED: **Finch's** |
| libsystem_eligibility | Eligibility | CLOSED: **Finch's** |
| libsystem_darwindirectory | Darwin directory services | CLOSED: **Finch's** |
| libsystem_collections | Libc-1752.100.10 | **Built by Finch** |
| libsystem_sanitizers | | CLOSED: **Finch's** |
| libcache | | CLOSED: **Finch's** |
| libunc | | ? |

## Other

| Item | Source | Status |
|---|---|---|
| `/usr/lib/dyld` | dyld-1376.6 | **Built by Finch** |
| `/bin/launchctl` | launchd (closed) | **Replaced by Finch's** (`userland/launchctl`, talks to finch-init) |
| `bash`, `zsh` + modules | bash-144, zsh-118 | **Built by Finch** (zsh is the console shell) |
| `bc`, `dc` | bc-35 | **Built by Finch** |
| `sh` | dash project (closed launcher) | **Finch's** (`userland/sh`): the variant launcher |
| `mount_tmpfs` | tmpfs.fs (closed) | **Finch's** (`userland/mount_tmpfs`) |
| libsysmon | sysmon (closed; sysmond client) | **Finch's** (`userland/libsysmon`, 36/36): process tables from libproc, no sysmond; `pgrep`/`pkill` run on it |
| libmd, libutil, libbsm, libncurses | libmd-7 (51/51; its SHA-2 headers in Finch's SDK), libutil-73, OpenBSM-21 (+ `userland/oss/OpenBSM/finch_compat.c`), ncurses-79 | **Built by Finch** |
| `libiconv.2`, `libcharset.1`, `/usr/lib/i18n/*` (25 modules), `/usr/share/i18n` (700 tables) | libiconv-115.100.1 | **Built by Finch** (exports match Apple's: 95/95, 2/2) |
| file_cmds, shell_cmds, text_cmds, adv_cmds, system_cmds | Apple OSS (`userland/projects.txt`) | **Built by Finch** (`tools/build-system.sh`; `ps` too, via `userland/patches/adv_cmds`) |
| `mount_*`, `fsck_*`, `newfs_*` (from the restore ramdisk) | diskdev_cmds / hfs; APFS tools are closed | Mixed |

## Deferred commands (don't build yet)

`userland/oss/<project>.deferred` lists these per project; `tools/build-system.sh` allows
exactly them to fail.

| Tool | Project | Blocker |
|---|---|---|
| passwd, chpass | system_cmds | OpenDirectory (closed) |
| atrun | system_cmds | Background Task Management SPI (closed) |
| bintrans tests | text_cmds | Apple-internal `darwintest.h` (the tools themselves build) |
| zprint, zlog | system_cmds | CoreSymbolication (closed) |

su and login build and use Finch's PAM: libpam from Apple's OpenPAM, the pam_modules
that don't need closed frameworks (rootok, uwtmp, self, env, group, nologin, sacl),
OpenPAM's pam_unix in place of pam_opendirectory, and Finch's `/etc/pam.d` stacks
(`userland/pam`). login weak-links libEndpointSecuritySystem, which the image doesn't have.
gcore works on processes it may read (in the VM, `finch-debuggee`); it relies on
libdyld's introspection, which needed two dyld patches (`userland/patches/dyld`):
falling back from the absent Dyld.framework, and the AA01 compact-info archive that
Apple's published dyld leaves out.

## Static libraries Finch provides

| Library | Apple | Finch |
|---|---|---|
| libCrashReporterClient.a | Apple-internal | `userland/CrashReporterClient`: per-image `__crash_info` record (version 5), linked by Libc and notifyd |
