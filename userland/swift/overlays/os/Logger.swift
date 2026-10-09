// SPDX-License-Identifier: MIT OR Apache-2.0
// Logger and the OSLogMessage forms of os_log: Finch's implementation of the
// os overlay's logging entry points, with the declarations (and so the
// symbols and inlinable ABI) of Apple's os overlay in the macOS 26.4 SDK.
// The client-side work (formatting and serializing the arguments, calling
// _os_log_impl) is inlined into callers; this file supplies the out-of-line
// entry points they and older clients call.

@_exported import os
@_exported import os.log

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public struct Logger: @unchecked Sendable {
  @usableFromInline
  internal let logObject: OSLog

  public static var disabled: Logger { Logger(OSLog.disabled) }

  public init(subsystem: String, category: String) {
    logObject = OSLog(subsystem: subsystem, category: category)
  }

  public init() {
    logObject = OSLog.default
  }

  public init(_ logObj: OSLog) {
    logObject = logObj
  }

  public func isEnabled(type: OSLogType) -> Bool {
    return logObject.isEnabled(type: type)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func log(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .default)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.log_with_level")
  public func log(level: OSLogType, _ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: level)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func trace(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .debug)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func debug(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .debug)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func info(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .info)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func notice(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .default)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func warning(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .error)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func error(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .error)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func critical(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .fault)
  }

  @_transparent
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public func fault(_ message: OSLogMessage) {
    osLogInternal(message, log: logObject, type: .fault)
  }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_disfavoredOverload
@_transparent
@_optimize(none)
@_semantics("oslog.requires_constant_arguments")
@_alwaysEmitIntoClient
public func os_log(_ message: OSLogMessage) {
  osLogInternal(message, log: .default, type: .default)
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_disfavoredOverload
@_transparent
@_optimize(none)
@_semantics("oslog.log_with_level")
public func os_log(
  _ logLevel: OSLogType = .default,
  log logObject: OSLog = .default,
  _ message: OSLogMessage
) {
  osLogInternal(message, log: logObject, type: logLevel)
}

/// Serializes the message's arguments into a buffer laid out as libtrace
/// expects (preamble, argument count, then each argument's header, size and
/// bytes) and hands it to _os_log_impl.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_transparent
@_alwaysEmitIntoClient
@_optimize(none)
internal func osLogInternal(
  _ message: OSLogMessage,
  log logObject: OSLog,
  type logLevel: OSLogType
) {
  let formatString = message.interpolation.formatString
  let preamble = message.interpolation.preamble
  let argumentCount = message.interpolation.argumentCount
  let bufferSize = message.bufferSize
  let objectCount = message.interpolation.objectArgumentCount
  let stringCount = message.interpolation.stringArgumentCount
  let uint32bufferSize = UInt32(bufferSize)
  let argumentClosures = message.interpolation.arguments.argumentClosures
  let formatStringPointer = _getGlobalStringTablePointer(formatString)

  guard logObject.isEnabled(type: logLevel) else { return }

  let bufferMemory = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
  let objectArguments = createStorage(capacity: objectCount, type: ObjectType?.self)
  let stringArgumentOwners = createStorage(capacity: stringCount, type: StringStorageType.self)
  var currentBufferPosition = bufferMemory
  var objectArgumentsPosition = objectArguments
  var stringArgumentOwnersPosition = stringArgumentOwners
  serialize(preamble, at: &currentBufferPosition)
  serialize(argumentCount, at: &currentBufferPosition)
  argumentClosures.forEach {
    $0(&currentBufferPosition, &objectArgumentsPosition, &stringArgumentOwnersPosition)
  }
  ___os_log_impl(UnsafeMutableRawPointer(mutating: #dsohandle), logObject, logLevel,
                 formatStringPointer, bufferMemory, uint32bufferSize)
  destroyStorage(objectArguments, count: objectCount)
  destroyStorage(stringArgumentOwners, count: stringCount)
  bufferMemory.deallocate()
}

/// Test hook: builds the message's buffer as osLogInternal would and passes
/// it, with the format string, to `assertion` instead of logging it.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_transparent
@_optimize(none)
public func _checkFormatStringAndBuffer(
  _ message: OSLogMessage,
  with assertion: (String, UnsafeBufferPointer<UInt8>) -> Void
) {
  let formatString = message.interpolation.formatString
  let preamble = message.interpolation.preamble
  let argumentCount = message.interpolation.argumentCount
  let bufferSize = message.bufferSize
  let objectCount = message.interpolation.objectArgumentCount
  let stringCount = message.interpolation.stringArgumentCount
  let argumentClosures = message.interpolation.arguments.argumentClosures

  let bufferMemory = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
  let objectArguments = createStorage(capacity: objectCount, type: ObjectType?.self)
  let stringArgumentOwners = createStorage(capacity: stringCount, type: StringStorageType.self)
  var currentBufferPosition = bufferMemory
  var objectArgumentsPosition = objectArguments
  var stringArgumentOwnersPosition = stringArgumentOwners
  serialize(preamble, at: &currentBufferPosition)
  serialize(argumentCount, at: &currentBufferPosition)
  argumentClosures.forEach {
    $0(&currentBufferPosition, &objectArgumentsPosition, &stringArgumentOwnersPosition)
  }
  assertion(formatString,
            UnsafeBufferPointer(start: UnsafePointer(bufferMemory), count: bufferSize))
  destroyStorage(objectArguments, count: objectCount)
  destroyStorage(stringArgumentOwners, count: stringCount)
  bufferMemory.deallocate()
}

/// The privacy qualifier and any extra attributes of a format specifier,
/// comma-separated, or nil when there are neither.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
@_semantics("constant_evaluable")
@_alwaysEmitIntoClient
@_optimize(none)
internal func concatPrivacyAndAttributes(
  privacy: OSLogPrivacy,
  attributes: String
) -> String? {
  var tagString = attributes
  if privacy.needsPrivacySpecifier && attributes != "" {
    tagString += ","
  }
  if let privacySpecifier = privacy.privacySpecifier {
    tagString += privacySpecifier
  }
  return tagString == "" ? nil : tagString
}
