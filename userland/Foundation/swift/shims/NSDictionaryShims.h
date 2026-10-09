//===--- NSDictionaryShims.h - Foundation decl. for Dictionary overlay ----===//
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
// Finch: from Swift's stdlib/public/SwiftShims/NSDictionaryShims.h (swift-5.4-RELEASE);
// C helpers take NSInteger where the overlays pass Int.

#import "FoundationShimSupport.h"

NS_BEGIN_DECLS

NS_INLINE void __NSDictionaryGetObjects(NS_NON_BRIDGED(NSDictionary *)nsDictionary, void *_Nullable objects, void *_Nullable keys, NSInteger count) {
    [(NSDictionary *)nsDictionary getObjects:(__unsafe_unretained id  _Nonnull *)(void *)objects andKeys:(__unsafe_unretained id  _Nonnull *)(void *)keys count:count];
}

NS_END_DECLS
