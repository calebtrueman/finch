# Userland inventory (macOS 26.4.1 / 25E253 ramdisk)

This is what the VM's userland is made of today, and where each piece comes from.
"Published" is checked against Apple's
[macOS 26.4 source release](https://github.com/apple-oss-distributions/distribution-macOS/blob/macos-264/release.json).
The ramdisk has **no dyld shared cache**: each library is a standalone dylib, so
pieces can be replaced one at a time.

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

## libSystem (`/usr/lib/libSystem.B.dylib` + `/usr/lib/system/*`)

| Dylib | Apple project | Status |
|---|---|---|
| libSystem.B | Libsystem-1356 | OPEN |
| libsystem_kernel | xnu-12377.101.15 (libsyscall) | OPEN |
| libsystem_platform | libplatform-375.100.10 | OPEN |
| libsystem_pthread | libpthread-539.100.4 | OPEN |
| libsystem_malloc | libmalloc-812.100.31 | OPEN |
| libsystem_c | Libc-1752.100.10 | OPEN |
| libsystem_darwin | Libc-1752.100.10 (libdarwin) | OPEN |
| libsystem_info | Libinfo-600 | OPEN |
| libsystem_notify | Libnotify-348.100.7 | OPEN |
| libsystem_blocks | libclosure-96 | OPEN |
| libdispatch | libdispatch-1542.100.32 | OPEN |
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
| libxpc, liblaunch | XPC / launchd | CLOSED |
| libquarantine | Quarantine | CLOSED |
| libsystem_sandbox, libsystem_secinit | Sandbox | CLOSED |
| libsystem_containermanager | Containers | CLOSED |
| libsystem_coreservices | CoreServices | CLOSED |
| libsystem_featureflags | Feature flags | CLOSED |
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
| `bash`, `ls`, `cat`, and other `/bin` and `/sbin` tools from darwin-vm's sysroot | Prebuilt by darwin-vm ([ios-cli-tools](https://github.com/jprx/ios-cli-tools)) | Rebuild from shell_cmds / file_cmds / text_cmds / bash / zsh / system_cmds |
| `mount_*`, `fsck_*`, `newfs_*` (from the restore ramdisk) | diskdev_cmds / hfs; APFS tools are closed | Mixed |
