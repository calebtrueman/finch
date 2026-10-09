// SPDX-License-Identifier: MIT OR Apache-2.0
// XPCArray and XPCDictionary: value views of XPC arrays and dictionaries
// with typed subscripts. Finch's implementation, Apple's declarations.

@_exported import XPC
@_implementationOnly import _FinchXPCShims

// MARK: XPCArray

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public struct XPCArray {
  internal let _object: xpc_object_t

  public init(_ value: xpc_object_t) {
    precondition(xpc_get_type(value) == XPC_TYPE_ARRAY, "XPCArray made from a non-array XPC object")
    _object = value
  }

  public init() {
    _object = xpc_array_create_empty()
  }

  public func withUnsafeUnderlyingArray<ReturnType>(
    _ closure: (xpc_object_t) throws -> ReturnType
  ) rethrows -> ReturnType {
    return try closure(_object)
  }

  internal func _value(at index: Int) -> xpc_object_t? {
    guard index >= 0, index < xpc_array_get_count(_object) else { return nil }
    return xpc_array_get_value(_object, index)
  }

  /// Sets the element at `index`, appending when `index` is the count; nil
  /// stores XPC null (XPC arrays can't shrink).
  internal func _set(_ value: xpc_object_t?, at index: Int) {
    let count = xpc_array_get_count(_object)
    precondition(index >= 0 && index <= count, "XPCArray index out of range")
    xpc_array_set_value(_object, index == count ? XPC_ARRAY_APPEND : index, value ?? xpc_null_create())
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray {
  public subscript<T: BinaryInteger>(index: Int, as type: T.Type = T.self) -> T? {
    return _value(at: index).flatMap { _xpcInteger($0) }
  }

  public subscript<T: SignedInteger>(index: Int) -> T? {
    get { return _value(at: index).flatMap { _xpcInteger($0) } }
    set { _set(newValue.map { xpc_int64_create(Int64($0)) }, at: index) }
  }

  public subscript<T: UnsignedInteger>(index: Int) -> T? {
    get { return _value(at: index).flatMap { _xpcInteger($0) } }
    set { _set(newValue.map { xpc_uint64_create(UInt64($0)) }, at: index) }
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray {
  public subscript<T: BinaryFloatingPoint>(index: Int, as type: T.Type = T.self) -> T? {
    return _value(at: index).flatMap { _xpcFloat($0) }
  }

  public subscript<T: BinaryFloatingPoint>(index: Int) -> T? {
    get { return _value(at: index).flatMap { _xpcFloat($0) } }
    set { _set(newValue.map { xpc_double_create(Double($0)) }, at: index) }
  }

  public subscript<T: BinaryFloatingPoint>(
    index: Int, as type: T.Type = T.self, default defaultValue: @autoclosure () -> T
  ) -> T {
    return _value(at: index).flatMap { _xpcFloat($0) } ?? defaultValue()
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray {
  public subscript(index: Int, as type: Bool.Type = Bool.self) -> Bool? {
    return _value(at: index).flatMap(_xpcBool)
  }

  public subscript(index: Int) -> Bool? {
    get { return _value(at: index).flatMap(_xpcBool) }
    set { _set(newValue.map { xpc_bool_create($0) }, at: index) }
  }

  public subscript(
    index: Int, as type: Bool.Type = Bool.self, default defaultValue: @autoclosure () -> Bool
  ) -> Bool {
    return _value(at: index).flatMap(_xpcBool) ?? defaultValue()
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray {
  public subscript(index: Int, as type: XPCDictionary.Type = XPCDictionary.self) -> XPCDictionary? {
    guard let v = _value(at: index), xpc_get_type(v) == XPC_TYPE_DICTIONARY else { return nil }
    return XPCDictionary(v)
  }

  public subscript(index: Int) -> XPCDictionary? {
    get {
      guard let v = _value(at: index), xpc_get_type(v) == XPC_TYPE_DICTIONARY else { return nil }
      return XPCDictionary(v)
    }
    set { _set(newValue?._object, at: index) }
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray {
  public subscript(index: Int, as type: OS_xpc_object.Type = xpc_object_t.self) -> xpc_object_t? {
    guard let v = _value(at: index), _xpcIsKind(v, type) else { return nil }
    return v
  }

  public subscript(index: Int, as type: xpc_type_t) -> xpc_object_t? {
    guard let v = _value(at: index), xpc_get_type(v) == type else { return nil }
    return v
  }

  public subscript(index: Int) -> xpc_object_t? {
    get { return _value(at: index) }
    set { _set(newValue, at: index) }
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray {
  public subscript(index: Int, as type: String.Type = String.self) -> String? {
    return _value(at: index).flatMap(_xpcString)
  }

  public subscript(index: Int) -> String? {
    get { return _value(at: index).flatMap(_xpcString) }
    set { _set(newValue.map { xpc_string_create($0) }, at: index) }
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray {
  /// Appends this array's elements to `destination`.
  public func copy(into destination: XPCArray) {
    forEach { _, value in xpc_array_append_value(destination._object, value) }
  }

  public var isEmpty: Bool { count == 0 }

  public var count: Int { xpc_array_get_count(_object) }

  internal var _elements: [IndexValuePair] {
    var elements: [IndexValuePair] = []
    xpc_array_apply(_object) { index, value in
      elements.append((index: index, value: value))
      return true
    }
    return elements
  }

  public func forEach(_ body: (_ index: Int, _ value: xpc_object_t) throws -> Void) rethrows {
    for element in _elements {
      try body(element.index, element.value)
    }
  }

  public typealias IndexValuePair = (index: Int, value: xpc_object_t)

  public func forEach(_ body: (IndexValuePair) throws -> Void) rethrows {
    for element in _elements {
      try body(element)
    }
  }

  public func map<ReturnType>(_ transform: (IndexValuePair) throws -> ReturnType) rethrows -> [ReturnType] {
    return try _elements.map(transform)
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray: Equatable {
  public static func == (lhs: XPCArray, rhs: XPCArray) -> Bool {
    return xpc_equal(lhs._object, rhs._object)
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(xpc_hash(_object))
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCArray: CustomDebugStringConvertible {
  public var debugDescription: String { _xpcDescription(_object) }
}

// MARK: XPCDictionary

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public struct XPCDictionary {
  internal let _object: xpc_object_t

  public init(_ value: xpc_object_t) {
    precondition(xpc_get_type(value) == XPC_TYPE_DICTIONARY,
                 "XPCDictionary made from a non-dictionary XPC object")
    _object = value
  }

  public init() {
    _object = xpc_dictionary_create_empty()
  }

  public func withUnsafeUnderlyingDictionary<ReturnType>(
    _ closure: (xpc_object_t) throws -> ReturnType
  ) rethrows -> ReturnType {
    return try closure(_object)
  }

  internal func _value(_ key: String) -> xpc_object_t? {
    return xpc_dictionary_get_value(_object, key)
  }

  internal func _set(_ value: xpc_object_t?, _ key: String) {
    xpc_dictionary_set_value(_object, key, value)
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  public subscript<T: BinaryInteger>(key: String, as type: T.Type = T.self) -> T? {
    return _value(key).flatMap { _xpcInteger($0) }
  }

  public subscript<T: SignedInteger>(key: String) -> T? {
    get { return _value(key).flatMap { _xpcInteger($0) } }
    set { _set(newValue.map { xpc_int64_create(Int64($0)) }, key) }
  }

  public subscript<T: UnsignedInteger>(key: String) -> T? {
    get { return _value(key).flatMap { _xpcInteger($0) } }
    set { _set(newValue.map { xpc_uint64_create(UInt64($0)) }, key) }
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  public subscript<T: BinaryFloatingPoint>(key: String, as type: T.Type = T.self) -> T? {
    return _value(key).flatMap { _xpcFloat($0) }
  }

  public subscript<T: BinaryFloatingPoint>(key: String) -> T? {
    get { return _value(key).flatMap { _xpcFloat($0) } }
    set { _set(newValue.map { xpc_double_create(Double($0)) }, key) }
  }

  public subscript<T: BinaryFloatingPoint>(
    key: String, as type: T.Type = T.self, default defaultValue: @autoclosure () -> T
  ) -> T {
    return _value(key).flatMap { _xpcFloat($0) } ?? defaultValue()
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  public subscript(key: String, as type: Bool.Type = Bool.self) -> Bool? {
    return _value(key).flatMap(_xpcBool)
  }

  public subscript(key: String) -> Bool? {
    get { return _value(key).flatMap(_xpcBool) }
    set { _set(newValue.map { xpc_bool_create($0) }, key) }
  }

  public subscript(
    key: String, as type: Bool.Type = Bool.self, default defaultValue: @autoclosure () -> Bool
  ) -> Bool {
    return _value(key).flatMap(_xpcBool) ?? defaultValue()
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  public subscript(key: String, as type: XPCDictionary.Type = XPCDictionary.self) -> XPCDictionary? {
    guard let v = _value(key), xpc_get_type(v) == XPC_TYPE_DICTIONARY else { return nil }
    return XPCDictionary(v)
  }

  public subscript(key: String) -> XPCDictionary? {
    get {
      guard let v = _value(key), xpc_get_type(v) == XPC_TYPE_DICTIONARY else { return nil }
      return XPCDictionary(v)
    }
    set { _set(newValue?._object, key) }
  }
}

@available(macOS, unavailable)
@available(iOS, unavailable)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension XPCDictionary {
  public subscript(key: String, as type: XPCArray.Type = XPCArray.self) -> XPCArray? {
    guard let v = _value(key), xpc_get_type(v) == XPC_TYPE_ARRAY else { return nil }
    return XPCArray(v)
  }

  public subscript(key: String) -> XPCArray? {
    get {
      guard let v = _value(key), xpc_get_type(v) == XPC_TYPE_ARRAY else { return nil }
      return XPCArray(v)
    }
    set { _set(newValue?._object, key) }
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  public subscript(key: String, as type: OS_xpc_object.Type = xpc_object_t.self) -> xpc_object_t? {
    guard let v = _value(key), _xpcIsKind(v, type) else { return nil }
    return v
  }

  public subscript(key: String, as type: xpc_type_t) -> xpc_object_t? {
    guard let v = _value(key), xpc_get_type(v) == type else { return nil }
    return v
  }

  public subscript(key: String) -> xpc_object_t? {
    get { return _value(key) }
    set { _set(newValue, key) }
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  public subscript(key: String, as type: String.Type = String.self) -> String? {
    return _value(key).flatMap(_xpcString)
  }

  public subscript(key: String) -> String? {
    get { return _value(key).flatMap(_xpcString) }
    set { _set(newValue.map { xpc_string_create($0) }, key) }
  }
}

/// Data values as bytes (SPI of Apple's overlay).
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  public subscript(key: String, as type: [UInt8].Type = [UInt8].self) -> [UInt8]? {
    guard let v = _value(key), xpc_get_type(v) == XPC_TYPE_DATA else { return nil }
    let count = xpc_data_get_length(v)
    guard count > 0, let bytes = xpc_data_get_bytes_ptr(v) else { return [] }
    return Array(UnsafeRawBufferPointer(start: bytes, count: count))
  }

  public subscript(key: String) -> [UInt8]? {
    get { return self[key, as: [UInt8].self] }
    set {
      _set(newValue.map { bytes in bytes.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) } }, key)
    }
  }

  /// A Codable value stored under `key`, as the XPC encoder encodes it.
  public func encode<T: Encodable>(_ value: T, forKey key: String) throws {
    try encode(value, forKey: key, withUserInfo: [:])
  }

  public func encode<T: Encodable>(_ value: T, forKey key: String,
                                   withUserInfo userInfo: [CodingUserInfoKey: Any]) throws {
    _set(try _XPCObjectEncoder.encode(value, codingPath: [], userInfo: userInfo), key)
  }

  public func decode<T: Decodable>(as type: T.Type, forKey key: String) throws -> T {
    return try decode(as: type, forKey: key, withUserInfo: [:])
  }

  public func decode<T: Decodable>(as type: T.Type, forKey key: String,
                                   withUserInfo userInfo: [CodingUserInfoKey: Any]) throws -> T {
    guard let v = _value(key) else {
      throw DecodingError.valueNotFound(type, DecodingError.Context(
        codingPath: [], debugDescription: "no value for \(key)"))
    }
    return try _XPCObjectDecoder.decode(type, from: v, codingPath: [], userInfo: userInfo)
  }
}

@available(macOS 15.0, macCatalyst 18.0, *)
extension XPCDictionary {
  public subscript(key: String, as type: XPCEndpoint.Type = XPCEndpoint.self) -> XPCEndpoint? {
    guard let v = _value(key), xpc_get_type(v) == XPC_TYPE_ENDPOINT else { return nil }
    return XPCEndpoint(v)
  }

  public subscript(key: String) -> XPCEndpoint? {
    get {
      guard let v = _value(key), xpc_get_type(v) == XPC_TYPE_ENDPOINT else { return nil }
      return XPCEndpoint(v)
    }
    set { _set(newValue?._endpoint, key) }
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  /// Copies this dictionary's entries into `destination`.
  public func copy(into destination: XPCDictionary) {
    forEach { key, value in xpc_dictionary_set_value(destination._object, key, value) }
  }

  @discardableResult
  public func removeValue(forKey key: String) -> xpc_object_t? {
    let old = _value(key)
    _set(nil, key)
    return old
  }

  public var isEmpty: Bool { count == 0 }

  public var count: Int { xpc_dictionary_get_count(_object) }

  internal var _entries: [KeyValuePair] {
    var entries: [KeyValuePair] = []
    xpc_dictionary_apply(_object) { key, value in
      entries.append((key: String(cString: key), value: value))
      return true
    }
    return entries
  }

  public func forEach(_ body: (_ key: String, _ value: xpc_object_t) throws -> Void) rethrows {
    for entry in _entries {
      try body(entry.key, entry.value)
    }
  }

  public typealias KeyValuePair = (key: String, value: xpc_object_t)

  public func forEach(_ body: (KeyValuePair) throws -> Void) rethrows {
    for entry in _entries {
      try body(entry)
    }
  }

  public func map<ReturnType>(_ transform: (KeyValuePair) throws -> ReturnType) rethrows -> [ReturnType] {
    return try _entries.map(transform)
  }

  public var keys: [String] { _entries.map { $0.key } }

  public var values: [xpc_object_t] { _entries.map { $0.value } }

  public func contains(key: String) -> Bool {
    return _value(key) != nil
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary {
  /// Replies to this (received) message with `reply`'s contents.
  public func reply(_ reply: XPCDictionary) {
    guard let message = xpc_dictionary_create_reply(_object) else { return }
    reply.copy(into: XPCDictionary(message))
    _finch_xpc_dictionary_send_reply(message)
  }

  /// A reply to this received message, or nil if it expects none.
  public func createReply() -> XPCDictionary? {
    return xpc_dictionary_create_reply(_object).map(XPCDictionary.init)
  }

  /// Sends this dictionary, made by createReply(), as the reply.
  public func sendReply() {
    _finch_xpc_dictionary_send_reply(_object)
  }

  /// The audit token of the process that sent this message.
  public var auditToken: audit_token_t {
    var token = audit_token_t()
    _finch_xpc_dictionary_get_audit_token(_object, &token)
    return token
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary: Equatable {
  public static func == (lhs: XPCDictionary, rhs: XPCDictionary) -> Bool {
    return xpc_equal(lhs._object, rhs._object)
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(xpc_hash(_object))
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension XPCDictionary: CustomDebugStringConvertible {
  public var debugDescription: String { _xpcDescription(_object) }
}

// MARK: XPCEndpoint

@available(macOS 15.0, macCatalyst 18.0, *)
public struct XPCEndpoint {
  internal let _object: xpc_endpoint_t

  public init(_ endpoint: xpc_endpoint_t) {
    _object = endpoint
  }
}

@available(macOS 15.0, macCatalyst 18.0, *)
extension XPCEndpoint {
  public var _endpoint: xpc_endpoint_t { _object }
}

@available(macOS 15.0, macCatalyst 18.0, *)
extension XPCEndpoint: Equatable, Hashable {
  public static func == (a: XPCEndpoint, b: XPCEndpoint) -> Bool {
    return xpc_equal(a._object, b._object)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(xpc_hash(_object))
  }
}

@available(macOS 15.0, macCatalyst 18.0, *)
extension XPCEndpoint: CustomDebugStringConvertible {
  public var debugDescription: String { _xpcDescription(_object) }
}

/// Endpoints only travel inside XPC messages: they encode with the XPC
/// encoder and fail with any other.
@available(macOS 15.0, macCatalyst 18.0, *)
extension XPCEndpoint: Codable {
  public func encode(to encoder: Encoder) throws {
    guard let encoder = encoder as? _XPCObjectEncoder else {
      throw EncodingError.invalidValue(self, EncodingError.Context(
        codingPath: encoder.codingPath, debugDescription: "XPCEndpoint can only be encoded by XPC"))
    }
    encoder.storeObject(_object)
  }

  public init(from decoder: Decoder) throws {
    guard let decoder = decoder as? _XPCObjectDecoder,
          xpc_get_type(decoder.object) == XPC_TYPE_ENDPOINT
    else {
      throw DecodingError.typeMismatch(XPCEndpoint.self, DecodingError.Context(
        codingPath: decoder.codingPath, debugDescription: "not an XPC endpoint"))
    }
    self.init(decoder.object)
  }
}

@available(macOS 15.0, macCatalyst 18.0, *)
extension XPCEndpoint: @unchecked Sendable {}
