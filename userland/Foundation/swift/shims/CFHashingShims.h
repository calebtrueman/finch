//===--- CFHashingShims.h - Declarations for CF hashing functions ---------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// Finch: from Swift's stdlib/public/SwiftShims/CFHashingShims.h (swift-5.4-RELEASE);
// C helpers take NSInteger where the overlays pass Int.

CF_IMPLICIT_BRIDGING_ENABLED
CF_EXTERN_C_BEGIN
_Pragma("clang assume_nonnull begin")


#define _CF_HASHFACTOR 2654435761U

CF_INLINE CFHashCode __CFHashInt(long i) {
    return ((i > 0) ? (CFHashCode)(i) : (CFHashCode)(-i)) * _CF_HASHFACTOR;
}

CF_INLINE CFHashCode __CFHashDouble(double d) {
    double dInt;
    if (d < 0) d = -d;
    dInt = floor(d+0.5);
    CFHashCode integralHash = _CF_HASHFACTOR * (CFHashCode)fmod(dInt, (double)ULONG_MAX);
    return (CFHashCode)(integralHash + (CFHashCode)((d - dInt) * ULONG_MAX));
}

CF_EXPORT CFHashCode CFHashBytes(uint8_t *_Nullable bytes, CFIndex len);


CF_INLINE CFHashCode __CFHashBytes(uint8_t *_Nullable bytes, CFIndex len) {
    return CFHashBytes(bytes, len);
}

_Pragma("clang assume_nonnull end")
CF_EXTERN_C_END
CF_IMPLICIT_BRIDGING_DISABLED
