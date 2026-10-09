// SPDX-License-Identifier: MIT OR Apache-2.0
//
// finch-combine-test: Combine's publishers, subscribers and subjects, run the same
// against Apple's Combine and Finch's (DYLD_FRAMEWORK_PATH); diff all but the first
// line. Everything is synchronous or on a virtual-time scheduler, so the output is
// the same every run.

import Combine
import Darwin

func show(_ s: String) { print(s) }

/// Records a publisher's events, asking for `demand` up front.
final class Recorder<Input, Failure: Error>: Subscriber {
    let combineIdentifier = CombineIdentifier()
    var events: [String] = []
    var subscription: Subscription?
    let demand: Subscribers.Demand
    init(_ demand: Subscribers.Demand = .unlimited) { self.demand = demand }
    func receive(subscription: Subscription) {
        self.subscription = subscription
        events.append("subscribed")
        if demand > .none { subscription.request(demand) }
    }
    func receive(_ input: Input) -> Subscribers.Demand {
        events.append("\(input)")
        return .none
    }
    func receive(completion: Subscribers.Completion<Failure>) {
        switch completion {
        case .finished: events.append("finished")
        case .failure(let e): events.append("failure(\(e))")
        }
    }
}

func run<P: Publisher>(_ label: String, _ p: P, demand: Subscribers.Demand = .unlimited, after: ((Recorder<P.Output, P.Failure>) -> Void)? = nil) {
    let r = Recorder<P.Output, P.Failure>(demand)
    p.subscribe(r)
    after?(r)
    show("\(label): \(r.events.joined(separator: " "))")
}

enum Oops: Error, CustomStringConvertible {
    case bad
    var description: String { return "bad" }
}

/// A scheduler whose clock moves only when told to.
final class VirtualScheduler: Scheduler {
    struct Time: Strideable, Comparable {
        var t: Int
        func distance(to other: Time) -> Stride { return Stride(other.t - t) }
        func advanced(by n: Stride) -> Time { return Time(t: t + n.n) }
        struct Stride: SchedulerTimeIntervalConvertible, Comparable, SignedNumeric, ExpressibleByIntegerLiteral {
            var n: Int
            init(_ n: Int) { self.n = n }
            init(integerLiteral v: Int) { n = v }
            init?<T: BinaryInteger>(exactly source: T) { n = Int(source) }
            var magnitude: Int { return abs(n) }
            static func seconds(_ s: Int) -> Stride { return Stride(s) }
            static func seconds(_ s: Double) -> Stride { return Stride(Int(s)) }
            static func milliseconds(_ ms: Int) -> Stride { return Stride(ms / 1000) }
            static func microseconds(_ us: Int) -> Stride { return Stride(0) }
            static func nanoseconds(_ ns: Int) -> Stride { return Stride(0) }
            static func < (a: Stride, b: Stride) -> Bool { return a.n < b.n }
            static func + (a: Stride, b: Stride) -> Stride { return Stride(a.n + b.n) }
            static func - (a: Stride, b: Stride) -> Stride { return Stride(a.n - b.n) }
            static func * (a: Stride, b: Stride) -> Stride { return Stride(a.n * b.n) }
            static func += (a: inout Stride, b: Stride) { a.n += b.n }
            static func -= (a: inout Stride, b: Stride) { a.n -= b.n }
            static func *= (a: inout Stride, b: Stride) { a.n *= b.n }
        }
    }
    typealias SchedulerTimeType = Time
    typealias SchedulerOptions = Never
    var now = Time(t: 0)
    var minimumTolerance: Time.Stride { return 0 }
    private var queue: [(Time, Int, () -> Void, Time.Stride?)] = []
    private var seq = 0
    func schedule(options: Never?, _ action: @escaping () -> Void) { action() }
    func schedule(after date: Time, tolerance: Time.Stride, options: Never?, _ action: @escaping () -> Void) {
        seq += 1
        queue.append((date, seq, action, nil))
    }
    final class Token: Cancellable {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    func schedule(after date: Time, interval: Time.Stride, tolerance: Time.Stride, options: Never?, _ action: @escaping () -> Void) -> Cancellable {
        let token = Token()
        func repeating(_ at: Time) {
            seq += 1
            queue.append((at, seq, { if !token.cancelled { action(); repeating(at.advanced(by: interval)) } }, nil))
        }
        repeating(date)
        return token
    }
    func advance(to t: Int) {
        while true {
            queue.sort { $0.0.t != $1.0.t ? $0.0.t < $1.0.t : $0.1 < $1.1 }
            guard let first = queue.first, first.0.t <= t else { break }
            queue.removeFirst()
            now = first.0
            first.2()
        }
        now = Time(t: t)
    }
}

final class Model: ObservableObject {
    @Published var count = 0
    @Published var name = "a"
}

@main
struct Main {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var info = Dl_info()
        let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s7Combine14AnyCancellableCMa")
        dladdr(sym, &info)
        show(info.dli_fname.map { String(cString: $0) } ?? "?")

        run("Just", Just(1))
        run("Just map filter", Just(4).map { $0 * 2 }.filter { $0 > 5 })
        run("Empty", Empty<Int, Never>())
        run("Fail", Fail<Int, Oops>(error: .bad))
        run("Sequence", [1, 2, 3].publisher)
        run("Sequence demand 2", [1, 2, 3].publisher, demand: .max(2))
        run("Optional some", Optional(5).publisher)
        run("Optional none", Optional<Int>.none.publisher)
        run("Result success", Result<Int, Oops>.success(7).publisher)
        run("Result failure", Result<Int, Oops>.failure(.bad).publisher)
        run("Just setFailureType", Just(3).setFailureType(to: Oops.self))
        run("scan reduce", [1, 2, 3, 4].publisher.scan(0, +).reduce(0, +))
        run("collect", [1, 2, 3, 4, 5].publisher.collect(2))
        run("removeDuplicates", [1, 1, 2, 2, 1].publisher.removeDuplicates())
        run("compactMap first last", ["1", "x", "3"].publisher.compactMap { Int($0) })
        run("prefix dropFirst", (1...10).publisher.dropFirst(3).prefix(3))
        run("flatMap", [1, 2].publisher.flatMap { [$0, $0 * 10].publisher })
        run("tryMap failure", [1, 2, 3].publisher.tryMap { v -> Int in if v == 2 { throw Oops.bad }; return v })
        run("catch", Fail<Int, Oops>(error: .bad).catch { _ in Just(99) })
        run("replaceError", Fail<Int, Oops>(error: .bad).replaceError(with: 0))
        run("count min max", [3, 1, 2].publisher.count())
        run("allSatisfy contains", [2, 4].publisher.allSatisfy { $0 % 2 == 0 })
        run("zip", [1, 2, 3].publisher.zip(["a", "b"].publisher))
        run("merge", [1, 2].publisher.merge(with: [3, 4].publisher))
        run("merge3", [1].publisher.merge(with: [2].publisher, [3].publisher))
        run("MergeMany", Publishers.MergeMany([[1].publisher, [2, 3].publisher, [4].publisher]))
        run("combineLatest", [1, 2].publisher.combineLatest(["a", "b"].publisher))
        run("combineLatest transform", [1].publisher.combineLatest([10].publisher) { $0 + $1 })
        run("combineLatest3", Just(1).combineLatest(Just("b"), Just(true)))
        run("combineLatest empty", Just(1).combineLatest(Empty<Int, Never>()))

        // subjects
        let pass = PassthroughSubject<Int, Oops>()
        run("PassthroughSubject", pass) { _ in pass.send(1); pass.send(2); pass.send(completion: .failure(.bad)); pass.send(3) }
        let current = CurrentValueSubject<String, Never>("first")
        run("CurrentValueSubject", current) { _ in current.send("second"); current.value = "third"; current.send(completion: .finished) }
        show("CurrentValueSubject value: \(current.value)")

        // live subjects through merge and combineLatest, with demand
        let s1 = PassthroughSubject<Int, Never>(), s2 = PassthroughSubject<Int, Never>()
        run("merge live", s1.merge(with: s2)) { _ in s1.send(1); s2.send(2); s1.send(3); s1.send(completion: .finished); s2.send(4); s2.send(completion: .finished) }
        let c1 = PassthroughSubject<Int, Never>(), c2 = PassthroughSubject<String, Never>()
        run("combineLatest live", c1.combineLatest(c2)) { _ in c1.send(1); c1.send(2); c2.send("a"); c1.send(3); c2.send("b"); c1.send(completion: .finished); c2.send("c"); c2.send(completion: .finished) }
        let d1 = PassthroughSubject<Int, Never>(), d2 = PassthroughSubject<Int, Never>()
        run("merge demand", d1.merge(with: d2), demand: .max(1)) { r in d1.send(1); d2.send(2); r.subscription?.request(.max(1)); d1.send(3) }

        // sink and assign, cancellation
        var got: [Int] = []
        let sinkSubject = PassthroughSubject<Int, Never>()
        let token = sinkSubject.sink { got.append($0) }
        sinkSubject.send(1)
        token.cancel()
        sinkSubject.send(2)
        show("sink then cancel: \(got)")
        final class Box { var v = 0 }
        let box = Box()
        let assigned = [5, 6].publisher.assign(to: \.v, on: box)
        show("assign: \(box.v)")
        _ = assigned
        var bag = Set<AnyCancellable>()
        Just(1).sink { _ in }.store(in: &bag)
        show("store: \(bag.count)")
        show("AnyPublisher: \(type(of: Just(1).eraseToAnyPublisher()))")

        // ObservableObject and @Published
        let model = Model()
        var changes = 0
        var counts: [Int] = []
        let w = model.objectWillChange.sink { changes += 1 }
        let c = model.$count.sink { counts.append($0) }
        model.count = 1
        model.count = 2
        model.name = "b"
        show("objectWillChange \(changes) counts \(counts)")
        _ = (w, c)

        // schedulers
        run("receive(on: ImmediateScheduler)", [1, 2].publisher.receive(on: ImmediateScheduler.shared))
        let vs = VirtualScheduler()
        let timed = PassthroughSubject<Int, Never>()
        run("collect byTime", timed.collect(.byTime(vs, 10))) { _ in
            timed.send(1); timed.send(2); vs.advance(to: 10); timed.send(3); vs.advance(to: 25); vs.advance(to: 30); timed.send(4); timed.send(completion: .finished)
        }
        let counted = PassthroughSubject<Int, Never>()
        let vs2 = VirtualScheduler()
        run("collect byTimeOrCount", counted.collect(.byTimeOrCount(vs2, 10, 2))) { _ in
            counted.send(1); counted.send(2); counted.send(3); vs2.advance(to: 10); counted.send(completion: .finished)
        }
        let deb = PassthroughSubject<Int, Never>()
        let vs3 = VirtualScheduler()
        run("debounce", deb.debounce(for: 5, scheduler: vs3)) { _ in
            deb.send(1); vs3.advance(to: 2); deb.send(2); vs3.advance(to: 10); deb.send(3); vs3.advance(to: 20)
        }
        show("Demand: \(Subscribers.Demand.max(3)) \(Subscribers.Demand.unlimited) \(Subscribers.Demand.none + 2)")
    }
}
