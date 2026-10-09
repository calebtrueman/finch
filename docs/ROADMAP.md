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
        - [x] SystemConfiguration's local preference and network-state reads, schema keys,
              and synchronous route checks (2026-10-09). Writes, subscriptions and configd
              remain unfinished; see [Security and SystemConfiguration](design/SECURITY.md).
        - [ ] cron; DiskArbitration; configd; mDNSPosix
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
- [ ] CoreFoundation: the ObjC bridge works; remaining hosted classes are listed above
  - [x] `CFNotificationCenter`: the local center shares observers with Foundation's
        default `NSNotificationCenter`; posts through either reach both in observer order.
        The Darwin center uses notify(3). `finch-cfnotify-test` matches Apple's on the host
        and in the VM (2026-10-09). Distributed notifications still stay within the process.
  - [x] Bundle localization: `.loctable` files, the `AppleLanguages` preference and
        Apple's ICU language matching. Image Capture now picks English instead of Korean.
        `finch-l10n-test` matches Apple's on the host (2026-10-09).
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
  - [x] NSXPCConnection, NSXPCListener, NSXPCInterface and NSXPCCoder over Finch's
        libxpc; `finch-nsxpc-test` and its bundled XPC service match Apple's on the
        host and in the VM (2026-10-09). App-bundled `.xpc` services still need a job
        plist (finch-init doesn't look in apps' `Contents/XPCServices` yet).
  - [ ] The rest, by what apps use (`tools/check-framework-api.py` lists it):
        the URL loading system, a system-wide distributed notification center.
  - [x] Swift Foundation and AppKit overlays, the Darwin overlay libraries, and Swift's
        runtime built from pinned open source (2026-10-09). The combined host build
        matches Apple's 78-line overlay check and 12-line runtime check, including
        generic classes, protocol calls, tasks, regexes and backtraces. Export coverage
        is still partial; see [Foundation](design/FOUNDATION.md#the-swift-overlays).
- [x] CoreServices' local app lookup and launch, type and filesystem APIs, Apple event
      values and local dispatch, and Foundation's event/activity wrappers (2026-10-09).
      The host check matches Apple's 1,366 body lines. Interprocess Apple events,
      Handoff and DictionaryServices remain unfinished; see [CoreServices](design/CORESERVICES.md).
- [x] Security's supported RSA/EC keys, certificate reads and caller-supplied trust roots
      (2026-10-09). Keychain, authorization and code-signing services return errors until
      implemented. Tests check signing, tampering, encryption and refused trust/rights;
      see [Security](design/SECURITY.md).
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
        fonts (`userland/fonts`: Inter, Open Runde, Fragment Mono,
        XCharter, Pagella, Inter, Liberation, DejaVu Sans Mono, Noto; about 67 MB)
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
  - [x] UIFoundation: fonts, paragraph styles, shadows, string drawing, TextKit 1 and 2.
        `finch-uifoundation-test` matches Apple's on the host and in the VM (2026-10-08).
        TextKit 2 (`NSTextLayoutManager`,
        `NSTextContentStorage`, layout and line fragments, the viewport, selection navigation) over
        the same layout, and `NSTextView` on TextKit 2 by default with Apple's switch to TextKit 1:
        `finch-textkit2-test` matches Apple's on the host and in the VM (2026-10-09); document formats to come.
  - [x] Drawing: colours, colour spaces, Bézier paths, gradients, images, graphics contexts.
        `finch-appkit-draw-test` matches Apple's on the host and in the VM (2026-10-08);
        dark-appearance colours to come. Asset catalogs now use Finch's CoreUI reader:
        486 host comparison lines match Apple, plus catalog metadata checked in five
        shipped apps (2026-10-09; [assets](design/ASSETS.md)).
  - [x] Applications, windows, views, events and the responder chain, on the window server:
        `finch-appkit-core-test` matches Apple's on the host and in the VM; `finch-appkit-window-test`
        drives a window through the server (drawing, clicks, keys, dragging, closing) (2026-10-08)
  - [x] Title bars and toolbars over full-size content windows, including toolbars loaded
        from nibs. Image Capture now shows both. Copying a custom image rep keeps its drawing
        handler; `NSFontEffectsBox` loads as a plain box for nibs such as Stickies' (2026-10-09).
  - [ ] Controls and cells, menus, nib loading. Nibs load (ibtool's NIBArchive format and keyed
        archives; custom objects and views, outlets, actions, windows): `finch-nib-test` matches
        Apple's (2026-10-08); controls and cells (buttons, text fields, sliders, steppers, progress
        and level indicators, segmented controls, colour wells, image views, boxes) load from nibs
        and work: `finch-appkit-controls-test` matches Apple's on the host and in the VM,
        `finch-appkit-controls-window-test` drives them through the server (2026-10-08); menus
        (`NSMenu`, `NSMenuItem`, validation, key equivalents, nib main menus), a Finch-drawn menu bar,
        context and pop-up menus, `NSPopUpButton`: `finch-appkit-menu-test` matches Apple's on the
        host and in the VM, `finch-appkit-menu-window-test` drives them through the server (2026-10-08)
  - [x] Text editing and scrolling: `NSTextView` and the field editor (TextKit 2, or 1 on request), `NSScrollView`,
        `NSClipView`, `NSScroller`, an in-process `NSPasteboard`. `finch-appkit-text-test` matches
        Apple's on the host and in the VM; `finch-appkit-text-window-test` types, clicks and scrolls
        through the server (2026-10-08); rich-text pasteboard types, find and spelling to come
  - [x] Panels, alerts and the workspace: `NSAlert` (modal and as window-modal sheets), Finch's own
        `NSSavePanel`/`NSOpenPanel` browser, `NSWorkspace` and `NSRunningApplication` without
        LaunchServices (apps found by their Info.plist, launched by spawning their executable).
        `finch-appkit-panels-test` matches Apple's on the host and in the VM;
        `finch-appkit-panels-window-test` answers alerts, browses, chooses, saves and launches an
        app through the server (2026-10-09); Apple events, column views and sheet animation to come
  - [ ] Bindings and controllers: Cocoa bindings (`NSKeyValueBinding`: bind/unbind/info, markers
        and placeholders, transformers, `NSEditor` commits) for text fields, checkboxes, sliders,
        pop-up buttons, text views and views; `NSObjectController`, `NSArrayController`,
        `NSUserDefaultsController`; nib binding connectors; `NSFontManager` and a Finch-look
        `NSFontPanel`. `finch-appkit-bindings-test` matches Apple's on the host and in the VM (2026-10-09);
        `NSTreeController`, outline view bindings, Core Data controllers to come (table bindings: below)
  - [x] Auto Layout and storyboards: `NSLayoutConstraint`, the visual format language, anchors and
        guides in a private CoreAutoLayout that Foundation re-exports, solved by Finch's own Cassowary
        simplex; views' constraint API, autoresizing masks as constraints, intrinsic sizes, fitting
        sizes, windows sized by their constraints; `NSStackView`; constraint nibs; `NSStoryboard`,
        segues and `NSMainStoryboardFile`. `finch-appkit-layout-test` matches Apple's on the host
        and in the VM (2026-10-09); popovers, storyboard references and right-to-left layout to come
  - [x] Tables, outlines and collections: `NSTableView` (cell- and view-based, Apple's geometry in every
        style, selection, sorting, editing, column resizing and autoresizing, row views and cell views
        with nib prototypes), `NSTableColumn`, the header and corner views, `NSOutlineView`,
        `NSCollectionView` with flow and grid layouts (and the older content/prototype API), table
        bindings (content, selection indexes, sort descriptors, column values) and their nib keys;
        scroll views' automatic insets under full-size content windows' bars.
        `finch-appkit-tables-test` matches Apple's on the host and in the VM; `finch-appkit-tables-window-test` clicks,
        types, sorts, resizes, edits and expands through the server (2026-10-09); drag and drop, type
        select and `NSTreeController` to come
  - [x] Search, combo, token, date and path controls, switches, combo buttons, matrices
        and forms: 730 comparison lines match Apple, with drawing and typing/click checks
        (2026-10-09). Path drag sessions and some completion/dropdown details remain.
  - [x] Grids, page controllers, popovers, drawers, rule/predicate editors, the colour panel
        and browser: 77 comparison lines match Apple, with saved-interface, drawing and
        window-event checks (2026-10-09). See AppKit's status for each remaining limit.
  - [x] Animation grouping, Touch Bar state, basic mouse gestures, slider accessories,
        visual-effect views and context-help storage (2026-10-09). Animators still jump
        to final values, visual effects have no blur, and Touch Bar hardware and Help
        Viewer remain unfinished; 26 small-feature comparison lines match Apple.
- [ ] Unmodified Mac apps: first launch reached; TextEdit or Calculator usable next
  - [x] A Cocoa app bundle built the usual way (`userland/tests/apps/Hello`: NSApplicationMain,
        a MainMenu nib from ibtool, outlets and actions) launches on Finch's frameworks and window
        server, shows its menu bar and window, and responds to clicks and typing
        (`tools/run-app.sh`, 2026-10-09)
  - [x] Apple's unmodified Image Capture launches on Finch's frameworks (ImageCaptureCore,
        ICADevices, Quartz with ImageKit's device views; `docs/design/IMAGECAPTURE.md`).
        It shows English strings, its title bar and an empty toolbar and device list
        (host, Finch's headless window server, 2026-10-09). `finch-imagekit-test` matches
        Apple's on the host and in the VM.
  - [ ] Cameras and scanners: device modules and Phase 3 USB support.
  - [x] Apple's unmodified TextEdit launches in the Finch VM (copied from the Mac at image
        build time with `FINCH_HOST_APPS=TextEdit tools/vm/mkramdisk.sh`; nothing of Apple's
        is committed), opens an untitled document and takes typing (2026-10-09). It reads and saves RTF;
        NSFileCoordinator (presenters in-process) and NSTextFinder's find bar match Apple's
        behaviour (`finch-filecoordinator-test`, `finch-textfinder-test`), and Show Ruler
        brings up NSRulerView with its markers and format bar (`finch-ruler-test`). Tables
        read from and write to RTF as Apple's do, and draw with their backgrounds and borders
        and cells' vertical alignment (2026-10-09). Next: NSFileVersion, sharing.
  - [x] App test tools: `finch-app-test` accepts `screenshot:PATH` to save a screen PNG and `screenshot64` to print one over the VM console; `tools/host-tests.sh` runs the host comparison suite;
        `tools/check-imports.py` finds libraries such as libxpc through the VM overlay list,
        including builds outside `build/root` (2026-10-09).

**Exit:** an unmodified Mac app draws a window on Finch's own frameworks and
window server.

**App milestone reached on the host, 2026-10-09:** Image Capture draws through Finch's
frameworks and headless window server. The Tier 2 display and input work above remains.

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
- [ ] QuartzCore (Core Animation): on-screen animation playback and a render server
  - [x] Layers and their drawing through CoreGraphics, animation objects and transactions.
        `finch-calayer-test` matches Apple's on the host and in the VM (2026-10-09).
        Animations keep their values but do not yet play; without a render server, added
        animations end on the next run-loop turn, as on Apple's off-screen layers.
- [ ] PDFKit (Apple's Quartz re-exports it; Finch's Quartz re-exports only QuartzCore and ImageKit
      so far), Quick Look UI, the rest of ImageKit (image browser and view, picture taker, slideshow)
- [ ] Metal → Mesa
- [x] Combine: OpenCombine (MIT) adapted to Apple's ABI, with Finch's Merge, CombineLatest
      and collecting by time; every Combine symbol the system apps import (2026-10-09)
- [ ] SwiftUI
- [ ] AVFoundation / CoreAudio / CoreMedia

**Exit:** a defined app corpus (e.g., top 50 non-App-Store Mac apps) runs with no Apple
binaries.

## Phase 5: Finch 1.0
Installer (the standalone install from Phase 3, run from recoveryOS), updates, Finch desktop polish, security model (code signing, sandbox, SIP-like
protections under Finch's own keys).
- [ ] Fieldwork, Finch's design language (`docs/design/FIELDWORK.md`). Its parts:
  - [x] Theme tokens: Day and Night system colours, palette and metrics, in a theme file.
        A theme switch: Fieldwork by default, Classic (Aqua-compatible) for the comparison
        tests and per app (2026-10-09).
  - [x] The window frame: the window server shapes windows (6 pt top corners, 2 pt
        bottom), with an outline and a shallow shadow on a chalk desktop. The title bar is
        slate, with a top highlight, the key window's green mark, and the left control
        cluster (2026-10-09).
  - [ ] Controls: buttons, pop-ups, segmented controls, check boxes, sliders, fields,
        scrollers, tabs, menus.
    - [x] The shared control colours and bezels, and menus (2026-10-09).
    - [x] Scrollers: a slim graphite bar with nearly square ends (2026-10-09).
    - [ ] Tabs, fields' focus rings, table headers.
  - [x] Night: `AppleInterfaceStyle` Dark makes apps' appearance DarkAqua, as on macOS,
        and Fieldwork draws it in Night's values. Views draw in their effective appearance,
        uncoloured text in text views is textColor, and the window server's desktop and
        outlines follow `FINCH_APPEARANCE` (2026-10-09). The session setting it for both
        comes with Settings.
  - [ ] The Instrument Bar: app menus on the left, system context on the right.
    - [x] Drawn by each app's menu bar: FINCH, the menus, the workbench and the clock (2026-10-09).
    - [ ] A system process owning it (network, battery, the launcher behind FINCH).
  - [ ] The Rail, in place of the Dock.
    - [x] `Rail.app` (`userland/shell/Rail`): the finch mark, pinned and running apps with
          per-window marks, the workbench switcher. Apps' visible frame leaves it out, and
          `FINCH_SHELL` starts it with the session in the VM (2026-10-09).
    - [ ] Hover names, drag to pin, retracting for full-screen apps.
  - [ ] Workbenches: named, persistent, defined in text files.
  - [ ] Window behaviour: alignment guides, layout zones, fill the workbench.
  - [ ] Illustrated icons, and the mascot in onboarding, empty states and About.

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

## Phase 7: Linux binaries
Run arm64 Linux programs directly on XNU, as FreeBSD's Linuxulator and the original WSL 1
do: a syscall translation layer, not a VM.
- An ELF loader beside the Mach-O one, and a Linux syscall table mapped onto XNU's
  calls.
- Emulate the Linux-only interfaces:
  - futex, epoll, clone and its flags, inotify, eventfd and signalfd;
  - `/proc` and `/sys`;
  - later, namespaces and cgroups for containers.
- **Licensing:** FreeBSD's Linuxulator is BSD-licensed and shares XNU's BSD heritage, so
  it's a legitimate reference. Linux kernel code is GPL-only and can't be copied in: the
  same rule that keeps Darling out (`docs/LICENSING.md`).
- **Apple Silicon:**
  - 16K pages: most arm64 Linux software copes, as Asahi shows, but some binaries
    assume 4K pages.
  - Only arm64 Linux binaries run natively. x86 Linux binaries need a translator, FEX
    or box64, the same family as Phase 6's.

**Exit:** a defined set of arm64 Linux command-line programs and services runs unmodified
on Finch.

## Beyond: Finch for iPhone/iPad
Depends on a bootrom/iBoot path to unsigned code on target devices, which is not
available on current iPhones without exploits. This is a research track, not a schedule.
