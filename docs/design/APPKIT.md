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
