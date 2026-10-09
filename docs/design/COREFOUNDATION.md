# CoreFoundation, and the daemons that need it

Finch runs nothing closed above the kernel. The next Apple open-source daemons
(cron, configd, diskarbitrationd, mDNSResponder) link closed frameworks, so
those frameworks come first. CoreFoundation is the root: IOKit.framework
(IOKitUser), SystemConfiguration, DiskArbitration and every daemon above sit
on it.

## What's needed

Measured from Apple's own 26.4 builds of the same components (`dyld_info
-imports` on the host's cron, crontab, configd, scutil, SystemConfiguration,
IOKit, diskarbitrationd and DiskArbitration):

| Closed dependency | Needed by | Plan |
|---|---|---|
| CoreFoundation (203 of its 3,076 exports) | everything | Finch's CoreFoundation, below |
| libicucore | CoreFoundation (strings, locales, formatters) | Build Apple's ICU-76142.4.7 |
| IOKit.framework | cron, configd, diskarbitrationd, SystemConfiguration | Build Apple's IOKitUser-100231.100.18.0.1 |
| SystemConfiguration.framework | configd, scutil, diskarbitrationd | Build from configd (it's in the project) |
| BackgroundTaskManagement, CoreAnalytics, FeatureFlags | cron, diskarbitrationd | Finch's own, small: answer "enabled" / drop events |
| FSKit, LiveFS, MediaKit (headers) | diskarbitrationd | Finch headers; FSKit paths answer "no FSKit modules" until Finch has one |
| Network.framework, NetworkExtension, CoreWiFi, Security, … | configd's plugins | One at a time, as configd needs them |
| mDNSResponder's macOS daemon | DNS-SD | Not published for 26.4 (no `mDNSMacOSX`). Build the portable `mDNSPosix` daemon, which speaks the same client protocol |

## Finch's CoreFoundation

**Base: swift-corelibs-foundation's CoreFoundation** (Apache 2.0, pinned to
`swift-6.4.0-RELEASE`). It's Apple's CF source as of the 2019-and-later
releases. It has the modern static runtime type IDs (`_kCFRuntimeIDCFArray`),
and it keeps the `CF_IS_OBJC` toll-free-bridging dispatch alongside its Swift
hooks. Both candidate bases define 194 to 196 of the 203 needed symbols.

**Darwin-only run-loop sources** (CFMachPort, CFMachPort_Lifetime, CFMessagePort)
come from swift-corelibs' own last release that had them (swift-5.10.1, same
license), pinned by checksum. CF-Lite's versions predate the modern runtime.

**Written by Finch:** what neither has. That includes `CFAllocatorAllocateTyped`
and the other typed-allocation entry points, plus the Objective-C classes that
Apple's CoreFoundation hosts since macOS 10.15: `NSArray`, `NSMutableArray`,
`NSDictionary`, `NSMutableDictionary`, `NSData`, and clang's `NSConstantArray`
and friends (for `@[]` literals). configd imports these from CoreFoundation.

**ABI:** the same rule as libxpc. Exports are checked against Apple's
CoreFoundation (`tools/check-exports.sh`), starting with the symbols Finch's
binaries import and growing toward the full 3,076. CF type layouts that the
SDK headers expose, such as `CFRuntimeBase` and the constant-string layout
`__CFConstantStringClassReference` that `CFSTR()` emits, match Apple's.

## Order

1. libicucore (ICU)
2. CoreFoundation: C API first (cron, IOKit, DiskArbitration), then the ObjC classes (configd)
3. IOKit.framework (IOKitUser)
4. cron, with Finch's BackgroundTaskManagement and CoreAnalytics
5. DiskArbitration and diskarbitrationd
6. SystemConfiguration and configd
7. mDNSPosix as mDNSResponder

## Building it

`userland/CoreFoundation/build.sh` fetches the pinned sources, applies
`patches/`, compiles them for the Objective-C runtime with Finch's prefix
header (`finch_prefix.h`) and its own files (`CFObjC.m`, `CFPlatform_Finch.c`),
and links `CoreFoundation.framework` as Apple ships it:
- same install name, current version 4424.1.255, compatibility version 150;
- re-exports libobjc and links Finch's libicucore;
- `__CFInitialize` as the library's initializer;
- swift-corelibs' `DarwinSymbolAliases` (`kCFLocaleCountryCode` and the rest),
  and `___CFConstantStringClassReference` as an alias of `__NSCFConstantString`.

Configuration notes:
- `DEPLOYMENT_RUNTIME_SWIFT=0` and `INCLUDE_OBJC`, as for Apple's build;
  `CFSTR()` uses Apple's (ObjC) constant-string layout, not Swift's.
- ICU is Finch's libicucore, with swift-corelibs' `<_foundation_unicode/…>`
  includes mapped to ICU's headers (`U_DISABLE_RENAMING`, as Apple's exports
  are unversioned). `__HAS_APPLE_ICU__=1` enables Apple's additions, including
  the language matching used by bundles.

## CF objects are Objective-C objects

Every CF object's isa (`CFRuntimeBase._cfisa`, signed with objc's isa schema on
arm64e) is the ObjC class registered for its type. `CFObjC.m` defines Apple's
classes: `__NSCFType` (the default), `__NSCFString`, `__NSCFConstantString`,
`__NSCFNumber`, `__NSCFBoolean`, and `NSNull`. They forward retain, release,
hash, equality and description to CF, and `__CFInitialize` fills the class
table with them, signed, before it makes any object. Static objects (the
allocators, `kCFBooleanTrue`, `kCFNull`, the CFNumber constants) start with
their class.

Finch now has Foundation and uses the same base classes as Apple:
`__NSCFString` subclasses `NSMutableString`; `__NSCFNumber` and
`__NSCFBoolean` subclass `NSNumber`. CF links Foundation upward, using a stub
at build time to allow Foundation to link back to CF.

The ObjC-to-CF direction also works. Finch compiles CF as Objective-C and
supplies the `CF_IS_OBJC` and `CF_OBJC_FUNCDISPATCHV` definitions that
swift-corelibs leaves empty outside Apple (`CFObjCDispatch_Finch.h`, patch
0003). Passing an app's `NSArray` subclass to `CFArrayGetCount`, for example,
calls its `-count` method. CF also hosts the collection classes and their
`__NSCF*` implementations. See `docs/design/FOUNDATION.md` for the class split
and the recorded host and VM comparisons.

## Notifications

`CFNotificationCenter_Finch.m` supplies the three centers that swift-corelibs
declares but does not implement:

- The local center shares observers with Foundation's default
  `NSNotificationCenter`. Posting through either reaches both sets of
  observers in the order they were added. Without Foundation, CF keeps its
  own observer list.
- The Darwin center uses `notify(3)` and delivers on the main queue. It carries
  names only; it drops the posted object and user info, as Apple's does.
- The distributed center delivers the object and user info on the main queue
  within the same process. Notifications between processes still need a
  `distnoted` service.

## Bundle languages and strings

CFBundle reads the user's `AppleLanguages` preference (patch 0006) and uses
Apple's ICU `ualoc_localizationsToUse` to choose among a bundle's languages.
This also serves Foundation's `NSBundle`. Before that ICU path was enabled,
the match could be empty and the first available language won, which made
Image Capture open in Korean despite the user's English preference.

When no `.strings` or `.stringsdict` table is found, CFBundle also reads
`<table>.loctable` (patch 0005). This property list holds a table for each
language. CF chooses the requested language, or the user's preferred one,
and skips the `LocProvenance` metadata when listing its choices.

## The Swift runtime

Finch's libobjc links libswiftCore (upward, delay-loaded), as Apple's does, so
the image needs one. `userland/swift/build.sh` builds it from Swift's open
source (`swift-6.3.1-RELEASE`, matching Xcode's compiler) with the standalone
`Runtimes/Core` build, using a pinned CMake 3.31 from a private venv (the
nested `.swiftmodule` layout breaks under CMake 4.1's CMP0195). The result has
14,885 of Apple's 15,043 exports. The rest are mostly exported generic
pre-specializations, plus `_swift_stdlib_CFStringCreateTaggedPointerString`.

## The image

The base image's closed binaries that link replaced libraries (Foundation,
CFNetwork, Security, the Swift overlays, …) need CF symbols Finch's
CoreFoundation doesn't have. `tools/vm/mkramdisk.sh` removes each image that
the shared-cache builder can't resolve: 98 are removed now, and the cache
shrank from 264 MB to 108 MB. A Finch-built image that can't resolve fails
the build, unless it still links a closed library itself (it's reported).

`tools/check-closed.py` lists the closed libraries that Finch-built binaries
still link. That's the work list for "nothing closed". On 2026-10-08 it found 14:
- zlib, bzip2, liblzma, libedit, libxo, libsbuf, libresolv (all published by
  Apple, so build them);
- IOKit, SystemConfiguration (on this plan);
- Foundation (gcore's GCoreFramework);
- libcompression, OpenDirectory, EndpointSecuritySystem (closed; Finch writes them);
- libobjc-env.

## Status

- 2026-10-08: libicucore built from ICU (8,979/8,979 exports). CoreFoundation
  builds (1,759 of Apple's 3,076 exports). `finch-cf-test` gives output
  identical to Apple's CoreFoundation, both on the host (pointer
  authentication enforced) and in the VM. It covers strings, collections,
  property lists (byte-identical XML and binary), ICU formatting, locales,
  calendars, URLs, run-loop timers and Mach ports, blocks, and the ObjC classes
  of CF objects. libswiftCore is built from source, and `finch-swift-hello`
  (arrays, dictionaries, strings, closures, generics) runs on it in the VM
  with output identical to the host's.
- 2026-10-08: CF gains CFFileDescriptor (Finch's: one-shot callbacks through a
  run-loop source; identical to Apple's in `finch-cf-test`), the CF/XPC bridge
  (`_CFXPCCreate…`), and App Nap's `__CFRunLoopSetOptionsReason` (accepted and
  ignored; Finch doesn't nap processes). IOKit.framework is built from
  IOKitUser (`userland/IOKit/build.sh`). The build assembles headers from the
  SDK, IOKitUser, xnu and configd, generates the MIG interfaces, and applies two
  fixes to the published source (`userland/IOKit/patches`). nvram, iostat and
  shutdown run on it in the VM.
- 2026-10-08: the seven open libraries Finch's commands linked prebuilt are
  built: zlib, bzip2, libedit, libresolv from Apple's sources (the published
  zlib and libedit need small fixes; build-oss now runs projects' script
  phases unsandboxed, as Apple's builds do), and liblzma, libxo, libsbuf from
  upstream. `tools/check-closed.py` is down to 5: Foundation, OpenDirectory,
  EndpointSecuritySystem, libcompression, libobjc-env.
- 2026-10-08: OpenDirectory (CFOpenDirectory's C API over the local node) and
  libEndpointSecuritySystem are Finch's. So is libcompression
  (`userland/libcompression`): Apple's public API over LZFSE, LZ4, Brotli,
  zlib and liblzma, in the same formats. `finch-compression-test`, run on the
  host against Apple's library, checks that each decodes what the other
  encodes, as buffers and as streams fed in uneven pieces. It also matches
  Apple's truncation behaviour (a short decode returns what fits, except
  for LZMA and Brotli, which return 0). Not done: LZBITMAP (Apple's
  undocumented format) and the private `compression_stream_*` calls.
  `tools/check-closed.py` is down to 1: Foundation.
- 2026-10-08: Foundation is Finch's (`docs/design/FOUNDATION.md`), so
  `tools/check-closed.py` finds no closed library in anything Finch builds.
- 2026-10-09: `CFNotificationCenter`'s local, Darwin and in-process distributed
  centers are implemented. `finch-cfnotify-test` matched Apple's output on
  the host and in the VM, including shared local observers with
  `NSNotificationCenter` (`824a13a`).
- 2026-10-09: bundle language matching, `AppleLanguages`, and `.loctable`
  tables are supported. `finch-l10n-test` matched Apple's output on the host;
  the CF and Foundation comparison tests still matched (`52f174f`).

## Run-time loads of closed frameworks

Linking isn't the only way to depend on a closed library: code can
`dlopen()` one by path. `tools/check-closed.py` also lists closed framework
paths named in Finch's binaries. Patched so far (2026-10-08): CF's lookups
of CarbonCore, CoreServicesInternal and CFNetwork (`CFUtilities.c`), IOKit's
SystemConfiguration (`userland/IOKit/patches/0003`), and libmalloc's
MallocStackLogging (`userland/patches/libmalloc/0002`). Each returns nothing,
so the caller takes the path it takes when the framework is missing, until
Finch provides its own (SystemConfiguration from configd, networking for
CFNetwork's stream functions).
