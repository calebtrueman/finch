// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Accessibility.framework's Swift half, to Apple's interface: the accessibility attribute
// scope for AttributedString, notifications, the settings, and Swift conveniences over the
// chart descriptors.

import CoreGraphics
import Foundation

// MARK: - Charts

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AXNumericDataAxisDescriptor {
    public var range: ClosedRange<Double> {
        get { __lowerBound...__upperBound }
        set(newRange) {
            __lowerBound = newRange.lowerBound
            __upperBound = newRange.upperBound
        }
    }

    public var gridlinePositions: [Double] {
        get { __gridlinePositions.map(\.doubleValue) }
        set(newPositions) { __gridlinePositions = newPositions.map { NSNumber(value: $0) } }
    }

    public convenience init(title: String, range: ClosedRange<Double>, gridlinePositions: [Double],
                            valueDescriptionProvider: @escaping (Double) -> String) {
        self.init(__title: title, lowerBound: range.lowerBound, upperBound: range.upperBound,
                  gridlinePositions: gridlinePositions.map { NSNumber(value: $0) }, valueDescriptionProvider: valueDescriptionProvider)
    }

    public convenience init(attributedTitle: NSAttributedString, range: ClosedRange<Double>, gridlinePositions: [Double],
                            valueDescriptionProvider: @escaping (Double) -> String) {
        self.init(__attributedTitle: attributedTitle, lowerBound: range.lowerBound, upperBound: range.upperBound,
                  gridlinePositions: gridlinePositions.map { NSNumber(value: $0) }, valueDescriptionProvider: valueDescriptionProvider)
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AXDataPoint {
    public enum Value {
        case number(Double)
        case category(String)

        var object: AXDataPointValue {
            switch self {
            case .number(let n): AXDataPointValue(__number: n)
            case .category(let c): AXDataPointValue(__category: c)
            }
        }
    }

    public convenience init(x: Double, y: Double? = nil, additionalValues: [Value] = [], label: String? = nil) {
        self.init(__x: AXDataPointValue(__number: x), y: y.map { AXDataPointValue(__number: $0) },
                  additionalValues: additionalValues.map(\.object), label: label)
    }

    public convenience init(x: String, y: Double? = nil, additionalValues: [Value] = [], label: String? = nil) {
        self.init(__x: AXDataPointValue(__category: x), y: y.map { AXDataPointValue(__number: $0) },
                  additionalValues: additionalValues.map(\.object), label: label)
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AXChartDescriptor {
    public var xAxis: any AXDataAxisDescriptor {
        get { __xAxis }
        set(newAxis) { __xAxis = newAxis }
    }

    public var additionalAxes: [any AXDataAxisDescriptor] {
        get { __additionalAxes ?? [] }
        set(newAdditionalAxes) { __additionalAxes = newAdditionalAxes }
    }

    public convenience init(title: String? = nil, summary: String? = nil, xAxis: any AXDataAxisDescriptor,
                            yAxis: AXNumericDataAxisDescriptor? = nil, additionalAxes: [any AXDataAxisDescriptor] = [],
                            series: [AXDataSeriesDescriptor]) {
        self.init(__title: title, summary: summary, xAxisDescriptor: xAxis, yAxisDescriptor: yAxis,
                  additionalAxes: additionalAxes, series: series)
    }

    public convenience init(attributedTitle: NSAttributedString? = nil, summary: String? = nil, xAxis: any AXDataAxisDescriptor,
                            yAxis: AXNumericDataAxisDescriptor? = nil, additionalAxes: [any AXDataAxisDescriptor] = [],
                            series: [AXDataSeriesDescriptor]) {
        self.init(__attributedTitle: attributedTitle, summary: summary, xAxisDescriptor: xAxis, yAxisDescriptor: yAxis,
                  additionalAxes: additionalAxes, series: series)
    }
}

@available(macOS 12.2, iOS 15.2, tvOS 15.2, watchOS 8.2, *)
extension AXBrailleMap {
    public subscript(point: CGPoint) -> Float {
        get { height(at: point) }
        set { setHeight(newValue, at: point) }
    }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension AXBrailleTable {
    public var language: Locale.Language { Locale.Language(identifier: __language) }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension AXBrailleTranslationResult {
    /// The index in the print text that the braille at `resultIndex` came from.
    public func inputIndex(forResultIndex resultIndex: String.Index) -> String.Index? {
        let offset = resultString.utf16.distance(from: resultString.startIndex, to: resultIndex)
        let map = __locationMap
        guard offset >= 0, offset < map.count else { return nil }
        // The location map's offsets are into the print text, which the result doesn't keep;
        // the index is made in the result's own string, as UTF-16 offsets carry over.
        return String.Index(utf16Offset: map[offset].intValue, in: resultString)
    }
}

// MARK: - The attribute scope

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes {
    public var accessibility: AccessibilityAttributes.Type { AccessibilityAttributes.self }

    public struct AccessibilityAttributes: AttributeScope {
        public let accessibilityHeadingLevel: HeadingLevelAttribute
        public let accessibilityTextCustom: TextCustomAttribute
        public let accessibilityTextualContext: TextualContextAttribute
        public let accessibilitySpeechIncludesPunctuation: IncludesPunctuationAttribute
        public let accessibilitySpeechAdjustedPitch: AdjustedPitchAttribute
        public let accessibilitySpeechSpellsOutCharacters: SpellOutAttribute
        @available(*, deprecated, renamed: "accessibilitySpeechAnnouncementPriority")
        public let accessibilitySpeechAnnouncementsQueued: QueueAnnouncementAttribute
        public let accessibilitySpeechPhoneticNotation: IPANotationAttribute
        @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
        public let accessibilitySpeechAnnouncementPriority: AnnouncementPriorityAttribute
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeDynamicLookup {
    public subscript<T>(dynamicMember keyPath: KeyPath<AttributeScopes.AccessibilityAttributes, T>) -> T
        where T: AttributedStringKey {
        self[T.self]
    }
}

/// A Markdown attribute's value decoded as the key's own value type.
private func decodeValue<V: Decodable>(_ type: V.Type, from decoder: any Decoder) throws -> V {
    try decoder.singleValueContainer().decode(V.self)
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.AccessibilityAttributes {
    @frozen
    public enum HeadingLevelAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey,
        ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = HeadingLevel
        public typealias ObjectiveCValue = NSNumber
        public static var name: String { "AXHeadingLevel" }
        public static let markdownName = "accessibilityHeadingLevel"

        public static func decodeMarkdown(from decoder: any Decoder) throws -> HeadingLevel {
            let level = try decodeValue(Int.self, from: decoder)
            guard let value = HeadingLevel(rawValue: level) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no heading level \(level)"))
            }
            return value
        }

        public static func objectiveCValue(for value: HeadingLevel) throws -> NSNumber { NSNumber(value: value.rawValue) }

        public static func value(for object: NSNumber) throws -> HeadingLevel {
            guard let value = HeadingLevel(rawValue: object.intValue) else { throw CocoaError(.coderInvalidValue) }
            return value
        }

        public enum HeadingLevel: Int, Codable, Sendable {
            case unspecified, h1, h2, h3, h4, h5, h6
        }
    }

    @frozen
    public enum TextCustomAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        public typealias Value = [String]
        public static var name: String { "AXCustom" }
        public static let markdownName = "accessibilityTextCustom"
    }

    @frozen
    public enum TextualContextAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey,
        ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = TextualContext
        public typealias ObjectiveCValue = NSString
        public static var name: String { "AXTextualContext" }
        public static let markdownName = "accessibilityTextualContext"

        public static func decodeMarkdown(from decoder: any Decoder) throws -> TextualContext {
            try decodeValue(TextualContext.self, from: decoder)
        }

        /// "sourceCode" is AXTextualContextSourceCode.
        public static func objectiveCValue(for value: TextualContext) throws -> NSString {
            ("AXTextualContext" + value.rawValue.prefix(1).uppercased() + value.rawValue.dropFirst()) as NSString
        }

        public static func value(for object: NSString) throws -> TextualContext {
            let s = object as String
            guard s.hasPrefix("AXTextualContext") else { throw CocoaError(.coderInvalidValue) }
            let raw = s.dropFirst("AXTextualContext".count)
            guard let value = TextualContext(rawValue: raw.prefix(1).lowercased() + raw.dropFirst()) else {
                throw CocoaError(.coderInvalidValue)
            }
            return value
        }

        public enum TextualContext: String, Codable, Sendable {
            case plain
            case console
            case fileSystem
            case messaging
            case narrative
            case sourceCode
            case spreadsheet
            case wordProcessing
        }
    }

    @frozen
    public enum IncludesPunctuationAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        public typealias Value = Bool
        public static var name: String { "AXPunctuation" }
        public static let markdownName = "accessibilitySpeechIncludesPunctuation"
    }

    @frozen
    public enum AdjustedPitchAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey,
        ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = Double
        public typealias ObjectiveCValue = NSNumber
        public static var name: String { "AXPitch" }
        public static let markdownName = "accessibilitySpeechAdjustedPitch"
        public static func objectiveCValue(for value: Double) throws -> NSNumber { NSNumber(value: value) }
        public static func value(for object: NSNumber) throws -> Double { object.doubleValue }
    }

    @frozen
    public enum SpellOutAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        public typealias Value = Bool
        public static var name: String { "AXSpellOut" }
        public static let markdownName = "accessibilitySpeechSpellsOutCharacters"
    }

    @available(*, deprecated, renamed: "AnnouncementPriorityAttribute")
    @frozen
    public enum QueueAnnouncementAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        public typealias Value = Bool
        public static var name: String { "AXQueueAnnouncement" }
        public static let markdownName = "accessibilitySpeechAnnouncementsQueued"
    }

    @frozen
    public enum IPANotationAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        public typealias Value = String
        public static var name: String { "AXIPANotation" }
        public static let markdownName = "accessibilitySpeechPhoneticNotation"
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    @frozen
    public enum AnnouncementPriorityAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey,
        ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = AnnouncementPriority
        public typealias ObjectiveCValue = NSString
        public static var name: String { "AXAnnouncementPriority" }
        public static let markdownName = "accessibilitySpeechAnnouncementPriority"

        public static func decodeMarkdown(from decoder: any Decoder) throws -> AnnouncementPriority {
            try decodeValue(AnnouncementPriority.self, from: decoder)
        }

        /// "high" is AXAnnouncementPriorityHigh.
        public static func objectiveCValue(for value: AnnouncementPriority) throws -> NSString {
            ("AXAnnouncementPriority" + value.rawValue.prefix(1).uppercased() + value.rawValue.dropFirst()) as NSString
        }

        public static func value(for object: NSString) throws -> AnnouncementPriority {
            let s = object as String
            guard s.hasPrefix("AXAnnouncementPriority"),
                  let value = AnnouncementPriority(rawValue: s.dropFirst("AXAnnouncementPriority".count).lowercased()) else {
                throw CocoaError(.coderInvalidValue)
            }
            return value
        }

        public enum AnnouncementPriority: String, Codable, Sendable {
            case low
            case `default`
            case high
        }
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.AccessibilityAttributes.HeadingLevelAttribute: Sendable {}
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.AccessibilityAttributes.TextCustomAttribute: Sendable {}
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.AccessibilityAttributes.TextualContextAttribute: Sendable {}
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.AccessibilityAttributes.IncludesPunctuationAttribute: Sendable {}
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.AccessibilityAttributes.AdjustedPitchAttribute: Sendable {}
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.AccessibilityAttributes.SpellOutAttribute: Sendable {}
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
@available(*, deprecated, renamed: "AnnouncementPriorityAttribute")
extension AttributeScopes.AccessibilityAttributes.QueueAnnouncementAttribute: Sendable {}
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.AccessibilityAttributes.IPANotationAttribute: Sendable {}
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension AttributeScopes.AccessibilityAttributes.AnnouncementPriorityAttribute: Sendable {}

// MARK: - Notifications

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public protocol _AccessibilityNotifications {
    associatedtype _Info
    func post()
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension _AccessibilityNotifications {
    /// Finch has no assistive technologies to tell yet, so posting goes nowhere.
    public func post() {}
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public enum AccessibilityNotification {
    public struct Announcement: _AccessibilityNotifications {
        public typealias _Info = NSAttributedString
        let text: NSAttributedString
        public init(_ announcement: AttributedString) { text = NSAttributedString(announcement) }
        public init(_ announcement: String) { text = NSAttributedString(string: announcement) }
        public init(_ announcement: NSAttributedString) { text = announcement }
    }

    public struct LayoutChanged: _AccessibilityNotifications {
        public typealias _Info = Any?
        let element: Any?
        public init(_ element: Any? = nil) { self.element = element }
    }

    public struct ScreenChanged: _AccessibilityNotifications {
        public typealias _Info = Any?
        let element: Any?
        public init(_ element: Any? = nil) { self.element = element }
    }

    public struct PageScrolled: _AccessibilityNotifications {
        public typealias _Info = NSAttributedString
        let text: NSAttributedString
        public init(_ announcement: AttributedString) { text = NSAttributedString(announcement) }
        public init(_ announcement: String) { text = NSAttributedString(string: announcement) }
        public init(_ announcement: NSAttributedString) { text = announcement }
    }
}

// MARK: - Settings

extension AccessibilitySettings {
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public static var prefersNonBlinkingTextInsertionIndicator: Bool { __AXPrefersNonBlinkingTextInsertionIndicator() }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public static var prefersHorizontalTextLayout: Bool { __AXPrefersHorizontalTextLayout() }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public static var prefersHorizontalTextLayoutDidChangeNotification: Notification.Name {
        .__AXPrefersHorizontalTextLayoutDidChange
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public static var animatedImagesEnabled: Bool { __AXAnimatedImagesEnabled() }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public static var animatedImagesEnabledDidChangeNotification: Notification.Name {
        .__AXAnimatedImagesEnabledDidChange
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public static func openSettings(for feature: Feature) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            __AXOpenSettingsFeature(feature) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @available(macOS 26.4, iOS 26.4, tvOS 26.4, watchOS 26.4, visionOS 26.4, *)
    public static func canOpenSettings(for feature: Feature) -> Bool { __AXOpenSettingsFeatureIsSupported(feature) }

    @available(iOS 26.1, macOS 26.1, tvOS 26.1, watchOS 26.1, visionOS 26.1, *)
    public static var prefersActionSliderAlternative: Bool { __AXPrefersActionSliderAlternative() }

    @available(iOS 26.1, macOS 26.1, tvOS 26.1, watchOS 26.1, visionOS 26.1, *)
    public static var showBordersEnabled: Bool { __AXShowBordersEnabled() }
}
