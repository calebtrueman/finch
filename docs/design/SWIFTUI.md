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

- 2026-10-09: controls. `Toggle`, `TextField`, `Slider` and `ProgressView` draw and respond,
  each as Apple's does on macOS: an AppKit control (checkbox, text field, slider) in an
  `NSViewRepresentable`, bound to the SwiftUI state (`userland/SwiftUI/Finch/SwiftUI/`).
  - AppKit hosts representable views as Apple's SwiftUI expects:
    `_NSConstraintBasedLayoutHostingView` and `-measureMin:max:ideal:stretchingPriority:`
    (a view's sizes from its intrinsic size, hugging and compression resistance).
  - `Binding` is `@frozen`, as Apple's is: apps copy it inline.
  - Pointer authentication: Compute now re-signs every Swift closure that reaches its C entry
    points (tuple buffers, field and enum visitors, graph searches, subgraph walks), and its
    main-thread trampoline is a plain C function on both sides. Conditional content asks for
    its storage type through a generic instead of calling a metadata accessor through an
    unsigned pointer (`adapt.py`).
  - Foundation: Swift strings with characters beyond ASCII lost them when copied into a
    mutable CF string (`NSMutableString` appends, attributed strings), because `NSString`
    told CF they fit in eight bits.

- 2026-10-09: `SwiftUIGallery` draws: shapes (filled and stroked), styled text, a divider,
  the controls, a `Picker` and a `List`.
  - `Picker` (on macOS an AppKit pop-up button) and `List` (rows with selection) are Finch's
    own, over variadic views: an option or row is chosen by its tag, or its identity in a
    `ForEach`. The pop-up's item titles are the options' Texts. `_TagTraitWritingModifier`,
    which `tag(_:)` uses from macOS 26, writes the tag traits.
  - `Path.strokedPath` strokes (and dashes) through CoreGraphics.
  - OpenRenderBox released a path by the address of its own handle rather than its
    storage, and couldn't turn a path into a CGPath (`patches/OpenRenderBox`).

  - The first window takes its content's size (upstream gave it a placeholder 500 x 300
    frame), is centred once laid out, and is titled by its scene or the app.
  - CoreText: a font descriptor's traits now choose the face: weight (the bold trait is
    semibold on the system font, as Apple's), italic, and the monospaced and serif designs.

- 2026-10-09: button styles. `buttonStyle(_:)` (primitive and plain styles, stacked so a
  style's `Button(configuration)` is the button as the outer styles make it), and the
  system styles as on macOS: automatic and bordered (the push button, its bezel drawn by
  AppKit's button cell so it matches Finch's), bordered prominent, borderless, plain, link.
  Buttons track the mouse as AppKit's do: pressed while it is down over them, the action on
  release over them. The system accent colour comes from AppKit's `controlAccentColor`
  (upstream reads CoreUI's asset catalogue).

- 2026-10-09: `ScrollView`, as Apple's on macOS: an AppKit scroll view whose document hosts
  the content (ideal size along the scrolling axes, the scroll view's across them). The
  content inherits the font, enablement, colour scheme, layout direction, locale, text
  layout, control size and button styles; not the whole environment, which holds the outer
  graph's state. `finch-app-test` has a `scroll:` step.

- 2026-10-10: lists scroll, within the view graph (their rows belong to the list's graph,
  so they can't move into a hosted document): the rows at full height, offset, clipped,
  with an overlay scroller, and the wheel's events taken by an AppKit view over them.
  `SwiftUIGallery` runs in the Finch VM: it draws, takes clicks and scrolls.
  - Compute compared a part of a value (an indirect attribute's) at the wrong place:
    `AttributeType::compare_values_partial` passes pointers already at the part, and
    `compare_partial` added the part's offset again, so comparisons read neighbouring
    fields as enums or objects. Which crashed depended on what memory held, so the host ran
    and the VM didn't; with malloc scribbling the host crashed too. `find_partial` also lost
    a nested layout's offset. Both fixed in `patches/Compute/0001-finch.patch`.
  - Compute read a heap object's type from its first word, which for Objective-C objects
    and Swift subclasses of NSObject is a non-pointer isa; it asks the Objective-C runtime
    now, and doesn't read tagged pointers.

- 2026-10-10: what apps use. `tools/swiftui-coverage.py` lists, for this Mac's 41 SwiftUI
  apps, the share of their SwiftUI imports Finch's SwiftUI exports (48% at first, 50% now)
  and the missing symbols most apps import, the order to write them in. Written so far:
  the accessibility modifiers (generated by `userland/SwiftUI/gen-accessibility.py`),
  `allowsHitTesting`, `onHover` and `help` (an AppKit view over the content; tooltips wait
  for AppKit to show them), the `task` modifiers of macOS 26.4, and `@AppStorage`.
  - Making them work found: user defaults weren't kept (swift-corelibs put every user's
    preferences in /Library/Preferences, `patches/0009`, and nothing wrote them without an
    explicit `-synchronize`; a change now writes them a moment later and at exit), and AppKit
    sent tracking-area events only through the view under the pointer, not by the areas'
    rects as AppKit does.
  - Observation is the Swift runtime's, as Apple's SwiftUI uses, not OpenObservation:
    apps' `@Observable` types conform to its `Observable`, and a model's changes update
    the views that read it. SwiftUI compiles against Finch's own build of the module (whose
    interface has the SPI SwiftUI uses; the SDK's doesn't), and shares its access list
    through the runtime's thread-local slot for it, as Apple's does.
  - List and picker styles (`listStyle`, `pickerStyle`; the picker as a pop-up button,
    segmented control or radio buttons), Section (headers and footers marked by the
    section traits, as upstream's group lists make them), Form and the form styles
    (columns, grouped). `SwiftUIForms` tests them.
  - Text field styles; Menu (a pull-down button), menu styles and `contextMenu` (an AppKit
    view over the content that takes right-clicks), shown as AppKit menus built from the
    content: buttons, toggles (checked), dividers, sections, pickers and submenus.
  - Sheets (an AppKit sheet hosting the content), alerts and confirmation dialogs (NSAlert
    sheets whose buttons are the actions'; the original `Alert` type too), popovers
    (NSPopover from the view's bounds) and `dismiss`/`isPresented`. A presentation follows
    its binding; `onDismiss` runs after the update that dismissed it.
  - Apple's names for SwiftUI's extensions of SwiftUICore's structs, enums and classes
    (`EnvironmentValues.dismiss`, `.scenePhase`): Swift mangles the extension context into
    them, Apple's binary mostly doesn't, and apps import the shorter name. The build exports
    both (`extension-aliases.py`, an `ld -alias_list`).
  - Toolbars (ToolbarItem, ToolbarItemGroup, the builder and its tuples, groups and
    conditions; custom content through its body) as the window's NSToolbar: navigation
    items leading, principal and status in the middle, the rest trailing, each hosting its
    content. Every `toolbar` in a window adds to the one toolbar. `navigationTitle` is the
    window's title.
  - A rounded rectangle's hit test is geometric (OpenRenderBox's path storage can't take
    elements yet).
  - NavigationStack (its own path, a NavigationPath binding or a collection binding),
    NavigationLink (by value or by view; the old isActive and tag forms), the
    `navigationDestination` forms, NavigationSplitView (sidebar, content, detail; column
    widths; visibility) and NavigationView. A stack shows its root or its top page with a
    back button in the toolbar. The pages under it stay alive but covered, so they keep their
    state, and only the top page's title and toolbar items reach the window. Links in a split
    view's sidebar replace the detail column's pages. `SwiftUINavigation` tests them.
  - AppKit controls in SwiftUI views (buttons' press trackers, sliders) keep the mouse
    after a container's SwiftUI gesture takes the mouse-down (NSWindow `_latchView`), as an
    inner control wins over its container's gestures.
  - Gradients (Gradient, LinearGradient, RadialGradient, EllipticalGradient,
    AngularGradient) as shape styles and views. A paint that isn't a color is drawn by
    CoreGraphics, clipped to the shape (filled or stroked), into its layer's contents. Upstream's
    layer helper and style renderer had no paint path.
  - Lazy stacks (as the stacks they're lazy about) and lazy grids (a Layout sizing tracks
    as Apple's: fixed, then flexible and adaptive sharing the rest), GridItem and
    PinnedScrollableViews. Every view is made; headers aren't pinned yet.
  - `mask` (_MaskEffect, _MaskAlignmentEffect): the mask view is laid out in the content's
    frame and its display list masks the content's. Finch's AppKit now draws a view's mask
    view (and QuartzCore a layer's mask) as a destination-in layer, which they kept but
    didn't use before.
  - `onSubmit` (a text field runs the submit actions around it when Return commits it),
    `submitScope`, SubmitLabel; list rows' backgrounds and insets (row traits), the minimum
    row height, `scrollContentBackground`, `menuIndicator`. Row and section separators and
    `textSelection` change nothing yet: macOS lists draw no separators, and Finch's text
    can't be selected.
  - DragGesture: built from upstream's gesture parts (a spatial event listener in a
    coordinate space, under a gesture state that tracks the start, distance and velocity).
    finch-app-test has a `drag:` step.
  - The main menu and commands: SwiftUI apps get Apple's menus (the app menu, File, Edit,
    View, Window, Help), each a run of command groups. CommandGroup adds before or after a
    group, or replaces it; CommandMenu adds a menu before Window. Commands are read from
    their content as menus are, keyboard shortcuts becoming key equivalents. Upstream's
    commands graph never reached the menu.
  - DisclosureGroup, ControlGroup (one bordered strip), ContentUnavailableView,
    scrollIndicators and contentMargins (scroll views honour both), Glass and glassEffect
    (a translucent fill of the shape, no refraction).
  - Window scenes, openWindow and dismissWindow: the app opens its first window scene's
    window as it launches; openWindow(id:) opens a window for the scene with that id after
    the current update, sized to its content and centered (a Window scene's is brought to the
    front if open). windowResizability and defaultSize change nothing yet.
  - LongPressGesture and onLongPressGesture, timed by the events' own timestamps (the
    graph's time doesn't move between events nothing was drawn between). `pressing` isn't
    told yet. finch-app-test has a `hold:` step.
  - Next: ScrollViewReader (needs views' frames by identity), Table, ShareLink.
