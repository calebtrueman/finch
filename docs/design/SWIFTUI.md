# SwiftUI

Apple's SwiftUI is closed source, and most of Apple's newer apps need it: 35 of the system
apps link it, and Calculator alone imports 955 of its symbols. Finch's SwiftUI is to be open
code built to Apple's ABI, as Finch's Combine is (`docs/design/COMBINE.md`).

## The base: OpenSwiftUI

[OpenSwiftUI](https://github.com/OpenSwiftUIProject/OpenSwiftUI) (MIT) is an open
reimplementation of SwiftUI that follows Apple's API and internal structure closely. It is
about 209,000 lines, in early development, and actively maintained. The same project
publishes open replacements for the private frameworks SwiftUI runs on:

| Apple's | Open | Licence | Notes |
|---|---|---|---|
| AttributeGraph | OpenAttributeGraph | MIT | the dependency graph SwiftUI's views live in; work in progress (about 7,500 lines) |
| RenderBox | OpenRenderBox | MIT | Apple's renderer; OpenSwiftUI can render without it |
| Observation | OpenObservation | MIT | Swift's Observation is open source anyway (Swift's repository) |
| CoreGraphics types | OpenCoreGraphics | MIT | not needed: Finch has CoreGraphics |

OpenSwiftUI renders the display list into Core Animation layers and NSViews. Finch has both:
QuartzCore draws layers through CoreGraphics, and AppKit is Finch's own.

## Findings (2026-10-09)

- OpenSwiftUI builds on this Mac with every Apple private framework switched off:
  - OpenAttributeGraph in place of AttributeGraph;
  - no RenderBox, CoreUI, CoreSVG, SFSymbols, FeatureFlags or BacklightServices;
  - no private imports;
  - library evolution on.
- With its module names mapped to Apple's (OpenSwiftUI to SwiftUI, OpenSwiftUICore to
  SwiftUICore), it already defines about half the SwiftUI symbols apps import, with no ABI
  work yet:

  | App | SwiftUI imports defined |
  |---|---|
  | Calculator | 463 of 955 |
  | Font Book | 590 of 1,204 |
  | Tips | 391 of 772 |
  | Print Center | 231 of 438 |
  | System Information | 74 of 130 |

## Plan

1. Build `SwiftUICore.framework` and `SwiftUI.framework` from OpenSwiftUI, with modules
   renamed as Combine's is. The open AttributeGraph and the rest are linked privately.
   Finch's Combine, Foundation and AppKit are used underneath.
2. Run a minimal SwiftUI app built against Apple's SDK (a window with text and a button) on
   the host and in the VM. Fix the hosting, drawing and event path until it draws and
   responds.
3. ABI: freeze what Apple freezes, and export what Apple's inlinable code calls, measured
   against Apple's swiftinterface and the system apps' imports (`check-imports.py`,
   `check-swift-parity.sh`).
4. Fill the gaps app by app, starting with the smallest: System Information, Print Center,
   Calculator. Missing pieces go upstream where OpenSwiftUI would want them, as issues
   filed under the user's name.

## Status

- 2026-10-09: `userland/SwiftUI/build.sh` builds the open SwiftUICore and SwiftUI modules for
  arm64e (OpenSwiftUI at `aefa4e6`, adapted by `adapt.py`). Building them showed what Finch's
  own frameworks lacked, and those now have it:
  - CoreFoundation: `CFStringTokenizer`, public API that swift-corelibs leaves out (over ICU;
    `finch-cftokenizer-test` matches Apple's apart from Chinese and Japanese words).
  - CoreText: text styles, size categories, font designs, weights and widths, and the system
    UI font functions.
  - CoreGraphics: the path counting and enumeration functions, and image headroom.
  - QuartzCore: `CAFilter` and its filter names, `CABackdropLayer`, `CADisplayLink`, the
    presentation modifiers.
  - UIFoundation: the text context provider, `NSAdaptiveImageGlyph`, `NSTextEncapsulation`.

  Then the Swift overlays and the rest of what the link needed:
  - CoreGraphics' Swift overlay, compiled into CoreGraphics as Apple's is, and CoreText's
    (`AttributedString.AdaptiveImageGlyph`, line heights, the CoreText attribute scope);
  - Foundation: `Date.ComponentsFormatStyle`, the Combine integration, and the URL loading
    system that Apple keeps in CFNetwork (`docs/design/FOUNDATION.md`);
  - AppKit: `NSAccessibilityElement`, custom actions and rotors, `NSHapticFeedbackManager`,
    and the private accessibility entry points and accent-colour functions;
  - QuartzCore: `CAChameleonLayer`.

  `SwiftUI.framework` and `SwiftUICore.framework` now link against Finch's frameworks alone.
  Next is step 2 of the plan: a minimal app on the host, then in the VM.

- 2026-10-09: the first app. `userland/tests/apps/SwiftUIHello` (a window, text, a counting
  button, built against Apple's SDK) now finds every symbol it imports in Finch's SwiftUI.
  Getting there needed:
  - ABI fixes in `adapt.py` and `userland/SwiftUI/Finch/`: `SceneBuilder` is a struct, as
    Apple's is (the kind is in every mangled name); `WindowGroup`'s `init(id:title:lazyContent:)`,
    which Apple's inlinable initializers call; a working `Button` (upstream's is a placeholder).
  - The frameworks Apple's SwiftUI links, written as Finch's own to Apple's ABI:
    CoreVideo (the display link), Accessibility (charts, custom content, settings, braille,
    the attribute scope), CoreTransferable and DeveloperToolsSupport. Network.framework was
    only used by OpenAttributeGraph's debug client, which is left out.
  - Finch's Swift runtime now authenticates the signed method descriptor references that
    Xcode 26's compiler emits for class overrides across images (key DA, 0x675a), which
    swift-6.3.1's runtime doesn't know (`userland/swift/patches/0001`).

  The app now stops in the attribute graph: OpenAttributeGraph's core (creating attributes,
  reading and updating values) is still unimplemented upstream; on macOS OpenSwiftUI runs on
  Apple's AttributeGraph. Next: ByteDance's DanceUIGraph (Apache 2.0, about 37,000 lines, a
  complete attribute graph), which OpenAttributeGraph already has an adapter for.

- 2026-10-09: SwiftUIHello draws: its window, title text, the counter and the button, from
  the app as Xcode builds it, on the host's headless window server with Finch's frameworks.
  - The attribute graph is Compute (MIT, `OpenSwiftUIProject/Compute` 0.6.0), a
    reimplementation of AttributeGraph that OpenAttributeGraph adapts to. OpenAttributeGraph's
    own graph is still empty upstream, and ByteDance's DanceUIGraph (Apache 2.0) builds only
    with CocoaPods and a full Swift toolchain build. Finch patches Compute for arm64e: Swift
    closures' function pointers are signed with a type discriminator C++ can't name, so they
    are re-signed before calls; the contexts of non-escaping closures (on the stack) aren't
    retained; and Compute's copy of the runtime headers gets Finch's signed-pointer patch.
  - Compute's one demangler call (`makeSymbolicMangledNameStringRef`) is Finch's
    (`userland/SwiftUI/demangle.cpp`): the toolchain's libswiftDemangle isn't on a system.
  - AppKit: layer-backed and layer-hosting views (rendered with the view tree; layer changes
    redisplay the view), `clipsToBounds`, `alphaValue`, private `-setFlipped:` and
    `ignoreHitTest`, window sizing from the content view's constraints, layout before display
    even when nothing is dirty, and `NSWindowController` loading through `-loadWindow` when
    `-windowNibName` is overridden.
  - Foundation: `-[NSBundle localizedAttributedStringForKey:value:table:]`, attributed string
    formatting, empty dictionaries bridging to Swift, locale/time zone/calendar equality with
    Swift subclasses. UIFoundation: `NSStringDrawingContext`'s private options and results.

  - Clicks work: the button counts and the text updates. This needed AppKit's private
    geometry observers and event latching (`AppKitPrivate.m`), an update pass when a view
    needs layout, and the Swift runtime authenticating `swift_lookUpClassMethod`'s
    arguments as Apple's does (descriptors signed DA/0xae86, method descriptors DA/0x675a).
    Finch's runtime now builds without clang's struct-pointer signing at its interfaces,
    matching what compiled code passes.

  - In the Finch VM (QEMU) too: the app draws and the button counts. The VM showed what the
    host had hidden: Finch's dyld, from AvailabilityVersions-157.2, knew OS version sets only
    up to 2023, so a program built with the macOS 26 SDK read as linked before 2024 and
    SwiftUI took unimplemented legacy paths. `tools/extend-version-map.py` adds the 2024 and
    2025 sets to dyld's `VersionMap.h`. Foundation also gained
    `+preferredLocalizationsFromArray:forPreferences:` and the `localization:` string lookups.

  Next: window placement (it is centred while still empty), Text styles and fonts, then
  larger apps.
