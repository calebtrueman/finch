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
- If `build/vz/AVPBooter.bin` exists, the VM boots that ROM instead of the host's, using
  Virtualization's private `-[VZMacOSBootLoader _setROMURL:]`. A patched stage 0 then
  lives in Finch's build tree. The host's Virtualization.framework (and the host's SIP
  and sealed system volume) is never modified.
- `MACHINE_CONFIG=VMAPPLE tools/build-kernel.sh` builds Finch's XNU for the VM platform.
- First guest: macOS 26.6.2 (25G83) from `UniversalMac_26.6.2_25G83_Restore.ipsw`.

## Booting a custom kernel collection in the guest

Virtualization guests boot through three Apple-signed stages, each of which verifies
the next stage's image signature (Steven Michaud,
[custom boot objects](https://gist.github.com/steven-michaud/16cff5628850799e428a2f2c56029677)
and [third-party kexts in VMs](https://gist.github.com/steven-michaud/fda019a4ae2df3a9295409053a53a65c)):

1. **Stage 0, `AVPBooter.vmapple2.bin`.** The VM ROM, a host file. Finch would
   use a patched copy via `_setROMURL:` (above), not a modified host.
2. **Stage 1, LLB.** Stored in the VM's own auxiliary storage (`build/vz/aux.img`).
3. **Stage 2, `iBoot.img4`.** In the guest's Preboot volume.

Each patch makes the stage's image verification report success. Inside the guest, in
Recovery, the security policy is set to Reduced Security (user-managed kexts) and the
custom collection is installed with `kmutil configure-boot`.

## Needs a decision by the user

Patching the boot stages to skip signature verification is a security-mechanism change,
and Claude Code's permission system stopped it pending an explicit decision (2026-10-07).
What it would touch: copies of Apple's VM boot objects inside `build/vz/` and inside the
guest's own volumes. It would never touch the host's files, boot policy, SIP or sealed
system volume. If approved, the steps are:

1. Copy `AVPBooter.vmapple2.bin` to `build/vz/AVPBooter.bin` and patch the copy (the
   digest-check epilogue that uses the `DG` constant returns 0).
2. Patch the active LLB in `build/vz/aux.img`.
3. In the guest: patch `iBoot.img4` in Preboot (and Recovery's copies). In Recovery,
   set Reduced Security and run `kmutil configure-boot` with Finch's VMAPPLE kernel
   collection.

An alternative that avoids patched boot objects entirely: run Phase 2's userland
(window server, first app) on the guest's stock kernel first, and move to Finch's
kernel later.

## Also needs the user at the machine

The guest's first boot runs Setup Assistant, which needs the GUI (`finch-vz run`).
After that, enable Remote Login in the guest so Finch's tools can drive it over SSH.
