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
  are unversioned).

## CF objects are Objective-C objects

Every CF object's isa (`CFRuntimeBase._cfisa`, signed with objc's isa schema on
arm64e) is the ObjC class registered for its type. `CFObjC.m` defines Apple's
classes: `__NSCFType` (the default), `__NSCFString`, `__NSCFConstantString`,
`__NSCFNumber`, `__NSCFBoolean`, and `NSNull`. They forward retain, release,
hash, equality and description to CF, and `__CFInitialize` fills the class
table with them, signed, before it makes any object. Static objects (the
allocators, `kCFBooleanTrue`, `kCFNull`, the CFNumber constants) start with
their class.

These subclass NSObject. Apple's `__NSCFString` and `__NSCFBoolean`
subclass Foundation's `NSMutableString` and `NSNumber`, which Finch doesn't
have yet.

**Not yet:** the ObjC-to-CF direction. swift-corelibs compiles `CF_IS_OBJC` and
the 200-odd `CF_OBJC_FUNCDISPATCHV` sites to nothing outside Apple, so an NSArray
made in ObjC can't be passed to `CFArrayGetCount`. Then come the collection
classes (`NSArray`, `NSDictionary`, … and `__NSCFArray`, …), which Apple's CF
exports and configd imports.

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
