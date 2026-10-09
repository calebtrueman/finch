// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// _DarwinFoundation2 (stdio.h, time.h, sys/time.h): the part of Apple's
// Darwin overlay that its SDK now builds as libswift_DarwinFoundation2,
// with Darwin's ABI name.
//
// The stdio part is from Swift's stdlib/public/Platform/Platform.swift at
// swift-5.4-RELEASE, the Duration conversions from the same file at
// swift-6.3.1-RELEASE (Apache 2.0 with the Runtime Library Exception);
// Finch split them into Apple's current modules.
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors

@_exported import _DarwinFoundation2
import _DarwinFoundation2._stdio
import _DarwinFoundation2._time
import _DarwinFoundation2.sys_time.timeval

//===----------------------------------------------------------------------===//
// stdio.h
//===----------------------------------------------------------------------===//

public var stdin: UnsafeMutablePointer<FILE> {
  get {
    return __stdinp
  }
  set {
    __stdinp = newValue
  }
}

public var stdout: UnsafeMutablePointer<FILE> {
  get {
    return __stdoutp
  }
  set {
    __stdoutp = newValue
  }
}

public var stderr: UnsafeMutablePointer<FILE> {
  get {
    return __stderrp
  }
  set {
    __stderrp = newValue
  }
}

public func dprintf(_ fd: Int, _ format: UnsafePointer<Int8>, _ args: CVarArg...) -> Int32 {
  return withVaList(args) { va_args in
    vdprintf(Int32(fd), format, va_args)
  }
}

public func snprintf(ptr: UnsafeMutablePointer<Int8>, _ len: Int, _ format: UnsafePointer<Int8>, _ args: CVarArg...) -> Int32 {
  return withVaList(args) { va_args in
    return vsnprintf(ptr, len, format, va_args)
  }
}

//===----------------------------------------------------------------------===//
// time.h, sys/time.h
//===----------------------------------------------------------------------===//

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension timespec {
  public init(_ duration: Duration) {
    let comps = duration.components
    self.init(tv_sec: Int(comps.seconds),
              tv_nsec: Int(comps.attoseconds / 1_000_000_000))
  }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension Duration {
  public init(_ ts: timespec) {
    self = .seconds(ts.tv_sec) + .nanoseconds(ts.tv_nsec)
  }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension timeval {
  public init(_ duration: Duration) {
    let comps = duration.components
    self.init(tv_sec: Int(comps.seconds),
              tv_usec: Int32(comps.attoseconds / 1_000_000_000_000))
  }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension Duration {
  public init(_ tv: timeval) {
    self = .seconds(tv.tv_sec) + .microseconds(tv.tv_usec)
  }
}
