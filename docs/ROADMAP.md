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
- [ ] **1.3 Open libSystem from source.** Swap dylibs one at a time, starting with
      libsystem_kernel from our own xnu build.
- [ ] **1.4 Finch replacements for closed libSystem pieces** (libxpc, libsystem_trace,
      sandbox, quarantine, …). Start with the subset our binaries actually import.
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
