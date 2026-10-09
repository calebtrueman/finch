// SPDX-License-Identifier: MIT OR Apache-2.0
// Codable over XPC: Finch's encoder and decoder between Swift values and
// XPC objects (keyed containers are XPC dictionaries, unkeyed ones XPC
// arrays, and scalars the XPC scalar types), used by XPCSession's Codable
// messages, plus the coding SPI Apple's overlay exports (XPCCodableObject,
// XPCEncodedContents, TopLevelGraphEncodingNode). The wire format is
// Finch's own: Finch's processes talk to Finch's.
//
// A message whose value isn't keyed travels as a dictionary holding it
// under _XPCMessageValueKey.

@_exported import XPC
@_implementationOnly import _FinchXPCShims

internal let _XPCMessageValueKey = "org.finch.xpc.value"

// MARK: Encoding

internal final class _XPCObjectEncoder: Encoder {
  var codingPath: [CodingKey]
  var userInfo: [CodingUserInfoKey: Any]
  /// The encoded value; containers are created on first use and filled in place.
  var object: xpc_object_t?

  init(codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any]) {
    self.codingPath = codingPath
    self.userInfo = userInfo
  }

  func storeObject(_ value: xpc_object_t) {
    object = value
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let dictionary: xpc_object_t
    if let existing = object, xpc_get_type(existing) == XPC_TYPE_DICTIONARY {
      dictionary = existing
    } else {
      dictionary = xpc_dictionary_create_empty()
      object = dictionary
    }
    return KeyedEncodingContainer(_XPCKeyedEncodingContainer<Key>(
      dictionary: dictionary, codingPath: codingPath, userInfo: userInfo))
  }

  func unkeyedContainer() -> UnkeyedEncodingContainer {
    let array: xpc_object_t
    if let existing = object, xpc_get_type(existing) == XPC_TYPE_ARRAY {
      array = existing
    } else {
      array = xpc_array_create_empty()
      object = array
    }
    return _XPCUnkeyedEncodingContainer(array: array, codingPath: codingPath, userInfo: userInfo)
  }

  func singleValueContainer() -> SingleValueEncodingContainer {
    return _XPCSingleValueEncodingContainer(encoder: self)
  }

  /// Encodes `value` to an XPC object.
  static func encode<T: Encodable>(_ value: T, codingPath: [CodingKey],
                                   userInfo: [CodingUserInfoKey: Any]) throws -> xpc_object_t {
    if let scalar = _xpcScalar(value) { return scalar }
    let encoder = _XPCObjectEncoder(codingPath: codingPath, userInfo: userInfo)
    try value.encode(to: encoder)
    return encoder.object ?? xpc_dictionary_create_empty()
  }
}

/// The XPC object for a value of a type XPC holds directly.
internal func _xpcScalar(_ value: Any) -> xpc_object_t? {
  switch value {
  case let v as Bool: return xpc_bool_create(v)
  case let v as String: return xpc_string_create(v)
  case let v as Double: return xpc_double_create(v)
  case let v as Float: return xpc_double_create(Double(v))
  case let v as Int: return xpc_int64_create(Int64(v))
  case let v as Int8: return xpc_int64_create(Int64(v))
  case let v as Int16: return xpc_int64_create(Int64(v))
  case let v as Int32: return xpc_int64_create(Int64(v))
  case let v as Int64: return xpc_int64_create(v)
  case let v as UInt: return xpc_uint64_create(UInt64(v))
  case let v as UInt8: return xpc_uint64_create(UInt64(v))
  case let v as UInt16: return xpc_uint64_create(UInt64(v))
  case let v as UInt32: return xpc_uint64_create(UInt64(v))
  case let v as UInt64: return xpc_uint64_create(v)
  default: return nil
  }
}

private struct _XPCKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let dictionary: xpc_object_t
  var codingPath: [CodingKey]
  let userInfo: [CodingUserInfoKey: Any]

  init(dictionary: xpc_object_t, codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any]) {
    self.dictionary = dictionary
    self.codingPath = codingPath
    self.userInfo = userInfo
  }

  mutating func encodeNil(forKey key: Key) throws {
    xpc_dictionary_set_value(dictionary, key.stringValue, xpc_null_create())
  }

  mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    let object = try _XPCObjectEncoder.encode(value, codingPath: codingPath + [key], userInfo: userInfo)
    xpc_dictionary_set_value(dictionary, key.stringValue, object)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type, forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    let nested = xpc_dictionary_create_empty()
    xpc_dictionary_set_value(dictionary, key.stringValue, nested)
    return KeyedEncodingContainer(_XPCKeyedEncodingContainer<NestedKey>(
      dictionary: nested, codingPath: codingPath + [key], userInfo: userInfo))
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
    let nested = xpc_array_create_empty()
    xpc_dictionary_set_value(dictionary, key.stringValue, nested)
    return _XPCUnkeyedEncodingContainer(array: nested, codingPath: codingPath + [key], userInfo: userInfo)
  }

  mutating func superEncoder() -> Encoder {
    return superEncoder(forKey: Key(stringValue: "super")!)
  }

  mutating func superEncoder(forKey key: Key) -> Encoder {
    let nested = xpc_dictionary_create_empty()
    xpc_dictionary_set_value(dictionary, key.stringValue, nested)
    let encoder = _XPCObjectEncoder(codingPath: codingPath + [key], userInfo: userInfo)
    encoder.object = nested
    return encoder
  }
}

private struct _XPCIndexKey: CodingKey {
  var stringValue: String
  var intValue: Int?
  init?(stringValue: String) { self.stringValue = stringValue; intValue = Int(stringValue) }
  init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

private struct _XPCUnkeyedEncodingContainer: UnkeyedEncodingContainer {
  let array: xpc_object_t
  var codingPath: [CodingKey]
  let userInfo: [CodingUserInfoKey: Any]
  var count: Int { xpc_array_get_count(array) }

  init(array: xpc_object_t, codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any]) {
    self.array = array
    self.codingPath = codingPath
    self.userInfo = userInfo
  }

  mutating func encodeNil() throws {
    xpc_array_append_value(array, xpc_null_create())
  }

  mutating func encode<T: Encodable>(_ value: T) throws {
    let path = codingPath + [_XPCIndexKey(intValue: count)]
    xpc_array_append_value(array, try _XPCObjectEncoder.encode(value, codingPath: path, userInfo: userInfo))
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type
  ) -> KeyedEncodingContainer<NestedKey> {
    let nested = xpc_dictionary_create_empty()
    let path = codingPath + [_XPCIndexKey(intValue: count)]
    xpc_array_append_value(array, nested)
    return KeyedEncodingContainer(_XPCKeyedEncodingContainer<NestedKey>(
      dictionary: nested, codingPath: path, userInfo: userInfo))
  }

  mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
    let nested = xpc_array_create_empty()
    let path = codingPath + [_XPCIndexKey(intValue: count)]
    xpc_array_append_value(array, nested)
    return _XPCUnkeyedEncodingContainer(array: nested, codingPath: path, userInfo: userInfo)
  }

  mutating func superEncoder() -> Encoder {
    let nested = xpc_dictionary_create_empty()
    let path = codingPath + [_XPCIndexKey(intValue: count)]
    xpc_array_append_value(array, nested)
    let encoder = _XPCObjectEncoder(codingPath: path, userInfo: userInfo)
    encoder.object = nested
    return encoder
  }
}

private struct _XPCSingleValueEncodingContainer: SingleValueEncodingContainer {
  let encoder: _XPCObjectEncoder
  var codingPath: [CodingKey] { encoder.codingPath }

  mutating func encodeNil() throws {
    encoder.object = xpc_null_create()
  }

  mutating func encode<T: Encodable>(_ value: T) throws {
    encoder.object = try _XPCObjectEncoder.encode(value, codingPath: codingPath, userInfo: encoder.userInfo)
  }
}

// MARK: Decoding

internal final class _XPCObjectDecoder: Decoder {
  let object: xpc_object_t
  var codingPath: [CodingKey]
  var userInfo: [CodingUserInfoKey: Any]

  init(object: xpc_object_t, codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any]) {
    self.object = object
    self.codingPath = codingPath
    self.userInfo = userInfo
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else {
      throw DecodingError.typeMismatch([String: Any].self, DecodingError.Context(
        codingPath: codingPath, debugDescription: "expected an XPC dictionary"))
    }
    return KeyedDecodingContainer(_XPCKeyedDecodingContainer<Key>(
      dictionary: object, codingPath: codingPath, userInfo: userInfo))
  }

  func unkeyedContainer() throws -> UnkeyedDecodingContainer {
    guard xpc_get_type(object) == XPC_TYPE_ARRAY else {
      throw DecodingError.typeMismatch([Any].self, DecodingError.Context(
        codingPath: codingPath, debugDescription: "expected an XPC array"))
    }
    return _XPCUnkeyedDecodingContainer(array: object, codingPath: codingPath, userInfo: userInfo)
  }

  func singleValueContainer() throws -> SingleValueDecodingContainer {
    return _XPCSingleValueDecodingContainer(decoder: self)
  }

  static func decode<T: Decodable>(_ type: T.Type, from object: xpc_object_t,
                                   codingPath: [CodingKey],
                                   userInfo: [CodingUserInfoKey: Any]) throws -> T {
    if let scalar = try _xpcDecodeScalar(type, object, codingPath) { return scalar }
    return try T(from: _XPCObjectDecoder(object: object, codingPath: codingPath, userInfo: userInfo))
  }
}

/// A scalar of type T from an XPC object, nil if T isn't a scalar type.
internal func _xpcDecodeScalar<T>(_ type: T.Type, _ object: xpc_object_t,
                                  _ codingPath: [CodingKey]) throws -> T? {
  func mismatch() -> DecodingError {
    return DecodingError.typeMismatch(type, DecodingError.Context(
      codingPath: codingPath, debugDescription: "XPC value is \(_xpcDescription(object))"))
  }
  func integer<I: BinaryInteger>(_: I.Type) throws -> I {
    guard let v: I = _xpcInteger(object) else { throw mismatch() }
    return v
  }
  switch type {
  case is Bool.Type:
    guard let v = _xpcBool(object) else { throw mismatch() }
    return (v as! T)
  case is String.Type:
    guard let v = _xpcString(object) else { throw mismatch() }
    return (v as! T)
  case is Double.Type:
    guard let v: Double = _xpcFloat(object) else { throw mismatch() }
    return (v as! T)
  case is Float.Type:
    guard let v: Float = _xpcFloat(object) else { throw mismatch() }
    return (v as! T)
  case is Int.Type: return (try integer(Int.self) as! T)
  case is Int8.Type: return (try integer(Int8.self) as! T)
  case is Int16.Type: return (try integer(Int16.self) as! T)
  case is Int32.Type: return (try integer(Int32.self) as! T)
  case is Int64.Type: return (try integer(Int64.self) as! T)
  case is UInt.Type: return (try integer(UInt.self) as! T)
  case is UInt8.Type: return (try integer(UInt8.self) as! T)
  case is UInt16.Type: return (try integer(UInt16.self) as! T)
  case is UInt32.Type: return (try integer(UInt32.self) as! T)
  case is UInt64.Type: return (try integer(UInt64.self) as! T)
  default: return nil
  }
}

private struct _XPCKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let dictionary: xpc_object_t
  var codingPath: [CodingKey]
  let userInfo: [CodingUserInfoKey: Any]

  var allKeys: [Key] {
    return XPCDictionary(dictionary).keys.compactMap { Key(stringValue: $0) }
  }

  func contains(_ key: Key) -> Bool {
    return xpc_dictionary_get_value(dictionary, key.stringValue) != nil
  }

  func value(_ key: Key) throws -> xpc_object_t {
    guard let v = xpc_dictionary_get_value(dictionary, key.stringValue) else {
      throw DecodingError.keyNotFound(key, DecodingError.Context(
        codingPath: codingPath, debugDescription: "no value for \(key.stringValue)"))
    }
    return v
  }

  func decodeNil(forKey key: Key) throws -> Bool {
    return xpc_get_type(try value(key)) == XPC_TYPE_NULL
  }

  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    return try _XPCObjectDecoder.decode(type, from: try value(key), codingPath: codingPath + [key],
                                        userInfo: userInfo)
  }

  func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type, forKey key: Key
  ) throws -> KeyedDecodingContainer<NestedKey> {
    return try _XPCObjectDecoder(object: try value(key), codingPath: codingPath + [key], userInfo: userInfo)
      .container(keyedBy: type)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
    return try _XPCObjectDecoder(object: try value(key), codingPath: codingPath + [key], userInfo: userInfo)
      .unkeyedContainer()
  }

  func superDecoder() throws -> Decoder {
    return try superDecoder(forKey: Key(stringValue: "super")!)
  }

  func superDecoder(forKey key: Key) throws -> Decoder {
    return _XPCObjectDecoder(object: try value(key), codingPath: codingPath + [key], userInfo: userInfo)
  }
}

private struct _XPCUnkeyedDecodingContainer: UnkeyedDecodingContainer {
  let array: xpc_object_t
  var codingPath: [CodingKey]
  let userInfo: [CodingUserInfoKey: Any]
  var currentIndex = 0

  init(array: xpc_object_t, codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any]) {
    self.array = array
    self.codingPath = codingPath
    self.userInfo = userInfo
  }

  var count: Int? { xpc_array_get_count(array) }
  var isAtEnd: Bool { currentIndex >= xpc_array_get_count(array) }

  mutating func next() throws -> (xpc_object_t, [CodingKey]) {
    guard !isAtEnd else {
      throw DecodingError.valueNotFound(Any.self, DecodingError.Context(
        codingPath: codingPath, debugDescription: "unkeyed container is at its end"))
    }
    let path = codingPath + [_XPCIndexKey(intValue: currentIndex)]
    let value = xpc_array_get_value(array, currentIndex)
    currentIndex += 1
    return (value, path)
  }

  mutating func decodeNil() throws -> Bool {
    guard !isAtEnd else { return false }
    if xpc_get_type(xpc_array_get_value(array, currentIndex)) == XPC_TYPE_NULL {
      currentIndex += 1
      return true
    }
    return false
  }

  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let (value, path) = try next()
    return try _XPCObjectDecoder.decode(type, from: value, codingPath: path, userInfo: userInfo)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type
  ) throws -> KeyedDecodingContainer<NestedKey> {
    let (value, path) = try next()
    return try _XPCObjectDecoder(object: value, codingPath: path, userInfo: userInfo).container(keyedBy: type)
  }

  mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
    let (value, path) = try next()
    return try _XPCObjectDecoder(object: value, codingPath: path, userInfo: userInfo).unkeyedContainer()
  }

  mutating func superDecoder() throws -> Decoder {
    let (value, path) = try next()
    return _XPCObjectDecoder(object: value, codingPath: path, userInfo: userInfo)
  }
}

private struct _XPCSingleValueDecodingContainer: SingleValueDecodingContainer {
  let decoder: _XPCObjectDecoder
  var codingPath: [CodingKey] { decoder.codingPath }

  func decodeNil() -> Bool {
    return xpc_get_type(decoder.object) == XPC_TYPE_NULL
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    return try _XPCObjectDecoder.decode(type, from: decoder.object, codingPath: codingPath,
                                        userInfo: decoder.userInfo)
  }
}

// MARK: Messages

/// A Codable value as an XPC message dictionary.
internal func _xpcMessage<T: Encodable>(_ value: T, userInfo: [CodingUserInfoKey: Any] = [:]) throws
  -> xpc_object_t
{
  let object = try _XPCObjectEncoder.encode(value, codingPath: [], userInfo: userInfo)
  if xpc_get_type(object) == XPC_TYPE_DICTIONARY {
    return object
  }
  let message = xpc_dictionary_create_empty()
  xpc_dictionary_set_value(message, _XPCMessageValueKey, object)
  return message
}

/// Encodes `value` into `message` (a dictionary made by the caller, such
/// as a reply).
internal func _xpcFill<T: Encodable>(_ message: xpc_object_t, with value: T,
                                     userInfo: [CodingUserInfoKey: Any] = [:]) throws {
  let object = try _xpcMessage(value, userInfo: userInfo)
  XPCDictionary(object).copy(into: XPCDictionary(message))
}

/// The Codable value a message carries.
internal func _xpcDecodeMessage<T: Decodable>(_ type: T.Type, _ message: xpc_object_t,
                                              userInfo: [CodingUserInfoKey: Any] = [:]) throws -> T {
  if xpc_get_type(message) == XPC_TYPE_DICTIONARY,
     let wrapped = xpc_dictionary_get_value(message, _XPCMessageValueKey),
     xpc_dictionary_get_count(message) == 1 {
    return try _XPCObjectDecoder.decode(type, from: wrapped, codingPath: [], userInfo: userInfo)
  }
  return try _XPCObjectDecoder.decode(type, from: message, codingPath: [], userInfo: userInfo)
}

// MARK: Coding SPI of Apple's overlay

extension CodingUserInfoKey {
  /// Set in the userInfo of the XPC encoder and decoder.
  @_spi(XPCCodable)
  public static var xpcCodable: CodingUserInfoKey {
    return CodingUserInfoKey(rawValue: "com.apple.xpc.codable")!
  }
}

/// An encoded value: the root of what the XPC encoder produced.
public final class TopLevelGraphEncodingNode {
  internal let object: xpc_object_t

  internal init(object: xpc_object_t) {
    self.object = object
  }
}

public func encodeToEncodingContainer<T: Encodable>(
  _ value: T, userInfo: [CodingUserInfoKey: Any]
) throws -> TopLevelGraphEncodingNode {
  return TopLevelGraphEncodingNode(object: try _XPCObjectEncoder.encode(value, codingPath: [], userInfo: userInfo))
}

public func decodeFromEncodingContainer<T: Decodable>(
  _ type: T.Type, from node: TopLevelGraphEncodingNode, userInfo: [CodingUserInfoKey: Any]
) throws -> T {
  return try _XPCObjectDecoder.decode(type, from: node.object, codingPath: [], userInfo: userInfo)
}

public func testEncodeDecodePipeline<T: Codable>(_ value: T, userInfo: [CodingUserInfoKey: Any]) throws -> T {
  return try decodeFromEncodingContainer(T.self, from: try encodeToEncodingContainer(value, userInfo: userInfo),
                                         userInfo: userInfo)
}

/// Also through XPC's wire form: the encoded value is copied, as sending
/// it would.
public func testEncodeDecodePipelineWithSerialization<T: Codable>(
  _ value: T, userInfo: [CodingUserInfoKey: Any]
) throws -> T {
  let node = try encodeToEncodingContainer(value, userInfo: userInfo)
  let copy = TopLevelGraphEncodingNode(object: xpc_copy(node.object) ?? node.object)
  return try decodeFromEncodingContainer(T.self, from: copy, userInfo: userInfo)
}

/// A Codable value already encoded for XPC. (This and the other coding
/// types here are SPI in Apple's overlay; being SPI, their default
/// arguments are exported functions rather than inlined into callers.)
public struct XPCEncodedContents {
  internal let message: xpc_object_t

  @_spi(XPCCodable)
  public init(value: Encodable, userInfo: [CodingUserInfoKey: Any] = [:]) throws {
    message = try _xpcMessage(value, userInfo: userInfo)
  }

  @_spi(XPCCodable)
  public func decode<T: Decodable>(as type: T.Type = T.self, userInfo: [CodingUserInfoKey: Any] = [:]) throws -> T {
    return try _xpcDecodeMessage(type, message, userInfo: userInfo)
  }
}

/// Any XPC object, carried through Codable values (XPC coding only).
public struct XPCCodableObject {
  internal let object: xpc_object_t

  public init(copying object: xpc_object_t) {
    self.object = xpc_copy(object) ?? object
  }

  public func copyUnderlyingXPCObject() -> xpc_object_t {
    return xpc_copy(object) ?? object
  }

  public var type: xpc_type_t { xpc_get_type(object) }
}

extension XPCCodableObject: Codable {
  public func encode(to encoder: Encoder) throws {
    guard let encoder = encoder as? _XPCObjectEncoder else {
      throw EncodingError.invalidValue(self, EncodingError.Context(
        codingPath: encoder.codingPath, debugDescription: "XPCCodableObject can only be encoded by XPC"))
    }
    encoder.storeObject(object)
  }

  public init(from decoder: Decoder) throws {
    guard let decoder = decoder as? _XPCObjectDecoder else {
      throw DecodingError.typeMismatch(XPCCodableObject.self, DecodingError.Context(
        codingPath: decoder.codingPath, debugDescription: "XPCCodableObject can only be decoded by XPC"))
    }
    self.init(copying: decoder.object)
  }
}

extension XPCCodableObject: Equatable, Hashable {
  public static func == (a: XPCCodableObject, b: XPCCodableObject) -> Bool {
    return xpc_equal(a.object, b.object)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(xpc_hash(object))
  }
}

extension XPCCodableObject: CustomDebugStringConvertible {
  public var debugDescription: String { _xpcDescription(object) }
}

/// A type that travels over XPC as an XPC object of its own.
public protocol XPCCodableObjectRepresentable {
  static var validXPCObjectTypes: Set<xpc_type_t> { get }
  init?(from object: XPCCodableObject)
  var xpcCodableObject: XPCCodableObject { get }
}

extension XPCCodableObjectRepresentable {
  public static var validXPCObjectTypes: Set<xpc_type_t> { [] }
}

// MARK: Audit tokens

extension audit_token_t {
  public var auid: UInt32 { val.0 }
  public var euid: UInt32 { val.1 }
  public var egid: UInt32 { val.2 }
  public var ruid: UInt32 { val.3 }
  public var rgid: UInt32 { val.4 }
  public var pid: UInt32 { val.5 }
  public var asid: UInt32 { val.6 }
  /// The process's pid version, which tells reused pids apart.
  public var execcnt: UInt32 { val.7 }

  public var isValid: Bool {
    let v = val
    return [v.0, v.1, v.2, v.3, v.4, v.5, v.6, v.7].contains { $0 != .max }
  }

  public func fromSameProcessAs(_ other: audit_token_t) -> Bool {
    return pid == other.pid && execcnt == other.execcnt
  }

  @available(macOS 26.0, macCatalyst 26.0, *)
  public func satisfies(requirement: XPCPeerRequirement) -> Bool {
    var token = self
    return _finch_xpc_peer_requirement_match_token(requirement._object, &token)
  }
}

extension Array where Element == UInt8 {
  /// The bytes in hex, as XPC's descriptions show data.
  public var byteDescription: String {
    return map { b in
      let hex = String(b, radix: 16)
      return b < 16 ? "0" + hex : hex
    }.joined()
  }
}
