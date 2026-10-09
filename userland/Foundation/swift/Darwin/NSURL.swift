//===----------------------------------------------------------------------===//
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
// Finch: from Swift's historical overlay stdlib/public/Darwin/Foundation/NSURL.swift
// (swift-5.4-RELEASE), less what swift-foundation now carries; edits are
// marked "Finch:" or noted in docs/design/FOUNDATION.md.

@_exported import Foundation // Clang module

extension NSURL : _CustomPlaygroundQuickLookable {
  @available(*, deprecated, message: "NSURL.customPlaygroundQuickLook will be removed in a future Swift version")
  public var customPlaygroundQuickLook: PlaygroundQuickLook {
    guard let str = absoluteString else { return .text("Unknown URL") }
    return .url(str)
  }
}
