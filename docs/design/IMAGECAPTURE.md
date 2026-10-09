# Image Capture's frameworks: ImageCaptureCore, ICADevices, Quartz and ImageKit

Apple's Image Capture app (`/System/Applications/Image Capture.app`) links
three frameworks Finch didn't have: ImageCaptureCore, ICADevices and Quartz.
It binds no symbols from any of them (`tools/check-imports.py`), but they must
exist to load, and at run time its storyboard and code use ImageKit's device
views and ImageCaptureCore's classes. Finch writes all four, as it does its
other frameworks: its own Objective-C (manual retain/release) compiled against
the SDK's headers, installed with Apple's install names and versions.

## How Apple's are built

Measured on the host (macOS 26.4, `dyld_info`, the SDK's `.tbd` files):

- **ImageCaptureCore** (`Versions/A`, current and compatibility version 1,
  bundle version 2020.2.2): `ICDeviceBrowser`, `ICDevice`, `ICCameraDevice`,
  `ICScannerDevice`, the camera items, the scanner functional units and
  features, and 66 string constants. Its browser talks to Apple's Image
  Capture agent; devices are served by device modules.
- **ICADevices** (`Versions/A`, version 1): the C library device modules are
  built on (`ICD_main`, `ICDNewObject`, connect/disconnect calls, the callback
  tables). The SDK's headers declare 64 of its exports; the rest are private.
- **Quartz** (`Versions/A`, version 1, bundle 1.5): no code of its own. It
  re-exports QuartzCore, PDFKit, QuickLookUI and three subframeworks inside it:
  ImageKit, QuartzComposer and QuartzFilters.
- **ImageKit** (`Quartz.framework/Versions/A/Frameworks/ImageKit.framework`,
  version 1, bundle 3.0/1233): the image browser and view, picture taker,
  slideshow, filter UI, and the device views `IKDeviceBrowserView`,
  `IKCameraDeviceView` and `IKScannerDeviceView`; 161 string constants.

## Finch's

`userland/ImageCaptureCore`, `userland/ICADevices`, `userland/Quartz`
(ImageKit in `userland/Quartz/ImageKit`), built by `tools/build-system.sh`
after Cocoa.

- **No devices yet.** Finch has no device modules or agent, so
  `ICDeviceBrowser` finds nothing. It behaves as Apple's does on a Mac with
  nothing attached: `browsedDeviceTypeMask` starts as camera | local (0x101),
  `devices` is an empty array, `-start` without a delegate is ignored, and with
  one it browses and sends `deviceBrowserDidEnumerateLocalDevices:` from the
  main run loop. The add and remove paths (Apple's `-addDevice:moreComing:`,
  `-removeDevice:moreGoing:`) are there for device modules to come.
- The device, item and scanner classes carry the headers' properties
  (synthesized); their requests fail with `ICErrorDomain` errors.
- **ICADevices** is the public API with nothing behind it: connecting fails
  with `kICADeviceNotFoundErr`, anything for the agent with
  `kICACommunicationErr`, `ICD_main` returns 1.
- **Quartz re-exports what Finch has**: QuartzCore and ImageKit. dyld only needs
  the libraries Quartz lists, so apps that link Quartz load. Apps that bind
  PDFKit or Quick Look symbols through it wait for those frameworks. PDFKit is
  a later task. QuartzComposer and QuartzFilters are deprecated.
- **ImageKit** has the three device views and every string constant (values
  read from Apple's with `dlsym`). `IKDeviceBrowserView` runs its own
  `ICDeviceBrowser` once it is in a window and passes the news to its
  delegate, including the private `deviceBrowserView:deviceBrowserDidEnumerateLocalDevices:`
  and `deviceBrowserView:numberOfDevicesChanged:` that Image Capture
  implements. It draws Apple's "DEVICES" and "SHARED" headings with a
  "No Devices" placeholder (Apple's is a source-list table). The camera and
  scanner views keep their properties with Apple's defaults, including the
  private ones Image Capture sets (`setAux*Control:`, the scan-panel options).
  They draw an empty list and nothing respectively. The image browser, image
  view, picture taker, slideshow and filter UI come later.

## Testing

`finch-imagekit-test` (`userland/tests/imagekit-test.m`) prints the
constants, classes, `ICDeviceBrowser`'s browsing, and the three views'
defaults, properties and delegate calls outside and inside a window. The
recorded host and VM runs match Apple's host output, all but the first line
(the loaded library's path). On the host, `DYLD_FRAMEWORK_PATH` must also include
`build/root/System/Library/Frameworks/Quartz.framework/Frameworks`: dyld looks
up a nested framework by its own name, so without it the process loads Apple's
ImageKit (and with it Apple's Quartz world). Run it with no camera or scanner
attached to the host.

## Status

- 2026-10-09: the four frameworks. `finch-imagekit-test` matches Apple's on
  the host and in the VM (`38a733e`). The unmodified Image Capture app launches
  on the host on Finch's frameworks and headless window server. Its window
  shows the device list with "DEVICES", "No Devices", "SHARED" and the
  no-device pane. To get there
  AppKit gained `NSSplitViewItem -initWithCoder:` and toolbar items from nibs
  (`NSToolbarItem -initWithCoder:`, Apple's private `NSToolbarFlexibleSpaceItem`,
  `NSToolbarSpaceItem`, `NSToolbarSeparatorItem`).
- 2026-10-09: CoreFoundation reads `.loctable` files, uses `AppleLanguages`,
  and matches languages through Apple's ICU (`52f174f`). `NSBundle` uses that
  support, so Image Capture can show its English strings when English is the
  user's preferred language. `finch-l10n-test` matched Apple's on the host.
- 2026-10-09: the app shows its title bar and toolbar (`ff499c9`). AppKit now
  draws them over full-size content windows, attaches the toolbar stored in
  the nib, and uses its saved items for the delegate's item identifiers.
  The toolbar is empty with no device selected, as on macOS. `finch-app-test`
  also gained `screenshot:PATH` for saving the whole screen as a PNG. The AppKit
  comparison and window-server tests still matched.

## Still to do

The app's recorded launch and window check ran on the host with Finch's
frameworks and headless window server. Launching the full app inside the VM
remains unverified; the VM result above covers the framework comparison test.

Real cameras and scanners still need device modules and an agent. Without
them, browsing stays empty, and import and scan requests cannot succeed.
ImageKit's general image browser, image view, picture taker, slideshow and
filter UI remain unfinished. AppKit also lacks Apple's unified toolbar style
with the title and items in one row. See `docs/design/APPKIT.md` for the window
and toolbar details.
