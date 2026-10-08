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

**Restored from CF-Lite (CF-1153.18, APSL 2.0):** the Darwin-only files that
swift-corelibs dropped, such as CFMachPort and CFMessagePort, where CF-Lite has
them. Files keep their own licenses.

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

## Status

Planned (2026-10-08).
