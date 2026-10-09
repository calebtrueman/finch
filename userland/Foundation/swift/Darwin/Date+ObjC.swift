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
// Finch: Date's description, which on Darwin defers to NSDate (swift-foundation
// leaves it to Foundation.framework). From Swift's historical overlay
// stdlib/public/Darwin/Foundation/Date.swift (swift-5.4-RELEASE).

extension Date {
    /// A string representation of the date object (read-only).
    /// The representation is useful for debugging only.
    public var description: String {
        // Defer to NSDate for description
        return NSDate(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate).description
    }

    /// Returns a string representation of the receiver using the given locale.
    public func description(with locale: Locale?) -> String {
        return NSDate(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate).description(with: locale)
    }
}
