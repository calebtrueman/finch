# Licensing & Provenance

This is not legal advice. Before Finch ships anything publicly, a real lawyer should
review this. The rules below exist to keep us out of trouble until then.

## Finch's own code

Original Finch code is dual-licensed **MIT OR Apache-2.0**, at the user's option (see
`LICENSE-MIT` and `LICENSE-APACHE`). Every source file carries
`SPDX-License-Identifier: MIT OR Apache-2.0`.

- **Why dual:** MIT keeps our code GPL-2.0-compatible, so Asahi Linux and other GPL
  projects can take our driver and hardware work. Apache-2.0 offers an explicit patent
  grant to those who want it. Rust and much of the Asahi ecosystem use the same
  arrangement.
- **Exception: changes to Apple's files.** Patches to XNU or other APSL-licensed files
  (`kernel/patches/`) stay APSL-2.0, as that license requires. New standalone files,
  such as Finch kexts, use MIT OR Apache-2.0.
- **Imported code** keeps its original license and headers.

Contributions are accepted under the same dual license (inbound = outbound).

## Sources

| Source | License | How we use it |
|---|---|---|
| XNU, most Darwin userland | APSL 2.0 | Build and modify. Modifications to APSL files stay APSL and must be published. |
| CF-Lite, libdispatch, swift-corelibs, Swift, LLVM/clang | Apache 2.0 / APSL | Build directly |
| WebKit | BSD / LGPL | Build directly |
| OpenSSL 3.5.9 | Apache 2.0 | Built and linked statically into Finch's libcorecrypto |
| LZFSE 1.0, LZ4 1.10.0 (lib), Brotli 1.1.0 | BSD-3 / BSD-2 / MIT | Built and linked statically into Finch's libcompression |
| XZ Utils 5.4.3 (liblzma), libxo, libsbuf | 0BSD / BSD | Build directly |
| m1n1 | MIT | Import |
| Mesa (incl. asahi driver) | MIT | Import |
| Asahi **documentation** (wiki, register notes) | Docs | Use as reference |
| Asahi Linux kernel code, **dual-licensed** files (e.g. `drivers/gpu/drm/asahi`: `GPL-2.0-only OR MIT`) | MIT option | Import under MIT. Keep the SPDX line and copyright. |
| Asahi Linux kernel code, **GPL-only** files | GPL-2.0 | **Reference only, under the clean-room rule** |
| GNUstep | LGPL | Case by case. Dynamic linking is fine; avoid copying it into APSL/MIT files. |
| Darling | GPL-3.0 | Ideas and research only. No code. |
| Apple proprietary binaries (kexts, frameworks, firmware) | Apple EULA | **Never committed, never redistributed.** Loaded from the user's own macOS install at runtime only. |

## Notices in the image

A third-party licence that requires its notice to travel with binaries (Apache,
MIT, BSD) is installed at `/usr/share/finch/licenses/<project>/`. The component
that embeds the code installs it. For example, `make -C userland/corecrypto
install` installs OpenSSL's `LICENSE.txt` and `AUTHORS.md`. For projects built with
`tools/build-oss.sh`, `userland/oss/<project>.notices` lists the source files to
install (OpenBSM's and OpenPAM's `LICENSE`, ncurses' `COPYING`). libm's build
installs CORE-MATH's and FreeBSD msun's notices. Where every source file
carries its own notice (CORE-MATH's per-file authors, msun's mix of BSD and Sun
fdlibm notices), `tools/collect-notices.py` collects them from exactly the
files built in, listing each distinct notice once with the files it covers.

## Clean-room rule for GPL drivers

Check each file's SPDX header first. Much of Asahi's newer Rust code is dual-licensed
`GPL-2.0-only OR MIT`, and we take that code under MIT. The rule below applies only to
GPL-only files.


APSL-2.0 and GPL-2.0 are mutually incompatible, so copying Linux driver code into an XNU
kext produces something nobody can legally distribute.

1. Hardware facts (register offsets, bit meanings, command protocols, firmware message
   formats) are not copyrightable. Write them up in `docs/hw/` in our own words.
2. Kext code is written from those writeups and m1n1/hardware traces, not by translating
   Linux source line by line.
3. When a driver is substantially informed by a specific Linux driver, record that in the
   commit message so provenance is auditable.

## Firmware

Some hardware (Wi-Fi, Bluetooth, DCP, GPU, ANS coprocessors) runs Apple firmware that is
loaded at boot. Asahi extracts it from the user's macOS install at install time, and so
will Finch. It is never committed to this repo.

## Trademarks

"Mac", "macOS", "Apple" and the like describe compatibility only. No Apple logos, icons or
artwork go into Finch's UI.
