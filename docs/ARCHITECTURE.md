# Finch Architecture

Finch is a stack of layers (diagrams of what runs today: `docs/STACK.md`). For each one, this doc lists where the code comes from today
and what ultimately replaces it.

| Status | Meaning |
|---|---|
| **OPEN** | Apple publishes the source and we build it |
| **IMPORT** | A third-party open project we can use directly |
| **BORROW** | A proprietary Apple binary loaded from the user's macOS install during bootstrap. Never redistributed. Since 2026-10-08 only the kexts are borrowed. |
| **WRITE** | Finch's own implementation |

```
┌────────────────────────────────────────────────────────────────┐
│ Apps (unmodified macOS .app bundles)                           │
├────────────────────────────────────────────────────────────────┤
│ Desktop: Finch window server, compositor, Dock/Finder-alikes   │  WRITE
├────────────────────────────────────────────────────────────────┤
│ App frameworks: AppKit, SwiftUI, CoreGraphics, CoreText,       │  WRITE + IMPORT
│                 CoreAnimation, Metal, AVFoundation …           │
├────────────────────────────────────────────────────────────────┤
│ Foundation layer: CoreFoundation, Foundation, libdispatch,     │  OPEN + WRITE
│                   libobjc, Swift runtime, Security, ICU …      │
├────────────────────────────────────────────────────────────────┤
│ Darwin userland: dyld, libSystem, launchd, shells, BSD tools   │  OPEN + WRITE
├────────────────────────────────────────────────────────────────┤
│ Platform drivers: AIC, DART, ANS (NVMe), DCP, AGX GPU, SMC,    │  BORROW → WRITE
│                   PMGR, USB/Thunderbolt, audio, Wi-Fi/BT …     │  (Asahi docs inform)
├────────────────────────────────────────────────────────────────┤
│ Kernel: XNU (Mach + BSD + IOKit)                               │  OPEN
├────────────────────────────────────────────────────────────────┤
│ Boot: iBoot (Apple, immutable) → kernel collection / m1n1      │  Apple fw + IMPORT
└────────────────────────────────────────────────────────────────┘
```

## Layer notes

### Boot
Apple Silicon always starts in Apple's iBoot. In **Permissive Security** mode, iBoot will
load a custom *kernel collection* registered with `kmutil configure-boot`. Asahi uses the
same mechanism to load **m1n1** (MIT licensed), which then chainloads Linux.

Finch has two boot routes:
- **Direct:** iBoot loads a Finch-built XNU kernel collection. This is the simplest route
  and is where we start.
- **Via m1n1:** iBoot → m1n1 → XNU. This route gives us m1n1's hypervisor, tracing and
  hardware-poking tools, which are invaluable for driver work. m1n1 already traces macOS
  running under it, which is how Asahi reverse-engineers hardware.

### Kernel
XNU source is published per macOS release at `apple-oss-distributions/xnu`, typically
within weeks of the OS release. It builds for arm64 with Xcode plus a matching
**Kernel Debug Kit (KDK)**.

Constraint: borrowed Apple kexts are tied to the kernel version they shipped with. While
we borrow kexts, Finch's XNU must track the exact macOS build those kexts came from.
Once a driver is replaced, that coupling for it disappears.

### Platform drivers (the hard part)
The kexts that make an Apple Silicon Mac a Mac are closed source. The main ones are the
interrupt controller (AIC), IOMMU (DART), NVMe (ANS), display coprocessor (DCP), GPU
(AGX), SMC and power management.

- The Asahi Linux team has documented almost all of this hardware for M1/M2, and now M3.
  Their **documentation** and m1n1 tooling are our map.
- Their **Linux kernel code is licensed per file.** GPL-only files are incompatible
  with XNU's APSL-2.0 and are reference-only (clean-room rule). Dual-licensed files,
  including the Rust GPU kernel driver `drm/asahi` (`GPL-2.0-only OR MIT`), can be
  ported under MIT. See [LICENSING.md](LICENSING.md).
- **Mesa's Asahi GPU userspace driver (MIT)** is directly importable. Together with
  `drm/asahi` under MIT, that covers both halves of the GPU stack as a starting point
  rather than a from-scratch rewrite.

Replacement order, roughly by how much it unlocks: AIC → DART → ANS (storage) →
framebuffer/DCP → SMC/PMGR → USB → input → audio → Wi-Fi/BT (Broadcom) → AGX GPU.

### Darwin userland
Most of it is published: `dyld`, `Libc`, `libpthread`, `libmalloc`, `libdispatch`,
`objc4`, `Libnotify`, `Libinfo`, `bash`/`zsh`, `file_cmds` and others, all built by Finch
at pinned tags (`userland/projects.txt`). Where Apple doesn't publish, Finch writes its
own: `finch-init` (PID 1, in place of the closed launchd), libxpc, `finch-logd`,
libsystem_trace and the private libSystem pieces. Phase 1 finished on 2026-10-07: the
VM boots with no closed Apple binaries above the kernel (`docs/design/PHASE1-EXIT.md`).

### Frameworks (the other hard part)
This layer is what makes Finch "compatible with Mac software." Options per framework:
1. Apple open source (CF from swift-corelibs-foundation, IOKitUser, ICU, WebKit, the
   Swift runtime).
2. Third-party open libraries underneath Apple's API: Skia, FreeType and HarfBuzz under
   CoreGraphics and CoreText (`docs/design/COREGRAPHICS.md`), and later Mesa under Metal.
3. Write our own, ABI-compatible with Apple's symbols, class placement and Objective-C
   class layouts. Foundation is Finch's own (`docs/design/FOUNDATION.md`).

Nothing closed is borrowed, not even temporarily. Each framework is checked against
Apple's on the host: the same test program runs on Apple's framework and on Finch's,
and the outputs must match. `tools/check-framework-api.py` measures how much of
Apple's exported API each Finch framework covers.

Metal is the long pole. The likely route is Metal API → Finch implementation → Mesa
(asahi / Gallium / NIR) → AGX.

### Desktop
WindowServer/SkyLight is private and undocumented. Finch writes its own window server
and compositor. CoreGraphics' public window/event APIs define the compatibility surface
that apps actually touch.
