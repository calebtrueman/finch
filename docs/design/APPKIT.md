# AppKit, and UIFoundation under it

Mac apps are written against AppKit, which Apple ships closed, so Finch
writes its own (Phase 2, `docs/ROADMAP.md`). It draws with Finch's
CoreGraphics and CoreText, and its windows and events come from Finch's
window server (`docs/design/WINDOWSERVER.md`).

## How Apple's is split

Measured on the host (`dyld_info -exports`, `-linked_dylibs`, macOS 26.4):

- **AppKit** (`/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit`,
  current version 2685.50.116, compatibility 45) exports 8,774 symbols: 667
  classes (572 `NS*`) and 2,115 other `NS*` symbols (constants and
  functions). It re-exports Foundation, ApplicationServices (CoreGraphics,
  CoreText, ImageIO, ColorSync, HIServices, ...) and two private frameworks,
  UIFoundation and CollectionViewCore.
- **UIFoundation** (private, re-exported by AppKit, 988 exports, 125 classes)
  holds what AppKit shares with UIKit: `NSFont`, `NSFontDescriptor`,
  `NSParagraphStyle`, `NSShadow`, `NSTextAttachment`, `NSStringDrawingContext`,
  string drawing, and the text system (`NSTextStorage`, `NSLayoutManager`,
  `NSTextContainer`).
- **AppKit itself** holds the rest: `NSApplication`, `NSWindow`, `NSView`,
  `NSEvent`, `NSResponder`, `NSColor`, `NSColorSpace`, `NSBezierPath`,
  `NSImage`, `NSGraphicsContext`, controls and cells, menus, nibs, and so on.
- Apps link **Cocoa** (re-exporting AppKit, Foundation and CoreData), or
  AppKit directly. A symbol an app takes from AppKit can live in any image
  AppKit re-exports, so Finch's must re-export the same set.

Finch keeps the same split and install names: an `AppKit.framework` that
re-exports a private `UIFoundation.framework`, an `ApplicationServices`
umbrella re-exporting CoreGraphics, CoreText and ImageIO, Foundation, and a
`Cocoa` umbrella. Frameworks Finch doesn't have yet (ColorSync, HIServices,
CoreData, ...) join the umbrellas as they are written.

## Implementation

Objective-C (MRC, as Foundation), compiled against the SDK's AppKit headers so
every method has Apple's signature and every constant Apple's name. Classes
apps subclass (`NSView`, `NSWindow`, `NSApplication`, `NSResponder`,
`NSDocument`, `NSCell`, ...) work with the non-fragile ivar ABI, so Finch's
ivars are its own.

- **Drawing**: `NSGraphicsContext` wraps a `CGContextRef`; `NSColor`,
  `NSBezierPath`, `NSImage` and string drawing draw through CoreGraphics and
  CoreText.
- **Windows**: an `NSWindow` is a window-server window. Its content is drawn
  into the window's shared buffer through a CG bitmap context, then flushed.
  The title bar and frame are drawn by AppKit, in Finch's own look (Apple's
  artwork is theirs).
- **Events**: the window-server connection is a run-loop source on the main
  thread. `-[NSApplication nextEventMatchingMask:...]` runs the run loop and
  turns `FWSEvent`s into `NSEvent`s; `-sendEvent:` routes them to windows,
  which route them to views (hit testing, the first responder).
- **Nibs**: compiled nibs are keyed archives (`NSKeyedArchiver`), so loading
  one is unarchiving Finch's own classes plus `NSIBObjectData`'s connections.

## Testing

As Finch's other frameworks: test programs built against the SDK, run on the
host against Apple's AppKit and against Finch's (`DYLD_FRAMEWORK_PATH`), and
diffed. Geometry, state, responder chains and drawing into bitmaps compare
directly. Controls are drawn in Finch's own look, so their pixels are not
compared with Apple's. Windows and events are tested against a headless
window server, Finch-only.

## Status

- 2026-10-08: design; framework skeletons.
- 2026-10-08: UIFoundation's public API, over Finch's CoreText and CoreGraphics.
  `NSFont` and `NSFontDescriptor` are CoreText's objects, as on macOS: UIFoundation
  bridges CTFont to `NSCTFont` and CTFontDescriptor to `NSCTFontDescriptor` (under
  `UIFont`/`UIFontDescriptor`), so `CTFontCreateWithName` returns an NSFont and CF,
  CT and NSFont calls work on the same object. This needed
  `_CFRuntimeBridgeTypeToClass` to sign the class it stores, as the arm64e class
  table is read (CF patch 0004). Fonts are cached as Apple's are; the system
  fonts (Inter, through the font aliases) report Apple's sizes, UI-usage
  descriptors and archive names and flags (`.AppleSystemUIFont`, `NSfFlags`), so
  macOS archives read back; `systemFontOfSize:weight:` rounds weights as Apple's.
  Metrics, glyph APIs, `-set`, coding, descriptions. Descriptors: attributes,
  traits, size/face/family/matrix/design variants, matching, text styles.
  `NSParagraphStyle`/`NSMutableParagraphStyle` (Apple's description, archive keys
  and their legacy alignment values), `NSTextTab`, `NSTextList` (all marker
  formats), `NSShadow`, `NSStringDrawingContext`, `NSTextAttachment` basics, and
  the 300 string and number constants (attribute names, document attributes,
  descriptor keys and traits, weights, text styles; the font-descriptor ones Apple
  exports from AppKit itself live in UIFoundation, which AppKit re-exports).
  String drawing (`NSStringDrawing.h`) and a TextKit 1 text system
  (`NSTextStorage`, `NSTextContainer`, `NSLayoutManager`: one glyph per
  character, rectangular containers, flowing across containers) share one layout
  (`UIFTextLayout.m`) that reproduces TextKit's: rounded line heights, line and
  paragraph spacing, wrapping, alignment, truncation, the extra line fragment,
  pixel-snapped underlines and strikethroughs. AppKit classes (`NSGraphicsContext`,
  `NSColor`) are reached by name; UIFoundation doesn't link AppKit. CoreText's
  registry now also finds process-registered fonts by full and family name.
  `finch-uifoundation-test` (constants, fonts and descriptors with Roboto for
  exact metrics, UI fonts, paragraph styles, tabs, lists, shadows, string sizes,
  the text system's geometry and editing, 18 drawing scenes against renders from
  Apple's frameworks) prints identical output against Apple's frameworks and
  Finch's on the host, and Finch's in the VM. Not yet: TextKit 2
  (`NSTextLayoutManager`, `NSTextContentStorage`, ...), `NSTextBlock`/`NSTextTable`,
  `NSGlyphInfo`, `NSTypesetter`, exclusion paths, Apple's tightening before
  truncation, and reading and writing RTF/HTML/document formats.
- 2026-10-08: the drawing classes. `NSGraphicsContext` (per-thread current context and
  save/restore stack; its rendering options live in the CGContext's graphics state, read
  through Apple's private CG getters, now exported by Finch's CoreGraphics too),
  `NSColor` (Apple's classes and behaviours: component colours in an `NSColorSpace` or
  the legacy device/calibrated spaces, catalog colours with the light appearance's
  measured values, pattern colours; Apple's descriptions, including which colours its
  tagged-pointer encoding would hold, the exceptions accessors raise, conversions
  through CoreGraphics at ColorSync's float precision, blending, archives with Apple's
  keys), `NSColorSpace` (the named spaces as singletons, Apple's names and archive
  IDs), `NSBezierPath` (Apple's element generation for closes, rects, ovals, rounded
  rects and arcs, its flattening subdivision, reversal, tight bounds, containment as
  `CGPathContainsPoint` answers it, `NSSegments` archives), `NSGradient` (premultiplied
  interpolation in extended sRGB by default), `NSAffineTransform`'s AppKit additions,
  the `NSGraphics.h` functions (fills use copy, as Apple's; the bezels are Finch's own
  flat look), `NSImageRep`, `NSCustomImageRep`, `NSBitmapImageRep` (every format
  Apple's accepts, its row padding, pixel access, contexts over its pixels,
  ImageIO-backed reading and writing) and `NSImage` (reps, `lockFocus` at 1x,
  drawing handlers, `+imageNamed:` for named images and bundle files).
  `finch-appkit-draw-test` (state, conversions, path elements, archives, formats, and
  23 drawing scenes against Apple's renders) prints identical output against Apple's
  AppKit and Finch's on the host, and Finch's in the VM. Not yet: dark-appearance
  system colours, asset-catalog colours and images, Apple's system images,
  `NSPDFImageRep`/`NSCIImageRep`/`NSEPSImageRep`, TIFF (until ImageIO writes it),
  glyph paths beyond CoreText's outlines, pasteboard reading and writing for colours
  and images.
- 2026-10-08: the core. `NSApplication` (the event queue on the main run loop, fed by
  CoreGraphics' window-server client; dispatch, activation, modal sessions, action
  routing through the key and main windows' responder chains to the app and its
  delegate, `NSApplicationMain`), `NSWindow` (a window-server window drawn through a CG
  bitmap context over its shared buffer; Finch's own title bar in `NSThemeFrame`;
  frames, ordering, key and main, first responders as Apple's rules, dragging by the
  title bar, close/miniaturize/zoom), `NSView` (geometry, conversions, hit testing,
  autoresizing with Apple's pixel alignment and its unrounded carry-over, drawing the
  tree, tracking areas), `NSResponder`, `NSEvent` (Apple's validity rules, exceptions
  and descriptions), key bindings (Finch's table of the standard Cocoa bindings in the
  documented DefaultKeyBinding format, plus the user's own), `NSScreen`, `NSAppearance`,
  `NSTrackingArea`, `NSWindowController` and `NSViewController`. Nibs: Finch's own
  NIBArchive decoder (`NSNib.m`'s header describes the format), `NSIBObjectData`,
  `NSCustomObject`, `NSCustomView`, `NSClassSwapper`, `NSWindowTemplate` and the
  outlet and action connectors. `finch-appkit-core-test` and `finch-nib-test` print
  the same as Apple's AppKit on the host (the core test also in the VM);
  `finch-appkit-window-test` runs a window end to end on a headless server.
- 2026-10-08: the document architecture: `NSDocument` (reading and writing through
  URLs, file wrappers or data, untitled names as Apple numbers them, the change count
  and its undo-manager tracking, window controllers, saving) and `NSDocumentController`
  (the shared controller, document types from `CFBundleDocumentTypes`, making and
  opening documents, recents). `NSViewController` joins the responder chain between
  its view and the superview, and the nib decoder allocates `NSClassSwapper`
  classes directly so objects that refer back to them get the real object.
  `finch-appkit-document-test` matches Apple's on the host. Open and save panels are
  still to come.
