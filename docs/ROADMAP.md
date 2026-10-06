# Roadmap

Strategy: **ship of Theseus.** Get a complete, booting system as early as possible by
borrowing Apple's proprietary parts from the user's macOS install. Then replace those
parts one by one, using the originals as the reference for correct behavior. Every phase
ends with something that boots.

## Phase 0: Our kernel boots
Build XNU from source and boot it on real Apple Silicon with Apple's own kexts.
- [x] Reproducible XNU build for `xnu-12377.101.15` (matches dev machine) with KDK: `tools/build-kernel.sh`
- [x] Build a kernel collection: our XNU + BORROWED kexts (KDK 25E253; 308/310 link, see `boot/kc/excluded-kexts.txt`)
- [x] Boot stock Darwin in darwin-vm (emulated M4) — see docs/DEV_VM.md
- [x] Boot our XNU in darwin-vm (2026-10-06)
- [ ] Create the isolated Finch APFS container on the M4. Permissive Security for that
      OS only. Boot our kernel collection on bare metal.
- [x] A visible Finch fingerprint: `uname -v` reports `finch:finch-0.0.1/xnu-12377.101.15/…`

**Exit:** macOS userland runs on a kernel we compiled.

## Phase 1: Our userland boots
Replace the userland with Darwin built from Apple's open source, plus Finch code where
Apple's is closed. Developed in the emulated M4 first. The map is
`userland/INVENTORY.md`.
- [x] **1.1 Finch PID 1.** `finch-init` replaces the closed launchd: console, OS version
      sysctls, rc script, respawning shell, orphan reaping. Boot with `FINCH_INIT=1`
      (2026-10-06).
- [ ] **1.2 Commands from source.** Build shell_cmds, file_cmds, text_cmds, system_cmds and
      bash/zsh ourselves, replacing darwin-vm's prebuilt sysroot.
  - [x] file_cmds, shell_cmds, text_cmds, adv_cmds, system_cmds: 188 binaries build and
        run under finch-init (`tools/build-oss.sh`, 2026-10-06)
  - [x] bash 3.2 (bash-144), zsh 5.9 + modules (zsh-118, via `userland/oss/zsh.build.sh`),
        bc/dc. zsh is the console shell.
  - [ ] libiconv i18n modules (`/usr/lib/i18n`, needed by zsh prompt expansion)
  - [ ] Deferred tools (see `userland/INVENTORY.md`)
  - [ ] Finch `reboot` / `halt` / `shutdown` (Apple's need closed launchd SPI)
  - [x] Ramdisk grown to 600 MiB without sudo (raw APFS resize); writable tmpfs for /tmp
        and /var/{tmp,run,log,root}
  - [ ] Root-owned files in dev images (they arrive as uid 99; the root fs can't be
        remounted read-write). Build release images with root.
  - [ ] Writable /var/db (System Policy denies tmpfs there)
- [ ] **1.3 Open libSystem from source.** Swap dylibs one at a time, starting with
      libsystem_kernel from our own xnu build.
  - [x] libsystem_kernel (xnu libsyscall + patch 0003), running in the VM (2026-10-06).
        Missing vs Apple's build: 7 legacy `__stat`-family stubs, `register_uexc_handler`,
        and 2 version symbols; nothing imports them.
  - [x] libsystem_platform (libplatform; recipe from its published xcconfigs, plus Finch
        `ffs`/`fls`, SME-safe string routines and one Swift tracing no-op). 185/185 exports.
  - [x] libsystem_pthread (libpthread + `userland/patches/libpthread`; Finch
        `<os/thread_self_restrict.h>` for the JIT write-protect toggle). 209/209 exports.
  - [x] libsystem_malloc (libmalloc; Finch `<os/feature_private.h>` ABI-compatible with
        Apple's libsystem_featureflags; header-only Finch SHA-256 replaces the libcorecrypto
        dependency). 118/118 exports.
  - [x] libdispatch (config reconstructed: Apple publishes libdispatch.xcconfig nearly
        empty). 410/411 exports (missing: an unused watchdog helper).
  - [x] `finch-libsystem-test` (userland/tests) passes in the VM: malloc, pthread, dispatch,
        string/bit ops. The JIT toggle is untestable in QEMU (no SPRR); verify on bare metal.
  - [ ] libsystem_c, libsystem_blocks, libsystem_info, libsystem_darwin, dyld, …
- [ ] **1.4 Finch replacements for closed libSystem pieces** (libxpc, libsystem_trace,
      sandbox, quarantine, …). Start with the subset our binaries actually import.
  - [x] libmalloc no longer depends on libcorecrypto
  - [ ] libsystem_featureflags (ABI known: `_os_feature_enabled_impl`,
        `_os_feature_enabled_simple_impl`)
- [ ] **1.5 dyld from source.**
- [ ] Finch root image on its own APFS volume (bare-metal Tier 3)

**Exit:** the VM boots to a shell with no closed-source Apple binaries above the kernel.

## Phase 2: First pixels and first app
- [ ] Framebuffer console via the iBoot-initialized display (simple framebuffer)
- [ ] Minimal Finch window server and compositor (software rendering)
- [ ] BORROWED AppKit/CoreGraphics running against Finch's window server via a shim
- [ ] TextEdit or Calculator launches and is usable

**Exit:** an unmodified Mac app draws a window on Finch.

## Phase 3: Open drivers
Replace BORROWED kexts with Finch kexts, M1/M2 first (best Asahi docs).
- [ ] AIC, DART
- [ ] ANS (NVMe storage)
- [ ] DCP (displays, brightness, external monitors)
- [ ] SMC, PMGR (power, sleep, battery)
- [ ] USB, keyboard/trackpad, audio
- [ ] Wi-Fi/Bluetooth
- [ ] AGX kernel driver + Mesa asahi userspace

**Exit:** Finch boots on an M1/M2 Mac with zero Apple kexts.

## Phase 4: Open frameworks
Replace BORROWED frameworks, ordered by app coverage.
- [ ] Foundation (from swift-corelibs + gaps)
- [ ] CoreGraphics / CoreText / ImageIO
- [ ] QuartzCore (CoreAnimation)
- [ ] AppKit
- [ ] Metal → Mesa
- [ ] SwiftUI
- [ ] AVFoundation / CoreAudio / CoreMedia

**Exit:** a defined app corpus (e.g., top 50 non-App-Store Mac apps) runs with no Apple
binaries.

## Phase 5: Finch 1.0
Installer, updates, Finch desktop polish, security model (code signing, sandbox, SIP-like
protections under Finch's own keys).

## Beyond: Finch for iPhone/iPad
Depends on a bootrom/iBoot path to unsigned code on target devices, which is not
available on current iPhones without exploits. This is a research track, not a schedule.
