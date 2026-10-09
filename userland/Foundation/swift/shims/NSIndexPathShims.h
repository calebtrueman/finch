//===--- NSIndexPathShims.h - Found. decl. for IndexPath overl. -*- C++ -*-===//
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
// Finch: from Swift's stdlib/public/SwiftShims/NSIndexPathShims.h (swift-5.4-RELEASE);
// C helpers take NSInteger where the overlays pass Int.

#import "FoundationShimSupport.h"

NS_BEGIN_DECLS

NS_INLINE NS_NON_BRIDGED(NSIndexPath *)_NSIndexPathCreateFromIndexes(NSInteger idx1, NSInteger idx2) NS_RETURNS_RETAINED {
    NSUInteger indexes[] = {idx1, idx2};
    return [[NSIndexPath alloc] initWithIndexes:&indexes[0] length:2];
}

NS_END_DECLS
