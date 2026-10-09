// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The subscription behind Merge, MergeMany and the CombineLatests: one downstream,
// several upstreams. Upstreams are asked for everything; what they send waits in a
// queue until the downstream asks for it. Merging, every value goes out in turn;
// combining (`make` given), once each upstream has sent something, every new value
// makes one output from the latest of each, and only the newest output waits.
// A failure ends it at once; it finishes when all its upstreams have (combining:
// or when one finishes without ever sending a value).

import Darwin

internal final class _FinchLock {
    private let l: UnsafeMutablePointer<os_unfair_lock>

    init() {
        l = .allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
    }

    deinit {
        l.deinitialize(count: 1)
        l.deallocate()
    }

    func lock() { os_unfair_lock_lock(l) }
    func unlock() { os_unfair_lock_unlock(l) }
}

internal final class _FinchFanIn<Output, Failure: Error>: Subscription, CustomStringConvertible {
    private let lock = _FinchLock()
    private let name: String
    private var downstream: AnySubscriber<Output, Failure>?
    private var upstreams: [Subscription?]
    private var finished: [Bool]
    private var demand = Subscribers.Demand.none
    private var queue: [Output] = []
    private var completion: Subscribers.Completion<Failure>?
    private var draining = false
    private let make: (([Any]) -> Output)?
    private var latest: [Any?]

    init(_ name: String, count: Int, downstream: AnySubscriber<Output, Failure>, make: (([Any]) -> Output)?) {
        self.name = name
        self.downstream = downstream
        self.make = make
        upstreams = Array(repeating: nil, count: count)
        finished = Array(repeating: false, count: count)
        latest = Array(repeating: nil, count: count)
        if count == 0 {
            completion = .finished
        }
    }

    var description: String { return name }

    /// The subscriber for upstream `index`.
    func side<Input>(_ index: Int, _ input: Input.Type) -> _FinchSide<Input, Failure> {
        return _FinchSide(
            attach: { [weak self] s in self?.attach(index, s) },
            value: { [weak self] v in self?.receive(index, v) },
            done: { [weak self] c in self?.complete(index, c) })
    }

    private func attach(_ index: Int, _ s: Subscription) {
        lock.lock()
        guard downstream != nil, completion == nil else {
            lock.unlock()
            s.cancel()
            return
        }
        upstreams[index] = s
        lock.unlock()
        s.request(.unlimited)
        drain()
    }

    private func receive(_ index: Int, _ value: Any) {
        lock.lock()
        guard downstream != nil, completion == nil else {
            lock.unlock()
            return
        }
        if let make = make {
            latest[index] = value
            if !latest.contains(where: { $0 == nil }) {
                queue = [make(latest.map { $0! })]
            }
        } else {
            queue.append(value as! Output)
        }
        lock.unlock()
        drain()
    }

    private func complete(_ index: Int, _ c: Subscribers.Completion<Failure>) {
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        var others: [Subscription] = []
        switch c {
        case .failure:
            completion = c
            queue.removeAll()
            others = upstreams.enumerated().compactMap { $0.offset == index ? nil : $0.element }
            upstreams = upstreams.map { _ in nil }
        case .finished:
            finished[index] = true
            upstreams[index] = nil
            if !finished.contains(false) || (make != nil && latest[index] == nil) {
                completion = .finished
                others = upstreams.compactMap { $0 }
                upstreams = upstreams.map { _ in nil }
            }
        }
        lock.unlock()
        for s in others {
            s.cancel()
        }
        drain()
    }

    func request(_ d: Subscribers.Demand) {
        lock.lock()
        demand += d
        lock.unlock()
        drain()
    }

    /// Sends what's queued while there's demand, then the completion once the queue is empty.
    private func drain() {
        lock.lock()
        if draining {
            lock.unlock()
            return
        }
        draining = true
        while let ds = downstream {
            if demand > .none, !queue.isEmpty {
                let v = queue.removeFirst()
                demand -= 1
                lock.unlock()
                let more = ds.receive(v)
                lock.lock()
                demand += more
                continue
            }
            if queue.isEmpty, let c = completion {
                downstream = nil
                lock.unlock()
                ds.receive(completion: c)
                lock.lock()
            }
            break
        }
        draining = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        downstream = nil
        let subs = upstreams.compactMap { $0 }
        upstreams = upstreams.map { _ in nil }
        queue.removeAll()
        lock.unlock()
        for s in subs {
            s.cancel()
        }
    }
}

internal struct _FinchSide<Input, Failure: Error>: Subscriber {
    let combineIdentifier = CombineIdentifier()
    let attach: (Subscription) -> Void
    let value: (Any) -> Void
    let done: (Subscribers.Completion<Failure>) -> Void

    func receive(subscription: Subscription) { attach(subscription) }

    func receive(_ input: Input) -> Subscribers.Demand {
        value(input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Failure>) { done(completion) }
}
