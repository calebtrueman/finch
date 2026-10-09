// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Foundation's Combine integration, as Apple's Foundation declares it: key-value observing,
// notification and timer publishers, URLSession data-task publishers, RunLoop and
// OperationQueue as schedulers, and the coders as Combine's top-level coders. Finch's own
// (with OpenCombineFoundation, MIT, as a guide); Combine is Finch's (userland/Combine).

import Combine
import Dispatch

// MARK: - Key-value observing

public protocol _KeyValueCodingAndObservingPublishing {}

extension NSObject: _KeyValueCodingAndObservingPublishing {}

extension _KeyValueCodingAndObservingPublishing where Self: NSObject {
    public func publisher<Value>(for keyPath: KeyPath<Self, Value>,
                                 options: NSKeyValueObservingOptions = [.initial, .new]) -> NSObject.KeyValueObservingPublisher<Self, Value>
    {
        NSObject.KeyValueObservingPublisher(object: self, keyPath: keyPath, options: options)
    }
}

extension NSObject.KeyValueObservingPublisher {
    public func didChange() -> Publishers.Map<NSObject.KeyValueObservingPublisher<Subject, Value>, Void> {
        map { _ in () }
    }
}

extension NSObject {
    public struct KeyValueObservingPublisher<Subject: NSObject, Value>: Equatable {
        public let object: Subject
        public let keyPath: KeyPath<Subject, Value>
        public let options: NSKeyValueObservingOptions

        public init(object: Subject, keyPath: KeyPath<Subject, Value>, options: NSKeyValueObservingOptions) {
            self.object = object
            self.keyPath = keyPath
            self.options = options
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.object === rhs.object && lhs.keyPath == rhs.keyPath && lhs.options == rhs.options
        }
    }
}

extension NSObject.KeyValueObservingPublisher: @unchecked Sendable {}

extension NSObject.KeyValueObservingPublisher: Combine.Publisher {
    public typealias Output = Value
    public typealias Failure = Never

    public func receive<S>(subscriber: S) where Value == S.Input, S: Subscriber, S.Failure == Never {
        let subscription = _FinchKVOSubscription(object: object, keyPath: keyPath, options: options, downstream: subscriber)
        subscriber.receive(subscription: subscription)
        subscription.start()
    }
}

private final class _FinchKVOSubscription<Subject: NSObject, Value, Downstream: Subscriber>: Subscription
    where Downstream.Input == Value, Downstream.Failure == Never
{
    private let lock = NSLock()
    private var downstream: Downstream?
    private var observation: NSKeyValueObservation?
    private var demand = Subscribers.Demand.none
    private let object: Subject
    private let keyPath: KeyPath<Subject, Value>
    private let options: NSKeyValueObservingOptions

    init(object: Subject, keyPath: KeyPath<Subject, Value>, options: NSKeyValueObservingOptions, downstream: Downstream) {
        self.object = object
        self.keyPath = keyPath
        self.options = options
        self.downstream = downstream
    }

    func start() {
        observation = object.observe(keyPath, options: options) { [weak self] object, change in
            guard let self else { return }
            let value = change.newValue ?? object[keyPath: self.keyPath]
            self.send(value)
        }
    }

    private func send(_ value: Value) {
        lock.lock()
        guard let ds = downstream, demand > .none else {
            lock.unlock()
            return
        }
        demand -= 1
        lock.unlock()
        let more = ds.receive(value)
        lock.lock()
        demand += more
        lock.unlock()
    }

    func request(_ d: Subscribers.Demand) {
        lock.lock()
        demand += d
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        downstream = nil
        let o = observation
        observation = nil
        lock.unlock()
        o?.invalidate()
    }
}

// MARK: - Notifications

extension NotificationCenter {
    public func publisher(for name: Notification.Name, object: AnyObject? = nil) -> NotificationCenter.Publisher {
        Publisher(center: self, name: name, object: object)
    }

    public struct Publisher: Combine.Publisher {
        public typealias Output = Notification
        public typealias Failure = Never

        public let center: NotificationCenter
        public let name: Notification.Name
        public let object: AnyObject?

        public init(center: NotificationCenter, name: Notification.Name, object: AnyObject? = nil) {
            self.center = center
            self.name = name
            self.object = object
        }

        public func receive<S>(subscriber: S) where S: Subscriber, S.Failure == Never, S.Input == Notification {
            let s = _FinchNotificationSubscription(center: center, name: name, object: object, downstream: subscriber)
            subscriber.receive(subscription: s)
        }
    }
}

extension NotificationCenter.Publisher: @unchecked Sendable {}

extension NotificationCenter.Publisher: Equatable {
    public static func == (lhs: NotificationCenter.Publisher, rhs: NotificationCenter.Publisher) -> Bool {
        lhs.center === rhs.center && lhs.name == rhs.name && lhs.object === rhs.object
    }
}

private final class _FinchNotificationSubscription<Downstream: Subscriber>: Subscription
    where Downstream.Input == Notification, Downstream.Failure == Never
{
    private let lock = NSLock()
    private var downstream: Downstream?
    private var demand = Subscribers.Demand.none
    private var token: NSObjectProtocol?
    private let center: NotificationCenter

    init(center: NotificationCenter, name: Notification.Name, object: AnyObject?, downstream: Downstream) {
        self.center = center
        self.downstream = downstream
        token = center.addObserver(forName: name, object: object, queue: nil) { [weak self] note in self?.send(note) }
    }

    private func send(_ note: Notification) {
        lock.lock()
        guard let ds = downstream, demand > .none else {
            lock.unlock()
            return
        }
        demand -= 1
        lock.unlock()
        let more = ds.receive(note)
        lock.lock()
        demand += more
        lock.unlock()
    }

    func request(_ d: Subscribers.Demand) {
        lock.lock()
        demand += d
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        downstream = nil
        let t = token
        token = nil
        lock.unlock()
        if let t { center.removeObserver(t) }
    }
}

// MARK: - Timers

extension Timer {
    public static func publish(every interval: TimeInterval, tolerance: TimeInterval? = nil, on runLoop: RunLoop,
                               in mode: RunLoop.Mode, options: RunLoop.SchedulerOptions? = nil) -> TimerPublisher
    {
        TimerPublisher(interval: interval, tolerance: tolerance, runLoop: runLoop, mode: mode, options: options)
    }

    /// Fires on the run loop once connected, sending each subscriber the date as it asks for them.
    public final class TimerPublisher: ConnectablePublisher {
        public typealias Output = Date
        public typealias Failure = Never

        public final let interval: TimeInterval
        public final let tolerance: TimeInterval?
        public final let runLoop: RunLoop
        public final let mode: RunLoop.Mode
        public final let options: RunLoop.SchedulerOptions?

        private let lock = NSLock()
        private var subscribers: [CombineIdentifier: (subject: PassthroughSubject<Date, Never>, cancel: AnyCancellable)] = [:]
        private let subject = PassthroughSubject<Date, Never>()
        private var timer: Timer?

        public init(interval: TimeInterval, tolerance: TimeInterval? = nil, runLoop: RunLoop, mode: RunLoop.Mode,
                    options: RunLoop.SchedulerOptions? = nil)
        {
            self.interval = interval
            self.tolerance = tolerance
            self.runLoop = runLoop
            self.mode = mode
            self.options = options
        }

        deinit {
            timer?.invalidate()
        }

        public final func connect() -> Cancellable {
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.subject.send(Date()) }
            if let tolerance { t.tolerance = tolerance }
            lock.lock()
            timer?.invalidate()
            timer = t
            lock.unlock()
            runLoop.add(t, forMode: mode)
            return AnyCancellable { [weak self] in
                t.invalidate()
                self?.subject.send(completion: .finished)
            }
        }

        public final func receive<S>(subscriber: S) where S: Subscriber, S.Failure == Never, S.Input == Date {
            subject.receive(subscriber: subscriber)
        }
    }
}

extension Timer.TimerPublisher: @unchecked Sendable {}

// MARK: - URLSession

extension URLSession {
    public func dataTaskPublisher(for url: URL) -> DataTaskPublisher {
        DataTaskPublisher(request: URLRequest(url: url), session: self)
    }

    public func dataTaskPublisher(for request: URLRequest) -> DataTaskPublisher {
        DataTaskPublisher(request: request, session: self)
    }

    public struct DataTaskPublisher: Combine.Publisher, Sendable {
        public typealias Output = (data: Data, response: URLResponse)
        public typealias Failure = URLError

        public let request: URLRequest
        public let session: URLSession

        public init(request: URLRequest, session: URLSession) {
            self.request = request
            self.session = session
        }

        public func receive<S>(subscriber: S) where S: Subscriber, S.Failure == URLError, S.Input == (data: Data, response: URLResponse) {
            let request = self.request, session = self.session
            Deferred {
                Future<(data: Data, response: URLResponse), URLError> { promise in
                    session.dataTask(with: request) { data, response, error in
                        if let error {
                            promise(.failure(error as? URLError ?? URLError(.unknown)))
                        } else if let response {
                            promise(.success((data ?? Data(), response)))
                        } else {
                            promise(.failure(URLError(.badServerResponse)))
                        }
                    }.resume()
                }
            }.receive(subscriber: subscriber)
        }
    }
}

// MARK: - Coders

extension JSONEncoder: TopLevelEncoder {
    public typealias Output = Data
}

extension PropertyListEncoder: TopLevelEncoder {
    public typealias Output = Data
}

extension JSONDecoder: TopLevelDecoder {
    public typealias Input = Data
}

extension PropertyListDecoder: TopLevelDecoder {
    public typealias Input = Data
}

// MARK: - Schedulers

extension RunLoop: Combine.Scheduler {
    public struct SchedulerTimeType: Strideable, Codable, Hashable, Sendable {
        public var date: Date

        public init(_ date: Date) { self.date = date }

        public func distance(to other: SchedulerTimeType) -> Stride {
            Stride(other.date.timeIntervalSince(date))
        }

        public func advanced(by n: Stride) -> SchedulerTimeType {
            SchedulerTimeType(date.addingTimeInterval(n.timeInterval))
        }

        public struct Stride: ExpressibleByFloatLiteral, Comparable, SignedNumeric, Codable, SchedulerTimeIntervalConvertible, Sendable {
            public typealias FloatLiteralType = TimeInterval
            public typealias IntegerLiteralType = TimeInterval
            public typealias Magnitude = TimeInterval

            public var magnitude: TimeInterval
            public var timeInterval: TimeInterval { magnitude }

            public init(integerLiteral value: TimeInterval) { magnitude = value }
            public init(floatLiteral value: TimeInterval) { magnitude = value }
            public init(_ timeInterval: TimeInterval) { magnitude = timeInterval }
            public init?<T: BinaryInteger>(exactly source: T) {
                guard let v = TimeInterval(exactly: source) else { return nil }
                magnitude = v
            }

            public static func < (lhs: Stride, rhs: Stride) -> Bool { lhs.magnitude < rhs.magnitude }
            public static func * (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude * rhs.magnitude) }
            public static func + (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude + rhs.magnitude) }
            public static func - (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude - rhs.magnitude) }
            public static func *= (lhs: inout Stride, rhs: Stride) { lhs.magnitude *= rhs.magnitude }
            public static func += (lhs: inout Stride, rhs: Stride) { lhs.magnitude += rhs.magnitude }
            public static func -= (lhs: inout Stride, rhs: Stride) { lhs.magnitude -= rhs.magnitude }

            public static func seconds(_ s: Int) -> Stride { Stride(TimeInterval(s)) }
            public static func seconds(_ s: Double) -> Stride { Stride(s) }
            public static func milliseconds(_ ms: Int) -> Stride { Stride(TimeInterval(ms) / 1_000) }
            public static func microseconds(_ us: Int) -> Stride { Stride(TimeInterval(us) / 1_000_000) }
            public static func nanoseconds(_ ns: Int) -> Stride { Stride(TimeInterval(ns) / 1_000_000_000) }
        }
    }

    public struct SchedulerOptions: Sendable {}

    public func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void) {
        perform(action)
    }

    public func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, options: SchedulerOptions?,
                         _ action: @escaping () -> Void)
    {
        let timer = Timer(fire: date.date, interval: 0, repeats: false) { _ in action() }
        timer.tolerance = tolerance.timeInterval
        add(timer, forMode: .default)
    }

    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride,
                         options: SchedulerOptions?, _ action: @escaping () -> Void) -> Cancellable
    {
        let timer = Timer(fire: date.date, interval: interval.timeInterval, repeats: true) { _ in action() }
        timer.tolerance = tolerance.timeInterval
        add(timer, forMode: .default)
        return AnyCancellable { timer.invalidate() }
    }

    public var now: SchedulerTimeType { SchedulerTimeType(Date()) }
    public var minimumTolerance: SchedulerTimeType.Stride { 0 }
}

extension OperationQueue: Combine.Scheduler {
    public struct SchedulerTimeType: Strideable, Codable, Hashable, Sendable {
        public var date: Date

        public init(_ date: Date) { self.date = date }

        public func distance(to other: SchedulerTimeType) -> Stride {
            Stride(other.date.timeIntervalSince(date))
        }

        public func advanced(by n: Stride) -> SchedulerTimeType {
            SchedulerTimeType(date.addingTimeInterval(n.timeInterval))
        }

        public struct Stride: ExpressibleByFloatLiteral, Comparable, SignedNumeric, Codable, SchedulerTimeIntervalConvertible, Sendable {
            public typealias FloatLiteralType = TimeInterval
            public typealias IntegerLiteralType = TimeInterval
            public typealias Magnitude = TimeInterval

            public var magnitude: TimeInterval
            public var timeInterval: TimeInterval { magnitude }

            public init(integerLiteral value: TimeInterval) { magnitude = value }
            public init(floatLiteral value: TimeInterval) { magnitude = value }
            public init(_ timeInterval: TimeInterval) { magnitude = timeInterval }
            public init?<T: BinaryInteger>(exactly source: T) {
                guard let v = TimeInterval(exactly: source) else { return nil }
                magnitude = v
            }

            public static func < (lhs: Stride, rhs: Stride) -> Bool { lhs.magnitude < rhs.magnitude }
            public static func * (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude * rhs.magnitude) }
            public static func + (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude + rhs.magnitude) }
            public static func - (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude - rhs.magnitude) }
            public static func *= (lhs: inout Stride, rhs: Stride) { lhs.magnitude *= rhs.magnitude }
            public static func += (lhs: inout Stride, rhs: Stride) { lhs.magnitude += rhs.magnitude }
            public static func -= (lhs: inout Stride, rhs: Stride) { lhs.magnitude -= rhs.magnitude }

            public static func seconds(_ s: Int) -> Stride { Stride(TimeInterval(s)) }
            public static func seconds(_ s: Double) -> Stride { Stride(s) }
            public static func milliseconds(_ ms: Int) -> Stride { Stride(TimeInterval(ms) / 1_000) }
            public static func microseconds(_ us: Int) -> Stride { Stride(TimeInterval(us) / 1_000_000) }
            public static func nanoseconds(_ ns: Int) -> Stride { Stride(TimeInterval(ns) / 1_000_000_000) }
        }
    }

    public struct SchedulerOptions: Sendable {}

    public func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void) {
        addOperation(action)
    }

    public func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, options: SchedulerOptions?,
                         _ action: @escaping () -> Void)
    {
        let delay = Swift.max(0, date.date.timeIntervalSinceNow)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.addOperation(action) }
    }

    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride,
                         options: SchedulerOptions?, _ action: @escaping () -> Void) -> Cancellable
    {
        let source = DispatchSource.makeTimerSource()
        source.schedule(deadline: .now() + Swift.max(0, date.date.timeIntervalSinceNow), repeating: interval.timeInterval,
                        leeway: .nanoseconds(Int(tolerance.timeInterval * 1_000_000_000)))
        source.setEventHandler { [weak self] in self?.addOperation(action) }
        source.resume()
        return AnyCancellable { source.cancel() }
    }

    public var now: SchedulerTimeType { SchedulerTimeType(Date()) }
    public var minimumTolerance: SchedulerTimeType.Stride { 0 }
}
