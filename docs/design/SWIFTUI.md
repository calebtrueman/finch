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

  The link still needs these Swift overlays, which are next:
  - CoreGraphics' (Apple compiles it into CoreGraphics.framework);
  - Foundation's `Date.ComponentsFormatStyle`;
  - CoreText's `AttributedString.AdaptiveImageGlyph`.

