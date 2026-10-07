# The dyld shared cache

macOS doesn't load its system libraries one file at a time. dyld maps one prelinked
**shared cache** that holds all of them, already bound to each other, with Objective-C
and Swift metadata pre-optimized and launch loaders pre-built. Finch's VM image started
without one. Every process mapped about 170 dylibs individually, and `/usr/bin/true`
took **5–7 seconds** to start in the emulator.

Finch builds its own cache from the image's dylibs (Apple's and Finch's), using Apple's
open-source builder.

## The builder (`tools/dsc/build-builder.sh`)

`dyld_shared_cache_builder` is in dyld-1376.6, but its Xcode target can't be built from
the published source:

- It depends on `SharedCacheLinker.framework`, built from `ld/` sources (Apple's new
  linker) that aren't published. The builder calls it only to synthesize optional dylibs
  (stub dylibs for elided libraries and `libswiftPrespecialized.dylib`), and treats a
  failure there as "not built". `tools/dsc/finch_missing.cpp` provides that one entry
  point, which reports "not available".
- A few pieces are redacted and are patched in `tools/dsc/patches/`:
  - `LinkerOptimizationHints::valid` has no body; it now accepts the hints.
  - The `allowedMissingWeakDylibs` allow-list is undefined; it's empty here, and missing
    weak dependencies are skipped anyway.
  - The Bom-based `-baseline_copy_roots` option is compiled out, since Bom's headers
    aren't published and Finch doesn't use the option.
  - The base-class `PointerFormat::writeChainEntry` has no definition; it's defined to
    return an error, because every real pointer format overrides it.
- Some headers and macros that Apple's internal build provides are supplied:
  - `tools/dsc/include`:
    - corecrypto's digest API on CommonCrypto (code-directory hashes);
    - `sandbox/private.h` → Finch's `<sandbox.h>`, whose path filter value was verified;
    - an empty `vproc_priv.h` (included but unused).
  - `tools/dsc/prelude.h`: `SUPPORT_ARCH_arm64e` and `SUPPORT_ARCH_arm64_32` (without
    them the builder can't name arm64e), `PLATFORM_IOSMAC`, and
    `DYLD_EXCLAVEKIT_UNAVAILABLE`.
  - The generated `dyld_cache_config.h` and `PrebuiltLoader_version.h`, made by Apple's
    own scripts.

The script compiles the sources directly (the list is in `tools/dsc/sources.txt`, taken
from Xcode's build plan) into `build/tools/dyld_shared_cache_builder`.

## Building the cache (`tools/vm/mkramdisk.sh`, step 4)

1. `tools/dsc/mkmanifest.py` walks the finished image. It lists every arm64e dylib and
   executable, plus every symlink that resolves to one of the dylibs (framework
   `Versions/Current` aliases), as the builder's JSON manifest.
2. The builder writes `/System/Library/dyld/dyld_shared_cache_arm64e` and its subcaches
   into the image. dyld looks there when libignition finds no OS cryptex.
3. Each cache file is code-signed. Its cdhash (`-print_cdhashes`) goes into the image's
   trust cache, like every Finch binary's.

`FINCH_DSC=0` skips the cache.

The builder links every dylib before writing anything, so it doubles as a **whole-image
link check**. Its first run found 31 libxpc symbols that Finch didn't export, imported by
RemoteXPC, ServiceManagement and others. They aren't in the every-process closure, so
nothing had noticed.

## Cached dylibs are removed from disk (as on macOS)

A cache with the dylibs also on disk was slower than no cache at all. dyld in PID 1
scans for "roots", meaning on-disk dylibs that override the cache, and records the
result in the commpage. Finding every system dylib on disk, every process then:

1. checked disk for each dependency and loaded it from there (164 images mapped);
2. patched the cache to point at the disk copies, making the cache's `__DATA_CONST`
   writable, which unnested part of the shared region in every process.

macOS has kept system dylibs only in the cache since macOS 11, so the image now does the
same. After building the cache, `mkramdisk.sh` deletes the on-disk copy of every dylib
the cache contains (294 of them, listed in the cache's map file). Variants and DriverKit
libraries, which aren't cached, stay.

## Results (emulated M4, `finch-trace` and `finch-launch-bench`)

| | `/usr/bin/true` | spawn → `main()` | page faults | images mapped from disk |
|---|---|---|---|---|
| No cache | ~3,000 ms | 2,400 ms | ~10,000 | 170 |
| Cache, dylibs also on disk | ~6,300 ms | 3,000 ms | ~10,900 | 164 |
| **Cache, dylibs removed** | **61 ms** | **47 ms** | **499** | **0** |

`userland/devtools/finch-trace` (installed in the VM) found this. It records kdebug
events while running a command and summarizes dyld's own launch phases (dyld emits
`DBG_DYLD` timing events), page faults and system calls for that process. Apple's
ktrace, fs_usage and spindump are closed. Usage: `finch-trace /usr/bin/true`.

## Kernel: trust-cached caches count as SIP-protected

XNU only maps a shared cache file that is SIP-protected (`SF_RESTRICTED`), unless SIP's
`CSR_ALLOW_UNRESTRICTED_FS` is set. Apple's caches get the flag from the sealed system
volume or cryptex. A build host can't set it with SIP enabled, and disabling SIP in Finch
to load a cache would weaken every other protection.

`kernel/patches/0004` instead treats a cache file whose cdhash is in a static or
engineering trust cache as protected. XNU already checks that trust cache, to skip its
root-ownership check. Pages are validated against that signature as they're mapped,
which pins the contents more strongly than a file flag does.
