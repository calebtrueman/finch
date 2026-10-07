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
  - [x] libiconv, libcharset and the i18n modules and tables (`/usr/lib/i18n`, `/usr/share/i18n`)
  - [ ] Deferred tools (see `userland/INVENTORY.md`)
  - [x] `reboot` / `halt` / `shutdown` from system_cmds, through finch-init's shutdown
        sequence (`reboot3`)
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
  - [x] libsystem_blocks (libclosure). 19/19 exports.
  - [x] libsystem_c (Libc). 1328/1328 exports. Finch `os/log_private.h` (ABI of the
        closed libsystem_trace), header-only `corecrypto/ccrng.h` over getentropy(2)
        (no libcorecrypto), generated dyld version constants, `_atexit_receipt`
        (App Store exit hook recorded, not run).
  - [x] libsystem_darwin, libsystem_info (on Finch libxpc)
  - [x] libsystem_notify and notifyd (Libnotify), with notifyd run on demand by finch-init
  - [x] dyld shared cache, built by Finch from the image (`docs/design/DYLD_CACHE.md`):
        process launch about 50× faster in the VM (3 s → 61 ms for `/usr/bin/true`)
  - [ ] libsystem_m, dyld, …
  - [x] Finch CrashReporterClient (`__crash_info` annotations), linked by Libc and notifyd
- [ ] **1.4 Finch replacements for closed libSystem pieces** (libxpc, libsystem_trace,
      sandbox, quarantine, …). Start with the subset our binaries actually import.
  - [ ] **libxpc**, the next gating piece: Apple-ABI-compatible XPC objects and
        connections, with the Mach bootstrap/service registry in finch-init. Mac apps and
        most of libSystem's upper half depend on it. Plan and progress:
        `docs/design/XPC.md`.
    - [x] X1 object model and value types (100/462 imported symbols)
    - [x] X2 wire format, byte-compatible with Apple's (checked against captured samples,
          fuzzed under ASan)
    - [x] X3 Mach transport: pipes and connections, interoperating with Apple's libxpc in
          both directions (144/462 imported symbols)
    - [x] X4 finch-init bootstrap server, X5 swap in (the VM runs on Finch libxpc)
  - [x] libsystem_info and libsystem_darwin built from source on Finch libxpc
  - [x] **Service manager** in finch-init: launchd job plists, MachServices with launch on
        demand, KeepAlive, run as another user (`docs/design/SERVICES.md`)
    - [x] `launchctl` (Finch's own: list, print, start/stop, kickstart, kill, load/unload)
    - [ ] LaunchAgents and per-user domains, Sockets/timers/WatchPaths,
          shutdown
    - [ ] Run Apple's open-source daemons under it (notifyd, syslogd, configd, ...)
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

## Phase 6: Windows software
Run Windows applications on Finch, as CrossOver and Game Porting Toolkit do on macOS.
- **Wine** (LGPL-2.1, dynamically linked component) for the Win32/Win64 API layer.
- **ARM64 Windows apps** first: they need no CPU translation.
- **x86-64 apps:** BORROW Rosetta 2 from the user's macOS install at first. The open
  replacement is an x86 translator ported to Darwin: FEX-Emu or Box64 (MIT), or Wine's
  ARM64EC path with FEX.
- **Graphics:** DXVK / vkd3d-proton (Direct3D → Vulkan) on Mesa's Vulkan driver for AGX,
  which Phase 3/4 bring up anyway.

**Exit:** a defined corpus of Windows apps (ARM64 and x86-64) runs on Finch with no
Apple binaries.

## Beyond: Finch for iPhone/iPad
Depends on a bootrom/iBoot path to unsigned code on target devices, which is not
available on current iPhones without exploits. This is a research track, not a schedule.
