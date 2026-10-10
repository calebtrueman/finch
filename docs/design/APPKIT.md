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
- **Layout and bindings**: CoreAutoLayout solves the rules that place and size
  views; AppKit applies them to windows, views and stack views. Cocoa bindings
  connect controls to values and controllers. Storyboards load their scenes and
  connections. The October 9 entries below describe the supported parts and gaps.

## Testing

As Finch's other frameworks: test programs built against the SDK, run on the
host against Apple's AppKit and against Finch's (`DYLD_FRAMEWORK_PATH`), and
diffed. Geometry, state, responder chains and drawing into bitmaps compare
directly. Controls are drawn in Finch's own look, so their pixels are not
compared with Apple's. Windows and events are tested against a headless
window server, Finch-only.

`finch-app-test` can drive an app on a headless window server. Its
`screenshot:PATH` step saves the whole screen as a PNG for checking what the app
draws (`userland/tests/app-test.c`).

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
  Finch's on the host, and Finch's in the VM. TextKit 2 was added on October 9
  (see its entry below). Still missing: `NSTextBlock`/`NSTextTable`,
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
  AppKit and Finch's on the host, and Finch's in the VM. Asset-catalog colours and
  images followed on October 9 (see [Asset catalogs](ASSETS.md)). Not yet: dark-appearance
  system colours, Apple's system images,
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
  `finch-appkit-document-test` matches Apple's on the host. Open and save panels
  were added on October 9 (see the alerts and panels entry below).
- 2026-10-08: controls and cells. `NSCell` (types, states and the mixed-state cycle,
  values and their conversions with Apple's string forms, formatters, which setters imply
  which, tracking, editing through the field editor), `NSActionCell`, `NSControl` (its
  own tag, value and target without a cell; value accessors that end editing; action
  routing; mouse tracking; the field editor's delegate, turned into the
  `NSControlTextEditingDelegate` methods and notifications), `NSButton`/`NSButtonCell`
  (every button type's `highlightsBy`/`showsStateBy`, the state as the value, titles,
  images and positions, bezel styles, key equivalents, the factories, radio groups by
  superview and action, the window's default button), `NSTextField`/`NSTextFieldCell`
  (labels and fields, the factories, placeholders, bezels, editing with action on Return
  and end editing, Tab to the next key view), `NSSecureTextField` (bullets; the field
  editor still shows the text while editing), `NSSlider`, `NSStepper`,
  `NSProgressIndicator`, `NSSegmentedControl`, `NSColorWell` (the colour panel followed on October 9),
  `NSImageView`/`NSImageCell`, `NSBox`, `NSLevelIndicator`, and the nib classes
  `NSCustomResource`, `NSButtonImageSource` and `NSSegmentItem`. Each decodes Apple's
  nib keys; the cell and button flag bits, learned from ibtool's output, are in
  `NSControl_Finch.h` and `NSButtonCell.m`. Controls are drawn in Finch's own flat look
  (rounded bezels, the accent colour for the default button and for "on"); sizes follow
  Apple's where layout depends on them (push buttons 24 high, text fields 24, labels a
  line). `finch-appkit-controls-test` (cells, values, states, actions, every control, a
  nib of controls) prints the same as Apple's AppKit on the host and in the VM;
  `finch-appkit-controls-window-test` clicks, drags and types at a window of controls
  on a headless server and samples what they draw. The window now offers key
  equivalents without Command (Return, Escape) when nothing else takes the key, lets a
  text field hand first responder on to its field editor, and doesn't give the focus to
  a clicked button or slider. The remaining controls and colour panel followed on October 9
  (see their entries below). Not yet: image dragging into image views and periodic events
  for continuous buttons.
- 2026-10-08: text editing and scrolling. `NSClipView` (the document view, flipped as
  it is; `-scrollToPoint:` goes where asked while `-setBoundsOrigin:` is held to the
  document and its content insets by `-constrainBoundsRect:`; follows the document's
  frame), `NSScrollView` (overlay scrollers by default, legacy ones taking room; borders;
  autohiding; line and page amounts; precise and line scroll-wheel deltas,
  predominant-axis scrolling, handing the wheel on when it can't scroll; content insets;
  magnification about the centre, a point or a rect; the size class methods; rulers
  recorded but not drawn), `NSScroller` (Finch's flat overlay knob, dragging and
  jump-to-click; value, proportion and target kept by the scroller itself), `NSText` and
  `NSTextView` over UIFoundation's TextKit 1 (editing through
  `shouldChangeTextInRange:`/`didChangeText` with Apple's delegate and notification order,
  including ending editing after each change when not first responder; selection with
  delegate vetting, still-selecting drags, typing-attribute updates; every
  `NSStandardKeyBindingResponding` movement, selection, deletion, kill/yank, transpose,
  case and newline/tab action, with Apple's goal column, upstream affinity at wrapped
  line ends, which-end-moves and stop-at-anchor rules; undo of typing (coalesced),
  deletes, cut and paste through the window's or delegate's undo manager; clicks,
  shift-clicks, double and triple clicks and drags; the blinking insertion point;
  sizing (`sizeToFit`, min/max size, resizable axes, container inset and tracking);
  Command-X/C/V/A/Z when no menu takes them; `NSTextInputClient` with simple marked
  text; nib decoding with Apple's keys, including `NSTextViewSharedData`'s flags), the
  field editor (`-[NSWindow fieldEditor:forObject:]`, `-endEditingFor:`; Return, Tab and
  Backtab end editing with their `NSTextMovement`), and a minimal in-process
  `NSPasteboard`/`NSPasteboardItem` (named pasteboards, strings, data and property lists,
  Apple's type and name constants; nothing crosses processes yet). UIFoundation's text
  system gained what the text view needs: insertion-point rects for empty ranges from
  `boundingRectForGlyphRange:`, the text view's typing attributes for empty text, edit
  callbacks to text views, `NSLayoutManager` and `NSTextStorage` archiving, and the
  default container height when a nib leaves it out. `finch-appkit-text-test` (editing,
  movement, selection, undo, delegate order, pasteboard, field editor, clip and scroll
  view geometry, magnification, a nib) prints the same as Apple's AppKit on the host and
  in the VM; `finch-appkit-text-window-test` clicks, types, uses arrows and the
  equivalents, and scrolls a text view on a headless server, sampling what it draws.
  The font panel, colour panel and TextKit 2 were added on October 9 (see their entries below).
  Still missing here: rich-text pasteboard types (RTF), spelling,
  find, rulers, smart insert/delete and substitutions, multiple selections, a
  pasteboard server.
- 2026-10-08: menus. `NSMenu` and `NSMenuItem` (all of the public API; `NSMenu.m`,
  `NSMenuItem.m`) behave as Apple's, as measured: building and indexes, submenus and
  supermenus (an item's submenu takes `submenuAction:` and the submenu as target when it has
  no action), the add/remove/change notifications (which setters post, which don't),
  states, indentation and modifier masks clamped as Apple's, `isEnabled` false under a
  disabled parent item, copying, and archives with Apple's keys (`NSTitle`, `NSKeyEquiv`,
  `NSKeyEquivModMask`, `NSIsDisabled`, ...). Validation (`-update`) asks
  `-[NSApp targetForAction:to:from:]` for each item, then `validateMenuItem:` or
  `validateUserInterfaceItem:`; items with submenus are enabled, separators left alone.
  Key equivalents: delegates' `menuHasKeyEquivalent:...` first, then each menu validates
  and matches `charactersIgnoringModifiers` exactly with the same Command, Option and
  Control (Shift doesn't count, as Apple's with synthesized events); disabled matches are
  consumed. Nib menus named `_NSMainMenu`, `_NSWindowsMenu`, `_NSServicesMenu`,
  `_NSHelpMenu` become NSApp's (`NSCustomResource` and `NSIBHelpConnector` were added for
  the state images and tool tips nibs carry). `NSApplication` validates Hide and Show All;
  `-targetForAction:to:from:` returns an explicit target as Apple's, and `-sendAction:` no
  longer goes through the overridable method. The menu bar and menus are drawn by the app
  (`FinchMenuWindow.m`; Finch has no system UI): a 24-point bar at `NSMainMenuWindowLevel`
  with the app name in bold, shown while the app is active once it has launched and redrawn
  when the main menu changes; menus are pop-up-level windows in Finch's own flat look
  (state marks, images, indentation, right-aligned key equivalents with ⌃⌥⇧⌘,
  submenu arrows, greyed items, separators, alternates swapped in by the modifier keys).
  Tracking: press-drag-release or click-to-open and click-to-choose, hover highlighting,
  submenus, moving across the bar, arrows/Return/Escape, a click outside cancels; the
  delegate fills a menu in as it opens (`menuNeedsUpdate:`, `numberOfItemsInMenu:`...),
  `menuWillOpen:`/`menuDidClose:`, the tracking notifications, the Windows menu lists the
  windows. Context menus (`+popUpContextMenu:...`, `NSView`'s right click) and
  `-popUpMenuPositioningItem:atLocation:inView:` use the same windows. `NSMenuItemCell`,
  `NSPopUpButtonCell` and `NSPopUpButton` (pop-up and pull-down, selection and state,
  titles, nib keys `NSMenu`, `NSMenuItem`, `NSPullDown`, `NSPreferredEdge`,
  `NSAltersState`, `NSArrowPosition`...) on the controls' `NSButtonCell`.
  `finch-appkit-menu-test` (building, notifications, validation along the chain, key
  equivalents, delegates, archiving, a main-menu nib with pop-up buttons) prints the same
  against Apple's AppKit and Finch's on the host, and in the VM;
  `finch-appkit-menu-window-test` (the bar draws, clicking a title opens its menu, clicks,
  drags, keys and submenus choose, Command keys fire, right click, positioned menus, a
  pop-up button) matches `appkit-menu-window-test.expected` on the host and in the VM.
  Not yet: Services, the Help menu's search field, menu item views drawn in menus (they
  take their height only), badges, palette menus, scrolling long menus, tear-offs,
  `NSStatusBar`, Apple's automatic Edit and Window menu items (dictation, emoji, tabs).
- 2026-10-09: alerts, open and save panels, the workspace. `NSAlert` (`NSAlert.m`) has
  Apple's state as measured on macOS 26: the implicit "OK" (tag 0) until a button is added,
  tags from `NSAlertFirstButtonReturn`, key equivalents by title (Return for the first button,
  Escape for "Cancel", Command-D for "Don't Save"), the suppression checkbox's placeholder title
  until layout and its shorter title beside two or more buttons, `+alertWithError:` (critical,
  recovery options as buttons, help anchor), the legacy `+alertWithMessageText:...` (Apple's
  button order and old return codes), nil texts raising; it is laid out as macOS's classic alert
  in Finch's own look (icon, bold message, informative text, accessory, checkbox, buttons from
  the right, help button at the left; a caution sign badged with the app icon when critical) and
  runs app-modally or as a sheet. Sheets (`FinchSheet.m`, NSWindow's sheet API) have no animation:
  the sheet is a child window placed over its parent, centred under the title bar, and an event
  monitor sends clicks and keys meant for the parent to the sheet. `NSApplication`'s
  `presentError:` family now shows an alert and calls the error's recovery attempter.
  `NSSavePanel`/`NSOpenPanel` (`NSSavePanel.m`) are Finch's own browser: message, "Save As:"
  field, back button, path pop-up and New Folder, a list of the folder (Finch-drawn icons; hidden
  files, packages, `allowedContentTypes` through UniformTypeIdentifiers, files/directories
  choosability and the delegate's `panel:shouldEnableURL:` decide what is enabled; double click,
  Command-Up/Down, arrows and type-to-select), the accessory view, Cancel and the prompt, "Hide
  extension". Choosing appends the first allowed type's extension, asks before replacing, and
  asks the delegate (`validateURL`, `userEnteredFilename`, `didChangeToDirectoryURL`,
  `panelSelectionDidChange`); `runModal`, `beginWithCompletionHandler:` and sheets. Their defaults
  and setters are Apple's (titles, prompts, `~/Documents`, URL as directory plus name until
  chosen, `allowedFileTypes` and `allowedContentTypes` mirroring each other, an open panel
  ignoring the name, `tagNames` only with the tag field, a non-file directory URL reading back
  nil). `NSWorkspace`, `NSWorkspaceOpenConfiguration` and `NSRunningApplication` (`NSWorkspace.m`)
  work without LaunchServices: apps are found in the application folders by their Info.plist
  (bundle identifiers, document types ranked as LaunchServices ranks them, URL schemes), launched
  by spawning the bundle's executable (arguments, environment, files on the command line, the
  launch and terminate notifications on the workspace's own centre), `recycleURLs:` moves to
  `~/.Trash`, `duplicateURLs:` names copies as Finder does, types and icons (Finch's generic app,
  folder, document and volume icons drawn in code), Apple's constants; running applications are
  this process and processes inside app bundles (`proc_pidpath`), with Apple's answers for an
  unbundled tool. `finch-appkit-panels-test` prints the same against Apple's AppKit and Finch's on
  the host and in the VM; `finch-appkit-panels-window-test` answers alerts by click, Return,
  Escape and Command-D, runs a sheet, browses, chooses and saves with the panels and launches an
  app bundle on a headless server, matching `appkit-panels-window-test.expected`. Not yet: Apple
  events (opened files reach a launched app only as arguments), activating or hiding other apps,
  a file viewer (`activateFileViewerSelectingURLs:` uses an app that opens folders, if any), file
  tags, custom icons, column and icon views, sidebar and search in the panels, sheet animation,
  the Help Viewer and help-book search (`NSHelpManager` text storage is covered below).
- 2026-10-09: Cocoa bindings and controllers, the font manager. `NSKeyValueBinding.m`: every
  binding, option and info-key name with Apple's value; the markers (`NSBindingSelectionMarker`,
  `NSMultipleValuesMarker`...) and default placeholders by class and binding; NSObject's
  `bind:toObject:withKeyPath:options:` (a KVO observer of the key path, through to a collection
  in it; one-way, falling back to KVC as Apple's), `unbind:`, `infoForBinding:` (every option the
  binding understands, NSNull where unset), `exposedBindings` (Apple's per-class lists, plus
  `exposeBinding:` and what's bound), `valueClassForBinding:`; value transformers by name or object;
  NSEditor registration (a binding being edited tells the bound object `objectDidBeginEditing:`, and
  commits or discards when asked). The controls: text fields (value, with placeholders shown as the
  placeholder string and `NSConditionallySetsEditable`; textColor), checkboxes and radio buttons
  (state, multiple values as mixed), sliders (value, min/maxValue), `NSControl`'s enabled
  (`enabled2`... ANDed) and `NSView`'s hidden (`hidden2`... ORed) and toolTip, editable, font;
  pop-up buttons (content, contentValues, contentObjects, `NSInsertsNullPlaceholder`,
  selectedIndex/Object/Value/Tag, an extra item for a selection they don't list); text views
  (attributedString, pushed on their text notifications). Controls give their value before their
  action (`-[NSControl sendAction:to:]`, now also called by cells without an action), text fields
  when editing ends or, with `NSContinuouslyUpdatesValue`, as they change. `NSController.m`:
  `NSController` (editors, commit, discard), `NSObjectController` (content, the selection proxy
  `_NSControllerObjectProxy` whose keys can be observed, add/remove, objectClass, prepareContent,
  canAdd/canRemove, validation, contentObject binding), `NSArrayController` (arrangement by sort
  descriptors and filter, automatic rearranging, Apple's selection rules for setting content,
  rearranging, inserting and removing, add/insert/remove and selectNext/Previous with Apple's
  deferral, contentArray, selectionIndexes, sortDescriptors and filterPredicate bindings, an
  observable `arrangedObjects` proxy), `NSUserDefaultsController` (the shared one, a values proxy
  bindable as `values.key`, initial values, applying immediately or saving and reverting); nib keys
  for all of them, and `NSNibBindingConnector` (NSBinding, NSKeyPath, NSOptions,
  NSPreviousConnector); the nib decoder reads `NS.boolval` numbers. `NSFontManager.m`: the shared
  manager over CoreText (fonts, families, members as `[name, face, weight, traits]` with AppKit's
  0-15 weights and faces from the typographic subfamily, read from the font's own tables), picking
  a family member by traits and weight, converting to and from traits, sizes, families, faces and
  weights, the action and its target (`changeFont:`, `currentFontAction`, `addFontTrait:`,
  `modifyFont:` tags), the Font menu as Apple builds it; `NSFontPanel.m`: a Finch-look panel of
  family, face and size lists converting fonts as Apple's does. `finch-appkit-bindings-test`
  (names, NSObject and control bindings both ways, options, pop-ups, editing and commits, text
  views, both controllers, the defaults controller on a private suite, a nib of bound controls,
  NSFontManager on Liberation Sans and Inter) prints the same against Apple's AppKit and Finch's on
  the host; the October 9 follow-up below records the VM result. Table and column bindings
  are covered in the tables entry below. Not yet: `NSTreeController`, `NSDictionaryController`,
  outline/collection view bindings, Core Data (managed object contexts, fetching), validation alerts, display patterns,
  font bindings beyond `font` (fontBold, fontSize...), the font panel's collections and effects,
  font collections kept on disk; Apple's `convertWeight:` quirks with italics and light faces are
  not copied.
- 2026-10-09: Auto Layout and storyboards. As on macOS, constraints live in a private
  `CoreAutoLayout.framework` (`userland/CoreAutoLayout`; current version 34) that Foundation
  weak-links and re-exports symbol by symbol (`userland/Foundation/CoreAutoLayout.reexports`, the
  classes and functions Apple's Foundation re-exports that Finch has), so apps binding
  `NSLayoutConstraint` from Foundation find it; it links Foundation upward and builds before it
  (against the SDK's Foundation stub, same install name). It holds `NSLayoutConstraint`
  (validation and exceptions with Apple's messages, priorities, identifiers, activation on the
  nearest common ancestor, nib coding with Apple's keys including `NSSymbolicConstant` NSSpace,
  and Apple's descriptions: spacing as visual format, `(LTR)`, `NSSpace(20)`,
  `NSLayoutAnchorConstraintSpace(8)`, names lists), `NSAutoresizingMaskLayoutConstraint`
  (Apple's per-mask recipe, `h=-&- v=&--` prefixes, private minX/minY attributes),
  `NSContentSizeLayoutConstraint`, the visual format parser (the whole language, alignment and
  direction options, Apple's error messages and caret positions), `NSLayoutAnchor` and its
  x/y/dimension kinds (all `constraint*` methods, system spacing, `_NSDistanceLayoutDimension`
  offsets), `_NSDictionaryOfVariableBindings`, and Finch's solver: the Cassowary incremental
  simplex written from the paper (`FinchLayoutSolver.c`), with a lexicographic objective (one row
  per priority, so 251 beats any number of 250s, and equal priorities settle on the L1 optimum, as
  Apple's), incremental add/remove, constant changes by the dual simplex (edit variables), and an
  ambiguity test. AppKit (`NSViewLayout.m`) runs it: one engine per layout root (a window's
  content view, or the top of a detached tree), variables per view and guide for its alignment
  rect, measured downward from its superview's top-left; autoresizing masks become constraints
  only once something under the root uses constraints, kept in step with frames (the classic
  autoresizing still runs first, as Apple's); intrinsic sizes become hugging/compression
  constraints with Apple's default priorities (250/750; controls hug 750 vertically, labels 251
  across); a root would keep its size just under 500, and a window grows or shrinks to what its
  constraints need, top left fixed; frames go out in `-layout`, top down, each edge rounded to the
  backing pixels (points outside a window), negative sizes shown empty; unsatisfiable required
  constraints are left out with Apple's "Unable to simultaneously satisfy constraints" log. Views:
  the constraint API, anchors, `NSLayoutGuide`, `fittingSize` (a separate solve at priority 50),
  alignment rects and baselines, content-size priorities and `*ContentSizeConstraintActive`,
  `updateConstraints`/`layoutSubtreeIfNeeded` passes, `hasAmbiguousLayout` (in windows, as Apple's),
  constraints dropped when a subtree leaves; `NSWindow`'s `layoutIfNeeded` and
  `updateConstraintsIfNeeded`. `NSStackView` (`NSStackView.m`) makes Apple's constraints (identifiers
  and priorities as measured: alignment at 260, gravity packing at 750 and 749.99..., edges at the
  stack's 249.99998 hugging, the fill, fill-equally, fill-proportionally, equal-spacing and
  equal-centering distributions through a shared dimension), gravity areas, custom spacing, hidden
  views detaching, and its nib keys. Storyboards (`NSStoryboard.m`): `.storyboardc` bundles
  (Info.plist's entry point, main menu and controller nibs; a scene owner with `sceneController`;
  `NSNibExternalObjectPlaceholder`s for the storyboard and, in a view's own nib, the segue
  templates), `NSStoryboardSegue` and the show/modal/sheet/popover/custom templates,
  `performSegueWithIdentifier:sender:` with `shouldPerform...`/`prepareForSegue:`, window
  controllers from window templates with their content controllers (through
  `NSIBUserDefinedRuntimeAttributesConnector`), `NSMainStoryboardFile` in `NSApplicationMain`. Hooks
  in the core, each a line or two: `NSView.m` (an `_finchLayout` ivar; frame, hidden, translates,
  superview and dealloc notifications; nib constraint keys; `needsLayout`/`needsUpdateConstraints`
  start YES, as Apple's; the old layout stubs moved out), `NSNib.m` (external placeholders),
  `NSWindowController.m` (storyboard keys, a storyboard controller's `loadView`),
  `NSApplication.m` (`NSMainStoryboardFile`). `finch-appkit-layout-test` (descriptions, validation,
  the visual format language and its errors, anchors, priorities, inequalities, multipliers,
  rounding, intrinsic sizes, baselines, guides, autoresizing masks, fitting sizes, windows sized by
  content, stack views in every alignment and distribution, a constraint nib and a storyboard
  compiled by ibtool) prints the same against Apple's AppKit and Finch's on the host and in the VM.
  Not yet: `exerciseAmbiguityInLayout` (does nothing), `constraintsAffectingLayoutForOrientation:`
  is Finch's guess, Apple's integralization of ties (exact .5 edges) and its per-view standard
  spacing for nib `NSSpace` (Finch uses 20 to the superview, 8 between siblings), right-to-left
  user interfaces, baseline alignment across a vertical stack, stack views' visibility priorities
  and delegate, storyboard references and embed segues,
  the creator blocks of `instantiateController...`. `NSPopover` and real storyboard popover
  presentation were added later on October 9 (see the container entry below).
- 2026-10-09: TextKit 2, in UIFoundation where Apple has it: `NSTextRange` and
  `NSCountableTextLocation`, `NSTextElement`/`NSTextParagraph`, `NSTextContentManager` and
  `NSTextContentStorage` (paragraphs made lazily, asking the delegate, kept across edits that don't
  touch them; Apple's enumeration rules and return values; the storage observed through
  `textStorageObserver`; setting `attributedString` lets the storage go, as Apple's), `NSTextLayoutManager`
  (fragments per paragraph made through its delegate and kept with their elements, their states,
  `ensureLayoutFor...`, invalidation, usage bounds, fragments by position and location, text
  segments of all three types and their options, rendering attributes, `NSTextSelectionDataSource`),
  `NSTextLayoutFragment` (frames, rendering surface bounds from the fonts' bounding boxes, drawing
  y-down into any context), `NSTextLineFragment`, `NSTextViewportLayoutController` (Apple's delegate
  order), `NSTextSelection` and `NSTextSelectionNavigation` (moves by character, word, line, sentence,
  paragraph and document in every direction, extending, deletion ranges, clicks, granularities, as
  measured), and `NSTextContainer`'s `textLayoutManager`. The text layout manager lays text out with a
  private `NSLayoutManager` of its own over the same `UIFTextLayout.m`, so TextKit 1 and 2 place every
  line alike (`UIFTextKit2.h`). Shared layout fixes found on the way: line offsets are glyph positions
  (kerning moves the glyph, not half of it), centred and right-aligned lines are placed without their
  trailing whitespace, and a container archives its layout manager (and that its storage)
  unconditionally, as Apple's. `NSTextView` is on TextKit 2 as on macOS 26 (`-initWithFrame:`, nibs and
  archives, which hold TextKit 1 objects and are converted, `+scrollableTextView` and friends, the field
  editor), TextKit 1 with `+textViewUsingTextLayoutManager:NO` or a TextKit 1 container; asking it or its
  container for `layoutManager` switches it to TextKit 1 with Apple's notifications. Both systems edit,
  move and measure alike (the view asks TextKit 2's layout engine TextKit 1's questions); a TextKit 2 view
  draws through its viewport's layout fragments and mirrors its selection in `textSelections`.
  `finch-textkit2-test` (ranges, content storage, layout and line fragments, editing, segments, the
  viewport, navigation, TextKit 1 and 2 alike, drawing, text views, the switch, archives, a nib) prints the
  same as Apple's frameworks on the host. Not yet: text list elements and attachments' view providers,
  layout queues, estimated (non-contiguous) layout of long documents, vertical text, right-to-left
  navigation, `NSTextView`'s own use of `NSTextSelectionNavigation`, Apple's reported
  `selectionAffinity` (upstream after every selection change; Finch reports downstream, also in TextKit 1).
- 2026-10-09: nib support Image Capture's storyboard needed (`docs/design/IMAGECAPTURE.md`):
  `NSSplitViewItem -initWithCoder:` (Apple's keys: behavior, view controller, and holding priority,
  thicknesses and collapsing when not the behavior's defaults), `NSToolbarItem -initWithCoder:` (label,
  palette label, tool tip, title, image, view, target and action, tag, enabled, autovalidates, bordered,
  navigational, visibility priority, min and max sizes), and Apple's private `NSToolbarFlexibleSpaceItem`,
  `NSToolbarSpaceItem` and `NSToolbarSeparatorItem` that nibs archive for the standard items.
- 2026-10-09: copying an `NSCustomImageRep` now keeps its drawing handler alive for the
  copy, so freeing the original and copy no longer releases the same handler twice.
  `NSFontEffectsBox` lets nibs that name the font panel's effects bar, including Stickies',
  load it as a plain `NSBox`; it does not add the effects controls. The
  `finch-appkit-bindings-test` comparison also matched Apple's in the VM.
- 2026-10-09: tables, outlines and collections. `NSTableView` (`NSTableView.m`): columns, Apple's
  geometry (rows of `rowHeight` plus the intercell height, columns padded by half the intercell width with
  6 at the outer edges of full-width, inset and source-list tables, inset and source-list tables inset 10
  at the sides, 5 above and 10 below the rows; group rows 28, 19 or 25 tall), the frame fitting the
  columns and rows and at least the clip view less its insets, column autoresizing in all six styles when
  the clip view changes width (only if the columns filled the table or no longer fit, each column held to
  its limits), `sizeToFit`/`sizeLastColumnToFit`, hidden and moved columns; the selection as measured
  (programmatic selection ignores the delegate and the multiple-selection flag, a set past the last row is
  ignored, `selectAll:`/`deselectAll:` ask `selectionShouldChangeInTableView:`, the selected row is the last
  selected, row and column selection exclude each other, inserted rows move it silently, removed selected
  rows deselect with a notification, a view-based table's `reloadData` clears it); `beginUpdates`
  insertion, removal and moves (only inside it for cell-based tables, raising Apple's exception);
  `noteNumberOfRowsChanged`, `noteHeightOfRowsWithIndexesChanged:`; sort descriptors (the data source told
  of changes, a header click sorts by the column's prototype or reverses it), indicator images, the
  highlighted column; prepared cells; cell-based drawing (background, alternating rows, selection, grid,
  the columns' cells) and editing through the field editor (double click, Return, Tab to the next
  editable column); view-based tables: row views and cell views for the visible rows (every row outside a
  window), made in Apple's order (row view, then each column's view, then its object value, then
  `didAddRowView:`), a reuse queue, prototypes archived in nibs (`NSTableViewArchivedReusableViewsKey`, a
  nested nib each) and `registerNib:forIdentifier:`; clicks (Command and Shift), drags, arrow keys, the
  action and double action. `NSTableColumn` (`NSTableColumn.m`, with `NSTableHeaderCell`),
  `NSTableHeaderView` (`NSTableHeaderView.m`: titles, the sort indicator, sorting and column selection by
  click, resizing by the trailing edge), `_NSCornerView` (no corner with overlay scrollers, as Apple's),
  `NSTableRowView` and `NSTableCellView` (`NSTableRowView.m`). In a scroll view the header goes in a clip
  view of its own across the top, and the content clip view's top inset grows by its height (content at
  the top stays at the top): two hooks in `NSScrollView.m`'s `-tile` and `-reflectScrolledClipView:`.
  `NSScrollView` also adjusts its content insets as Apple's does under a full-size content window's title
  bar and toolbar: in the window's layout pass, after its frame or window changes or
  `automaticallyAdjustsContentInsets` is turned on, it takes a top inset of how far it runs above the
  window's `contentLayoutRect` (and no others); insets set by hand stand until the next such change, and
  the clip view's insets are the scroll view's plus a table's header.
  `NSOutlineView` (`NSOutlineView.m`): the rows of the expanded tree (children asked for as items expand
  and kept until reloaded), levels, parents and child indexes, 13 per level of indentation, the disclosure
  triangle 13 wide before the indented cell, the outline column growing and shrinking with the deepest
  visible level, expanding and collapsing with Apple's order of questions and notifications (collapsed
  children remembered and expanded again with their parent), selected items kept selected as rows move,
  hidden ones deselected with a notification, insertion, removal, moves and reloading of items.
  `NSCollectionView` (`NSCollectionView.m`): sections and items from the data source, items from
  registered classes and nibs for the visible elements (frames rounded to the backing pixels), a reuse
  queue, supplementary views, selection as measured (programmatic selection ignores `selectable` and tells
  the delegate nothing, `selectAll:`/`deselectAll:` tell it, reloading clears it), clicks; the older API
  (content, item prototype, a grid of the prototype's size, `selectionIndexes`). Layouts
  (`NSCollectionViewLayout.m`): attributes, `NSCollectionViewFlowLayout` (uniform items in a grid spread to
  the edges with the same spacing on every line, items of different sizes in lines spread to the edges but
  the last, centred across the line, headers and footers, insets, both directions, delegate metrics) and
  `NSCollectionViewGridLayout` (columns at the minimum width, items stretched to the maximum size and to the
  visible height, a fixed number of rows scrolling sideways). Bindings: a column's `value` to
  `arrangedObjects.key` binds the table's content, selection indexes and sort descriptors to the same
  controller and gives the column a sort prototype; the table's own content, selectionIndexes,
  sortDescriptors and rowHeight bindings; cell views show their row's object for `objectValue.key`
  bindings (`NSKeyValueBinding.m`'s machinery, no change to it). Nib keys for all of them (`NSTvFlags` bits
  worked out from ibtool's output). `finch-appkit-tables-test` (columns, geometry in every style, selection,
  edits, autoresizing, scroll views, view-based realization and reuse, outlines, flow and grid layouts in a
  window's layout pass, the older collection view, bindings, a nib with cell- and view-based tables, an
  outline, a collection view and bound columns, scroll views under full-size content windows' bars)
  prints the same against Apple's AppKit and Finch's on the
  host and in the VM; `finch-appkit-tables-window-test` clicks, Shift- and Command-clicks, arrows, sorts, resizes,
  edits, expands and selects through the window server and samples the drawing (compare with
  `appkit-tables-window-test.expected`). Not yet: drag and drop (sources, destinations, gaps, reordering
  rows and columns by dragging), type select, column autosave, floating group rows, automatic row heights,
  hidden rows, `NSTreeController` and outline bindings, table animations, Apple's half-point
  rounding of uniformly autoresized columns and of grid items, the grid layout's switch to sideways
  scrolling when rows overflow, collection view drag and drop and section collapsing.
- 2026-10-09: full-size content windows (`NSWindowStyleMaskFullSizeContentView`, as Image Capture's):
  the content fills the frame and Finch's title bar and toolbar row are drawn over it by an overlay
  view (`FinchTitlebarView`), honouring `titlebarAppearsTransparent` and `titleVisibility`;
  `contentLayoutRect` leaves the title bar and toolbar out, as Apple's does. Window templates attach
  the toolbar archived under `NSViewClass`; a toolbar uses the nib's items for the identifiers its
  delegate names, and asks a delegate set after it was first shown. Image Capture now shows
  its title bar and toolbar; the toolbar is empty without a device, as on macOS. Scroll views'
  automatic space below these bars is covered in the tables entry above. Still missing:
  Apple's unified toolbar style (title and items in one 52-point row). This change also added
  `finch-app-test`'s `screenshot:PATH` step; the AppKit comparison tests and window-server
  tests still matched.

- 2026-10-09: the colour panel and column browser. `NSColorPanel` (`NSColorPanel.m`) has a
  shared panel, target/action and colour-change notifications, alpha and continuous changes,
  an accessory view, attached colour lists, and Finch-drawn wheel, RGB sliders and palette.
  Setting the same colour again does not send another change. Active `NSColorWell`s follow
  panel changes; opening another well without exclusive activation keeps the panel's colour,
  and closing the panel deactivates its wells. The list of active wells does not keep them
  alive. `NSColorPicker` provides the base picker API. Other colour-space modes use the RGB
  controls for now. Not yet: external picker plug-ins, an eyedropper, colour dragging, or a
  separate CMYK, grayscale and HSB slider interface.
  `NSBrowser` and `NSBrowserCell` (`NSBrowser.m`, `NSBrowserCell.m`) support item delegates
  and both older cell delegates: the browser makes rows for a passive delegate, or asks an
  active delegate to fill its `NSMatrix`. They load and reload columns, preserve selected
  items on reload, track leaf rows, support a custom root, string and index paths, multiple
  selection, column titles, width limits and saved widths, horizontal scrolling, arrow keys,
  basic type select, column resizing and variable row heights. Item delegates have no matrix,
  as on macOS. Nibs decode the browser and cell settings with Apple's keys. Finch draws the
  columns, selected rows and leaf indicators itself. Not yet: drag and drop, cell editing,
  preview and header view controllers, full type select, or exact Apple font and drawing sizes.
  The standalone `appkit-color-browser-test.m` comparison matched all 22 lines against Apple's
  AppKit and Finch's on the host, including an ibtool-compiled nib. Its reusable sections are
  also part of `finch-appkit-containers2-test`. Browser content-width conversion depends on
  the host's scrollbar preference; the combined test checks the sum of the two widths rather
  than one preference's split. `appkit-color-browser-render-test.m` uses view hit tests and
  mouse events to select `/Folder/B`, then writes browser, wheel, palette and RGB-panel PNGs.
  It passed on the host; the browser, wheel and palette images were visually checked.
- 2026-10-09: animation and Touch Bar state. `NSAnimationContext` (`NSAnimationContext.m`)
  keeps the same current-context object through nested groups, saves and restores the outer
  duration, timing, implicit-animation flag and completion handler, and queues completion
  callbacks after a group closes. A changes block that throws still closes its group. Views,
  windows and constraints have cached animator proxies and animation dictionaries; proxies
  hold weak targets. The proxy applies final values at once, so it does not yet draw the
  intermediate frames of a view or window animation. `NSAnimation` has timed progress, curves,
  progress marks and delegate calls; `NSViewAnimation` changes frames and handles basic
  fade-in/fade-out visibility. Not yet: linked start/stop triggers, `NSAnimation` archives,
  full alpha fades, or separate-thread blocking behavior.
  `NSTouchBar` and its items (`NSTouchBar.m`) keep their identifiers, settings, templates and
  delegate-made items. Responders make a bar when first asked and keep it. Standard space
  items, custom views, groups, popovers, buttons, sliders, colour pickers and steppers expose
  their state. Bar archives keep the template set, identifiers and customization arrays;
  item archives keep the identifier and visibility priority, using keys checked against host
  archives. The bar delegate and action targets are weak. There is no Touch Bar hardware display,
  system customization palette or popover presentation; some item archives and the scrubber
  and candidate-list interfaces remain incomplete.
  `finch-appkit-misc2-test` matched all 26 lines against Apple's AppKit and Finch's on the
  host. It covers nested context identity and restored settings, deferred completion,
  zero-duration animator changes, four curve values, Touch Bar lookup, defaults and saved
  settings, plus the gesture, accessory, material and help checks below. This test does not
  establish timed animation drawing or Touch Bar presentation.
- 2026-10-09: gestures, help text, visual effects and slider accessories.
  `NSGestureRecognizer` (`NSGestureRecognizer.m`) attaches to a view, moves between views,
  and holds weak targets and delegates. Recognizers on the clicked view and its ancestors
  receive the event.
  Click, pan and press recognizers handle mouse events; magnification and rotation recognizers
  accept the corresponding events. Views expose their recognizer lists, and window event
  delivery forwards events to them. Recognition is basic: full conflict handling between
  recognizers, dependencies between them and trackpad gesture recognition are not complete.
  `NSHelpManager` attaches, returns and removes attributed help text and keeps the context-help
  mode flag. It does not open Help Viewer, search help books or register them.
  `NSVisualEffectView` keeps its material, blending mode, state, mask and emphasis settings,
  decodes and saves those settings, and draws a solid background. It has no background blur;
  its default `allowsVibrancy` is false, as measured on the host. `NSSliderAccessory` keeps its
  image, enabled state and behavior. Explicit handler and target/action behaviors work;
  automatic step/reset behavior has no link to a slider yet. The 26-line host comparison
  above checks gesture defaults and attachment/removal, an accessory handler call, visual
  effect defaults, and help text storage/removal. No VM result is recorded for these new
  colour/browser, animation, Touch Bar and gesture checks here.
- 2026-10-09: named assets. `NSAssetCatalog`, `NSImage` and `NSColor` use Finch's CoreUI
  reader for compiled `Assets.car` catalogs, bundle lookups, and the tested appearance and
  scale variants. `AssetsTest.app`, built from Finch's fixtures with `actool`, matched all
  486 result lines against Apple on the host after excluding the framework-path line.
  The comparison covers named lookups, sizes, colour values and decoded pixels. Reads of
  five installed apps' catalogs also matched `assetutil` for the names, properties and sizes
  of 70 colour and 141 image renditions. This does not establish every bitmap codec or
  private CoreUI drawing call; raw JPEG and HEIF pixel comparisons were not part of that
  installed-app check. See [Asset catalogs](ASSETS.md) for the reader, fixtures and limits.
- 2026-10-09: more controls and cells. `NSSearchField`, `NSSearchFieldCell` and
  `NSSearchToolbarItem` add search and cancel buttons, recents and search actions.
  `NSComboBox` and its cell hold an item list or ask a data source, keep the selection and
  provide completion. `NSTokenField` and its cell edit represented objects as tokens, ask
  delegates for display text and completions, and handle typing and deletion. `NSDatePicker`
  and its cell keep dates and ranges, expose the styles and elements, and provide field,
  calendar and clock editing. `NSPathControl`, its cell, component cells and path items keep
  URL components and clicked items in both styles. `NSSwitch`, `NSComboButton`, `NSMatrix`,
  `NSForm` and `NSFormCell` add switch actions, a button with a menu, cell grids and labelled
  fields. These controls draw in Finch's own style and support the tested editing, actions,
  delegate calls, bindings, archives, accessibility answers and nib settings.
  `finch-appkit-controls2-test` matched all 730 body lines against Apple's AppKit on the host,
  excluding the first line that names the loaded framework. It includes an ibtool-compiled
  nib; text widths that depend on the font are not compared. Apple's search button is as wide
  as its image rendered for the main screen (15 points on a 2x screen, 16 on a 1x one, which
  also moves small and mini fields' text); Finch follows its main screen's scale, and the test
  prints the geometry as on a 2x screen so the host's displays don't change it. The Finch-only
  `appkit-controls2-render-test.m` checks token typing and deletion, switch and combo actions,
  the lifetime of a clicked path item, date arrow keys, opening the calendar, changing months,
  choosing a date and clicking the clock. Its PNG was visually checked. These are actual
  input and drawing checks, not only stored-property tests.
  Not yet: an end-to-end path drag through the shared view drag-session code. Path source
  and drop delegate methods exist, but that complete flow is unverified. The combo dropdown
  uses `NSMenu`; visible-item and scroller settings are kept but do not provide a separate
  scrolling combo list. Token completion calls its delegate automatically, while the
  suggestion menu opens through the Complete command.
- 2026-10-09: more containers. `NSPopover` (`NSPopover.m`) presents a child window with a
  pointer to its anchor, supports all four edges and content-size changes, and asks its
  delegate about closing. Application-defined, transient and semitransient behaviors use
  event monitors for dismissal: transient popovers close on clicks outside them, semitransient
  ones only on clicks in their anchor's window (as `NSPopover.h` describes), both on Escape. A
  content view controller's `preferredContentSize`, when set, sizes the popover each time it is
  shown, as Apple's does. View controllers present and dismiss real popovers;
  storyboard popover segues preserve their anchor, edge and behavior. `NSDrawer` uses child
  windows with edge placement, size limits, delegate calls and nib settings. Both transitions
  happen at once; popover detachment and animated presentation are not implemented.
  `NSGridView`, `NSGridRow`, `NSGridColumn` and `NSGridCell` use layout guides and constraints
  for content sizing, placement, spacing, padding, merged cells, hidden rows and columns,
  custom placement constraints and row/column changes. They decode nibs, but do not try to
  reproduce Apple's private constraint objects. `NSPageController` keeps selected objects,
  asks its delegate for controllers, switches views and keeps navigation history. Page
  swipes and animated transitions are not implemented.
  `NSRuleEditor` supports rows and nested groups, selection, delegate choices, row controls
  and predicates. `NSPredicateEditor` and `NSPredicateEditorRowTemplate` add common typed
  comparisons and compound predicates, matching and copying templates, and row editing.
  The full Cocoa bindings row model and all specialized predicate templates are not covered.
  `finch-appkit-containers2-test --windows` matched all 78 body lines against Apple's AppKit
  on the host, excluding the framework-path line; neither run wrote to stderr. It covers
  grids, rule trees, predicates and templates, page selection and history, popover geometry,
  close veto and notification order, drawers, the colour/browser sections above, and two
  compiled nibs. The native popover comparison used macOS WindowServer access so its screen
  placement was real. The ordinary run without `--windows` has 64 body lines; it finds the
  nibs next to the executable or in `/usr/local/share/finch`.
  The Finch-only container render test ran a 1000-by-800 headless window server at scale 2,
  wrote grid, predicate-editor and popover PNGs, and clicked the row-add button. It also sent
  mouse events and Escape through `NSApplication` to test each popover behavior and dismissal
  after clicks in its parent or another window. The three images were opened and checked;
  grid text, predicate controls and the popover pointer were readable. In the VM,
  `finch-appkit-containers2-test` (with its two nibs from `/usr/local/share/finch`) prints the
  same 64 body lines as Apple's AppKit on the host (checksum 652695619).
- 2026-10-09: remaining planned work from this AppKit pass. The earlier plan also named
  `NSSharingService`, `NSSharingServicePicker` and `NSSound`. They have no implementation
  here yet. The inherited work included a host sound-defaults probe and a class/import
  survey, but no sound or sharing-service source. `NSSharingServicePickerTouchBarItem`
  only keeps its item settings; it does not supply a working share sheet or sharing service.
  Sound loading and playback, sharing-service discovery and execution, and their UI still
  need separate work. The completed controls, containers and support classes above do not
  mean that every item in that earlier plan, or AppKit as a whole, is finished.
- 2026-10-10: `NSSharingService` and `NSSharingServicePicker` (`NSSharingService.m`). Finch's
  services are those it can perform itself: Copy (the items onto the general pasteboard),
  Open (URL items, each through NSWorkspace) and Email (a `mailto:` URL with the
  recipients, subject and the items' text as the body, offered when an app handles
  `mailto:`). `+sharingServiceNamed:` answers nil for services with no Finch counterpart
  (AirDrop, Messages, the photo apps). The picker shows its services as a menu at the rect,
  asks its delegate for the list and for each service's delegate, reports the choice
  (or nil when the menu closes without one), and gives `standardShareMenuItem` the same
  menu as a submenu. SwiftUI's ShareLink drives it; the copy round trip was checked through
  the pasteboard. NSSound is still to do.
- 2026-10-09: AppKit's Swift overlay. Apple compiles AppKit's Swift half
  (module AppKit) into AppKit.framework, and Swift apps import it from there
  (TextEdit imports `CGRect.fill(using:)` and `CGRect.frame(withWidth:using:)`).
  `AppKitOverlay.swift` is Swift's historical open overlay
  (`stdlib/public/Darwin/AppKit` at `swift-5.2.5-RELEASE`, Apache 2.0 with the
  Runtime Library Exception): `NSApplicationMain(_:_:)`, the rect fill, frame and
  clip extensions, `NSEvent.SpecialKey`, `IndexPath(item:section:)`, the colour
  and image literals, `NSSound.beep()`, `_AppKitKitNumericRawRepresentable`
  (window levels, layout priorities) and the AppKit error codes. `build.sh`
  compiles it like Apple's overlays: resilient, `-import-underlying-module`,
  linking only the Swift libraries it uses (`swiftCore`, `swiftCoreFoundation`,
  `swiftObjectiveC`), so it never pulls Metal's or Core Image's overlays in.
  TextEdit's imports now all resolve against `build/root`
  (`tools/check-imports.py`). Apple's overlay has 4,660 Swift exports; Finch's
  has 293 (`tools/check-swift-parity.sh`). Apps also import diffable data
  sources, `NSView.Invalidating`, text suggestions, `NSMenuItem.sectionHeader`,
  `NSCursor.frameResize` and the AppKit attribute scope
  (`AttributeScopes.AppKitAttributes`), which come later.
- 2026-10-09: the find bar. `NSTextFinder` (`NSTextFinder.m`) runs every
  `NSTextFinderAction` against its client: show and hide the bar, next and previous
  (case-insensitive, wrapping), set the search string from the selection, replace,
  replace all (in the selection too) and select all. The search string lives on the find
  pasteboard, as on macOS. The bar is `NSTextFinderBarView`, Apple's class name, 32 points
  tall, with a replace row when asked for. `NSScrollView` tiles it above or below the
  content (`findBarPosition`). `NSTextView` answers `performTextFinderAction:` and the
  older `performFindPanelAction:` through a finder of its own, so TextEdit's Find menu
  works. `finch-textfinder-test` matches Apple's run.
- 2026-10-09: rulers. `NSRulerView` and `NSRulerMarker` (`NSRulerView.m`) match Apple's
  defaults and thicknesses: a 17-point rule, 15 points for a horizontal ruler's markers,
  the baseline where the rule meets the markers, and an exception when markers are added
  before a client view. Units are registered by name (Inches, Centimeters, Points, Picas,
  and `registerUnitWithName:`), and the default follows the locale. Hash marks and labels
  are drawn in client coordinates from `originOffset`. Markers drag through the client
  methods, and a removable marker pulled off the ruler goes. As on macOS, `NSScrollView`
  floats its rulers over the content's top and leading edges and insets the clip view by
  their thickness, with the scrollers below. `NSTextView`'s ruler shows the selected
  paragraph's head, tail and first-line indents and its tab stops over a 30-point format
  bar (alignment, line spacing). Dragging changes the paragraphs, and a click adds a tab.
  A text view in a clip view now takes the visible size as its minimum and fills it, as
  Apple's does. `finch-ruler-test` matches Apple's run, except for the inset that Apple's
  scroll pockets add, which Finch doesn't have.
- 2026-10-09: text blocks and tables, in UIFoundation. `NSTextBlock`, `NSTextTable` and
  `NSTextTableBlock` (`NSTextBlock.m`) keep Apple's values and their types. They archive
  with Apple's keys (`NSParam<n>`, `NSValueTypes` with the vertical alignment in its top
  bits, `NSNumCols`, `NSTableFlags`, `NSRowNum`...), and blocks are equal only to
  themselves. Layout (`UIFTextLayout.m`) puts paragraphs inside their blocks' margins,
  borders and padding. A table's cells share its columns and stand side by side, and a
  row is as tall as its tallest cell. `NSLayoutManager` answers the block rect queries and
  draws block backgrounds and borders. `NSAttributedString` finds the ranges of blocks,
  tables and lists, and item numbers. `NSTextStorage` fixes attributes as Apple's does:
  text with no font gets Helvetica 12, characters the font can't show get CoreText's
  fallback, and a paragraph takes its first character's style. The fixes are done
  quietly, so they don't widen the edits that delegates see. `finch-textblock-test`
  matches Apple's run. Next: RTF tables.
- 2026-10-09: RTF tables. The reader builds `NSTextTable` and `NSTextTableBlock`s from
  `\trowd` row definitions (cells' padding, borders, backgrounds, vertical alignment; the
  table's borders, spread over its rows) and `\intbl`, `\cell` and `\row`. The writer lays
  tables out as Apple's does, row definitions included, and `\colortbl` now holds Generic
  RGB values, as Apple's does. Both match Apple's byte for byte in `finch-rtf-test`.
  `NSTextView` switches to TextKit 1 for text with blocks, as Apple's does, so TextEdit draws
  tables with their backgrounds and borders.

