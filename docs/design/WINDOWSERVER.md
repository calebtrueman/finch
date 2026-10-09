# Finch's window server

Apple's WindowServer and SkyLight are closed, so Finch writes its own
window server and compositor (Phase 2, `docs/ROADMAP.md`). Where its output
goes and where its input comes from is `docs/design/WINDOWSERVER-DISPLAY.md`.
This note covers the server itself and how apps talk to it.

## Pieces

- **`finch-windowserver`** (`userland/WindowServer`): a daemon owning the
  screen. It keeps the windows (frame, level, order, alpha, shadow, title,
  owner), composites them into frames, owns the cursor, and routes input to
  the app that should get it.
- **The client library**, in CoreGraphics (`CGWindowServer.cpp`), with
  Finch-private `FWS*` functions. CoreGraphics' public window, display and
  event APIs are built on it (`CGWindowListCopyWindowInfo`, `CGMainDisplayID`,
  `CGDisplayBounds`, `CGEventPost`, `CGWarpMouseCursorPosition`, ...), and
  Finch's AppKit uses it for its windows and events. On macOS the same split
  is SkyLight's `CGS*` API under AppKit.
- **Backends**, chosen when the server starts: where frames go and where
  input comes from. First the host viewer (frames out over TCP to a window
  on the host, input back the same way: `tools/vz/finch-viewer`), and a
  headless one for tests. A direct-display backend comes with bare metal.

## Protocol

A Unix-domain stream socket (`/tmp/finch-windowserver`, or
`FINCH_WINDOWSERVER_SOCKET`). Every message is a fixed header (type, size,
serial) and a body; requests that need an answer get a reply with the same
serial. Window backing stores are shared memory: the server creates each
one and passes its file descriptor to the client (`SCM_RIGHTS`), which maps
it and draws into it with a CGBitmapContext. The same transport works on
the host, in the Tier 1 and Tier 2 VMs, and on bare metal, and needs no
launchd registration while Finch is developed on macOS.

The messages are in `userland/WindowServer/FinchWSProtocol.h`:

- connection: hello (the client's pid and name) and the display's size,
  scale and refresh rate in reply;
- windows: create (frame, level, flags), set frame, order (in, out, above or
  below another), set level, alpha, opacity, shadow, title, flush (a damaged
  rect, after drawing), destroy; a resize sends a new buffer;
- the cursor: set (standard shape or an image), warp, hide and show;
- queries: the window list (for `CGWindowListCopyWindowInfo`), the display;
- events, server to client: mouse (moved, dragged, down, up, for each
  button), scroll, key (down, up, flags changed), with the window and the
  location in it, the screen location, modifiers, key code (macOS virtual
  key codes), characters, click count and timestamp; window moved; app
  activated; display changed.

## Coordinates and buffers

Window frames are in CG's global display coordinates: the origin at the main
display's top left, y down, in points. Buffers are in pixels at the
display's scale, 8-bit BGRA, premultiplied (`kCGImageAlphaPremultipliedFirst
| kCGBitmapByteOrder32Little`), which Skia draws in place.

## Compositing

The server composites with Skia (the library under Finch's CoreGraphics)
into a frame buffer the size of the display: the desktop, then each
ordered-in window from the back (an image over its shared buffer, with its
alpha and, if it asks, a blurred shadow), then the cursor. It recomposes
only the damaged area, when a window flushes, moves, resizes or changes
order, and hands that rect to the backend.

## Input routing

Mouse events go to the window under the pointer, or, while a button is
held, to the window the press went to. Key events go to the key window: the
last window the active app ordered front and asked to make key. Moving and
resizing windows is the app's business (AppKit tracks the drag and sets the
frame), as on macOS.

## Status

- 2026-10-08: design; server and client in progress.
- 2026-10-08: `finch-windowserver` and CoreGraphics' client work: windows,
  levels and ordering, alpha, shadows, titles, resizing with a new buffer,
  the cursor, input routing (capture while a button is held, click counts,
  the key window, activation), the window list (`CGWindowListCopyWindowInfo`),
  displays (`CGMainDisplayID`, `CGDisplayBounds`, ...), and a snapshot for
  tests. Backends: headless, and the TCP viewer stream (the host viewer is
  next). `finch-ws-test` (Finch-only, against `ws-test.expected`) passes on
  the host and in the VM.
