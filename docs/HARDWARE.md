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

## Test strategy: M4 only

There is one machine, so testing works in three tiers, from safest to riskiest. Most work
happens in Tier 1.

### Tier 1: Emulated M4 (QEMU via [darwin-vm](https://github.com/jprx/darwin-vm), MIT)
QEMU emulation of Apple Silicon Macs, M4 included, that boots Darwin to a root shell with
custom XNU kernel collections. It can't brick anything, it attaches a debugger, and it
resets in seconds. There's no GUI, GPU, Wi-Fi or Bluetooth.
- **Use for:** Phase 0 (our kernel), Phase 1 (our userland), and early driver logic
  against emulated devices.
- QEMU is a GPL host tool that we run, not link. Licensing is fine.

### Tier 2: macOS guest in Virtualization.framework
Apple's own VM, which provides a GUI through paravirtual display/GPU devices. Custom
kernel collections need patched guest iBoot stages (see Steven Michaud's
[custom boot objects gist](https://gist.github.com/steven-michaud/16cff5628850799e428a2f2c56029677)).
- **Use for:** Phase 2 (window server, first app) before touching real display hardware.

### Tier 3: Bare metal M4, isolated boot volume
Asahi uses the same arrangement. Finch lives in its **own APFS container** with its own
macOS-installed boot policy. Permissive Security is set on **that** OS only. The main
macOS keeps Full Security and SIP. Choose the OS by holding the power button →
Startup Options.
- **Use for:** proving each phase on real silicon, and all real driver work (Phase 3).
- **Rules on metal:**
  - Keep a current Time Machine backup before any Tier 3 session.
  - Keep Apple's SMC/PMGR/battery kexts until our replacements have been proven by
    tracing (m1n1 hypervisor). Thermal, charging and power management are the only areas
    where bad driver writes could plausibly damage hardware.
  - Never change the main macOS boot policy.
  - Recovery fallback: if both macOS and recoveryOS become unbootable, a DFU revive needs
    a second Mac (or an Apple Store). This is unlikely, since custom kernels don't touch
    iBoot or the system recoveryOS, but it isn't impossible.

## Disk space ⚠

The internal SSD has about **58 GB free** (494 GB total). One IPSW is about 18 GB. XNU
plus userland builds, QEMU images and a Tier 3 container (≥40 GB) won't all fit. Get an
**external SSD** for IPSWs, build output and VM images, and reserve internal space for
the Tier 3 container.

## M4-specific reality

Asahi's M4 (T8132) work is still in progress. For Phase 3, we'll be doing original
reverse engineering on M4 alongside them, using m1n1 hypervisor tracing of macOS, not
just reading their docs. Their M1–M3 findings still carry over heavily; Apple reuses
most IP blocks across generations.
