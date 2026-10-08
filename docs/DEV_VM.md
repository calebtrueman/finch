# Dev VM: emulated M4 (Tier 1)

[darwin-vm](https://github.com/jprx/darwin-vm) runs Apple Silicon Darwin in QEMU
(`qemu-sptm` fork). It's pinned as a submodule at `third_party/darwin-vm`. Its
`firmware/` directory holds Apple binaries extracted from an IPSW. They live only in the
submodule's working tree and are never committed.

## Target
| | |
|---|---|
| Emulated device | `Mac16,10` (M4 Mac mini, j773gap) |
| SoC / kernel ext | `t8132` / `mac16g` |
| macOS | 26.4.1 (25E253): same build as the host |
| Stock kernel | `xnu-12377.101.15~1/RELEASE_ARM64_T8132` |

## Setup (one time)

```sh
brew install jq ipsw ninja pkgconf glib pixman python@3.13
git submodule update --init --recursive third_party/darwin-vm
git -C third_party/darwin-vm/qemu-sptm apply ../../patches/qemu-sptm/*.patch

# Build QEMU. Notes:
# - The host has MacPorts in /opt/local, which shadows Homebrew; put Homebrew first.
# - The build runs scripts via `#!/usr/bin/env python3`, which must be ≥3.12
#   (the system's 3.9 fails on nested-quote f-strings in dumpregs.py).
cd third_party/darwin-vm/qemu-sptm && mkdir build && cd build
export PATH=/opt/homebrew/opt/python@3.13/libexec/bin:/opt/homebrew/bin:$PATH
export PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig
../configure --python=python3 --target-list=aarch64-softmmu --disable-pvg
make -j10
cd ../..

# Fetch firmware: partial remote extraction, not a full IPSW download.
DEVNAME="Mac16,10" \
URL="https://updates.cdn-apple.com/2026WinterFCS/fullrestores/122-28781/DCB2FF13-06CB-44C2-BCA2-DFCAF3521D46/UniversalMac_26.4.1_25E253_Restore.ipsw" \
./get_files.sh

# Needs sudo. Run in a real terminal.
echo y | ./fix_perms.sh firmware/ramdisk.dmg
```

## Run
- Interactive: `cd third_party/darwin-vm && ./run.sh`. Quit with `Ctrl-A x`.
- Automated smoke test: `expect tools/vm/smoke.exp`. It boots to the root shell, runs
  `uname -a` and `sysctl`, and quits.

## Finch userland in the VM

```sh
make -C userland/finch-init       # -> build/userland/finch-init
tools/vm/mkramdisk.sh             # base ramdisk + tools/vm/overlay.txt -> build/vm/ (no sudo)
tools/vm/run.sh                   # boot with finch-init as PID 1 (launchdsuffix=finch)
expect tools/vm/smoke.exp
```

`tools/vm/run.sh` uses `build/vm/ramdisk.dmg` when it exists. Otherwise it uses darwin-vm's
base ramdisk.

The image adds a test user, `finchtest` (uid 501, no password, so it's reachable only
by `su` from root), for per-user domain tests. Home directories are under `/Users`, a
link into the `/private/var/rw` tmpfs, as `/var/db` is.

`mkramdisk.sh` runs without sudo, so files it adds belong to `_unknown` (uid 99) in the VM,
not root. Everything runs as root there, so this rarely matters. The exception is setuid
tools used by another user, e.g. `su` run from `nobody` reports "not running setuid".

## Apple open-source commands

```sh
tools/fetch-src.sh                       # clone projects pinned in userland/projects.txt
tools/mksdk.sh                           # private-header overlay -> build/sdk
tools/build-oss.sh file_cmds executables # xcodebuild -> build/root (signed)
tools/build-oss.sh shell_cmds All_OSX
tools/build-oss.sh text_cmds executables
tools/build-oss.sh adv_cmds Desktop
tools/build-oss.sh system_cmds All_MacOSX
tools/vm/mkramdisk.sh                    # overlays build/root, trusts every Mach-O, checks dylib deps
expect tools/vm/smoke.exp "ls -la /bin" "df -h /"
```

## libSystem pieces

```sh
tools/build-oss.sh libsyscall          # -> libsystem_kernel.dylib (needs tools/build-kernel.sh first)
tools/build-oss.sh libplatform         # -> libsystem_platform.dylib
tools/check-exports.sh /usr/lib/system/libsystem_platform.dylib
tools/build-llvm-runtimes.sh           # -> libc++, libc++abi, libunwind, libcompiler_rt (upstream LLVM)
tools/build-oss.sh objc4 objc-env objc  # -> libobjc.A.dylib
```

`check-exports.sh` compares our dylib with Apple's original and fails if any binary in the
image imports a missing symbol, whether directly or through the libSystem umbrella.
Run it before booting a swapped library: a missing symbol in PID 1's closure panics the
boot.

## QEMU patches

Finch carries patches against `qemu-sptm` in `third_party/patches/qemu-sptm/`. Apply them
before building QEMU:
`git -C third_party/darwin-vm/qemu-sptm apply ../../patches/qemu-sptm/*.patch`

- 0001: clear FEAT_LVA (`ID_AA64MMFR2_EL1.VARange`). Apple Silicon doesn't have it, and
  DEVELOPMENT kernels assert on it (`vm_sanitize.c`). This bug panicked the first
  `ps` run under finch-init. Reported upstream: https://github.com/jprx/darwin-vm/issues/14

## Booting the Finch kernel

```sh
tools/build-kernel.sh --install   # build XNU + patches, link KC, make it darwin-vm's bootkc
expect tools/vm/smoke.exp
```

The original kernelcache from Apple's restore image is kept at `firmware/kcs/stock.release`. To go back to it:
`ln -sfn kcs/stock.release third_party/darwin-vm/firmware/bootkc`.

## Debugging an early panic

If nothing prints, the kernel probably panicked before the console came up. Run QEMU with
`-s -S`, then attach lldb to the kernel collection. darwin-vm loads it slid by 0x20000000:

```
target create build/kc/finch-0.0.1.t8132.development
target modules load --file finch-0.0.1.t8132.development --slide 0x20000000
gdb-remote 127.0.0.1:1234
br set -n panic_with_thread_kernel_state
c
```

## Known intermittent boot failures

Smoke runs fail now and then in two ways, both seen in every session's logs
since Phase 1 (2026-10-06 onward: roughly 1 in 12 runs over several hundred).
Rerunning boots normally.

- **New processes stall after the jobs load.** `smoke.exp` reports
  `TIMEOUT waiting for shell`. Tracing finch-init on 2026-10-08 showed that the
  console shell is forked and exec'd, and syslogd and dynamic_pager are
  exec'd too (AMFI logs them), but none of the three reaches its first
  bootstrap request. Every process makes that lookup of logd early in
  libSystem's initialization, so the stall is between exec and libSystem init:
  in the kernel, dyld, or the emulated TXM/SPTM path. finch-init and its
  bootstrap server stay responsive. It was seen in about 1 boot in 3 with
  dynamic_pager's job and none in 10 without it, which suggests
  timing (more concurrent execs) more than dynamic_pager itself. That job
  only exits in the VM. The next step is the QEMU gdb stub
  (`DEBUG=1 tools/vm/run.sh`) on a stalled boot, to see where the kernel
  threads of those processes wait.
- **QEMU exits during the boot banner.** `smoke.exp` reports `send: spawn id
  ... not open`. The console stops mid-banner, right after
  `load_init_program`, and the emulator process is gone. Not yet
  investigated. As with any qemu-sptm bug, it would be reported upstream
  as an issue.

## Console output
The serial console drops bytes 0x80–0x9F, so 4-byte UTF-8 characters (emoji)
look garbled in `smoke.exp` logs, though the program wrote the right bytes.
Pipe output through `od -An -tx1` to check what a program actually wrote.

## Status
- 2026-10-06: the stock 25E253 kernel boots to a root shell. It reports
  `hw.model: Mac16,10` with 10 CPUs and 8 GB.
- 2026-10-06: **the Finch kernel boots** to a root shell:
  `Darwin Kernel Version 25.4.0 … finch:finch-0.0.1/xnu-12377.101.15/DEVELOPMENT_ARM64_T8132`.
  The first attempt panicked before the console came up. The public Xcode's
  `libclang_rt.cc_kext.a` `__chkstk_darwin` has no `bti c` landing pad, so a BTI fault
  recursed until the stack overflowed. Fixed by `kernel/patches/0001`.
