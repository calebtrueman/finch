// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Collecting by time, as Apple's Combine declares it: the upstream's values gather
// into an array that goes out at every stride of the scheduler's clock (and, with
// byTimeOrCount, whenever it reaches the count). An empty window sends nothing.
// What's gathered goes out before a finish; a failure goes at once.

extension Publisher {
    public func collect<S>(_ strategy: Publishers.TimeGroupingStrategy<S>, options: S.SchedulerOptions? = nil)
        -> Publishers.CollectByTime<Self, S> where S: Scheduler
    {
        return Publishers.CollectByTime(upstream: self, strategy: strategy, options: options)
    }
}

extension Publishers {
    public enum TimeGroupingStrategy<Context> where Context: Scheduler {
        case byTime(Context, Context.SchedulerTimeType.Stride)
        case byTimeOrCount(Context, Context.SchedulerTimeType.Stride, Int)
    }

    public struct CollectByTime<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = [Upstream.Output]
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let strategy: TimeGroupingStrategy<Context>
        public let options: Context.SchedulerOptions?

        public init(upstream: Upstream, strategy: TimeGroupingStrategy<Context>, options: Context.SchedulerOptions?) {
            self.upstream = upstream
            self.strategy = strategy
            self.options = options
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, S.Input == [Upstream.Output] {
            let inner = _FinchCollectByTime<Upstream.Output, Failure, Context>(
                downstream: AnySubscriber(subscriber), strategy: strategy, options: options)
            upstream.subscribe(inner)
        }
    }
}

internal final class _FinchCollectByTime<Input, Failure: Error, Context: Scheduler>: Subscriber, Subscription,
    CustomStringConvertible
{
    let combineIdentifier = CombineIdentifier()
    private let lock = _FinchLock()
    private var downstream: AnySubscriber<[Input], Failure>?
    private var upstream: Subscription?
    private var timer: Cancellable?
    private let scheduler: Context
    private let stride: Context.SchedulerTimeType.Stride
    private let limit: Int
    private let options: Context.SchedulerOptions?
    private var window: [Input] = []
    private var ready: [[Input]] = []
    private var demand = Subscribers.Demand.none
    private var completion: Subscribers.Completion<Failure>?
    private var draining = false

    init(downstream: AnySubscriber<[Input], Failure>, strategy: Publishers.TimeGroupingStrategy<Context>,
         options: Context.SchedulerOptions?)
    {
        self.downstream = downstream
        self.options = options
        switch strategy {
        case let .byTime(s, t):
            scheduler = s
            stride = t
            limit = .max
        case let .byTimeOrCount(s, t, n):
            scheduler = s
            stride = t
            limit = max(n, 1)
        }
    }

    var description: String { return "CollectByTime" }

    func receive(subscription: Subscription) {
        lock.lock()
        upstream = subscription
        let ds = downstream
        lock.unlock()
        ds?.receive(subscription: self)
        timer = scheduler.schedule(after: scheduler.now.advanced(by: stride), interval: stride, tolerance: scheduler.minimumTolerance,
                                   options: options) { [weak self] in self?.tick() }
        subscription.request(.unlimited)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        window.append(input)
        if window.count >= limit {
            ready.append(window)
            window = []
        }
        lock.unlock()
        drain()
        return .none
    }

    func receive(completion c: Subscribers.Completion<Failure>) {
        lock.lock()
        if case .finished = c, !window.isEmpty {
            ready.append(window)
        } else if case .failure = c {
            ready.removeAll()
        }
        window = []
        completion = c
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
        drain()
    }

    private func tick() {
        lock.lock()
        if !window.isEmpty {
            ready.append(window)
            window = []
        }
        lock.unlock()
        drain()
    }

    func request(_ d: Subscribers.Demand) {
        lock.lock()
        demand += d
        lock.unlock()
        drain()
    }

    private func drain() {
        lock.lock()
        if draining {
            lock.unlock()
            return
        }
        draining = true
        while let ds = downstream {
            if demand > .none, !ready.isEmpty {
                let v = ready.removeFirst()
                demand -= 1
                lock.unlock()
                let more = ds.receive(v)
                lock.lock()
                demand += more
                continue
            }
            if ready.isEmpty, let c = completion {
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
        let u = upstream, t = timer
        upstream = nil
        timer = nil
        lock.unlock()
        u?.cancel()
        t?.cancel()
    }
}
