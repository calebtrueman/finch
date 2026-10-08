# Tier 2: Finch in a Virtualization.framework VM

Phase 2 (first pixels, first app) needs a display. The emulated M4 (Tier 1) has none:
darwin-vm's `darwin` machine passes XNU an empty video structure, and adding a
framebuffer would mean changing qemu-sptm, whose AI-content policy Finch respects. So
Phase 2 runs in Tier 2: a macOS guest in Apple's Virtualization.framework, which has a
paravirtual display, booting Finch's kernel built for the VM platform (`VMAPPLE`).

## What exists

- `tools/vz/finch-vz` (`tools/vz/build.sh`): `fetch` downloads the newest restore image
  Apple supports for VMs, `install` creates the VM in `build/vz/` and installs macOS,
  and `run [--recovery] [--headless]` boots it. `build/` is shared into the guest
  read-only (virtiofs tag `finch`), and the VM has NAT networking for SSH.
- `MACHINE_CONFIG=VMAPPLE tools/build-kernel.sh` builds Finch's XNU for the VM platform.
- First guest: macOS 26.6.2 (25G83) from `UniversalMac_26.6.2_25G83_Restore.ipsw`.

## Which kernel

The guest boots the standard way, through Apple's signed boot chain, on its
own kernel. Finch doesn't modify the VM's boot stages. (2026-10-08: an
attempt to boot a custom kernel collection there was abandoned; see Status.)
That kernel is the one borrowed piece in Tier 2, as Apple's kexts are
everywhere until Phase 3. Everything above it is meant to be Finch's.

Finch's own kernel:
- runs in Tier 1 (the emulated M4) now, as it has since 2026-10-06;
- moves to the Mac itself through Apple's supported setting for a separate OS
  volume (Permissive Security on the dedicated Finch container, `docs/HARDWARE.md`),
  which is the bare-metal plan;
- `MACHINE_CONFIG=VMAPPLE tools/build-kernel.sh` still builds it for the VM
  platform, should Apple's VM gain a supported way to boot a custom kernel.

## Also needs the user at the machine

The guest's first boot runs Setup Assistant, which needs the GUI (`finch-vz run`).
After that, enable Remote Login in the guest so Finch's tools can drive it over SSH.

## Status

- 2026-10-08: the custom-kernel path was abandoned. `-[VZMacOSBootLoader _setROMURL:]`
  makes Virtualization's VM service crash at start, even with an unmodified ROM,
  and modifying the boot chain isn't a direction Finch takes. The host-side
  patched copies were deleted. **To do (user):** the guest's Preboot and Recovery
  volumes still hold a modified `iBoot.img4` from that attempt. Copy the original,
  saved as `build/vz/iBoot.orig.img4`, back over both (with the VM stopped) before
  booting the guest.
