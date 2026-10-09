//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// Finch: helpers of swift-foundation's String+Bridging.swift
// (swift-6.3.1-RELEASE) that other swift-foundation files use; Finch
// bridges String with Darwin/String.swift and leaves that file out. Plus
// String._nfd, the canonical decomposition String+Internals.swift reads.

extension String {
    internal var _nfd: String.UnicodeScalarView {
        (self as NSString).decomposedStringWithCanonicalMapping.unicodeScalars
    }
}

extension Substring {
    func _components(separatedBy characterSet: CharacterSet) -> [String] {
        var result = [String]()
        var searchStart = startIndex
        while searchStart < endIndex {
            let r = self[searchStart...]._rangeOfCharacter(from: characterSet, options: [])
            guard let r, !r.isEmpty else {
                break
            }

            result.append(String(self[searchStart ..< r.lowerBound]))
            searchStart = r.upperBound
        }

        result.append(String(self[searchStart..<endIndex]))

        return result
    }
}

extension BidirectionalCollection where Element == Unicode.Scalar, Index == String.Index {
    func _trimmingCharacters(in set: CharacterSet) -> SubSequence {

        var idx = startIndex
        while idx < endIndex && set.contains(self[idx]) {
            formIndex(after: &idx)
        }

        let startOfNonTrimmedRange = idx // Points at the first char not in the set
        guard startOfNonTrimmedRange != endIndex else {
            return self[endIndex...]
        }

        let beforeEnd = index(before: endIndex)
        guard startOfNonTrimmedRange < beforeEnd else {
            return self[startOfNonTrimmedRange ..< endIndex]
        }

        var backIdx = beforeEnd
        // No need to bound-check because we've already trimmed from the beginning, so we'd definitely break off of this loop before `backIdx` rewinds before `startIndex`
        while set.contains(self[backIdx]) {
            formIndex(before: &backIdx)
        }
        return self[startOfNonTrimmedRange ... backIdx]
    }

}


extension StringProtocol {
    /// The string as a native UTF-8 substring, for the Swift fast paths; nil
    /// sends callers to NSString's implementation (Finch: always).
    internal func _asContiguousUTF8Substring(from range: Range<Index>) -> Substring? {
        nil
    }
}
