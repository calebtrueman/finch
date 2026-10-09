// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// _DarwinFoundation3 (signal.h, unistd.h): the part of Apple's Darwin
// overlay that its SDK now builds as libswift_DarwinFoundation3, with
// Darwin's ABI name.
//
// From Swift's stdlib/public/Platform/Platform.swift at swift-5.4-RELEASE
// (Apache 2.0 with the Runtime Library Exception); Finch split it into
// Apple's current modules.
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors

@_exported import _DarwinFoundation3
import _DarwinFoundation3._signal
@_exported import _DarwinFoundation3.pthread
import _DarwinFoundation3.unistd

//===----------------------------------------------------------------------===//
// unistd.h
//===----------------------------------------------------------------------===//

@available(*, unavailable, message: "Please use threads or posix_spawn*()")
public func fork() -> Int32 {
  fatalError("unavailable function can't be called")
}

@available(*, unavailable, message: "Please use threads or posix_spawn*()")
public func vfork() -> Int32 {
  fatalError("unavailable function can't be called")
}

//===----------------------------------------------------------------------===//
// signal.h
//===----------------------------------------------------------------------===//

public var SIG_DFL: sig_t? { return nil }
public var SIG_IGN: sig_t { return unsafeBitCast(1, to: sig_t.self) }
public var SIG_ERR: sig_t { return unsafeBitCast(-1, to: sig_t.self) }
public var SIG_HOLD: sig_t { return unsafeBitCast(5, to: sig_t.self) }
