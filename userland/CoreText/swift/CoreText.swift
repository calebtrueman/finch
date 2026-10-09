// SPDX-License-Identifier: MIT OR Apache-2.0
//
// CoreText's Swift overlay, compiled into CoreText as Apple's is, to Apple's public interface:
// AttributedString's adaptive image glyphs, line heights and text alignment, and the
// CoreText attribute scope. And the conversion SwiftUI uses from an AttributedString
// adaptive image glyph to CoreText's.

import Foundation
import UniformTypeIdentifiers
import CoreText_FinchPrivate

extension AttributedString {
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public struct AdaptiveImageGlyph: Codable, Hashable, Equatable, Sendable {
        public let imageContent: Data
        public let contentIdentifier: String
        public let contentDescription: String

        public init(imageContent: Data) {
            self.imageContent = imageContent
            self.contentIdentifier = UUID().uuidString
            self.contentDescription = ""
        }

        public static var contentType: UTType { .heic }
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension CTAdaptiveImageGlyph {
    public static func _adaptiveImageGlyph(convertingFrom glyph: AttributedString.AdaptiveImageGlyph) -> CTAdaptiveImageGlyph {
        return CTAdaptiveImageGlyph(imageContent: glyph.imageContent)
    }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension AttributedString {
    /// A paragraph's line height.
    public struct LineHeight: Codable, Hashable, Sendable {
        enum Kind: Codable, Hashable, Sendable {
            case variable, normal, tight, loose
            case multiple(CGFloat)
            case leading(CGFloat)
            case exact(CGFloat)
        }
        let kind: Kind

        public static var variable: LineHeight { LineHeight(kind: .variable) }
        public static var normal: LineHeight { LineHeight(kind: .normal) }
        public static var tight: LineHeight { LineHeight(kind: .tight) }
        public static var loose: LineHeight { LineHeight(kind: .loose) }
        public static func multiple(factor: CGFloat) -> LineHeight { LineHeight(kind: .multiple(factor)) }
        public static func leading(increase: CGFloat) -> LineHeight { LineHeight(kind: .leading(increase)) }
        public static func exact(points: CGFloat) -> LineHeight { LineHeight(kind: .exact(points)) }
    }

    /// A paragraph's alignment.
    public enum TextAlignment: CaseIterable, Codable, Hashable, Sendable {
        case left
        case center
        case right
    }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension AttributeScopes {
    public struct CoreTextAttributes: Sendable {
        @frozen public enum LineHeightAttribute: AttributedStringKey, Sendable {
            public typealias Value = AttributedString.LineHeight
            public static let name = "CTLineHeight"
            public static let runBoundaries: AttributedString.AttributeRunBoundaries? = .paragraph
        }

        @frozen public enum TextAlignmentAttribute: CodableAttributedStringKey, Sendable {
            public typealias Value = AttributedString.TextAlignment
            public static let name = "CTTextAlignment"
            public static let runBoundaries: AttributedString.AttributeRunBoundaries? = .paragraph
        }
    }
}
