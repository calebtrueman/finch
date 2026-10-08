# Finch: notes for Claude

Finch is an open-source OS for Apple Silicon built on Darwin/XNU and aiming at macOS
binary compatibility. Read `README.md` and `docs/` before making structural decisions.

Hard rules:
- Never commit Apple proprietary binaries (kexts, frameworks, firmware, KDK contents).
  Bootstrap loads them from the user's macOS install at runtime only.
- Never copy GPL-only code (Darling; GPL-only Asahi files) into Finch. Check SPDX per file:
  Asahi `GPL-2.0-only OR MIT` files may be used under MIT. See `docs/LICENSING.md`.
- Patches sent to QEMU / qemu-sptm must not contain AI-generated content (QEMU's
  code-provenance policy). Report bugs as issues and let the user write any patch.
- Pin Apple open-source imports to exact tags (e.g., `xnu-12377.101.15`).
- The M4 is the only machine (build host + test target). Test in QEMU (darwin-vm) first,
  then a VZ VM, then bare metal. On metal, only touch the boot policy of the dedicated
  Finch APFS container, never the main macOS. See `docs/HARDWARE.md`.
- `docs/STACK.md` holds the Mermaid diagrams of the software stack. Any commit that
  adds, replaces or removes a component updates them (and the "As of" line) in the
  same commit. Run `tools/render-stack.sh` to check they render.
