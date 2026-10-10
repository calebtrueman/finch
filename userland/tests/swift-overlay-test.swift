// SPDX-License-Identifier: MIT OR Apache-2.0
// The Swift overlays (docs/design/FOUNDATION.md, "The Swift overlays"): a
// Swift program that uses what apps use from Foundation's and AppKit's Swift
// halves and from /usr/lib/swift's overlay libraries. Its output must be the
// same against Apple's libraries and Finch's (on the host, with
// DYLD_FRAMEWORK_PATH and DYLD_LIBRARY_PATH pointing at build/root; in the
// VM, as is). Where each library came from goes to stderr.
import AppKit
import Dispatch
import Foundation
import os

setvbuf(stdout, nil, _IOLBF, 0)

func show(_ label: String, _ value: Any) { print("\(label): \(value)") }

// MARK: Where the code comes from (stderr: differs by design)
func origin(_ name: String, _ address: UnsafeRawPointer?) {
    var info = Dl_info()
    if let address, dladdr(address, &info) != 0, let path = info.dli_fname {
        FileHandle.standardError.write("origin \(name): \(String(cString: path))\n".data(using: .utf8)!)
    }
}
origin("Foundation", unsafeBitCast(class_getMethodImplementation(NSString.self, NSSelectorFromString("uppercaseString")), to: UnsafeRawPointer.self))
if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$sSa10FoundationE19_bridgeToObjectiveCSo7NSArrayCyF") {
    origin("Array bridging", UnsafeRawPointer(sym))
}
for (lib, sym) in [("libswiftCore", "swift_retain"), ("libswiftObjectiveC", "$sSo8NSObjectC10ObjectiveCE2eeoiySbAB_ABtFZ"),
                   ("libswiftDispatch", "$sSo17OS_dispatch_queueC8DispatchE4syncyyyyXEF"),
                   ("libswiftCoreFoundation", "$s12CoreGraphics7CGFloatVMn"),
                   ("libswiftos", "$s2os6LoggerVMn"),
                   ("libswift_Concurrency", "swift_task_create")] {
    if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), sym) { origin(lib, UnsafeRawPointer(p)) }
}

// MARK: Array, Dictionary, Set and String bridging
print("== bridging")
let swiftArray = [3, 1, 2]
let nsArray = swiftArray as NSArray
show("NSArray count", nsArray.count)
show("NSArray sorted", (nsArray.sortedArray(using: #selector(NSNumber.compare(_:))) as! [Int]))
let back = nsArray as! [Int]
show("round trip", back)
let mixed: [Any] = ["a", 1, 2.5, true, ["nested": [1, 2]]]
show("mixed", (mixed as NSArray).description.replacingOccurrences(of: "\n", with: " "))
let dict: [String: Int] = ["b": 2, "a": 1]
let nsDict = dict as NSDictionary
show("NSDictionary keys", (nsDict.allKeys as! [String]).sorted())
show("dict back", (nsDict as! [String: Int]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
let set: Set<String> = ["x", "y"]
show("NSSet count", (set as NSSet).count)
let ns: NSString = "Hello, Finch"
let str = ns as String
show("String from NSString", str)
show("NSString from String", ("swift" as NSString).uppercased)
show("components", "a,b,,c".components(separatedBy: ","))
show("trimmed", "  padded \n".trimmingCharacters(in: .whitespacesAndNewlines))
show("range", "Hello, world".range(of: "world").map { "Hello, world"[$0] } ?? "nil")
show("NSRange", NSRange("Hello, world".range(of: "world")!, in: "Hello, world"))
show("format", String(format: "%d-%@-%.2f", 42, "x", 3.14159))
show("anyhashable", AnyHashable("k") == AnyHashable("k" as NSString))
// a native Swift string beyond ASCII, copied into a mutable CF string (as attributed strings do)
var native = "Plain"; native += " \u{2014} dash \u{1F426}"
let appended = NSMutableString(); appended.append(native)
show("append non-ASCII", appended as String == native)
show("attributed non-ASCII", NSMutableAttributedString(string: native).string == native)

// MARK: Data
print("== data")
var data = Data([0x46, 0x69, 0x6e, 0x63, 0x68])
show("data string", String(data: data, encoding: .utf8) ?? "nil")
data.append(contentsOf: [0x21])
show("data count", data.count)
show("base64", data.base64EncodedString())
let nsData = data as NSData
show("NSData length", nsData.length)
show("data back", (nsData as Data) == data)
show("subdata", Array(data[1..<3]))
let big = Data(repeating: 7, count: 100_000)
show("big", "\(big.count) \(big.reduce(0) { $0 + Int($1) })")

// MARK: URL
print("== url")
let url = URL(string: "https://example.com/path/to/file.txt?q=1#frag")!
show("host", url.host ?? "nil")
show("path", url.path)
show("lastPathComponent", url.lastPathComponent)
show("pathExtension", url.pathExtension)
show("query", url.query ?? "nil")
show("appending", url.deletingLastPathComponent().appendingPathComponent("other.md").absoluteString)
let fileURL = URL(fileURLWithPath: "/tmp/finch dir/file.txt")
show("file url", fileURL.absoluteString)
show("isFileURL", fileURL.isFileURL)
let nsurl = url as NSURL
show("NSURL", nsurl.absoluteString ?? "nil")
show("URL back", (nsurl as URL) == url)
var comps = URLComponents(string: "https://example.com/a?b=1&c=2")!
comps.queryItems?.append(URLQueryItem(name: "d", value: "3"))
show("components", comps.url?.absoluteString ?? "nil")

// MARK: Value types
print("== values")
let date = Date(timeIntervalSince1970: 1_000_000_000)
show("date", date.timeIntervalSinceReferenceDate)
show("NSDate", (date as NSDate).timeIntervalSince1970)
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!
let dc = cal.dateComponents([.year, .month, .day, .hour], from: date)
show("components", "\(dc.year!)-\(dc.month!)-\(dc.day!) \(dc.hour!)")
let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
show("uuid", uuid.uuidString)
show("NSUUID", (uuid as NSUUID).uuidString)
var indexes = IndexSet(integersIn: 2..<5)
indexes.insert(9)
show("IndexSet", Array(indexes))
show("NSIndexSet", (indexes as NSIndexSet).count)
show("IndexSet ranges", indexes.rangeView.map { "\($0.lowerBound)..<\($0.upperBound)" })
show("IndexSet range slice", indexes.rangeView(of: 3..<10).map { "\($0.lowerBound)..<\($0.upperBound)" })
let path = IndexPath(indexes: [1, 2, 3])
show("IndexPath", "\(path.count) \(path[1])")
let note = Notification(name: Notification.Name("FinchTest"), object: nil, userInfo: ["k": 1])
show("notification", "\(note.name.rawValue) \(note.userInfo?["k"] as? Int ?? 0)")
show("CharacterSet", CharacterSet.decimalDigits.contains("7"))
let m = Measurement(value: 1.5, unit: UnitLength.kilometers)
show("measurement", m.converted(to: .meters).value)
let cg: CGFloat = 1.5
show("CGFloat", cg * 2 + CGFloat(Double(3)))
show("CGRect", NSStringFromRect(NSRect(x: 1, y: 2, width: 3, height: 4)))

// MARK: Errors
print("== errors")
do {
    _ = try Data(contentsOf: URL(fileURLWithPath: "/nonexistent/finch"))
} catch let error as CocoaError {
    show("CocoaError", error.code == .fileReadNoSuchFile)
} catch {
    show("other error", type(of: error))
}
struct MyError: Error {}
let nsError = MyError() as NSError
show("custom NSError", nsError.domain.hasSuffix("MyError"))
struct ExplainedError: LocalizedError {
    var errorDescription: String? { "A test error" }
    var failureReason: String? { "A test reason" }
    var recoverySuggestion: String? { "Try the test again" }
}
let explained = ExplainedError() as NSError
show("localized error", explained.localizedDescription)
show("error reason", explained.localizedFailureReason ?? "missing")
show("error recovery", explained.localizedRecoverySuggestion ?? "missing")

// MARK: Codable
print("== codable")
struct Point: Codable, Equatable { var x: Int; var y: String }
let encoder = JSONEncoder()
encoder.outputFormatting = .sortedKeys
let json = try! encoder.encode([Point(x: 1, y: "a")])
show("json", String(data: json, encoding: .utf8)!)
show("decoded", try! JSONDecoder().decode([Point].self, from: json) == [Point(x: 1, y: "a")])
let plist = try! PropertyListEncoder().encode(Point(x: 2, y: "b"))
show("plist", try! PropertyListDecoder().decode(Point.self, from: plist).x)

// MARK: ObjectiveC
print("== objc")
let o1 = NSObject(), o2 = NSObject()
show("NSObject ==", (o1 == o1, o1 == o2))
show("Selector", NSStringFromSelector(#selector(NSObject.description)))
show("ObjCBool", ObjCBool(true).boolValue)

// MARK: Dispatch and concurrency
print("== dispatch")
let queue = DispatchQueue(label: "org.finch.test")
var counter = 0
let group = DispatchGroup()
for _ in 0..<10 { queue.async(group: group) { counter += 1 } }
group.wait()
show("counter", queue.sync { counter })
let semaphore = DispatchSemaphore(value: 0)
DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) { semaphore.signal() }
show("semaphore", semaphore.wait(timeout: .now() + 5) == .success)
let done = DispatchSemaphore(value: 0)
nonisolated(unsafe) var taskResult = 0
Task {
    async let a = Task { 20 }.value
    async let b = Task { 22 }.value
    taskResult = await a + b
    done.signal()
}
done.wait()
show("async", taskResult)

// MARK: os
print("== os")
let logger = Logger(subsystem: "org.finch.test", category: "overlay")
logger.info("Swift overlay test \(42, privacy: .public)")
os_log("os_log from Swift: %{public}@", "ok")
show("logger", "ok")

// MARK: AppKit
print("== appkit")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 16, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 4, height: 4).fill(using: .copy)
NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1).set()
NSRect(x: 0, y: 0, width: 4, height: 4).frame(withWidth: 1, using: .copy)
NSGraphicsContext.restoreGraphicsState()
let corner = rep.colorAt(x: 0, y: 0)!, center = rep.colorAt(x: 1, y: 1)!
show("frame pixel", (Int(corner.redComponent * 255), Int(corner.blueComponent * 255)))
show("fill pixel", (Int(center.redComponent * 255), Int(center.blueComponent * 255)))
show("special key", NSEvent.SpecialKey.upArrow.rawValue)
show("IndexPath item", IndexPath(item: 3, section: 1).item)
print("== done")
