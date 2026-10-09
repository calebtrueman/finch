//===--- NSIndexSetShims.h - Foundation declarations for IndexSet overlay -===//
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
// Finch: from Swift's stdlib/public/SwiftShims/NSIndexSetShims.h (swift-5.4-RELEASE);
// C helpers take NSInteger where the overlays pass Int.

#import "FoundationShimSupport.h"

NS_BEGIN_DECLS

@interface NSIndexSet (NSRanges)
- (NSUInteger)rangeCount;
- (NSRange)rangeAtIndex:(NSUInteger)rangeIndex;
- (NSUInteger)_indexOfRangeContainingIndex:(NSUInteger)value;
@end

NS_INLINE NSInteger __NSIndexSetRangeCount(NS_NON_BRIDGED(NSIndexSet *)self_) {
    return [(NSIndexSet *)self_ rangeCount];
}

NS_INLINE void __NSIndexSetRangeAtIndex(NS_NON_BRIDGED(NSIndexSet *)self_, NSInteger rangeIndex, NSInteger *location, NSInteger *length) {
    NSRange result = [(NSIndexSet *)self_ rangeAtIndex:rangeIndex];
    *location = result.location;
    *length = result.length;
}

NS_INLINE NSInteger __NSIndexSetIndexOfRangeContainingIndex(NS_NON_BRIDGED(NSIndexSet *)self_, NSInteger index) {
    return [(NSIndexSet *)self_ _indexOfRangeContainingIndex:index];
}

NS_END_DECLS
