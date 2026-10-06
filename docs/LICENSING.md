# Licensing & Provenance

This is not legal advice. Before Finch ships anything publicly, a real lawyer should
review this. The rules below exist to keep us out of trouble until then.

## Sources

| Source | License | How we use it |
|---|---|---|
| XNU, most Darwin userland | APSL 2.0 | Build and modify. Modifications to APSL files stay APSL and must be published. |
| CF-Lite, libdispatch, swift-corelibs, Swift, LLVM/clang | Apache 2.0 / APSL | Build directly |
| WebKit | BSD / LGPL | Build directly |
| m1n1 | MIT | Import |
| Mesa (incl. asahi driver) | MIT | Import |
| Asahi **documentation** (wiki, register notes) | Docs | Use as reference |
| Asahi **Linux kernel drivers** | GPL-2.0 | **Reference only, under the clean-room rule** |
| GNUstep | LGPL | Case by case. Dynamic linking is fine; avoid copying it into APSL/MIT files. |
| Darling | GPL-3.0 | Ideas and research only. No code. |
| Apple proprietary binaries (kexts, frameworks, firmware) | Apple EULA | **Never committed, never redistributed.** Loaded from the user's own macOS install at runtime only. |

## Clean-room rule for GPL drivers

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
