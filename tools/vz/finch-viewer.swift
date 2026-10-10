// SPDX-License-Identifier: MIT OR Apache-2.0
//
// finch-viewer: the host end of finch-windowserver's viewer backend
// (docs/design/WINDOWSERVER.md). A host-side dev tool, like finch-vz: it
// uses the host's AppKit, and is not part of Finch.
//
//   finch-viewer [host[:port]] [--dump PATH [--frames N]] [--test-input X,Y]
//
// Connects over TCP (default 127.0.0.1:5901), retrying until the server is
// up and again whenever it goes away. The server sends FWS_VIEWER_HELLO (the
// display's size in pixels and its scale), then FWS_VIEWER_FRAME messages
// (a damaged rect in pixels and its BGRA premultiplied rows), which are
// applied to a copy of the screen drawn in a window the display's size in
// points. Mouse, scroll and key events go back as FWS_VIEWER_INPUT: an
// FWSEvent with CGEventType's type values and screen coordinates in points
// (origin top-left of the Finch display, y down). The server draws its own
// cursor, so the host's is hidden over the view.
//
// For tests: --dump writes the view's rendering as a PNG after N frames
// (default 1) and exits; --test-input posts a click, a right click, a scroll
// and a key press at X,Y (points) through the view's event handlers, then exits.
//
// The protocol's structs come from userland/WindowServer/FinchWSProtocol.h
// (-import-objc-header; see build-viewer.sh).

import AppKit
import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(("finch-viewer: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(("finch-viewer: " + message + "\n").data(using: .utf8)!)
}

// MARK: - Arguments

var host = "127.0.0.1"
var port = UInt16(FWS_VIEWER_PORT)
var dumpPath: String?
var dumpFrames = 1
var testInput: NSPoint?
/// The server is at the other end of a serial line (the VM's tunnel UART behind QEMU's TCP
/// port): attach to it, find the sync marker, and take deflated frames.
var lineMode = false

do {
    var args = CommandLine.arguments.dropFirst()
    func next(_ flag: String) -> String {
        guard let v = args.popFirst() else { die("\(flag) needs a value") }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "--line": lineMode = true
        case "--dump": dumpPath = next(a)
        case "--frames": dumpFrames = max(1, Int(next(a)) ?? 1)
        case "--test-input":
            let xy = next(a).split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { die("--test-input takes X,Y") }
            testInput = NSPoint(x: xy[0], y: xy[1])
        case "-h", "--help":
            print("usage: finch-viewer [host[:port]] [--line] [--dump PATH [--frames N]] [--test-input X,Y]")
            exit(0)
        default:
            if a.hasPrefix("-") { die("unknown option \(a)") }
            // host, host:port, :port, or [v6]:port
            if a.hasPrefix("["), let close = a.firstIndex(of: "]") {
                host = String(a[a.index(after: a.startIndex)..<close])
                let rest = a[a.index(after: close)...]
                if rest.hasPrefix(":") { port = UInt16(rest.dropFirst()) ?? port }
            } else if a.filter({ $0 == ":" }).count == 1, let colon = a.firstIndex(of: ":") {
                if colon != a.startIndex { host = String(a[..<colon]) }
                guard let p = UInt16(a[a.index(after: colon)...]) else { die("bad port in \(a)") }
                port = p
            } else {
                host = a
            }
        }
    }
}

// MARK: - The screen copy

// Written by the connection's thread, read by the main thread to draw.
final class Screen {
    let lock = NSLock()
    private(set) var pixelWidth = 0, pixelHeight = 0
    private(set) var scale = 1.0
    private var pixels = [UInt8]()

    func reset(width: Int, height: Int, scale: Double) {
        lock.lock()
        defer { lock.unlock() }
        pixelWidth = width
        pixelHeight = height
        self.scale = scale
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    // rows: width * height BGRA pixels, tightly packed
    func apply(x: Int, y: Int, width: Int, height: Int, rows: UnsafeRawBufferPointer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard x >= 0, y >= 0, width >= 0, height >= 0, x + width <= pixelWidth, y + height <= pixelHeight,
              rows.count >= width * height * 4 else { return false }
        let stride = pixelWidth * 4, rowBytes = width * 4
        pixels.withUnsafeMutableBytes { dst in
            for row in 0..<height {
                memcpy(dst.baseAddress! + (y + row) * stride + x * 4, rows.baseAddress! + row * rowBytes, rowBytes)
            }
        }
        return true
    }

    func image() -> CGImage? {
        lock.lock()
        let data = Data(pixels)
        let w = pixelWidth, h = pixelHeight
        lock.unlock()
        guard w > 0, h > 0, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                                          CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

let screen = Screen()

// MARK: - The connection

func readFully(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) -> Bool {
    var got = 0
    while got < n {
        let r = read(fd, p + got, n - got)
        if r < 0 && errno == EINTR { continue }
        if r <= 0 { return false }
        got += r
    }
    return true
}

func readStruct<T>(_ fd: Int32, _ value: inout T) -> Bool {
    withUnsafeMutableBytes(of: &value) { readFully(fd, $0.baseAddress!, $0.count) }
}

func skip(_ fd: Int32, _ n: Int) -> Bool {
    var scratch = [UInt8](repeating: 0, count: min(n, 65536))
    var left = n
    while left > 0 {
        let chunk = min(left, scratch.count)
        if !scratch.withUnsafeMutableBytes({ readFully(fd, $0.baseAddress!, chunk) }) { return false }
        left -= chunk
    }
    return true
}

final class Connection {
    private let lock = NSLock()
    private var fd: Int32 = -1
    var onHello: (Int, Int, Double) -> Void = { _, _, _ in }
    var onFrame: () -> Void = {}
    var onState: (Bool) -> Void = { _ in }

    func start() {
        Thread.detachNewThread { self.run() }
    }

    private func connect() -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return -1 }
        defer { freeaddrinfo(res) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                // a send/receive timeout bounds the connect as well
                var limit = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                if Darwin.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                    var none = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
                    var one: Int32 = 1
                    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    return s
                }
                close(s)
            }
            ai = a.pointee.ai_next
        }
        return -1
    }

    private func run() {
        var waiting = false
        while true {
            let s = connect()
            if s < 0 {
                if !waiting { log("waiting for the window server at \(host):\(port)") }
                waiting = true
                usleep(500_000)
                continue
            }
            waiting = false
            log("connected to \(host):\(port)")
            lock.lock()
            fd = s
            lock.unlock()
            onState(true)
            if !lineMode || attach(s) {
                session(s)
            }
            lock.lock()
            fd = -1
            lock.unlock()
            close(s)
            if !lineMode { log("disconnected") }
            onState(false)
            usleep(500_000)
        }
    }

    /// On a serial line: waits for the server's beacon (sending nothing before it: see
    /// FWS_VIEWER_BEACON), asks for the display, and reads up to the sync marker.
    private func attach(_ s: Int32) -> Bool {
        let beacon = Array(FWS_VIEWER_BEACON.utf8), sync = Array(FWS_VIEWER_SYNC.utf8)
        var tail = [UInt8]()
        while true {
            var byte: UInt8 = 0
            let n = read(s, &byte, 1)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            tail.append(byte)
            if tail.count > 8 { tail.removeFirst() }
            if tail == beacon {
                var h = FWSViewerHeader(type: UInt32(FWS_VIEWER_ATTACH), length: 0)
                guard write(s, &h, MemoryLayout<FWSViewerHeader>.size) == MemoryLayout<FWSViewerHeader>.size else {
                    return false
                }
            } else if tail == sync {
                log("attached to the window server on the line")
                return true
            }
        }
    }

    // Reads messages until the stream ends or goes wrong.
    private func session(_ s: Int32) {
        var rows = [UInt8]()
        while true {
            var h = FWSViewerHeader()
            guard readStruct(s, &h) else { return }
            let length = Int(h.length)
            switch h.type {
            case UInt32(FWS_VIEWER_HELLO) where length >= MemoryLayout<FWSViewerHello>.size:
                var hello = FWSViewerHello()
                guard readStruct(s, &hello), skip(s, length - MemoryLayout<FWSViewerHello>.size) else { return }
                let w = Int(hello.pixel_width), ht = Int(hello.pixel_height)
                let sc = hello.scale > 0 ? hello.scale : 1
                screen.reset(width: w, height: ht, scale: sc)
                log("display \(w)x\(ht) pixels at \(sc)x")
                onHello(w, ht, sc)
            case UInt32(FWS_VIEWER_FRAME) where length >= MemoryLayout<FWSViewerFrame>.size:
                var f = FWSViewerFrame()
                guard readStruct(s, &f) else { return }
                let n = length - MemoryLayout<FWSViewerFrame>.size
                if rows.count < n { rows = [UInt8](repeating: 0, count: n) }
                guard rows.withUnsafeMutableBytes({ readFully(s, $0.baseAddress!, n) }) else { return }
                let ok = rows.withUnsafeBytes {
                    screen.apply(x: Int(f.x), y: Int(f.y), width: Int(f.width), height: Int(f.height),
                                 rows: UnsafeRawBufferPointer(rebasing: $0[0..<n]))
                }
                if !ok {
                    log("bad frame rect \(f.x),\(f.y) \(f.width)x\(f.height)")
                    continue
                }
                onFrame()
            case UInt32(FWS_VIEWER_FRAME_DEFLATED) where length >= MemoryLayout<FWSViewerFrame>.size:
                var f = FWSViewerFrame()
                guard readStruct(s, &f) else { return }
                let n = length - MemoryLayout<FWSViewerFrame>.size
                var packed = Data(count: n)
                guard packed.withUnsafeMutableBytes({ readFully(s, $0.baseAddress!, n) }) else { return }
                guard let raw = try? (packed as NSData).decompressed(using: .zlib) as Data,
                      raw.count == Int(f.width) * Int(f.height) * 4 else {
                    log("bad deflated frame \(f.x),\(f.y) \(f.width)x\(f.height)")
                    continue
                }
                let ok = raw.withUnsafeBytes {
                    screen.apply(x: Int(f.x), y: Int(f.y), width: Int(f.width), height: Int(f.height), rows: $0)
                }
                if ok { onFrame() }
            default:
                guard skip(s, length) else { return }
            }
        }
    }

    func send(_ event: FWSEvent) {
        var h = FWSViewerHeader(type: UInt32(FWS_VIEWER_INPUT), length: UInt32(MemoryLayout<FWSEvent>.size))
        var e = event
        var out = Data()
        withUnsafeBytes(of: &h) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &e) { out.append(contentsOf: $0) }
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        out.withUnsafeBytes { p in
            var sent = 0
            while sent < p.count {
                let n = write(fd, p.baseAddress! + sent, p.count - sent)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }  // the reading side notices and reconnects
                sent += n
            }
        }
    }
}

let connection = Connection()

// MARK: - The view

// Characters as FWSEvent's fixed UTF-16 arrays.
func fill(_ tuple: inout (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16), _ s: String) -> UInt32 {
    let units = Array(s.utf16.prefix(8))
    withUnsafeMutableBytes(of: &tuple) { p in
        let a = p.bindMemory(to: UInt16.self)
        for (i, u) in units.enumerated() { a[i] = u }
    }
    return UInt32(units.count)
}

final class ScreenView: NSView {
    // The server draws its own cursor.
    private let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true },
                                       hotSpot: .zero)

    override var isFlipped: Bool { true }  // y down, as on the Finch display
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: blankCursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image = screen.image(), let cg = NSGraphicsContext.current?.cgContext else { return }
        let backing = window?.backingScaleFactor ?? 1
        cg.interpolationQuality = abs(backing - screen.scale) < 0.01 ? .none : .high
        // CGContext draws images bottom-up; undo the view's flip for it
        cg.saveGState()
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: bounds)
        cg.restoreGState()
    }

    // MARK: Input

    private func event(_ type: Int32, _ ns: NSEvent) -> FWSEvent {
        var e = FWSEvent()
        e.type = UInt32(type)
        e.timestamp = ns.timestamp
        // CGEventFlags; NSEvent's device-independent flags share their bits
        e.modifiers = ns.cgEvent?.flags.rawValue ?? UInt64(ns.modifierFlags.rawValue)
        let p = location(ns)
        e.screen_x = Double(p.x)
        e.screen_y = Double(p.y)
        return e
    }

    // In the view, so on the Finch display: points, y down.
    private func location(_ ns: NSEvent) -> NSPoint {
        guard let window else { return .zero }
        switch ns.type {
        case .keyDown, .keyUp, .flagsChanged:  // where the mouse is
            return convert(window.mouseLocationOutsideOfEventStream, from: nil)
        default:
            // an event with no window has its location in screen coordinates
            let w = ns.window === window ? ns.locationInWindow : window.convertPoint(fromScreen: ns.locationInWindow)
            return convert(w, from: nil)
        }
    }

    private func mouse(_ type: Int32, _ ns: NSEvent) {
        var e = event(type, ns)
        switch Int(type) {  // CGMouseButton: 0 left, 1 right, then the others
        case FWS_EVENT_LEFT_DOWN, FWS_EVENT_LEFT_UP, FWS_EVENT_LEFT_DRAGGED, FWS_EVENT_MOUSE_MOVED: e.button = 0
        case FWS_EVENT_RIGHT_DOWN, FWS_EVENT_RIGHT_UP, FWS_EVENT_RIGHT_DRAGGED: e.button = 1
        default: e.button = UInt32(max(2, ns.buttonNumber))
        }
        e.delta_x = Double(ns.deltaX)
        e.delta_y = Double(ns.deltaY)
        connection.send(e)
    }

    private func key(_ type: Int32, _ ns: NSEvent) {
        var e = event(type, ns)
        e.key_code = UInt32(ns.keyCode)
        if ns.type != .flagsChanged {  // .characters raises for flagsChanged
            e.is_repeat = ns.isARepeat ? 1 : 0
            e.length = fill(&e.characters, ns.characters ?? "")
            _ = fill(&e.unmodified, ns.charactersIgnoringModifiers ?? "")
        }
        connection.send(e)
    }

    override func mouseMoved(with ns: NSEvent) { mouse(Int32(FWS_EVENT_MOUSE_MOVED), ns) }
    override func mouseDown(with ns: NSEvent) { mouse(Int32(FWS_EVENT_LEFT_DOWN), ns) }
    override func mouseUp(with ns: NSEvent) { mouse(Int32(FWS_EVENT_LEFT_UP), ns) }
    override func mouseDragged(with ns: NSEvent) { mouse(Int32(FWS_EVENT_LEFT_DRAGGED), ns) }
    override func rightMouseDown(with ns: NSEvent) { mouse(Int32(FWS_EVENT_RIGHT_DOWN), ns) }
    override func rightMouseUp(with ns: NSEvent) { mouse(Int32(FWS_EVENT_RIGHT_UP), ns) }
    override func rightMouseDragged(with ns: NSEvent) { mouse(Int32(FWS_EVENT_RIGHT_DRAGGED), ns) }
    override func otherMouseDown(with ns: NSEvent) { mouse(Int32(FWS_EVENT_OTHER_DOWN), ns) }
    override func otherMouseUp(with ns: NSEvent) { mouse(Int32(FWS_EVENT_OTHER_UP), ns) }
    override func otherMouseDragged(with ns: NSEvent) { mouse(Int32(FWS_EVENT_OTHER_DRAGGED), ns) }

    override func scrollWheel(with ns: NSEvent) {
        var e = event(Int32(FWS_EVENT_SCROLL), ns)
        // points; a wheel's line steps are about 10 points
        let lines = ns.hasPreciseScrollingDeltas ? 1.0 : 10.0
        e.delta_x = Double(ns.scrollingDeltaX) * lines
        e.delta_y = Double(ns.scrollingDeltaY) * lines
        connection.send(e)
    }

    override func keyDown(with ns: NSEvent) { key(Int32(FWS_EVENT_KEY_DOWN), ns) }
    override func keyUp(with ns: NSEvent) { key(Int32(FWS_EVENT_KEY_UP), ns) }
    override func flagsChanged(with ns: NSEvent) { key(Int32(FWS_EVENT_FLAGS_CHANGED), ns) }

    // Command-key combinations are Finch's too (close the viewer with its close button)
    override func performKeyEquivalent(with ns: NSEvent) -> Bool {
        guard ns.type == .keyDown, window?.firstResponder === self else { return false }
        keyDown(with: ns)
        return true
    }

    // MARK: Tests

    // Posts synthetic AppKit events through the handlers above, as the user would.
    func postTestInput(at p: NSPoint) {
        guard let window else { return }
        let loc = convert(p, to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        func m(_ type: NSEvent.EventType, _ clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func k(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ chars: String, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: t,
                             windowNumber: window.windowNumber, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        mouseMoved(with: m(.mouseMoved, 0))
        mouseDown(with: m(.leftMouseDown, 1))
        mouseUp(with: m(.leftMouseUp, 1))
        rightMouseDown(with: m(.rightMouseDown, 1))
        rightMouseUp(with: m(.rightMouseUp, 1))
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 3, wheel3: 0) {
            let w = window.convertPoint(toScreen: loc)
            cg.location = CGPoint(x: w.x, y: NSScreen.screens[0].frame.height - w.y)  // CG: global, y down
            if let ns = NSEvent(cgEvent: cg) { scrollWheel(with: ns) }
        }
        flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: t,
                                            windowNumber: window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        keyDown(with: k(.keyDown, .shift, "A", 0))
        keyUp(with: k(.keyUp, .shift, "A", 0))
        log("posted test input at \(p.x),\(p.y)")
    }
}

// MARK: - The app

final class Viewer: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let view = ScreenView()
    var frames = 0
    var redrawPending = false
    var testDone = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.contentView = view
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "Finch: waiting for \(host):\(port)"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        connection.onHello = { w, h, scale in
            DispatchQueue.main.async { self.resize(w, h, scale) }
        }
        connection.onState = { up in
            DispatchQueue.main.async {
                self.window.title = up ? "Finch (\(host):\(port))" : "Finch: waiting for \(host):\(port)"
            }
        }
        connection.onFrame = {
            DispatchQueue.main.async { self.frameArrived() }
        }
        connection.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func resize(_ w: Int, _ h: Int, _ scale: Double) {
        let size = NSSize(width: Double(w) / scale, height: Double(h) / scale)
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        window.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }

    func frameArrived() {
        frames += 1
        view.needsDisplay = true
        if let p = testInput, !testDone {
            testDone = true
            view.postTestInput(at: p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if dumpPath == nil { exit(0) } }
        }
        if let path = dumpPath, frames >= dumpFrames {
            dump(path)
            exit(0)
        }
    }

    // The view's rendering (at the window's backing scale) as a PNG.
    func dump(_ path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { die("can't render the view") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { die("can't encode PNG") }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            die("can't write \(path): \(error.localizedDescription)")
        }
        log("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh)) after \(frames) frame(s)")
    }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let viewer = Viewer()
app.delegate = viewer
app.setActivationPolicy(.regular)
app.run()
