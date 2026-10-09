// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// The Darwin overlay proper (libswiftDarwin): what Apple's still builds as
// module Darwin, beside _DarwinFoundation1-3 which it re-exports. Mach
// errors and the TIOC constants are MachError.swift and TiocConstants.swift
// from swift-5.4-RELEASE.
//
// From Swift's stdlib/public/Platform/Platform.swift and Darwin.swift.gyb at
// swift-5.4-RELEASE (Apache 2.0 with the Runtime Library Exception); Finch
// split it into Apple's current modules and added the audit token
// conformances and constants of Apple's macOS 26 overlay.
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors

@_exported import Darwin // Clang module
@_exported import _Builtin_float
@_exported import _DarwinFoundation1
@_exported import _DarwinFoundation2
@_exported import _DarwinFoundation3
import SwiftOverlayShims

//===----------------------------------------------------------------------===//
// MacTypes.h
//===----------------------------------------------------------------------===//

@inlinable
public var noErr: OSStatus { return 0 }

/// The `Boolean` type declared in MacTypes.h and used throughout Core
/// Foundation.
///
/// The C type is a typedef for `unsigned char`.
@frozen
public struct DarwinBoolean: ExpressibleByBooleanLiteral, Sendable {
  @usableFromInline var _value: UInt8

  @_transparent
  public init(_ value: Bool) {
    self._value = value ? 1 : 0
  }

  /// The value of `self`, expressed as a `Bool`.
  @_transparent
  public var boolValue: Bool {
    return _value != 0
  }

  /// Create an instance initialized to `value`.
  @_transparent
  public init(booleanLiteral value: Bool) {
    self.init(value)
  }
}

extension DarwinBoolean: CustomReflectable {
  /// Returns a mirror that reflects `self`.
  public var customMirror: Mirror {
    return Mirror(reflecting: boolValue)
  }
}

extension DarwinBoolean: CustomStringConvertible {
  /// A textual representation of `self`.
  public var description: String {
    return self.boolValue.description
  }
}

extension DarwinBoolean: Equatable {
  @_transparent
  public static func ==(lhs: DarwinBoolean, rhs: DarwinBoolean) -> Bool {
    return lhs.boolValue == rhs.boolValue
  }
}

@_transparent
public // COMPILER_INTRINSIC
func _convertBoolToDarwinBoolean(_ x: Bool) -> DarwinBoolean {
  return DarwinBoolean(x)
}

@_transparent
public // COMPILER_INTRINSIC
func _convertDarwinBooleanToBool(_ x: DarwinBoolean) -> Bool {
  return x.boolValue
}

//===----------------------------------------------------------------------===//
// fcntl.h
//===----------------------------------------------------------------------===//

public func open(
  _ path: UnsafePointer<CChar>,
  _ oflag: Int32
) -> Int32 {
  return _swift_stdlib_open(path, oflag, 0)
}

public func open(
  _ path: UnsafePointer<CChar>,
  _ oflag: Int32,
  _ mode: mode_t
) -> Int32 {
  return _swift_stdlib_open(path, oflag, mode)
}

public func openat(
  _ fd: Int32,
  _ path: UnsafePointer<CChar>,
  _ oflag: Int32
) -> Int32 {
  return _swift_stdlib_openat(fd, path, oflag, 0)
}

public func openat(
  _ fd: Int32,
  _ path: UnsafePointer<CChar>,
  _ oflag: Int32,
  _ mode: mode_t
) -> Int32 {
  return _swift_stdlib_openat(fd, path, oflag, mode)
}

public func fcntl(
  _ fd: Int32,
  _ cmd: Int32
) -> Int32 {
  return _swift_stdlib_fcntl(fd, cmd, 0)
}

public func fcntl(
  _ fd: Int32,
  _ cmd: Int32,
  _ value: Int32
) -> Int32 {
  return _swift_stdlib_fcntl(fd, cmd, value)
}

public func fcntl(
  _ fd: Int32,
  _ cmd: Int32,
  _ ptr: UnsafeMutableRawPointer
) -> Int32 {
  return _swift_stdlib_fcntlPtr(fd, cmd, ptr)
}

public var S_IFMT: mode_t   { return mode_t(0o170000) }
public var S_IFIFO: mode_t  { return mode_t(0o010000) }
public var S_IFCHR: mode_t  { return mode_t(0o020000) }
public var S_IFDIR: mode_t  { return mode_t(0o040000) }
public var S_IFBLK: mode_t  { return mode_t(0o060000) }
public var S_IFREG: mode_t  { return mode_t(0o100000) }
public var S_IFLNK: mode_t  { return mode_t(0o120000) }
public var S_IFSOCK: mode_t { return mode_t(0o140000) }
public var S_IFWHT: mode_t  { return mode_t(0o160000) }

public var S_IRWXU: mode_t  { return mode_t(0o000700) }
public var S_IRUSR: mode_t  { return mode_t(0o000400) }
public var S_IWUSR: mode_t  { return mode_t(0o000200) }
public var S_IXUSR: mode_t  { return mode_t(0o000100) }

public var S_IRWXG: mode_t  { return mode_t(0o000070) }
public var S_IRGRP: mode_t  { return mode_t(0o000040) }
public var S_IWGRP: mode_t  { return mode_t(0o000020) }
public var S_IXGRP: mode_t  { return mode_t(0o000010) }

public var S_IRWXO: mode_t  { return mode_t(0o000007) }
public var S_IROTH: mode_t  { return mode_t(0o000004) }
public var S_IWOTH: mode_t  { return mode_t(0o000002) }
public var S_IXOTH: mode_t  { return mode_t(0o000001) }

public var S_ISUID: mode_t  { return mode_t(0o004000) }
public var S_ISGID: mode_t  { return mode_t(0o002000) }
public var S_ISVTX: mode_t  { return mode_t(0o001000) }

public var S_ISTXT: mode_t  { return S_ISVTX }
public var S_IREAD: mode_t  { return S_IRUSR }
public var S_IWRITE: mode_t { return S_IWUSR }
public var S_IEXEC: mode_t  { return S_IXUSR }

//===----------------------------------------------------------------------===//
// ioctl.h
//===----------------------------------------------------------------------===//

public func ioctl(
  _ fd: CInt,
  _ request: UInt,
  _ value: CInt
) -> CInt {
  return _swift_stdlib_ioctl(fd, request, value)
}

public func ioctl(
  _ fd: CInt,
  _ request: UInt,
  _ ptr: UnsafeMutableRawPointer
) -> CInt {
  return _swift_stdlib_ioctlPtr(fd, request, ptr)
}

public func ioctl(
  _ fd: CInt,
  _ request: UInt
) -> CInt {
  return _swift_stdlib_ioctl(fd, request, 0)
}

//===----------------------------------------------------------------------===//
// semaphore.h
//===----------------------------------------------------------------------===//

public typealias Semaphore = UnsafeMutablePointer<sem_t>

/// The value returned by `sem_open()` in the case of failure.
public var SEM_FAILED: Semaphore? {
  // The value is ABI.  Value verified to be correct for OS X, iOS, watchOS, tvOS.
  return Semaphore(bitPattern: -1)
}

public func sem_open(
  _ name: UnsafePointer<CChar>,
  _ oflag: Int32
) -> Semaphore? {
  return _stdlib_sem_open2(name, oflag)
}

public func sem_open(
  _ name: UnsafePointer<CChar>,
  _ oflag: Int32,
  _ mode: mode_t,
  _ value: CUnsignedInt
) -> Semaphore? {
  return _stdlib_sem_open4(name, oflag, mode, value)
}

//===----------------------------------------------------------------------===//
// Misc.
//===----------------------------------------------------------------------===//

public var environ: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
  return _swift_stdlib_getEnviron()
}

nonisolated(unsafe) public let MAP_FAILED: UnsafeMutableRawPointer! =
  UnsafeMutableRawPointer(bitPattern: -1)

// Macros defined in bsd/sys/proc.h that do not import into Swift.
extension extern_proc {
  // #define p_starttime p_un.__p_starttime
  @_transparent
  public var p_starttime: timeval {
    get { return self.p_un.__p_starttime }
    set { self.p_un.__p_starttime = newValue }
  }
}

//===----------------------------------------------------------------------===//
// bsm/audit.h (Finch)
//===----------------------------------------------------------------------===//

/// No process: every field all ones.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public let INVALID_AUDIT_TOKEN_VALUE: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) =
  (.max, .max, .max, .max, .max, .max, .max, .max)

/// The kernel: every field zero.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public let KERNEL_AUDIT_TOKEN_VALUE: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) =
  (0, 0, 0, 0, 0, 0, 0, 0)

/// An audit token encodes as its eight fields, in order.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension audit_token_t: Codable, Equatable, Hashable {
  private var fields: [UInt32] {
    let v = val
    return [v.0, v.1, v.2, v.3, v.4, v.5, v.6, v.7]
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    for field in fields {
      try container.encode(field)
    }
  }

  public init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var f = [UInt32]()
    for _ in 0..<8 {
      f.append(try container.decode(UInt32.self))
    }
    self.init(val: (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]))
  }

  public static func == (lhs: audit_token_t, rhs: audit_token_t) -> Bool {
    return lhs.fields == rhs.fields
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(fields)
  }
}
