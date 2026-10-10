// SPDX-License-Identifier: MIT OR Apache-2.0
// Runtime paths used by the Swift overlays: generic classes, protocol tables,
// tasks, regexes, locking and backtraces. Compare Apple and Finch output.
import Dispatch
import RegexBuilder
import Runtime
import Synchronization

protocol ValueSource {
    associatedtype Value
    func read() -> Value
}

class Box<Value>: ValueSource {
    var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { value }
}

final class IntBox: Box<Int> {
    override func read() -> Int { super.read() + 1 }
}

actor Counter {
    private var value = 0
    func add(_ amount: Int) { value += amount }
    func read() -> Int { value }
}

/// Copies through the value witnesses (an unspecialized generic copy).
@inline(never)
func copies<T>(_ value: T) -> [T] {
    [value, value]
}

func read<Source: ValueSource>(_ source: Source) -> Source.Value {
    source.read()
}

@inline(never)
func checkBacktrace() throws {
    let trace = try Backtrace.capture(limit: 16)
    let frames = Array(trace.frames)
    print("backtrace captured:", !frames.isEmpty)
    let resolved = trace.symbolicated(options: [])
    print("backtrace resolved:", resolved?.frames.contains { $0.symbol != nil } == true)
}

@main
struct RuntimeTest {
    static func main() async throws {
        let nested = Box(["one": [1, nil, 3]])
        print("generic values:", read(nested)["one"]! as [Int?])
        print("class override:", read(IntBox(6)))
        let source: any ValueSource = nested
        print("existential cast:", source is Box<[String: [Int?]]>)
        let collection = AnyCollection([2, 4, 6])
        print("collection witnesses:", Array(collection), collection.reduce(0, +))
        let set = Set([Box(3).read(), 1, 3])
        print("hash witnesses:", set.sorted())
        let expression = Regex { OneOrMore(.digit) }
        print("regex:", String("Finch 123".firstMatch(of: expression)!.output))
        let mutex = Mutex(3)
        mutex.withLock { $0 += 4 }
        print("mutex:", mutex.withLock { $0 })
        // enums with payloads, copied through the witnesses of generic types (as the
        // attribute graph compares view values)
        let range = 1...20
        let second = range.index(after: range.startIndex)
        print("enum payload copies:", copies(second) == [second, second], copies(Optional(second)).count,
              copies(range.endIndex) == [range.endIndex, range.endIndex])
        let anyIndex: Any = second
        print("existential enum:", (anyIndex as? ClosedRange<Int>.Index) == second)
        print("POD witnesses:", _isPOD(Int.self), _isPOD(ClosedRange<Int>.Index.self), _isPOD(Optional<Int>.self))
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for value in 1...8 { group.addTask { await counter.add(value) } }
        }
        print("actor tasks:", await counter.read())
        let detached = Task.detached { [5, 6, 7].reduce(0, +) }
        print("detached task:", await detached.value)
        try checkBacktrace()
        print("finch-swift-runtime-test: ok")
    }
}
