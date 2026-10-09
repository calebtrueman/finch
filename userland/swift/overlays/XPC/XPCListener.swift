// SPDX-License-Identifier: MIT OR Apache-2.0
// XPCListener and XPCPeerHandler: Finch's implementation over libxpc's
// listener API, with the declarations of Apple's XPC overlay (macOS 26.4).

@_exported import XPC
import Dispatch
@_implementationOnly import _FinchXPCShims

@available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@preconcurrency
public protocol XPCPeerHandler: Sendable {
  associatedtype Input
  associatedtype Output
  func handleIncomingRequest(_: Input) -> Output?
  func handleCancellation(error: XPCRichError)
}

@available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
extension XPCPeerHandler {
  public func handleCancellation(error: XPCRichError) {
  }
}

@available(macOS 14.0, macCatalyst 17.0, *)
public class XPCListener {
  @available(macOS 14.0, macCatalyst 17.0, *)
  public struct InitializationOptions: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let none = InitializationOptions([])
    public static let inactive = InitializationOptions(rawValue: 1 << 0)
  }

  /// A peer asking for a session; the listener's handler answers with a
  /// Decision made by one of its accept or reject methods.
  public class IncomingSessionRequest {
    public struct Decision {
      internal let rejectionReason: String?
    }

    internal let _peer: xpc_object_t

    internal init(peer: xpc_object_t) {
      _peer = peer
    }

    private func accept(handler: @escaping (xpc_object_t) -> Void,
                        cancellationHandler: (@Sendable (XPCRichError) -> Void)?) -> Decision {
      _finch_xpc_session_set_incoming_message_handler(_peer, handler)
      if let cancellationHandler {
        _finch_xpc_session_set_cancel_handler(_peer) { cancellationHandler(XPCRichError($0)) }
      }
      return Decision(rejectionReason: nil)
    }

    @preconcurrency
    public func accept(
      incomingMessageHandler: @escaping @Sendable (XPCDictionary) -> XPCDictionary?,
      cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
    ) -> Decision {
      return accept(handler: _xpcDictionaryHandler(incomingMessageHandler),
                    cancellationHandler: cancellationHandler)
    }

    @preconcurrency
    public func accept<Message: Decodable>(
      incomingMessageHandler: @escaping @Sendable (Message) -> Encodable?,
      cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
    ) -> Decision {
      return accept(handler: _xpcDecodingHandler(incomingMessageHandler),
                    cancellationHandler: cancellationHandler)
    }

    @preconcurrency
    public func accept(
      incomingMessageHandler: @escaping @Sendable (XPCReceivedMessage) -> Encodable?,
      cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
    ) -> Decision {
      return accept(handler: _xpcReceivedHandler(incomingMessageHandler),
                    cancellationHandler: cancellationHandler)
    }

    @preconcurrency
    public func accept(
      incomingMessageHandler: @escaping @Sendable (XPCDictionary) -> XPCDictionary?,
      cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
    ) -> (Decision, XPCSession) {
      return (accept(handler: _xpcDictionaryHandler(incomingMessageHandler),
                     cancellationHandler: cancellationHandler), XPCSession(_peer: _peer))
    }

    @preconcurrency
    public func accept<Message: Decodable>(
      incomingMessageHandler: @escaping @Sendable (Message) -> Encodable?,
      cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
    ) -> (Decision, XPCSession) {
      return (accept(handler: _xpcDecodingHandler(incomingMessageHandler),
                     cancellationHandler: cancellationHandler), XPCSession(_peer: _peer))
    }

    @preconcurrency
    public func accept(
      incomingMessageHandler: @escaping @Sendable (XPCReceivedMessage) -> Encodable?,
      cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
    ) -> (Decision, XPCSession) {
      return (accept(handler: _xpcReceivedHandler(incomingMessageHandler),
                     cancellationHandler: cancellationHandler), XPCSession(_peer: _peer))
    }

    public func accept<Handler: XPCPeerHandler>(
      _ inactiveSessionHandler: (XPCSession) -> Handler
    ) -> Decision where Handler.Input == XPCDictionary, Handler.Output == XPCDictionary {
      let handler = inactiveSessionHandler(XPCSession(_peer: _peer))
      return accept(handler: _xpcDictionaryHandler { handler.handleIncomingRequest($0) },
                    cancellationHandler: { handler.handleCancellation(error: $0) })
    }

    public func accept<Handler: XPCPeerHandler>(
      _ inactiveSessionHandler: (XPCSession) -> Handler
    ) -> Decision where Handler.Input: Decodable, Handler.Output == Encodable {
      let handler = inactiveSessionHandler(XPCSession(_peer: _peer))
      return accept(handler: _xpcDecodingHandler { (input: Handler.Input) in handler.handleIncomingRequest(input) },
                    cancellationHandler: { handler.handleCancellation(error: $0) })
    }

    public func accept<Handler: XPCPeerHandler>(
      _ inactiveSessionHandler: (XPCSession) -> Handler
    ) -> Decision where Handler.Input == XPCReceivedMessage, Handler.Output == Encodable {
      let handler = inactiveSessionHandler(XPCSession(_peer: _peer))
      return accept(handler: _xpcReceivedHandler { handler.handleIncomingRequest($0) },
                    cancellationHandler: { handler.handleCancellation(error: $0) })
    }

    public func reject(reason: String) -> Decision {
      return Decision(rejectionReason: reason)
    }

    /// Accepts the peer, giving the caller its session to configure.
    public func _accept(_ configure: (XPCSession) -> Void) -> Decision {
      configure(XPCSession(_peer: _peer))
      return Decision(rejectionReason: nil)
    }

    deinit {
    }
  }

  internal let _listener: xpc_listener_t
  internal let _targetQueue: DispatchQueue?

  /// The C handler: asks `handler` and rejects the peer if it says so.
  internal static func _sessionHandler(
    _ handler: @escaping @Sendable (IncomingSessionRequest) -> IncomingSessionRequest.Decision
  ) -> (xpc_object_t) -> Void {
    return { peer in
      let decision = handler(IncomingSessionRequest(peer: peer))
      if let reason = decision.rejectionReason {
        _finch_xpc_listener_reject_peer(peer, reason)
      }
    }
  }

  @preconcurrency
  public init(
    service: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingSessionHandler: @escaping @Sendable (IncomingSessionRequest) -> IncomingSessionRequest.Decision
  ) throws {
    var error: xpc_object_t?
    guard let listener = _finch_xpc_listener_create(
      service, targetQueue, options.rawValue, XPCListener._sessionHandler(incomingSessionHandler), &error)
    else {
      throw _xpcError(error)
    }
    _listener = listener
    _targetQueue = targetQueue
  }

  @available(macOS 15.0, macCatalyst 18.0, *)
  @preconcurrency
  public init(
    targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    incomingSessionHandler: @escaping @Sendable (IncomingSessionRequest) -> IncomingSessionRequest.Decision
  ) {
    var error: xpc_object_t?
    guard let listener = _finch_xpc_listener_create_anonymous(
      targetQueue, options.rawValue, XPCListener._sessionHandler(incomingSessionHandler), &error)
    else {
      fatalError("XPCListener: \(_xpcError(error).debugDescription)")
    }
    _listener = listener
    _targetQueue = targetQueue
  }

  public func activate() throws {
    var error: xpc_object_t?
    if !_finch_xpc_listener_activate(_listener, &error) {
      throw _xpcError(error)
    }
  }

  public func cancel() {
    _finch_xpc_listener_cancel(_listener)
  }

  /// Replaces the handler that answers incoming sessions.
  public func setIncomingSessionHandler(
    _ handler: @escaping @Sendable (IncomingSessionRequest) -> IncomingSessionRequest.Decision
  ) {
    _finch_xpc_listener_set_incoming_session_handler(_listener, XPCListener._sessionHandler(handler))
  }

  deinit {
  }
}

@available(macOS 14.0, macCatalyst 17.0, *)
extension XPCListener.IncomingSessionRequest {
    public func withUnsafeAuditToken<T>(_ body: (audit_token_t) throws -> T) rethrows -> T {
      var token = audit_token_t()
      _finch_xpc_session_get_peer_audit_token(_peer, &token)
      return try body(token)
    }

    @available(macOS 26.0, macCatalyst 26.0, *)
    public func satisfies(requirement: XPCPeerRequirement) -> Bool {
      return withUnsafeAuditToken { $0.satisfies(requirement: requirement) }
    }
}

@available(macOS 14.0, macCatalyst 17.0, *)
extension XPCListener {
  public var targetQueue: DispatchQueue? { _targetQueue }

  @available(macOS 26.0, macCatalyst 26.0, *)
  public func setPeerRequirement(_ requirement: XPCPeerRequirement) {
    _finch_xpc_listener_set_peer_requirement(_listener, requirement._object)
  }
}

@available(macOS 15.0, macCatalyst 18.0, *)
extension XPCListener {
  public var endpoint: XPCEndpoint {
    return XPCEndpoint(_finch_xpc_listener_create_endpoint(_listener))
  }
}

@available(macOS 14.0, macCatalyst 17.0, *)
extension XPCListener: CustomDebugStringConvertible {
  public var debugDescription: String {
    return _xpcTakeString(_finch_xpc_listener_copy_description(_listener))
  }
}

@available(macOS 26.0, macCatalyst 26.0, *)
extension XPCListener {
  /// The listener is made inactive, given the requirement, then activated
  /// as the options say.
  @preconcurrency
  public convenience init(
    service: String, targetQueue: DispatchQueue? = nil, options: InitializationOptions = .none,
    requirement: XPCPeerRequirement,
    incomingSessionHandler: @escaping @Sendable (IncomingSessionRequest) -> IncomingSessionRequest.Decision
  ) throws {
    try self.init(service: service, targetQueue: targetQueue, options: options.union(.inactive),
                  incomingSessionHandler: incomingSessionHandler)
    setPeerRequirement(requirement)
    if !options.contains(.inactive) {
      try activate()
    }
  }
}

@available(macOS 26.0, macCatalyst 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *)
extension XPCListener: @unchecked Sendable {}
