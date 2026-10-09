// SPDX-License-Identifier: MIT OR Apache-2.0
// OSSignposter, OSSignpostIntervalState and the animation signposts:
// Finch's implementation, with the declarations of Apple's os overlay (macOS
// 26.4 SDK) so that symbols and inlinable ABI match. As with Logger, the
// message serialization is inlined into callers; signposts go out through
// libsystem_trace's _os_signpost_emit_with_name_impl.

@_exported import os
@_exported import os.signpost
import _SwiftOSOverlayShims

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension OSLog.Category {
  /// OS_LOG_CATEGORY_DYNAMIC_TRACING
  public static let dynamicTracing = OSLog.Category(string: "DynamicTracing")
  /// OS_LOG_CATEGORY_DYNAMIC_STACK_TRACING
  public static let dynamicStackTracing = OSLog.Category(string: "DynamicStackTracing")
}

// MARK: Animation signposts

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public enum AnimationFormatString {
  @inlinable
  @_optimize(none)
  @_semantics("constant_evaluable")
  internal static func constructOSLogInterpolation(_ formatString: String) -> OSLogInterpolation {
    var s = OSLogInterpolation(literalCapacity: 1, interpolationCount: 0)
    s.formatString += formatString
    s.formatString += " isAnimation=YES"
    return s
  }

  /// A literal format string for an animation-begin signpost, with
  /// " isAnimation=YES" appended at compile time.
  @frozen
  public struct OSLogMessage: ExpressibleByStringLiteral {
    @usableFromInline
    internal var formatStringPointer: UnsafePointer<CChar>

    @_transparent
    public init(stringLiteral value: String) {
      let message = os.OSLogMessage(
        stringInterpolation: constructOSLogInterpolation(value))
      let formatString = message.interpolation.formatString
      formatStringPointer = _getGlobalStringTablePointer(formatString)
    }
  }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public enum OSSignpostAnimationBegin {
  case animationBegin
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@usableFromInline
internal func animationBeginSignpostHelper(
  dso: UnsafeRawPointer,
  log: OSLog,
  name: StaticString,
  signpostID: OSSignpostID,
  formatStringPointer: UnsafePointer<CChar>,
  arguments: [CVarArg]
) {
  let hasValidID = signpostID != .invalid && signpostID != .null
  guard log.signpostsEnabled && hasValidID else { return }
  let ra = _swift_os_log_return_address()
  name.withUTF8Buffer { (nameBuf: UnsafeBufferPointer<UInt8>) in
    nameBuf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: nameBuf.count) { nameStr in
      withVaList(arguments) { valist in
        _swift_os_signpost_with_format(dso, ra, log, .begin, nameStr,
                                       signpostID.rawValue, formatStringPointer, valist)
      }
    }
  }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_transparent
public func os_signpost(
  _ animationBegin: OSSignpostAnimationBegin,
  dso: UnsafeRawPointer = #dsohandle,
  log: OSLog,
  name: StaticString,
  signpostID: OSSignpostID = .exclusive,
  _ format: AnimationFormatString.OSLogMessage,
  _ arguments: CVarArg...
) {
  animationBeginSignpostHelper(dso: dso, log: log, name: name, signpostID: signpostID,
                               formatStringPointer: format.formatStringPointer,
                               arguments: arguments)
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_transparent
public func os_signpost(
  _ animationBegin: OSSignpostAnimationBegin,
  dso: UnsafeRawPointer = #dsohandle,
  log: OSLog,
  name: StaticString,
  signpostID: OSSignpostID = .exclusive
) {
  let formatStringPointer = _getGlobalStringTablePointer("isAnimation=YES")
  animationBeginSignpostHelper(dso: dso, log: log, name: name, signpostID: signpostID,
                               formatStringPointer: formatStringPointer, arguments: [])
}

// MARK: OSSignposter

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public typealias SignpostMetadata = OSLogMessage

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public struct OSSignposter: @unchecked Sendable {
  @usableFromInline
  internal let logHandle: OSLog

  public var isEnabled: Bool { logHandle.signpostsEnabled }

  public static var disabled: OSSignposter { OSSignposter(logHandle: .disabled) }

  public init(subsystem: String, category: String) {
    logHandle = OSLog(subsystem: subsystem, category: category)
  }

  public init(subsystem: String, category: OSLog.Category) {
    logHandle = OSLog(subsystem: subsystem, category: category)
  }

  public init() {
    logHandle = .default
  }

  public init(logHandle: OSLog) {
    self.logHandle = logHandle
  }

  public init(logger: Logger) {
    logHandle = logger.logObject
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive,
                        _ message: SignpostMetadata) {
    osSignpost(message, log: logHandle, name: name, id: id, type: .event, state: nil)
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive) {
    osSignpostWithoutMessage(log: logHandle, name: name, id: id, type: .event, state: nil)
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive,
                            _ message: SignpostMetadata) -> OSSignpostIntervalState {
    osSignpost(message, log: logHandle, name: name, id: id, type: .begin, state: nil)
    return OSSignpostIntervalState(id: id)
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive)
    -> OSSignpostIntervalState
  {
    osSignpostWithoutMessage(log: logHandle, name: name, id: id, type: .begin, state: nil)
    return OSSignpostIntervalState(id: id)
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func beginAnimationInterval(_ name: StaticString, id: OSSignpostID = .exclusive)
    -> OSSignpostIntervalState
  {
    osSignpostWithoutMessage(log: logHandle, name: name, id: id, type: .begin, state: nil,
                             formatString: "isAnimation=YES")
    return OSSignpostIntervalState(id: id)
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func beginAnimationInterval(_ name: StaticString, id: OSSignpostID = .exclusive,
                                     _ message: SignpostMetadata) -> OSSignpostIntervalState {
    osSignpost(message, log: logHandle, name: name, id: id, type: .begin, state: nil,
               formatStringTransform: animationFormatString)
    return OSSignpostIntervalState(id: id)
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState,
                          _ message: SignpostMetadata) {
    osSignpost(message, log: logHandle, name: name, id: state.signpostID, type: .end,
               state: state)
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
    osSignpostWithoutMessage(log: logHandle, name: name, id: state.signpostID, type: .end,
                             state: state)
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func withIntervalSignpost<T>(
    _ name: StaticString,
    id: OSSignpostID = .exclusive,
    _ message: SignpostMetadata,
    around task: () throws -> T
  ) rethrows -> T {
    let formatString = message.interpolation.formatString
    let nameStringPointer = _globalStringTablePointerOfStaticString(name)
    let formatStringPointer = _getGlobalStringTablePointer(formatString)
    return try emitSignpost(
      preamble: message.interpolation.preamble,
      argumentCount: message.interpolation.argumentCount,
      bufferSize: message.bufferSize,
      objectCount: message.interpolation.objectArgumentCount,
      stringCount: message.interpolation.stringArgumentCount,
      argumentClosures: message.interpolation.arguments.argumentClosures
    ) {
      try callSignpostAroundTask(
        dsoHandle: UnsafeMutableRawPointer(mutating: #dsohandle), log: logHandle, id: id,
        nameStringPointer: nameStringPointer, formatStringPointer: formatStringPointer,
        bufferMemory: $0, uint32bufferSize: $1, task: task)
    }
  }

  @_transparent
  @_optimize(none)
  @_semantics("constant_evaluable")
  public func withIntervalSignpost<T>(
    _ name: StaticString,
    id: OSSignpostID = .exclusive,
    around task: () throws -> T
  ) rethrows -> T {
    let nameStringPointer = _globalStringTablePointerOfStaticString(name)
    let formatStringPointer = _getGlobalStringTablePointer("")
    return try emitSignpost(preamble: 0, argumentCount: 0, bufferSize: 2, objectCount: 0,
                            stringCount: 0, argumentClosures: []) {
      try callSignpostAroundTask(
        dsoHandle: UnsafeMutableRawPointer(mutating: #dsohandle), log: logHandle, id: id,
        nameStringPointer: nameStringPointer, formatStringPointer: formatStringPointer,
        bufferMemory: $0, uint32bufferSize: $1, task: task)
    }
  }

  @inlinable
  @inline(__always)
  public func makeSignpostID() -> OSSignpostID {
    return OSSignpostID(log: logHandle)
  }

  @inlinable
  @inline(__always)
  public func makeSignpostID(from object: AnyObject) -> OSSignpostID {
    return OSSignpostID(log: logHandle, object: object)
  }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@usableFromInline
internal enum OSSignpostError {
  case doubleEnd
  case none

  @_transparent
  @_alwaysEmitIntoClient
  internal static var doubleEndErrorString: String {
    return "[Error] Interval already ended"
  }
}

/// The state of a signpost interval: its ID, and whether it's still open
/// (ending it twice is reported instead of emitted twice).
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public class OSSignpostIntervalState: Codable, @unchecked Sendable {
  @usableFromInline
  internal final let signpostID: OSSignpostID

  private let lock: UnsafeMutablePointer<os_unfair_lock>
  private var isOpen: Bool

  @usableFromInline
  internal init(id: OSSignpostID, isOpen: Bool = true) {
    signpostID = id
    self.isOpen = isOpen
    lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    lock.initialize(to: os_unfair_lock())
  }

  @inlinable
  @inline(__always)
  public static func beginState(id: OSSignpostID) -> OSSignpostIntervalState {
    return OSSignpostIntervalState(id: id)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case isOpen
  }

  public required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    signpostID = OSSignpostID(try container.decode(UInt64.self, forKey: .id))
    isOpen = try container.decode(Bool.self, forKey: .isOpen)
    lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    lock.initialize(to: os_unfair_lock())
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(signpostID.rawValue, forKey: .id)
    try container.encode(withLock { isOpen }, forKey: .isOpen)
  }

  public func _hasValue(id: OSSignpostID, isOpen: Bool) -> Bool {
    return signpostID == id && withLock { self.isOpen } == isOpen
  }

  /// Closes the interval; false if it was already closed.
  internal func close() -> Bool {
    return withLock {
      let wasOpen = isOpen
      isOpen = false
      return wasOpen
    }
  }

  private func withLock<R>(_ body: () -> R) -> R {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    return body()
  }

  deinit {
    lock.deinitialize(count: 1)
    lock.deallocate()
  }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@usableFromInline
internal func checkForErrorAndConsumeState(state: OSSignpostIntervalState) -> OSSignpostError {
  return state.close() ? .none : .doubleEnd
}

// MARK: Client-side helpers (always inlined into callers)

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@_transparent
@_alwaysEmitIntoClient
@_optimize(none)
internal func osSignpost(
  _ message: SignpostMetadata,
  log: OSLog,
  name: StaticString,
  id: OSSignpostID,
  type: OSSignpostType,
  state: OSSignpostIntervalState?,
  formatStringTransform: (String) -> String = id
) {
  let formatString = formatStringTransform(message.interpolation.formatString)
  guard log.signpostsEnabled else { return }
  var preamble = message.interpolation.preamble
  var argumentCount = message.interpolation.argumentCount
  let nameStringPointer = _globalStringTablePointerOfStaticString(name)
  let formatStringPointer = checkStateAndGetFormatStringPointer(
    formatString: formatString, state: state, preamble: &preamble,
    argumentCount: &argumentCount)
  emitSignpost(
    preamble: preamble, argumentCount: argumentCount, bufferSize: message.bufferSize,
    objectCount: message.interpolation.objectArgumentCount,
    stringCount: message.interpolation.stringArgumentCount,
    argumentClosures: message.interpolation.arguments.argumentClosures
  ) {
    ___os_signpost_emit_with_name_impl(
      UnsafeMutableRawPointer(mutating: #dsohandle), log, type, id.rawValue,
      nameStringPointer, formatStringPointer, $0, $1)
  }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@_transparent
@_alwaysEmitIntoClient
@_optimize(none)
internal func osSignpostWithoutMessage(
  log: OSLog,
  name: StaticString,
  id: OSSignpostID,
  type: OSSignpostType,
  state: OSSignpostIntervalState?,
  formatString: String = ""
) {
  guard log.signpostsEnabled else { return }
  var preamble: UInt8 = 0
  var argumentCount: UInt8 = 0
  let nameStringPointer = _globalStringTablePointerOfStaticString(name)
  let formatStringPointer = checkStateAndGetFormatStringPointer(
    formatString: formatString, state: state, preamble: &preamble,
    argumentCount: &argumentCount)
  emitSignpost(preamble: preamble, argumentCount: argumentCount, bufferSize: 2,
               objectCount: 0, stringCount: 0, argumentClosures: []) {
    ___os_signpost_emit_with_name_impl(
      UnsafeMutableRawPointer(mutating: #dsohandle), log, type, id.rawValue,
      nameStringPointer, formatStringPointer, $0, $1)
  }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@_transparent
@_alwaysEmitIntoClient
@_optimize(none)
internal func emitSignpost<T>(
  preamble: UInt8,
  argumentCount: UInt8,
  bufferSize: Int,
  objectCount: Int,
  stringCount: Int,
  argumentClosures: ArgumentClosures,
  signpostTask: (UnsafeMutablePointer<UInt8>, UInt32) throws -> T
) rethrows -> T {
  let bufferMemory = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
  let objectArguments = createStorage(capacity: objectCount, type: ObjectType?.self)
  let stringArgumentOwners = createStorage(capacity: stringCount, type: Any.self)
  var currentBufferPosition = bufferMemory
  var objectArgumentsPosition = objectArguments
  var stringArgumentOwnersPosition = stringArgumentOwners
  serialize(preamble, at: &currentBufferPosition)
  serialize(argumentCount, at: &currentBufferPosition)
  argumentClosures.forEach {
    $0(&currentBufferPosition, &objectArgumentsPosition, &stringArgumentOwnersPosition)
  }
  let result = try signpostTask(bufferMemory, UInt32(bufferSize))
  destroyStorage(objectArguments, count: objectCount)
  destroyStorage(stringArgumentOwners, count: stringCount)
  bufferMemory.deallocate()
  return result
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@_transparent
@_alwaysEmitIntoClient
internal func callSignpostAroundTask<T>(
  dsoHandle: UnsafeMutableRawPointer,
  log: OSLog,
  id: OSSignpostID,
  nameStringPointer: UnsafePointer<CChar>,
  formatStringPointer: UnsafePointer<CChar>,
  bufferMemory: UnsafeMutablePointer<UInt8>,
  uint32bufferSize: UInt32,
  task: () throws -> T
) rethrows -> T {
  ___os_signpost_emit_with_name_impl(dsoHandle, log, .begin, id.rawValue, nameStringPointer,
                                     formatStringPointer, bufferMemory, uint32bufferSize)
  let result = try task()
  ___os_signpost_emit_with_name_impl(dsoHandle, log, .end, id.rawValue, nameStringPointer,
                                     formatStringPointer, bufferMemory, uint32bufferSize)
  return result
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@_transparent
@_alwaysEmitIntoClient
@_optimize(none)
internal func checkStateAndGetFormatStringPointer(
  formatString: String,
  state: OSSignpostIntervalState?,
  preamble: inout UInt8,
  argumentCount: inout UInt8
) -> UnsafePointer<CChar> {
  var formatStringPointer = _getGlobalStringTablePointer(formatString)
  if let state = state, case .doubleEnd = checkForErrorAndConsumeState(state: state) {
    formatStringPointer = _getGlobalStringTablePointer(OSSignpostError.doubleEndErrorString)
    preamble = 0
    argumentCount = 0
  }
  return formatStringPointer
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@_transparent
@_alwaysEmitIntoClient
@_optimize(none)
internal func _globalStringTablePointerOfStaticString(
  _ value: StaticString
) -> UnsafePointer<CChar> {
  value.withUTF8Buffer { (valueBuf: UnsafeBufferPointer<UInt8>) in
    valueBuf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: valueBuf.count) { $0 }
  }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@_transparent
@_optimize(none)
@_alwaysEmitIntoClient
@_semantics("constant_evaluable")
internal func animationFormatString(_ formatString: String) -> String {
  var s = ""
  s += formatString
  s += " isAnimation=YES"
  return s
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@_transparent
@_optimize(none)
@_alwaysEmitIntoClient
@_semantics("constant_evaluable")
internal func id(_ s: String) -> String {
  return s
}
