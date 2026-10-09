// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// _DarwinFoundation1 (errno.h, math.h): the part of Apple's Darwin overlay
// that its SDK now builds as libswift_DarwinFoundation1, with Darwin's ABI
// name. The math functions are tgmath.swift.gyb and POSIXErrorCode is
// POSIXError.swift, both from swift-5.4-RELEASE.
//
// From Swift's stdlib/public/Platform/Platform.swift at swift-5.4-RELEASE
// (Apache 2.0 with the Runtime Library Exception); Finch split it into
// Apple's current modules and made the <math.h> constants plain (Apple's
// are no longer deprecated), and errno reads errno.h's __error() directly.
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors

@_exported import _DarwinFoundation1
import _DarwinFoundation1._errno
import _DarwinFoundation1._math

//===----------------------------------------------------------------------===//
// sys/errno.h
//===----------------------------------------------------------------------===//

public var errno: Int32 {
  get {
    return __error().pointee
  }
  set(val) {
    __error().pointee = val
  }
}

//  Constants defined by <math.h>
public let M_PI = Double.pi
public let M_PI_2 = Double.pi / 2
public let M_PI_4 = Double.pi / 4
public let M_SQRT2 = 2.squareRoot()
public let M_SQRT1_2 = 0.5.squareRoot()
