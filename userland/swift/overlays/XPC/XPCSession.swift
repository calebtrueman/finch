// SPDX-License-Identifier: MIT OR Apache-2.0
// XPCSession, XPCRichError, XPCReceivedMessage and XPCPeerRequirement:
// Finch's implementation over libxpc's session API, with the declarations of
// Apple's XPC overlay (macOS 26.4 SDK).

@_exported import XPC
import Dispatch
@_implementationOnly import _FinchXPCShims

// MARK: XPCRichError

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public struct XPCRichError: Error, Sendable {
  nonisolated(unsafe) internal let _object: xpc_object_t

  internal init(_ object: xpc_object_t) {
    _object = object
  }

  public var canRetry: Bool { _finch_xpc_rich_error_can_retry(_object) }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
extension XPCRichError: CustomDebugStringConvertible {
  public var debugDescription: String {
    return _xpcTakeString(_finch_xpc_rich_error_copy_description(_object))
  }
}

/// The error for a C call that failed without one.
internal func _xpcError(_ error: xpc_object_t?) -> XPCRichError {
  return XPCRichError(error ?? XPC_ERROR_CONNECTION_INVALID)
}

// MARK: XPCPeerRequirement

@available(macOS 26.0, macCatalyst 26.0, *)
public struct XPCPeerRequirement {
  internal let _object: xpc_object_t

  internal init(_ make: (inout xpc_object_t?) -> xpc_object_t?) {
    var error: xpc_object_t?
    guard let requirement = make(&error) else {
      fatalError("XPCPeerRequirement: \(_xpcError(error).debugDescription)")
    }
    _object = requirement
  }
}

@available(macOS 26.0, macCatalyst 26.0, *)
extension XPCPeerRequirement {
  public static func hasEntitlement(_ entitlement: String) -> XPCPeerRequirement {
    return XPCPeerRequirement { _finch_xpc_peer_requirement_create_entitlement_exists(entitlement, &$0) }
  }

  public static func entitlement(_ entitlement: String, matches value: Bool) -> XPCPeerRequirement {
    return XPCPeerRequirement {
      _finch_xpc_peer_requirement_create_entitlement_matches_value(entitlement, xpc_bool_create(value), &$0)
    }
  }

  public static func entitlement(_ entitlement: String, matches value: String) -> XPCPeerRequirement {
    return XPCPeerRequirement {
      _finch_xpc_peer_requirement_create_entitlement_matches_value(entitlement, xpc_string_create(value), &$0)
    }
  }

  public static func entitlement(_ entitlement: String, matches value: Int) -> XPCPeerRequirement {
    return XPCPeerRequirement {
      _finch_xpc_peer_requirement_create_entitlement_matches_value(
        entitlement, xpc_int64_create(Int64(value)), &$0)
    }
  }

  public static func isFromSameTeam(andMatchesSigningIdentifier: String? = nil) -> XPCPeerRequirement {
    return XPCPeerRequirement { _finch_xpc_peer_requirement_create_team_identity(andMatchesSigningIdentifier, &$0) }
  }

  public static func isPlatformCode(andMatchesSigningIdentifier: String? = nil) -> XPCPeerRequirement {
    return XPCPeerRequirement {
      _finch_xpc_peer_requirement_create_platform_identity(andMatchesSigningIdentifier, &$0)
    }
  }

  /// A requirement from a serialized lightweight code requirement.
  public static func fromLWCRData(_ data: UnsafeRawBufferPointer) -> XPCPeerRequirement {
    let blob = xpc_data_create(data.baseAddress, data.count)
    return XPCPeerRequirement { _finch_xpc_peer_requirement_create_lwcr(blob, &$0) }
  }
}

@available(macOS 26.0, macCatalyst 26.0, *)
extension XPCPeerRequirement {
  public init(lightweightCodeRequirements dictionary: XPCDictionary) {
    self.init { _finch_xpc_peer_requirement_create_lwcr(dictionary._object, &$0) }
  }
}

@available(macOS 26.0, macCatalyst 26.0, *)
extension XPCPeerRequirement: @unchecked Sendable {}

// MARK: XPCReceivedMessage

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public struct XPCReceivedMessage {
  internal let _message: xpc_object_t

  internal init(_ message: xpc_object_t) {
    _message = message
  }

  public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
    return try _xpcDecodeMessage(type, _message)
  }

  @_spi(XPCCodable)
  public func decode<T: Decodable>(as type: T.Type = T.self, userInfo: [CodingUserInfoKey: Any]) throws -> T {
    return try _xpcDecodeMessage(type, _message, userInfo: userInfo)
  }

  public func reply<Message: Encodable>(_ object: Message) {
    reply(object, userInfo: [:])
  }

  public func reply<Message: Encodable>(_ object: Message, userInfo: [CodingUserInfoKey: Any]) {
    guard let reply = xpc_dictionary_create_reply(_message) else { return }
    do {
      try _xpcFill(reply, with: object, userInfo: userInfo)
    } catch {
      fatalError("XPCReceivedMessage.reply: \(error)")
    }
    _finch_xpc_dictionary_send_reply(reply)
  }

  /// Runs `continuation` on `queue`, which replies; the handler returns
  /// this method's nil.
  @preconcurrency
  public func handoffReply(to queue: DispatchQueue, _ continuation: @escaping @Sendable () -> Void) -> Encodable? {
    guard let reply = xpc_dictionary_create_reply(_message) else {
      queue.async(execute: continuation)
      return nil
    }
    _finch_xpc_dictionary_handoff_reply(reply, queue, continuation)
    return nil
  }

  /// Stops a handed-off reply from being sent automatically.
  public func detachHandoff() {
  }

  public var expectsReply: Bool { _finch_xpc_dictionary_expects_reply(_message) }

  /// Whether the sender waits for the reply (Finch can't tell; it answers
  /// whether a reply is expected).
  public var isSync: Bool { expectsReply }

  public var auditToken: audit_token_t {
    var token = audit_token_t()
    _finch_xpc_dictionary_get_audit_token(_message, &token)
    return token
  }
}

@available(macOS 26.0, macCatalyst 26.0, *)
extension XPCReceivedMessage {
  public func senderSatisfies(_ requirement: XPCPeerRequirement) -> Bool {
    var error: xpc_object_t?
    return _finch_xpc_peer_requirement_match_received_message(requirement._object, _message, &error)
  }
}

// MARK: Message handlers

/// Answers a message as a handler's reply value says.
internal func _xpcReply(to message: xpc_object_t, with reply: Encodable?) {
  guard let reply, let replyMessage = xpc_dictionary_create_reply(message) else { return }
  do {
    try _xpcFill(replyMessage, with: reply)
  } catch {
    fatalError("XPC reply encoding failed: \(error)")
  }
  _finch_xpc_dictionary_send_reply(replyMessage)
}

internal func _xpcDictionaryHandler(_ handler: @escaping (XPCDictionary) -> XPCDictionary?)
  -> (xpc_object_t) -> Void
{
  return { message in
    guard let reply = handler(XPCDictionary(message)) else { return }
    XPCDictionary(message).reply(reply)
  }
}

internal func _xpcDecodingHandler<Message: Decodable>(
  _ handler: @escaping (Message) -> Encodable?
) -> (xpc_object_t) -> Void {
  return { message in
    guard let value = try? _xpcDecodeMessage(Message.self, message) else { return }
    _xpcReply(to: message, with: handler(value))
  }
}

internal func _xpcReceivedHandler(_ handler: @escaping (XPCReceivedMessage) -> Encodable?)
  -> (xpc_object_t) -> Void
{
  return { message in
    _xpcReply(to: message, with: handler(XPCReceivedMessage(message)))
  }
}

// MARK: XPCSession

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public class XPCSession {
  public struct InitializationOptions: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let none = InitializationOptions([])
    public static let inactive = InitializationOptions(rawValue: 1 << 0)
    public static let privileged = InitializationOptions(rawValue: 1 << 1)
  }

  internal let _session: xpc_object_t

  /// Wraps a session libxpc made inactive: sets its handlers and target
  /// queue, then activates it unless the options say not to.
  internal init(
    _session session: xpc_object_t, targetQueue: DispatchQueue?, options: InitializationOptions,
    incomingMessageHandler: ((xpc_object_t) -> Void)?,
    cancellationHandler: ((XPCRichError) -> Void)?
  ) throws {
    _session = session
    if let targetQueue {
      _finch_xpc_session_set_target_queue(session, targetQueue)
    }
    if let incomingMessageHandler {
      _finch_xpc_session_set_incoming_message_handler(session, incomingMessageHandler)
    }
    if let cancellationHandler {
      _finch_xpc_session_set_cancel_handler(session) { cancellationHandler(XPCRichError($0)) }
    }
    if !options.contains(.inactive) {
      try activate()
    }
  }

  /// An already-active session libxpc handed over (a listener's peer).
  internal init(_peer session: xpc_object_t) {
    _session = session
  }

  internal static func _create(
    _ make: (UInt64, inout xpc_object_t?) -> xpc_object_t?, options: InitializationOptions
  ) throws -> xpc_object_t {
    var error: xpc_object_t?
    // Created inactive, so the handlers are in place before it runs.
    guard let session = make(options.rawValue | InitializationOptions.inactive.rawValue, &error) else {
      throw _xpcError(error)
    }
    return session
  }

  // MARK: XPC services

  @preconcurrency
  public convenience init(
    xpcService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_service(xpcService, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: nil, cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    xpcService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_service(xpcService, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcDictionaryHandler),
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init<Message: Decodable>(
    xpcService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (Message) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_service(xpcService, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map { _xpcDecodingHandler($0) },
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    xpcService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (XPCReceivedMessage) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_service(xpcService, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcReceivedHandler),
                  cancellationHandler: cancellationHandler)
  }

  // MARK: Mach services

  @preconcurrency
  public convenience init(
    machService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_mach_service(machService, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: nil, cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    machService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_mach_service(machService, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcDictionaryHandler),
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init<Message: Decodable>(
    machService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (Message) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_mach_service(machService, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map { _xpcDecodingHandler($0) },
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    machService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (XPCReceivedMessage) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_mach_service(machService, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcReceivedHandler),
                  cancellationHandler: cancellationHandler)
  }

  // MARK: Handlers and state

  @preconcurrency
  public func setIncomingMessageHandler(_ incomingMessageHandler: @escaping @Sendable (XPCDictionary) -> XPCDictionary?) {
    _finch_xpc_session_set_incoming_message_handler(_session, _xpcDictionaryHandler(incomingMessageHandler))
  }

  @preconcurrency
  public func setIncomingMessageHandler<Message: Decodable>(
    _ incomingMessageHandler: @escaping @Sendable (Message) -> Encodable?
  ) {
    _finch_xpc_session_set_incoming_message_handler(_session, _xpcDecodingHandler(incomingMessageHandler))
  }

  @preconcurrency
  public func setIncomingMessageHandler(_ incomingMessageHandler: @escaping @Sendable (XPCReceivedMessage) -> Encodable?) {
    _finch_xpc_session_set_incoming_message_handler(_session, _xpcReceivedHandler(incomingMessageHandler))
  }

  @preconcurrency
  public func setCancellationHandler(_ cancellationHandler: @escaping @Sendable (XPCRichError) -> Void) {
    _finch_xpc_session_set_cancel_handler(_session) { cancellationHandler(XPCRichError($0)) }
  }

  public func setTargetQueue(_ targetQueue: DispatchQueue) {
    _finch_xpc_session_set_target_queue(_session, targetQueue)
  }

  public func activate() throws {
    var error: xpc_object_t?
    if !_finch_xpc_session_activate(_session, &error) {
      throw _xpcError(error)
    }
  }

  /// Cancels the session (libxpc's sessions take no reason; Finch drops it).
  public func cancel(reason: String) {
    _finch_xpc_session_cancel(_session)
  }

  // MARK: Sending

  public func send(message: XPCDictionary) throws {
    if let error = _finch_xpc_session_send_message(_session, message._object) {
      throw XPCRichError(error)
    }
  }

  public func send<Message: Encodable>(_ message: Message) throws {
    if let error = _finch_xpc_session_send_message(_session, try _xpcMessage(message)) {
      throw XPCRichError(error)
    }
  }

  public func sendSync(message: XPCDictionary) throws -> XPCDictionary {
    var error: xpc_object_t?
    guard let reply = _finch_xpc_session_send_message_with_reply_sync(_session, message._object, &error) else {
      throw _xpcError(error)
    }
    return XPCDictionary(reply)
  }

  public func sendSync<Message: Encodable, Reply: Decodable>(_ message: Message) throws -> Reply {
    var error: xpc_object_t?
    guard let reply = _finch_xpc_session_send_message_with_reply_sync(_session, try _xpcMessage(message), &error)
    else {
      throw _xpcError(error)
    }
    return try _xpcDecodeMessage(Reply.self, reply)
  }

  public func sendSync<Message: Encodable>(_ message: Message) throws -> XPCReceivedMessage {
    var error: xpc_object_t?
    guard let reply = _finch_xpc_session_send_message_with_reply_sync(_session, try _xpcMessage(message), &error)
    else {
      throw _xpcError(error)
    }
    return XPCReceivedMessage(reply)
  }

  @preconcurrency
  public func send(
    message: XPCDictionary,
    replyHandler: @escaping @Sendable (Result<XPCDictionary, XPCRichError>) -> Void
  ) {
    _finch_xpc_session_send_message_with_reply_async(_session, message._object) { reply, error in
      if let reply {
        replyHandler(.success(XPCDictionary(reply)))
      } else {
        replyHandler(.failure(_xpcError(error)))
      }
    }
  }

  @preconcurrency
  public func send<Message: Encodable, Reply: Decodable>(
    _ message: Message, replyHandler: @escaping @Sendable (Result<Reply, Error>) -> Void
  ) throws {
    _finch_xpc_session_send_message_with_reply_async(_session, try _xpcMessage(message)) { reply, error in
      if let reply {
        replyHandler(Result { try _xpcDecodeMessage(Reply.self, reply) })
      } else {
        replyHandler(.failure(_xpcError(error)))
      }
    }
  }

  @preconcurrency
  public func send<Message: Encodable>(
    _ message: Message,
    replyHandler: @escaping @Sendable (Result<XPCReceivedMessage, XPCRichError>) -> Void
  ) throws {
    try send(message, userInfo: [:], replyHandler: replyHandler)
  }



  deinit {
  }
}

/// Not overridable (Apple's has these in an extension).
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
extension XPCSession {
  public func send<Message: Encodable>(
    _ message: Message, userInfo: [CodingUserInfoKey: Any],
    replyHandler: @escaping @Sendable (Result<XPCReceivedMessage, XPCRichError>) -> Void
  ) throws {
    _finch_xpc_session_send_message_with_reply_async(_session, try _xpcMessage(message, userInfo: userInfo)) {
      reply, error in
      if let reply {
        replyHandler(.success(XPCReceivedMessage(reply)))
      } else {
        replyHandler(.failure(_xpcError(error)))
      }
    }
  }
  // MARK: Peer identity

  public var auditToken: audit_token_t {
    var token = audit_token_t()
    _finch_xpc_session_get_peer_audit_token(_session, &token)
    return token
  }

  public func setTargetUserSession(userIdentifier: UInt32) {
    _finch_xpc_session_set_target_user_session_uid(_session, userIdentifier)
  }

  /// The XPC connection under the session.
  public func extractConnection() -> xpc_object_t {
    return _finch_xpc_session_extract_connection(_session)
  }
}

// MARK: Endpoints, connections, requirements

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
extension XPCSession {
  @preconcurrency
  public convenience init(
    endpoint: XPCEndpoint, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_endpoint(endpoint._object, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: nil, cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    endpoint: XPCEndpoint, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_endpoint(endpoint._object, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcDictionaryHandler),
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init<Message: Decodable>(
    endpoint: XPCEndpoint, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (Message) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_endpoint(endpoint._object, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map { _xpcDecodingHandler($0) },
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    endpoint: XPCEndpoint, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingMessageHandler: (@Sendable (XPCReceivedMessage) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_endpoint(endpoint._object, nil, $0, &$1) },
                                         options: options)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcReceivedHandler),
                  cancellationHandler: cancellationHandler)
  }

  /// A session over an existing XPC connection.
  internal static func _wrapping(_ connection: xpc_object_t) throws -> xpc_object_t {
    guard let session = _finch_xpc_session_create_from_connection(connection) else {
      throw _xpcError(nil)
    }
    return session
  }

  public convenience init(
    fromConnection connection: xpc_object_t, targetQueue: DispatchQueue? = nil,
    options: InitializationOptions = .none, cancellationHandler: ((XPCRichError) -> Void)? = nil
  ) throws {
    try self.init(_session: try XPCSession._wrapping(connection), targetQueue: targetQueue, options: options,
                  incomingMessageHandler: nil, cancellationHandler: cancellationHandler)
  }

  public convenience init(
    fromConnection connection: xpc_object_t, targetQueue: DispatchQueue? = nil,
    options: InitializationOptions = .none,
    incomingMessageHandler: ((XPCDictionary) -> XPCDictionary?)? = nil,
    cancellationHandler: ((XPCRichError) -> Void)? = nil
  ) throws {
    try self.init(_session: try XPCSession._wrapping(connection), targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcDictionaryHandler),
                  cancellationHandler: cancellationHandler)
  }

  public convenience init<Message: Decodable>(
    fromConnection connection: xpc_object_t, targetQueue: DispatchQueue? = nil,
    options: InitializationOptions = .none,
    incomingMessageHandler: ((Message) -> Encodable?)? = nil,
    cancellationHandler: ((XPCRichError) -> Void)? = nil
  ) throws {
    try self.init(_session: try XPCSession._wrapping(connection), targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map { _xpcDecodingHandler($0) },
                  cancellationHandler: cancellationHandler)
  }

  public convenience init(
    fromConnection connection: xpc_object_t, targetQueue: DispatchQueue? = nil,
    options: InitializationOptions = .none,
    incomingMessageHandler: ((XPCReceivedMessage) -> Encodable?)? = nil,
    cancellationHandler: ((XPCRichError) -> Void)? = nil
  ) throws {
    try self.init(_session: try XPCSession._wrapping(connection), targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcReceivedHandler),
                  cancellationHandler: cancellationHandler)
  }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
extension XPCSession: CustomDebugStringConvertible {
  public var debugDescription: String {
    return _xpcTakeString(_finch_xpc_session_copy_description(_session))
  }
}

@available(macOS 26.0, macCatalyst 26.0, *)
extension XPCSession {
  public func setPeerRequirement(_ requirement: XPCPeerRequirement) {
    _finch_xpc_session_set_peer_requirement(_session, requirement._object)
  }
}

/// With a requirement: the session is made inactive, given the requirement,
/// then activated as the options say.
@available(macOS 26.0, macCatalyst 26.0, *)
extension XPCSession {
  internal static func _create(
    _ make: (UInt64, inout xpc_object_t?) -> xpc_object_t?, options: InitializationOptions,
    requirement: XPCPeerRequirement
  ) throws -> xpc_object_t {
    let session = try _create(make, options: options)
    _finch_xpc_session_set_peer_requirement(session, requirement._object)
    return session
  }

  @preconcurrency
  public convenience init(
    xpcService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement, cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_service(xpcService, nil, $0, &$1) },
                                         options: options, requirement: requirement)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: nil, cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    xpcService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement,
    incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_service(xpcService, nil, $0, &$1) },
                                         options: options, requirement: requirement)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcDictionaryHandler),
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init<Message: Decodable>(
    xpcService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement,
    incomingMessageHandler: (@Sendable (Message) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_service(xpcService, nil, $0, &$1) },
                                         options: options, requirement: requirement)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map { _xpcDecodingHandler($0) },
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    xpcService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement,
    incomingMessageHandler: (@Sendable (XPCReceivedMessage) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_xpc_service(xpcService, nil, $0, &$1) },
                                         options: options, requirement: requirement)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcReceivedHandler),
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    machService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement, cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_mach_service(machService, nil, $0, &$1) },
                                         options: options, requirement: requirement)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: nil, cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    machService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement,
    incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_mach_service(machService, nil, $0, &$1) },
                                         options: options, requirement: requirement)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcDictionaryHandler),
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init<Message: Decodable>(
    machService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement,
    incomingMessageHandler: (@Sendable (Message) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_mach_service(machService, nil, $0, &$1) },
                                         options: options, requirement: requirement)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map { _xpcDecodingHandler($0) },
                  cancellationHandler: cancellationHandler)
  }

  @preconcurrency
  public convenience init(
    machService: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement,
    incomingMessageHandler: (@Sendable (XPCReceivedMessage) -> Encodable?)? = nil,
    cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
  ) throws {
    let session = try XPCSession._create({ _finch_xpc_session_create_mach_service(machService, nil, $0, &$1) },
                                         options: options, requirement: requirement)
    try self.init(_session: session, targetQueue: targetQueue, options: options,
                  incomingMessageHandler: incomingMessageHandler.map(_xpcReceivedHandler),
                  cancellationHandler: cancellationHandler)
  }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
extension XPCSession: @unchecked Sendable {}
