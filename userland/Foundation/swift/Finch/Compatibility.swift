// SPDX-License-Identifier: MIT OR Apache-2.0
// Linked-on-or-after switches swift-foundation consults in Foundation.framework
// (Apple's private half defines them from the app's SDK version). Each one
// selects an old behaviour that apps built against older SDKs relied on.
// Finch runs apps built against current SDKs, so each answers false: the
// current behaviour.

extension Calendar {
    internal static var compatibility1: Bool { false }
    internal static var compatibility2: Bool { false }
}

extension Decimal {
    internal static var compatibility1: Bool { false }
}

extension JSONEncoder {
    internal static var compatibility1: Bool { false }
}

extension URL {
    internal static var compatibility1: Bool { false }
    internal static var compatibility2: Bool { false }
}

extension String {
    internal static var compatibility1: Bool { false }
}

extension String {
    // (sic: swift-foundation's String+IO.swift spells it so)
    internal static var compatibiltity2: Bool { false }
}
