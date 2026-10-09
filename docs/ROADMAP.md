# Roadmap

Strategy: **ship of Theseus.** Get a complete, booting system as early as possible, then
replace Apple's proprietary parts one by one, using the originals as the reference for
correct behavior. Every phase ends with something that boots. Since 2026-10-08, nothing
closed is borrowed above the kernel: each closed library or framework is built from
Apple's open source or written by Finch when something needs it. Apple's kexts (and, in
the Tier 2 VM, its kernel) stay borrowed until Phase 3 replaces them.

## Phase 0: Our kernel boots
Build XNU from source and boot it on real Apple Silicon with Apple's own kexts.
- [x] Reproducible XNU build for `xnu-12377.101.15` (matches dev machine) with KDK: `tools/build-kernel.sh`
- [x] Build a kernel collection: our XNU + BORROWED kexts (KDK 25E253; 308/310 link, see `boot/kc/excluded-kexts.txt`)
- [x] Boot stock Darwin in darwin-vm (emulated M4) — see docs/DEV_VM.md
- [x] Boot our XNU in darwin-vm (2026-10-06)
- [ ] Create the isolated Finch APFS container on the M4. Permissive Security for that
      OS only. Boot our kernel collection on bare metal. **Deferred (2026-10-07):** QEMU
      covers Phases 0–1 and Virtualization.framework covers Phase 2, so metal waits. When it
      comes, it uses a boot stub, not a full macOS donor install (see "Standalone install"
      in Phase 3).
- [x] A visible Finch fingerprint: `uname -v` reports `finch:finch-0.0.1/xnu-12377.101.15/…`

**Exit:** macOS userland runs on a kernel we compiled.

## Phase 1: Our userland boots
Replace the userland with Darwin built from Apple's open source, plus Finch code where
Apple's is closed. Developed in the emulated M4 first. The map is
`userland/INVENTORY.md`.
- [x] **1.1 Finch PID 1.** `finch-init` replaces the closed launchd: console, OS version
      sysctls, rc script, respawning shell, orphan reaping. The default PID 1 of Finch's VM image
      (2026-10-06).
- [ ] **1.2 Commands from source.** Build shell_cmds, file_cmds, text_cmds, system_cmds and
      bash/zsh ourselves, replacing darwin-vm's prebuilt sysroot.
  - [x] file_cmds, shell_cmds, text_cmds, adv_cmds, system_cmds: 188 binaries build and
        run under finch-init (`tools/build-oss.sh`, 2026-10-06)
  - [x] bash 3.2 (bash-144), zsh 5.9 + modules (zsh-118, via `userland/oss/zsh.build.sh`),
        bc/dc. zsh is the console shell.
  - [x] libiconv, libcharset and the i18n modules and tables (`/usr/lib/i18n`, `/usr/share/i18n`)
  - [ ] Deferred tools (see `userland/INVENTORY.md`)
  - [x] `reboot` / `halt` / `shutdown` from system_cmds, through finch-init's shutdown
        sequence (`reboot3`)
  - [x] Ramdisk grown to 600 MiB without sudo (raw APFS resize); writable tmpfs for /tmp
        and /var/{tmp,run,log,root}
  - [ ] Root-owned files in dev images (they arrive as uid 99; the root fs can't be
        remounted read-write). Build release images with root.
  - [x] Writable /var/db: System Policy (the sandbox's platform profile) refuses a mount
        there, so it's a link into a tmpfs at `/private/var/rw` (2026-10-08)
- [x] **1.3 Open libSystem from source.** Swap dylibs one at a time, starting with
      libsystem_kernel from our own xnu build.
  - [x] libsystem_kernel (xnu libsyscall + patch 0003), running in the VM (2026-10-06).
        Missing vs Apple's build: 7 legacy `__stat`-family stubs, `register_uexc_handler`,
        and 2 version symbols; nothing imports them.
  - [x] libsystem_platform (libplatform; recipe from its published xcconfigs, plus Finch
        `ffs`/`fls`, SME-safe string routines and one Swift tracing no-op). 185/185 exports.
  - [x] libsystem_pthread (libpthread + `userland/patches/libpthread`; Finch
        `<os/thread_self_restrict.h>` for the JIT write-protect toggle). 209/209 exports.
  - [x] libsystem_malloc (libmalloc; Finch `<os/feature_private.h>` ABI-compatible with
        Apple's libsystem_featureflags; header-only Finch SHA-256 replaces the libcorecrypto
        dependency). 118/118 exports.
  - [x] libdispatch (config reconstructed: Apple publishes libdispatch.xcconfig nearly
        empty). 410/411 exports (missing: an unused watchdog helper).
  - [x] `finch-libsystem-test` (userland/tests) passes in the VM: malloc, pthread, dispatch,
        string/bit ops. The JIT toggle is untestable in QEMU (no SPRR); verify on bare metal.
  - [x] libsystem_blocks (libclosure). 19/19 exports.
  - [x] libsystem_c (Libc). 1328/1328 exports. Finch `os/log_private.h` (ABI of the
        closed libsystem_trace), header-only `corecrypto/ccrng.h` over getentropy(2)
        (no libcorecrypto), generated dyld version constants, `_atexit_receipt`
        (App Store exit hook recorded, not run).
  - [x] libsystem_darwin, libsystem_info (on Finch libxpc)
  - [x] libsystem_notify and notifyd (Libnotify), with notifyd run on demand by finch-init
  - [x] dyld shared cache, built by Finch from the image (`docs/design/DYLD_CACHE.md`):
        process launch about 50× faster in the VM (3 s → 61 ms for `/usr/bin/true`)
  - [x] libsystem_m (CORE-MATH and FreeBSD msun), dyld, libcorecrypto and CommonCrypto,
        libsystem_trace, libutil, libbsm, libncurses (2026-10-07)
  - [x] Finch CrashReporterClient (`__crash_info` annotations), linked by Libc and notifyd
- [ ] **1.4 Finch replacements for closed libSystem pieces** (libxpc, libsystem_trace,
      sandbox, quarantine, …). Start with the subset our binaries actually import.
  - [x] **libxpc**: Apple-ABI-compatible XPC objects and
        connections, with the Mach bootstrap/service registry in finch-init. Mac apps and
        most of libSystem's upper half depend on it. Plan and progress:
        `docs/design/XPC.md`.
    - [x] X1 object model and value types (100/462 imported symbols)
    - [x] X2 wire format, byte-compatible with Apple's (checked against captured samples,
          fuzzed under ASan)
    - [x] X3 Mach transport: pipes and connections, interoperating with Apple's libxpc in
          both directions (144/462 imported symbols)
    - [x] X4 finch-init bootstrap server, X5 swap in (the VM runs on Finch libxpc)
  - [x] libsystem_info and libsystem_darwin built from source on Finch libxpc
  - [x] **Service manager** in finch-init: launchd job plists, MachServices with launch on
        demand, KeepAlive, run as another user (`docs/design/SERVICES.md`)
    - [x] `launchctl` (Finch's own: list, print, start/stop, kickstart, kill, load/unload)
    - [x] Sockets, StartInterval, StartCalendarInterval, WatchPaths, QueueDirectories,
          `launch_activate_socket` and `launch_msg` check-in (2026-10-07)
    - [x] LaunchAgents and per-user domains (`user/<uid>`, entered through Apple's
          pam_launchd by `login` and `su -l`, or `launchctl asuser`; 2026-10-08)
    - [ ] Run Apple's open-source daemons under it (notifyd, syslogd, configd, ...)
      - [x] notifyd; syslogd (checks in with `launch_msg`, which Finch's libxpc
            answers from finch-init's job; 2026-10-07)
      - [x] finch-logd and `log show`/`log stream`: os_log over libdispatch's open-source
            firehose server (`docs/design/LOGD.md`, 2026-10-08)
      - [x] aslmanager (on demand), newsyslog, dynamic_pager (2026-10-08)
      - [ ] cron, configd, mDNSResponder, diskarbitrationd. They link closed frameworks,
            which Finch builds or writes first (nothing closed is borrowed):
            `docs/design/COREFOUNDATION.md`
        - [x] libicucore (ICU-76142.4.7; all 8,979 exports)
        - [ ] CoreFoundation (swift-corelibs base; C API, then the ObjC collection classes)
          - [x] C API and CF objects as ObjC objects: `finch-cf-test` output identical to
                Apple's, on the host and in the VM (2026-10-08)
          - [ ] ObjC-to-CF dispatch and the collection classes. In progress: CF compiles
                as Objective-C with Apple's dispatch, and hosts NSException, the array,
                dictionary and set clusters, NSData and NSDate, identical to Apple's in
                `finch-bridge-test`; message forwarding and NSInvocation, identical to
                Apple's in `finch-forward-test` (`docs/design/FOUNDATION.md`). Since
                then: ordered sets, NSCache, streams, ports and the CFError and
                CFAttributedString bridges. Left of Apple's CF classes: NSFileSecurity,
                NSSharedKeySet, the constant data and date classes, tagged-pointer strings.
        - [x] libswiftCore from Swift's open source (libobjc links it; 14,885/15,043 exports)
        - [x] zlib, bzip2, libedit, libresolv, libxml2 (Apple's sources) and liblzma, libxo, libsbuf
              (upstream, where Apple doesn't publish its copy), each with Apple's exports
              exactly (2026-10-08)
        - [x] OpenDirectory (CFOpenDirectory's C API over the local node),
              libEndpointSecuritySystem, and libcompression (Apple's API over LZFSE, LZ4,
              Brotli, zlib and LZMA; cross-checked against Apple's): Finch's own (2026-10-08)
        - [x] su and login authenticate through Finch's PAM stacks (OpenPAM's pam_unix
              with Apple's pam_launchd; 2026-10-08)
        - [x] Foundation: Finch's own (Phase 2's first item, below). Since 2026-10-08,
              `tools/check-closed.py` finds no closed library in anything Finch builds.
        - [x] IOKit.framework from IOKitUser: IOKitLib, power management, power sources
              (`userland/IOKit`; nvram, iostat and shutdown run on it, 2026-10-08)
        - [ ] cron; DiskArbitration; SystemConfiguration and configd; mDNSPosix
  - [x] libmalloc no longer depends on libcorecrypto
  - [x] libsystem_featureflags, coreservices, darwindirectory, eligibility, symptoms,
        trial, secinit, sanitizers, libRosetta: Finch's own (`userland/libsystem`)
  - [x] The rest of the strict Phase 1 exit: `docs/design/PHASE1-EXIT.md`
        (2026-10-07; `tools/check-boot-path.py`: 94/94 boot-path images Finch-built)
- [x] **1.5 dyld from source.** dyld-1376.6 boots the VM (`tools/build-system.sh`)
- [ ] Finch root image on its own APFS volume (bare-metal Tier 3)

**Exit:** the VM boots to a shell with no closed-source Apple binaries above the kernel.
**Reached 2026-10-07** (`docs/design/PHASE1-EXIT.md`). The unchecked items above
continue alongside Phase 2.

## Phase 2: Open graphics stack and first app
Nothing closed is borrowed (2026-10-08). Unmodified Mac apps need Foundation,
CoreGraphics and AppKit, so Finch builds open ones before running any app
(work that Phase 4 had). Most of it is built and tested on the host (against
Apple's, for behaviour) and in Tier 1. The display is Tier 2's
(`docs/design/TIER2-VZ.md`): a Virtualization.framework guest that boots
normally on its own kernel, until Finch's kernel runs on bare metal. The guest
is set up and reachable with `tools/vz/ssh` (2026-10-08).
- [x] The open libraries Finch's binaries link: all of them, Foundation included
      (`tools/check-closed.py`, 2026-10-08). IOKit is done.
- [ ] CoreFoundation's ObjC bridge and the classes it hosts (in progress, above)
- [ ] Foundation, Finch's own in Objective-C over Finch's CF, class for class where
      Apple's is (`docs/design/FOUNDATION.md`). Behaviour is checked against Apple's
      on the host; swift-corelibs-foundation is the reference implementation.
  - [x] The framework, linked as Apple's, with CF linked to it upward; NSString,
        NSNumber/NSValue and literals, NSCharacterSet, NSError, NSAutoreleasePool,
        NSLog and the common functions. `finch-foundation-test` is identical to
        Apple's, and GCoreFramework (gcore) runs on it (2026-10-08).
  - [x] Collection descriptions; NSRunLoop/NSTimer, NSThread, locks, notifications,
        operation queues, NSProcessInfo, performSelector variants (2026-10-08)
  - [x] NSURL and NSURLComponents, NSFileManager, NSBundle, property lists (2026-10-08)
  - [x] NSLocale, NSTimeZone, NSCalendar, the date and number formatters,
        NSUserDefaults, the time-zone database (2026-10-08)
  - [x] KVC and KVO, NSIndexSet, geometry functions and NSValue boxes (2026-10-08)
  - [x] NSDecimalNumber, NSScanner, NSJSONSerialization, NSUUID, NSSortDescriptor (2026-10-08)
  - [x] NSCoder, NSKeyedArchiver/NSKeyedUnarchiver in Apple's format (2026-10-08)
  - [x] NSAttributedString, NSRegularExpression, NSOrderedSet, NSCache, pointer
        collections, NSCountedSet (2026-10-08)
  - [x] NSProxy, NSAssertionHandler, NSIndexPath, NSUndoManager, NSValueTransformer,
        NSNotificationQueue, NSAffineTransform, NSDateInterval (2026-10-08)
  - [x] Streams, ports, file handles, pipes, tasks, hosts (2026-10-08)
  - [x] NSPredicate and NSExpression (2026-10-08)
  - [x] NSProgress, NSFileWrapper, byte-count, ISO 8601 and date-components formatters,
        collection differences (2026-10-08)
  - [x] Units and measurements (NSUnit and its 22 dimensions, NSMeasurement,
        NSMeasurementFormatter over ICU) and NSXMLParser over Apple's libxml2
        (libxml2-39.10, built by Finch with Apple's exports) (2026-10-08)
  - [ ] The rest, by what apps use (`tools/check-framework-api.py` lists it):
        the URL loading system, NSXPCConnection, a system-wide distributed
        notification center.
- [ ] CoreGraphics, CoreText, ImageIO over open renderers (`docs/design/COREGRAPHICS.md`)
  - [x] Skia (chrome/m155) builds for arm64e with FreeType and the open codecs, and
        without Apple's graphics frameworks (`userland/skia`, 2026-10-08)
  - [ ] CoreGraphics' drawing half: geometry, paths, colour spaces, bitmap contexts,
        images, gradients, then shadings, patterns, layers and PDF writing. Geometry,
        affine transforms, paths, colour spaces, colours, data providers, images,
        bitmap contexts and drawing (fills, strokes, dashes, clips, masks, images,
        blend modes, shadows, transparency layers) are done: `finch-cg-test` is
        identical to Apple's, and `finch-cg-draw-test` matches Apple's renders, on
        the host and in the VM (2026-10-08). Gradients (linear, radial, conic),
        shadings, patterns and CGLayer, and CGFont and glyph drawing
        (font smoothing as Apple's) too (2026-10-08). PDF: CGPDFContext writes
        through Skia's PDF backend (page boxes, links, destinations, outlines,
        metadata, output intents, AES-128 encryption added in a final pass), and
        CGPDFDocument, CGPDFScanner and CGContextDrawPDFPage run on Finch's own
        parser and interpreter (fonts through FreeType); `finch-cgpdf-test` is
        identical to Apple's on the host, and each CG reads the other's PDFs as
        its own (2026-10-08). Next: tagged PDF, the VM run.
  - [ ] ImageIO over Skia's codecs. Image sources (PNG, JPEG, GIF, BMP, ICO,
        WebP; properties, images, thumbnails, incremental loading), PNG and JPEG
        destinations, and all 750 public property keys are done: `finch-imageio-test`
        is identical to Apple's on the host and in the VM (2026-10-08).
        Next: TIFF and HEIF, metadata (XMP), GIF writing.
  - [ ] CoreText over HarfBuzz and FreeType, with open fonts in place of Apple's.
        Fonts, lines, runs, typesetting and frames are done: `finch-ct-test` is
        identical to Apple's on the host and in the VM (2026-10-08). The open
        fonts (`userland/fonts`: Inter, Liberation, DejaVu Sans Mono, Noto; 59 MB)
        ship with Apple's font names aliased onto them, the UI fonts, the
        default font and a fallback cascade for other scripts and emoji
        (`finch-ctfonts-test`, Finch-only, 2026-10-08). Next: justification as
        Apple's, colour glyphs (emoji) when drawing, font stylistic classes.
  - [ ] The window-server half of CoreGraphics (windows, events, displays)
- [ ] Finch window server and compositor (software rendering), on the Tier 2 display
  - Display and input paths in Tier 2: [`docs/design/WINDOWSERVER-DISPLAY.md`](design/WINDOWSERVER-DISPLAY.md)
  - [x] `finch-windowserver` (`docs/design/WINDOWSERVER.md`): windows over shared
        memory, levels and ordering, alpha and shadows, a Skia compositor, the
        cursor, input routing (capture, click counts, key window), the window list,
        and a headless backend; CoreGraphics' `FWS*` client and its display and
        window-list API. `finch-ws-test` passes on the host and in the VM (2026-10-08).
  - [x] The host viewer (`tools/vz/finch-viewer`) for the TCP backend: frames into
        a host window at the display's scale, mouse, scroll and key input back,
        reconnecting; tested end to end on the host (2026-10-08).
  - [ ] CGEvent, and the server on the Tier 2 display
- [ ] AppKit ([`docs/design/APPKIT.md`](design/APPKIT.md))
  - [x] Framework skeletons as Apple splits them: AppKit re-exporting a private
        UIFoundation, ApplicationServices and Foundation; the Cocoa umbrella
  - [x] UIFoundation: fonts, paragraph styles, shadows, string drawing, the text system
        (TextKit 1; TextKit 2 and document formats to come). `finch-uifoundation-test`
        matches Apple's on the host and in the VM (2026-10-08).
  - [x] Drawing: colours, colour spaces, Bézier paths, gradients, images, graphics contexts.
        `finch-appkit-draw-test` matches Apple's on the host and in the VM (2026-10-08);
        dark-appearance colours and asset catalogs to come.
  - [x] Applications, windows, views, events and the responder chain, on the window server:
        `finch-appkit-core-test` matches Apple's on the host and in the VM; `finch-appkit-window-test`
        drives a window through the server (drawing, clicks, keys, dragging, closing) (2026-10-08)
  - [ ] Controls and cells, menus, nib loading. Nibs load (ibtool's NIBArchive format and keyed
        archives; custom objects and views, outlets, actions, windows): `finch-nib-test` matches
        Apple's (2026-10-08)
- [ ] TextEdit or Calculator launches and is usable

**Exit:** an unmodified Mac app draws a window on Finch's own frameworks and
window server.

## Phase 3: Open drivers
Replace BORROWED kexts with Finch kexts on the M4 (Mac16,1, T8132), the only machine
available. Asahi's M1–M3 work is the reference; M4 differences are found by tracing
macOS on the M4 itself (m1n1 hypervisor).
- [ ] AIC, DART
- [ ] ANS (NVMe storage)
- [ ] DCP (displays, brightness, external monitors)
- [ ] SMC, PMGR (power, sleep, battery)
- [ ] USB, keyboard/trackpad, audio
- [ ] Wi-Fi/Bluetooth
- [ ] AGX kernel driver + Mesa asahi userspace
- [ ] **POSIX conformance** (after the GUI stack, alongside the bare-metal userland;
      see [design/POSIX.md](design/POSIX.md)). A correctness and portability baseline
      that doesn't move the way macOS does. Not formal certification.
  - Run an open POSIX conformance suite (Open POSIX Test Suite, plus the shell and
    utility checks) on Finch's own code: finch-init, the launchd replacements, Libc
    patches, the commands.
  - Fix failures where Finch diverges from both POSIX and Apple. Where they disagree,
    keep Apple's default (`$UNIX2003` variants, `COMMAND_MODE`).
  - Unpatched Unix software builds on Finch: autotools projects, POSIX `sh` scripts,
    Homebrew-style build systems.
- [ ] **Standalone install: no macOS on the Mac.** The end goal for installing Finch.
  - The Finch container holds only a boot stub plus Finch. The stub is Apple's
    second-stage iBoot and device firmware, downloaded from Apple's restore image at
    install time and never redistributed.
  - The boot policy is created for the Finch container, and no macOS volume is needed.
  - The Mac keeps what it can't do without: system firmware and the system recoveryOS.
  - To prove on hardware: the installer runs from the system recoveryOS, so not even
    installing needs macOS.
  - Needs Finch drivers for the whole boot path (ANS, SEP, DCP, input, SMC/PMGR), because
    there are no Apple kexts to borrow.

**Exit:** Finch installs and boots on the M4 with zero Apple kexts and no macOS
installed.

## Phase 4: Open frameworks
The rest of the frameworks, ordered by app coverage (Foundation, CoreGraphics
and AppKit come in Phase 2).
- [ ] QuartzCore (CoreAnimation)
- [ ] Metal → Mesa
- [ ] SwiftUI
- [ ] AVFoundation / CoreAudio / CoreMedia

**Exit:** a defined app corpus (e.g., top 50 non-App-Store Mac apps) runs with no Apple
binaries.

## Phase 5: Finch 1.0
Installer (the standalone install from Phase 3, run from recoveryOS), updates, Finch desktop polish, security model (code signing, sandbox, SIP-like
protections under Finch's own keys).

## Phase 6: Windows software
Run Windows applications on Finch, as CrossOver and Game Porting Toolkit do on macOS.
- **Wine** (LGPL-2.1, dynamically linked component) for the Win32/Win64 API layer.
- **ARM64 Windows apps** first: they need no CPU translation.
- **x86-64 apps:** BORROW Rosetta 2 from the user's macOS install at first. The open
  replacement is an x86 translator ported to Darwin: FEX-Emu or Box64 (MIT), or Wine's
  ARM64EC path with FEX.
- **Graphics:** DXVK / vkd3d-proton (Direct3D → Vulkan) on Mesa's Vulkan driver for AGX,
  which Phase 3/4 bring up anyway.

**Exit:** a defined corpus of Windows apps (ARM64 and x86-64) runs on Finch with no
Apple binaries.

## Beyond: Finch for iPhone/iPad
Depends on a bootrom/iBoot path to unsigned code on target devices, which is not
available on current iPhones without exploits. This is a research track, not a schedule.
