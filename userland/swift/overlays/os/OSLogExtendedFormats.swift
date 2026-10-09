// SPDX-License-Identifier: MIT OR Apache-2.0
// The os overlay's typed log arguments beyond plain numbers, strings and
// objects: pointers with a decoding format (%{uuid_t}.*P, ...), Booleans,
// and integers with an extended format (%{darwin.errno}d, %{bytes}ld, ...).
// Finch's implementation; the declarations are Apple's os overlay's (macOS
// 26.4 SDK), so the symbols and the inlinable ABI match.

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public enum OSLogPointerFormat {
  case ipv6Address
  case timeval
  case timespec
  case uuid
  case sockaddr
  case none
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public enum OSLogBoolFormat {
  case truth
  case answer
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public enum OSLogInt32ExtendedFormat {
  case ipv4Address
  case secondsSince1970
  case darwinErrno
  case darwinMode
  case darwinSignal
  case machErrno
  case bitrate
  case bitrateIEC
  @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
  case byteCount
  @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
  case byteCountIEC
  case truth
  case answer
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public enum OSLogIntExtendedFormat {
  case bitrate
  case bitrateIEC
  case byteCount
  case byteCountIEC
  @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
  case secondsSince1970

  @_semantics("constant_evaluable")
  @_alwaysEmitIntoClient
  @_optimize(none)
  internal var tag: String {
    switch self {
    case .bitrate: return "bitrate"
    case .bitrateIEC: return "iec-bitrate"
    case .byteCount: return "bytes"
    case .byteCountIEC: return "iec-bytes"
    case .secondsSince1970: return "time_t"
    default: return ""
    }
  }
}

/// The name libtrace's decoders know a format by.
@_alwaysEmitIntoClient
@_semantics("constant_evaluable")
@_optimize(none)
internal func _finchPointerFormatTag(_ format: OSLogPointerFormat) -> String {
  switch format {
  case .ipv6Address: return "network:in6_addr"
  case .timeval: return "timeval"
  case .timespec: return "timespec"
  case .uuid: return "uuid_t"
  case .sockaddr: return "network:sockaddr"
  default: return ""
  }
}

@_alwaysEmitIntoClient
@_semantics("constant_evaluable")
@_optimize(none)
internal func _finchInt32FormatTag(_ format: OSLogInt32ExtendedFormat) -> String {
  switch format {
  case .secondsSince1970: return "time_t"
  case .ipv4Address: return "network:in_addr"
  case .darwinErrno: return "darwin.errno"
  case .darwinMode: return "darwin.mode"
  case .machErrno: return "mach.errno"
  case .darwinSignal: return "darwin.signal"
  case .bitrate: return "bitrate"
  case .bitrateIEC: return "iec-bitrate"
  case .byteCount: return "bytes"
  case .byteCountIEC: return "iec-bytes"
  case .truth: return "bool"
  case .answer: return "BOOL"
  default: return ""
  }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension OSLogInterpolation {

  // MARK: Pointers

  @_semantics("constant_evaluable")
  @inlinable
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public mutating func appendInterpolation(
    _ pointer: @autoclosure @escaping () -> UnsafeRawBufferPointer,
    format: OSLogPointerFormat = .none,
    privacy: OSLogPrivacy = .auto
  ) {
    appendInterpolation(pointer().baseAddress!, bytes: pointer().count,
                        format: format, privacy: privacy)
  }

  @_semantics("constant_evaluable")
  @inlinable
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public mutating func appendInterpolation(
    _ pointer: @autoclosure @escaping () -> UnsafeRawPointer,
    bytes: @autoclosure @escaping () -> Int,
    format: OSLogPointerFormat = .none,
    privacy: OSLogPrivacy = .auto
  ) {
    guard argumentCount < maxOSLogArgumentCount else { return }
    formatString += getPointerFormatSpecifier(format, privacy)
    if privacy.hasMask {
      appendMaskArgument(privacy)
    }
    // The byte count travels as the precision: %.*P.
    appendPrecisionArgument(bytes)
    addPointerHeaders(privacy)
    arguments.append(pointer)
    argumentCount += 1
  }

  @_semantics("constant_evaluable")
  @inlinable
  @_optimize(none)
  internal mutating func addPointerHeaders(_ privacy: OSLogPrivacy) {
    let header = getArgumentHeader(privacy: privacy, type: .pointer)
    arguments.append(header)
    let byteCount = pointerSizeInBytes()
    arguments.append(UInt8(byteCount))
    totalBytesForSerializingArguments += byteCount + 2
    preamble = getUpdatedPreamble(privacy: privacy, isScalar: false)
  }

  /// "%{format,privacy}.*P", with the braces only when there's a tag.
  @usableFromInline
  @_semantics("constant_evaluable")
  @_effects(readonly)
  @_optimize(none)
  internal func getPointerFormatSpecifier(
    _ format: OSLogPointerFormat,
    _ privacy: OSLogPrivacy
  ) -> String {
    var tags = _finchPointerFormatTag(format)
    if let privacySpecifier = privacy.privacySpecifier {
      if tags != "" { tags += "," }
      tags += privacySpecifier
    }
    return tags == "" ? "%.*P" : "%{" + tags + "}.*P"
  }

  // MARK: Booleans and extended integer formats

  @_semantics("constant_evaluable")
  @inlinable
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public mutating func appendInterpolation(
    _ number: @autoclosure @escaping () -> Int32,
    format: OSLogInt32ExtendedFormat,
    privacy: OSLogPrivacy = .auto
  ) {
    guard argumentCount < maxOSLogArgumentCount else { return }
    formatString += getExtendedFormatSpecifier(format, privacy)
    if privacy.hasMask {
      appendMaskArgument(privacy)
    }
    addIntHeaders(privacy, sizeForEncoding(Int32.self))
    arguments.append(number)
    argumentCount += 1
  }

  @_semantics("constant_evaluable")
  @inlinable
  @_optimize(none)
  @_semantics("oslog.requires_constant_arguments")
  public mutating func appendInterpolation(
    _ boolean: @autoclosure @escaping () -> Bool,
    format: OSLogBoolFormat = .truth,
    privacy: OSLogPrivacy = .auto
  ) {
    appendInterpolation(boolean() ? Int32(1) : Int32(0),
                        format: getInt32BoolFormat(format), privacy: privacy)
  }

  @_semantics("constant_evaluable")
  @inlinable
  @_optimize(none)
  internal func getInt32BoolFormat(_ format: OSLogBoolFormat) -> OSLogInt32ExtendedFormat {
    switch format {
    case .answer: return .answer
    default: return .truth
    }
  }

  /// "%{format,privacy}d".
  @usableFromInline
  @_semantics("constant_evaluable")
  @_effects(readonly)
  @_optimize(none)
  internal func getExtendedFormatSpecifier(
    _ format: OSLogInt32ExtendedFormat,
    _ privacy: OSLogPrivacy
  ) -> String {
    var specifier = "%{" + _finchInt32FormatTag(format)
    if let privacySpecifier = privacy.privacySpecifier {
      specifier += ","
      specifier += privacySpecifier
    }
    specifier += "}d"
    return specifier
  }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension OSLogArguments {
  @_semantics("constant_evaluable")
  @inlinable
  @_optimize(none)
  internal mutating func append(_ value: @escaping () -> UnsafeRawPointer) {
    argumentClosures.append({ (position, _, _) in
      serialize(value(), at: &position)
    })
  }
}

@_alwaysEmitIntoClient
@inline(__always)
internal func serialize(
  _ pointer: UnsafeRawPointer,
  at bufferPosition: inout ByteBufferPointer
) {
  let byteCount = pointerSizeInBytes()
  let dest = UnsafeMutableRawBufferPointer(start: bufferPosition, count: byteCount)
  withUnsafeBytes(of: pointer) { dest.copyMemory(from: $0) }
  bufferPosition += byteCount
}

// MARK: Entry points of earlier releases, kept for clients built against them

/// Serializes a string argument as a pointer to its UTF-8 bytes, keeping
/// what owns those bytes alive in `stringStorage` until the call completes.
@usableFromInline
internal func serialize(
  _ stringValue: String,
  at bufferPosition: inout UnsafeMutablePointer<UInt8>,
  using stringStorage: inout ObjectStorage<Any>
) {
  let stringPointer = getNullTerminatedUTF8Pointer(stringValue, using: &stringStorage)
  let byteCount = pointerSizeInBytes()
  let dest = UnsafeMutableRawBufferPointer(start: bufferPosition, count: byteCount)
  withUnsafeBytes(of: stringPointer) { dest.copyMemory(from: $0) }
  bufferPosition += byteCount
}

@usableFromInline
internal func getNullTerminatedUTF8Pointer(
  _ stringValue: String,
  using stringStorage: inout ObjectStorage<Any>
) -> UnsafeRawPointer {
  let (optStorage, bytePointer, _, _, _):
    (AnyObject?, UnsafeRawPointer, Int, Bool, Bool) =
    stringValue._deconstructUTF8(scratch: nil)
  if let storage = optStorage {
    initializeAndAdvance(&stringStorage, to: storage)
  } else {
    initializeAndAdvance(&stringStorage, to: stringValue._guts)
  }
  return bytePointer
}
