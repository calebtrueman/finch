# Hardware

## Current dev machine

| | |
|---|---|
| Model | Mac16,1 (MacBook Pro, M4) |
| SoC | T8132 |
| macOS | 26.4.1 (25E253) |
| Kernel | `xnu-12377.101.15~1/RELEASE_ARM64_T8132` (source tag published upstream ✔) |

## Asahi coverage by SoC (as of Oct 2026)

| SoC | Asahi status | Implication for Finch |
|---|---|---|
| M1 / M2 family | Mature, well documented | Best driver-replacement target |
| M3 family | Officially supported since Sep 2026 (GPU 3D still weak) | Good |
| M4 / M5 | Bring-up in progress | Least documentation; we'd be doing original RE |

## Recommended setup

- **Keep the primary M4 as the build host.** Build XNU, userland and images on it under
  normal macOS with SIP on.
- **Get a dedicated test Mac,** ideally a used M1 or M2 Mac mini. It's cheap, has HDMI
  out, Asahi has fully mapped it, and it makes recovery easy. Phase 0 requires
  Permissive Security, and booting experimental kernels shouldn't happen on the machine
  you work on.
- Optionally, add a second internal APFS volume with a macOS install on the test Mac.
  Finch boots alongside it, which provides the borrowed kexts, frameworks and firmware.
- Use a serial/debug path. m1n1 provides USB debug via a second Mac and a USB-C cable.
  Set it up before it's needed.

The M4 is fine for Phase 0 (custom XNU plus Apple kexts doesn't depend on Asahi). It
becomes the hard target once we start replacing drivers.
