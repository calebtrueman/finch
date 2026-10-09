// SPDX-License-Identifier: MIT OR Apache-2.0
// The XPC overlay (libswiftXPC): Finch's implementation over Finch's libxpc,
// with the declarations of Apple's overlay (macOS 26.4 SDK). This file: the
// C constants, the Swift spellings of the C session and listener functions
// (the SDK hides the C ones from Swift), and small helpers.

@_exported import XPC
import Dispatch
@_implementationOnly import _FinchXPCShims

// MARK: Constants

public var XPC_TYPE_CONNECTION: xpc_type_t { _finch_xpc_type_CONNECTION() }
public var XPC_TYPE_ENDPOINT: xpc_type_t { _finch_xpc_type_ENDPOINT() }
public var XPC_TYPE_NULL: xpc_type_t { _finch_xpc_type_NULL() }
public var XPC_TYPE_BOOL: xpc_type_t { _finch_xpc_type_BOOL() }
public var XPC_TYPE_INT64: xpc_type_t { _finch_xpc_type_INT64() }
public var XPC_TYPE_UINT64: xpc_type_t { _finch_xpc_type_UINT64() }
public var XPC_TYPE_DOUBLE: xpc_type_t { _finch_xpc_type_DOUBLE() }
public var XPC_TYPE_DATE: xpc_type_t { _finch_xpc_type_DATE() }
public var XPC_TYPE_DATA: xpc_type_t { _finch_xpc_type_DATA() }
public var XPC_TYPE_STRING: xpc_type_t { _finch_xpc_type_STRING() }
public var XPC_TYPE_UUID: xpc_type_t { _finch_xpc_type_UUID() }
public var XPC_TYPE_FD: xpc_type_t { _finch_xpc_type_FD() }
public var XPC_TYPE_SHMEM: xpc_type_t { _finch_xpc_type_SHMEM() }
public var XPC_TYPE_ARRAY: xpc_type_t { _finch_xpc_type_ARRAY() }
public var XPC_TYPE_DICTIONARY: xpc_type_t { _finch_xpc_type_DICTIONARY() }
public var XPC_TYPE_ERROR: xpc_type_t { _finch_xpc_type_ERROR() }
public var XPC_TYPE_ACTIVITY: xpc_type_t { _finch_xpc_type_ACTIVITY() }
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public var XPC_TYPE_RICH_ERROR: xpc_type_t { _finch_xpc_type_RICH_ERROR() }
// libxpc's private types (SPI of Apple's overlay).
public var XPC_TYPE_PIPE: xpc_type_t { _finch_xpc_type_PIPE() }
public var XPC_TYPE_BUNDLE: xpc_type_t { _finch_xpc_type_BUNDLE() }
public var XPC_TYPE_POINTER: xpc_type_t { _finch_xpc_type_POINTER() }
public var XPC_TYPE_SERVICE: xpc_type_t { _finch_xpc_type_SERVICE() }
public var XPC_TYPE_MACH_RECV: xpc_type_t { _finch_xpc_type_MACH_RECV() }
public var XPC_TYPE_MACH_SEND: xpc_type_t { _finch_xpc_type_MACH_SEND() }
public var XPC_TYPE_SERIALIZER: xpc_type_t { _finch_xpc_type_SERIALIZER() }
public var XPC_TYPE_FILE_TRANSFER: xpc_type_t { _finch_xpc_type_FILE_TRANSFER() }
public var XPC_TYPE_MACH_SEND_ONCE: xpc_type_t { _finch_xpc_type_MACH_SEND_ONCE() }
public var XPC_TYPE_SERVICE_INSTANCE: xpc_type_t { _finch_xpc_type_SERVICE_INSTANCE() }

nonisolated(unsafe) public let XPC_ERROR_KEY_DESCRIPTION: UnsafePointer<CChar> = _xpc_error_key_description
nonisolated(unsafe) public let XPC_EVENT_KEY_NAME: UnsafePointer<CChar> = _xpc_event_key_name

public var XPC_BOOL_TRUE: xpc_object_t { _finch_xpc_bool_true() }
public var XPC_BOOL_FALSE: xpc_object_t { _finch_xpc_bool_false() }
public var XPC_ARRAY_APPEND: size_t { return -1 }

public var XPC_ERROR_CONNECTION_INTERRUPTED: xpc_object_t { _finch_xpc_error_connection_interrupted() }
public var XPC_ERROR_CONNECTION_INVALID: xpc_object_t { _finch_xpc_error_connection_invalid() }
public var XPC_ERROR_TERMINATION_IMMINENT: xpc_object_t { _finch_xpc_error_termination_imminent() }
@available(macOS 12.0, macCatalyst 15.0, *)
public var XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT: xpc_object_t {
  _finch_xpc_error_peer_code_signing_requirement()
}

// MARK: Helpers

/// A malloc'd C string from libxpc, as a String (freed).
internal func _xpcTakeString(_ p: UnsafeMutablePointer<CChar>?) -> String {
  guard let p else { return "" }
  defer { free(p) }
  return String(cString: p)
}

internal func _xpcDescription(_ object: xpc_object_t) -> String {
  return _xpcTakeString(xpc_copy_description(object))
}

/// The value as T, if it is an XPC integer that fits.
internal func _xpcInteger<T: BinaryInteger>(_ value: xpc_object_t) -> T? {
  let type = xpc_get_type(value)
  if type == XPC_TYPE_INT64 { return T(exactly: xpc_int64_get_value(value)) }
  if type == XPC_TYPE_UINT64 { return T(exactly: xpc_uint64_get_value(value)) }
  return nil
}

internal func _xpcFloat<T: BinaryFloatingPoint>(_ value: xpc_object_t) -> T? {
  return xpc_get_type(value) == XPC_TYPE_DOUBLE ? T(xpc_double_get_value(value)) : nil
}

internal func _xpcBool(_ value: xpc_object_t) -> Bool? {
  return xpc_get_type(value) == XPC_TYPE_BOOL ? xpc_bool_get_value(value) : nil
}

internal func _xpcString(_ value: xpc_object_t) -> String? {
  guard xpc_get_type(value) == XPC_TYPE_STRING, let p = xpc_string_get_string_ptr(value) else {
    return nil
  }
  return String(cString: p)
}

internal func _xpcIsKind(_ value: xpc_object_t, _ type: any OS_xpc_object.Type) -> Bool {
  if let cls = type as? AnyClass {
    return (value as AnyObject).isKind(of: cls)
  }
  return true
}

// MARK: The C session API, as the overlay presents it to Swift

@available(macOS 13.0, macCatalyst 16.0, *)
public typealias xpc_session_t = OS_xpc_object

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_copy_description(_ session: OS_xpc_object) -> UnsafeMutablePointer<CChar>? {
  return _finch_xpc_session_copy_description(session)
}

@available(macOS, introduced: 13.0, deprecated: 14.0, renamed: "XPCSession.InitializationOptions")
public struct xpc_session_create_flags_t: OptionSet, @unchecked Sendable {
  public private(set) var rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static let none = xpc_session_create_flags_t([])
  public static let privileged = xpc_session_create_flags_t(rawValue: 1 << 1)
  public static let inactive = xpc_session_create_flags_t(rawValue: 1 << 0)
}

public typealias xpc_session_cancel_handler_t = (xpc_rich_error_t) -> Void
public typealias xpc_session_incoming_message_handler_t = (xpc_object_t) -> Void
public typealias xpc_session_reply_handler_t = (xpc_object_t?, xpc_rich_error_t?) -> Void

@available(macOS 13.0, macCatalyst 16.0, *)
public func xpc_session_create_xpc_service(
  _ name: UnsafePointer<CChar>, _ target_queue: dispatch_queue_t?,
  _ flags: xpc_session_create_flags_t,
  _ error_out: AutoreleasingUnsafeMutablePointer<xpc_rich_error_t?>?
) -> OS_xpc_object? {
  var error: xpc_object_t?
  let session = _finch_xpc_session_create_xpc_service(name, target_queue, flags.rawValue, &error)
  error_out?.pointee = error
  return session
}

@available(macOS 13.0, macCatalyst 16.0, *)
public func xpc_session_create_mach_service(
  _ mach_service: UnsafePointer<CChar>, _ target_queue: dispatch_queue_t?,
  _ flags: xpc_session_create_flags_t,
  _ error_out: AutoreleasingUnsafeMutablePointer<xpc_rich_error_t?>?
) -> OS_xpc_object? {
  var error: xpc_object_t?
  let session = _finch_xpc_session_create_mach_service(mach_service, target_queue, flags.rawValue, &error)
  error_out?.pointee = error
  return session
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_set_incoming_message_handler(
  _ session: OS_xpc_object, _ handler: @escaping xpc_session_incoming_message_handler_t
) {
  _finch_xpc_session_set_incoming_message_handler(session, handler)
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_set_cancel_handler(
  _ session: OS_xpc_object, _ cancel_handler: @escaping xpc_session_cancel_handler_t
) {
  _finch_xpc_session_set_cancel_handler(session, cancel_handler)
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_set_target_queue(_ session: OS_xpc_object, _ target_queue: dispatch_queue_t?) {
  _finch_xpc_session_set_target_queue(session, target_queue)
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_activate(
  _ session: OS_xpc_object, _ error_out: AutoreleasingUnsafeMutablePointer<xpc_rich_error_t?>?
) -> Bool {
  var error: xpc_object_t?
  let ok = _finch_xpc_session_activate(session, &error)
  error_out?.pointee = error
  return ok
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_cancel(_ session: OS_xpc_object) {
  _finch_xpc_session_cancel(session)
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_send_message(_ session: OS_xpc_object, _ message: xpc_object_t) -> xpc_rich_error_t? {
  return _finch_xpc_session_send_message(session, message)
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_send_message_with_reply_sync(
  _ session: OS_xpc_object, _ message: xpc_object_t,
  _ error_out: AutoreleasingUnsafeMutablePointer<xpc_rich_error_t?>?
) -> xpc_object_t? {
  var error: xpc_object_t?
  let reply = _finch_xpc_session_send_message_with_reply_sync(session, message, &error)
  error_out?.pointee = error
  return reply
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func xpc_session_send_message_with_reply_async(
  _ session: OS_xpc_object, _ message: xpc_object_t,
  _ reply_handler: @escaping xpc_session_reply_handler_t
) {
  _finch_xpc_session_send_message_with_reply_async(session, message, reply_handler)
}

// MARK: The C listener API (unavailable: XPCListener replaces it)

public typealias xpc_listener_t = OS_xpc_listener

@available(*, unavailable, renamed: "XPCListener.InitializationOptions")
public struct xpc_listener_create_flags_t {}

@available(*, unavailable, message: "see XPCListener(service:) and XPCListener.XPCPeerHandler")
public typealias xpc_listener_incoming_session_handler_t = (OS_xpc_object) -> Void

@available(*, unavailable, renamed: "debugDescription")
public func xpc_listener_copy_description(_ listener: xpc_listener_t) -> UnsafeMutablePointer<CChar>? {
  return _finch_xpc_listener_copy_description(listener)
}

@available(*, unavailable, renamed: "XPCListener(service:)")
public func xpc_listener_create(
  _ service: UnsafePointer<CChar>, _ target_queue: dispatch_queue_t?,
  _ flags: xpc_listener_create_flags_t,
  _ incoming_session_handler: @escaping xpc_listener_incoming_session_handler_t,
  _ error_out: AutoreleasingUnsafeMutablePointer<xpc_rich_error_t?>?
) -> xpc_listener_t? {
  var error: xpc_object_t?
  let listener = _finch_xpc_listener_create(service, target_queue, 0, incoming_session_handler, &error)
  error_out?.pointee = error
  return listener
}

@available(*, unavailable, renamed: "activate()")
public func xpc_listener_activate(
  _ listener: xpc_listener_t, _ error_out: AutoreleasingUnsafeMutablePointer<xpc_rich_error_t?>?
) -> Bool {
  var error: xpc_object_t?
  let ok = _finch_xpc_listener_activate(listener, &error)
  error_out?.pointee = error
  return ok
}

@available(*, unavailable, renamed: "cancel()")
public func xpc_listener_cancel(_ listener: xpc_listener_t) {
  _finch_xpc_listener_cancel(listener)
}

@available(*, unavailable, renamed: "XPCListener.IncomingSessionRequest.reject(reason:)")
public func xpc_listener_reject_peer(_ peer: OS_xpc_object, _ reason: UnsafePointer<CChar>) {
  _finch_xpc_listener_reject_peer(peer, reason)
}

// MARK: Reference counting (ARC does this in Swift)

@available(macOS, introduced: 10.7, deprecated: 14.4,
           message: "Use Swift's automatic reference counting to manage the lifetime of XPC objects")
public func xpc_retain(_ object: xpc_object_t) -> xpc_object_t {
  return object
}

@available(macOS, introduced: 10.7, deprecated: 14.4,
           message: "Use Swift's automatic reference counting to manage the lifetime of XPC objects")
public func xpc_release(_ object: xpc_object_t) {
}

// MARK: UUIDs (Apple's overlay has these for its own use)

public func xpc_uuid_create_with_uuid(_ uuid: uuid_t) -> xpc_object_t {
  var u = uuid
  return withUnsafeBytes(of: &u) { xpc_uuid_create($0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
}

public func xpc_uuid_get_uuid(_ object: xpc_object_t) -> uuid_t? {
  guard xpc_get_type(object) == XPC_TYPE_UUID, let bytes = xpc_uuid_get_bytes(object) else {
    return nil
  }
  var u: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  withUnsafeMutableBytes(of: &u) { $0.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 16)) }
  return u
}
