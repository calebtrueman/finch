// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Foundation's asynchronous byte sequences, at Apple's ABI: the shared byte buffer
// their iterators inline (_AsyncBytesBuffer), the byte sequences of file handles, URLs
// and URL sessions, and the sequences that decode bytes into Unicode scalars,
// characters and lines. Stored layouts of the frozen iterators are Apple's; the code
// is Finch's.

// MARK: - The buffer

/// What refills an `_AsyncBytesBuffer`: the buffer's memory and a reader that fills it.
final class _AsyncBytesStorage: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let capacity: Int
    /// Fills the buffer, returning the count of bytes read (0 at the end).
    var reader: ((UnsafeMutableRawBufferPointer) async throws -> Int)?

    init(capacity: Int) {
        self.capacity = Swift.max(capacity, 1)
        base = UnsafeMutableRawPointer.allocate(byteCount: self.capacity, alignment: 1)
    }

    deinit { base.deallocate() }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
@frozen @usableFromInline
internal struct _AsyncBytesBuffer: @unchecked Sendable {
    internal var storage: AnyObject? = nil
    @usableFromInline internal var nextPointer: UnsafeMutableRawPointer
    @usableFromInline internal var endPointer: UnsafeMutableRawPointer

    @usableFromInline
    internal init(capacity: Int) {
        let s = _AsyncBytesStorage(capacity: capacity)
        storage = s
        nextPointer = s.base
        endPointer = s.base
    }

    init(capacity: Int, reader: @escaping (UnsafeMutableRawBufferPointer) async throws -> Int) {
        self.init(capacity: capacity)
        (storage as! _AsyncBytesStorage).reader = reader
    }

    @usableFromInline @inline(never)
    internal mutating func reloadBufferAndNext() async throws -> UInt8? {
        guard let s = storage as? _AsyncBytesStorage, let reader = s.reader else { return nil }
        let n = try await reader(UnsafeMutableRawBufferPointer(start: s.base, count: s.capacity))
        guard n > 0 else {
            s.reader = nil
            return nil
        }
        nextPointer = s.base + 1
        endPointer = s.base + n
        return s.base.load(as: UInt8.self)
    }

    @inlinable @inline(__always)
    internal mutating func next() async throws -> UInt8? {
        guard nextPointer == endPointer else {
            defer { nextPointer += 1 }
            return nextPointer.load(as: UInt8.self)
        }
        return try await reloadBufferAndNext()
    }
}

/// A reader that hands out a `Data` in buffer-sized pieces.
private func dataReader(_ data: Data) -> (UnsafeMutableRawBufferPointer) async throws -> Int {
    var offset = data.startIndex
    return { buffer in
        let count = Swift.min(buffer.count, data.endIndex - offset)
        guard count > 0 else { return 0 }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: offset..<offset + count)
        offset += count
        return count
    }
}

private let bufferSize = 16384

// MARK: - FileHandle

extension FileHandle {
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public struct AsyncBytes: AsyncSequence, Sendable {
        public typealias Element = UInt8
        public typealias AsyncIterator = Iterator

        let handle: FileHandle

        @frozen
        public struct Iterator: AsyncIteratorProtocol, Sendable {
            public typealias Element = UInt8
            @usableFromInline internal var buffer: _AsyncBytesBuffer

            @inlinable @inline(__always)
            public mutating func next() async throws -> UInt8? { try await buffer.next() }
        }

        public func makeAsyncIterator() -> Iterator {
            let fd = handle.fileDescriptor
            return Iterator(buffer: _AsyncBytesBuffer(capacity: bufferSize) { buffer in
                while true {
                    let n = read(fd, buffer.baseAddress, buffer.count)
                    if n >= 0 { return n }
                    if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                }
            })
        }
    }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public var bytes: AsyncBytes { AsyncBytes(handle: self) }
}

// MARK: - URL

extension URL {
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public struct AsyncBytes: AsyncSequence, Sendable {
        public typealias Element = UInt8

        let url: URL

        @frozen
        public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
            @usableFromInline internal var buffer: _AsyncBytesBuffer = _AsyncBytesBuffer(capacity: 0)

            @inlinable @inline(__always)
            public mutating func next() async throws -> UInt8? { try await buffer.next() }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            let url = self.url
            var reader: ((UnsafeMutableRawBufferPointer) async throws -> Int)? = nil
            // The resource opens on the first read: a file's handle, otherwise a session load.
            return AsyncIterator(buffer: _AsyncBytesBuffer(capacity: bufferSize) { buffer in
                if reader == nil {
                    if url.isFileURL {
                        let handle = try FileHandle(forReadingFrom: url)
                        let fd = handle.fileDescriptor
                        reader = { buffer in
                            _ = handle
                            return read(fd, buffer.baseAddress, buffer.count)
                        }
                    } else {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        reader = dataReader(data)
                    }
                }
                return try await reader!(buffer)
            })
        }
    }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public var resourceBytes: AsyncBytes { AsyncBytes(url: self) }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public var lines: AsyncLineSequence<AsyncBytes> { resourceBytes.lines }
}

// MARK: - URLSession

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension URLSession {
    public struct AsyncBytes: AsyncSequence, Sendable {
        public typealias Element = UInt8
        public typealias AsyncIterator = Iterator

        public var task: URLSessionDataTask { _task }
        let _task: URLSessionDataTask
        let data: Data

        @frozen
        public struct Iterator: AsyncIteratorProtocol, Sendable {
            public typealias Element = UInt8
            @usableFromInline internal var buffer: _AsyncBytesBuffer

            @inlinable @inline(__always)
            public mutating func next() async throws -> UInt8? { try await buffer.next() }
        }

        public __consuming func makeAsyncIterator() -> Iterator {
            Iterator(buffer: _AsyncBytesBuffer(capacity: bufferSize, reader: dataReader(data)))
        }
    }

    /// Runs a task to completion, cancelling it with the calling task.
    private func run<T>(_ make: (@escaping @Sendable (T?, URLResponse?, Error?) -> Void) -> URLSessionTask,
                        delegate: URLSessionTaskDelegate?) async throws -> (T, URLResponse, URLSessionTask) {
        let box = _TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(T, URLResponse, URLSessionTask), Error>) in
                var task: URLSessionTask!
                task = make { result, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let result, let response {
                        continuation.resume(returning: (result, response, task))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                if let delegate { task.delegate = delegate }
                box.start(task)
            }
        } onCancel: {
            box.cancel()
        }
    }

    public func data(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        let (data, response, _) = try await run({ dataTask(with: request, completionHandler: $0) }, delegate: delegate)
        return (data, response)
    }

    public func data(from url: URL, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url), delegate: delegate)
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        try await upload(for: request, from: Data(contentsOf: fileURL), delegate: delegate)
    }

    public func upload(for request: URLRequest, from bodyData: Data, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        let (data, response, _) = try await run({ uploadTask(with: request, from: bodyData, completionHandler: $0) }, delegate: delegate)
        return (data, response)
    }

    /// Downloads to a temporary file the caller owns (the session's own copy is removed
    /// once the completion handler returns).
    public func download(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (URL, URLResponse) {
        let (url, response, _) = try await run({ handler in
            downloadTask(with: request) { location, response, error in
                var kept: URL? = nil
                if let location {
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("CFNetworkDownload_\(UUID().uuidString).tmp")
                    if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { kept = dest }
                }
                handler(kept, response, error ?? (location != nil && kept == nil ? URLError(.cannotMoveFile) : nil))
            }
        }, delegate: delegate)
        return (url, response)
    }

    public func download(from url: URL, delegate: URLSessionTaskDelegate? = nil) async throws -> (URL, URLResponse) {
        try await download(for: URLRequest(url: url), delegate: delegate)
    }

    public func download(resumeFrom resumeData: Data, delegate: URLSessionTaskDelegate? = nil) async throws -> (URL, URLResponse) {
        throw URLError(.cannotDecodeContentData)
    }

    public func bytes(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (AsyncBytes, URLResponse) {
        let (data, response, task) = try await run({ dataTask(with: request, completionHandler: $0) }, delegate: delegate)
        return (AsyncBytes(_task: task as! URLSessionDataTask, data: data), response)
    }

    public func bytes(from url: URL, delegate: URLSessionTaskDelegate? = nil) async throws -> (AsyncBytes, URLResponse) {
        try await bytes(for: URLRequest(url: url), delegate: delegate)
    }
}

/// A task to start, and to cancel if the awaiting Swift task is cancelled first or later.
private final class _TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func start(_ task: URLSessionTask) {
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { self.task = task }
        lock.unlock()
        task.resume()
        if wasCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
    }
}

// MARK: - Decoding

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public struct AsyncUnicodeScalarSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = UnicodeScalar
    let base: Base

    @frozen
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline internal var _base: Base.AsyncIterator
        @usableFromInline internal var _leftover: UInt8? = nil

        @usableFromInline
        init(_base: Base.AsyncIterator) { self._base = _base }

        /// The number of continuation bytes a lead byte announces, or nil for a byte
        /// that can't begin a scalar.
        @inlinable @inline(__always)
        internal func _expectedContinuationCountForByte(_ byte: UInt8) -> Int? {
            switch byte {
            case 0x00...0x7F: return 0
            case 0xC0...0xDF: return 1
            case 0xE0...0xEF: return 2
            case 0xF0...0xF7: return 3
            default: return nil
            }
        }

        /// Decodes a multi-byte scalar from its lead byte; malformed input gives U+FFFD and
        /// keeps the offending byte for the next call.
        @inlinable
        internal mutating func _nextComplexScalar(_ first: UInt8) async rethrows -> UnicodeScalar? {
            guard let count = _expectedContinuationCountForByte(first), count > 0 else { return "\u{FFFD}" }
            var value = UInt32(first) & (0x7F >> UInt32(count + 1))
            for _ in 0..<count {
                guard let byte = try await _base.next() else { return "\u{FFFD}" }
                guard byte & 0xC0 == 0x80 else {
                    _leftover = byte
                    return "\u{FFFD}"
                }
                value = value << 6 | UInt32(byte & 0x3F)
            }
            return UnicodeScalar(value) ?? "\u{FFFD}"
        }

        @inlinable @inline(__always)
        public mutating func next() async rethrows -> UnicodeScalar? {
            let byte: UInt8
            if let leftover = _leftover {
                _leftover = nil
                byte = leftover
            } else {
                guard let b = try await _base.next() else { return nil }
                byte = b
            }
            if byte < 0x80 { return UnicodeScalar(byte) }
            return try await _nextComplexScalar(byte)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(_base: base.makeAsyncIterator()) }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AsyncUnicodeScalarSequence: Sendable where Base: Sendable {}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public struct AsyncCharacterSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = Character
    let base: Base

    @frozen
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline internal var remaining: AsyncUnicodeScalarSequence<Base>.AsyncIterator
        @usableFromInline internal var accumulator: String = ""

        /// Scalars gather until a second character starts, so combining marks join the
        /// character before them.
        @inlinable @inline(__always)
        public mutating func next() async rethrows -> Character? {
            while true {
                guard let scalar = try await remaining.next() else { break }
                accumulator.unicodeScalars.append(scalar)
                if accumulator.count >= 2 { return accumulator.removeFirst() }
            }
            return accumulator.isEmpty ? nil : accumulator.removeFirst()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(remaining: AsyncUnicodeScalarSequence(base: base).makeAsyncIterator())
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AsyncCharacterSequence: Sendable where Base: Sendable {}

/// Lines end at LF, CR, CRLF, NEL, LS or PS; the terminators aren't part of the line,
/// and there is no empty last line after a final terminator.
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public struct AsyncLineSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = String
    let base: Base

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = String
        var byteSource: Base.AsyncIterator
        var buffer: [UInt8] = []
        var leftover: UInt8? = nil

        public mutating func next() async rethrows -> String? {
            func yield(_ drop: Int) -> String {
                let s = String(decoding: buffer.dropLast(drop), as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                return s
            }
            while true {
                let byte: UInt8
                if let l = leftover {
                    leftover = nil
                    byte = l
                } else if let b = try await byteSource.next() {
                    byte = b
                } else {
                    return buffer.isEmpty ? nil : yield(0)
                }
                switch byte {
                case 0x0A:
                    return yield(0)
                case 0x0D:
                    if let after = try await byteSource.next(), after != 0x0A { leftover = after }
                    return yield(0)
                default:
                    buffer.append(byte)
                    let n = buffer.count
                    if n >= 2, buffer[n - 2] == 0xC2, byte == 0x85 { return yield(2) }
                    if n >= 3, buffer[n - 3] == 0xE2, buffer[n - 2] == 0x80, byte == 0xA8 || byte == 0xA9 { return yield(3) }
                }
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(byteSource: base.makeAsyncIterator()) }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AsyncLineSequence: Sendable where Base: Sendable {}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AsyncLineSequence.AsyncIterator: Sendable where Base.AsyncIterator: Sendable {}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AsyncSequence where Element == UInt8 {
    public var lines: AsyncLineSequence<Self> { AsyncLineSequence(base: self) }
    public var characters: AsyncCharacterSequence<Self> { AsyncCharacterSequence(base: self) }
    public var unicodeScalars: AsyncUnicodeScalarSequence<Self> { AsyncUnicodeScalarSequence(base: self) }
}
