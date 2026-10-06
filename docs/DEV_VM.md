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

## Status
- 2026-10-06: the stock 25E253 kernel boots to a root shell. It reports
  `hw.model: Mac16,10` with 10 CPUs and 8 GB.
