// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Date.ComponentsFormatStyle, as Apple's Foundation declares it: the time between two dates
// as calendar components ("2 hours, 5 minutes"). Apple's implementation is closed and
// swift-foundation has only a stub, so this is Finch's. It formats through
// NSDateComponentsFormatter: the style picks the units style, and the fields pick the
// allowed units (with no fields, every unit, largest first, the zeros left out).

#if canImport(FoundationEssentials)
import FoundationEssentials
#endif

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension Date {
    public struct ComponentsFormatStyle: Foundation.FormatStyle, Codable, Hashable, Sendable {
        public struct Field: Codable, Hashable, Sendable {
            enum Option: Int, Codable, Hashable, CaseIterable, Comparable {
                case year, month, week, day, hour, minute, second

                static func < (a: Option, b: Option) -> Bool { a.rawValue < b.rawValue }

                /* as swift-foundation's other formats use it */
                init?(component: Calendar.Component) {
                    switch component {
                    case .year: self = .year
                    case .month: self = .month
                    case .weekOfMonth, .weekOfYear: self = .week
                    case .day: self = .day
                    case .hour: self = .hour
                    case .minute: self = .minute
                    case .second: self = .second
                    default: return nil
                    }
                }

                var component: Calendar.Component {
                    switch self {
                    case .year: return .year
                    case .month: return .month
                    case .week: return .weekOfMonth
                    case .day: return .day
                    case .hour: return .hour
                    case .minute: return .minute
                    case .second: return .second
                    }
                }

                var unit: NSCalendar.Unit {
                    switch self {
                    case .year: return .year
                    case .month: return .month
                    case .week: return .weekOfMonth
                    case .day: return .day
                    case .hour: return .hour
                    case .minute: return .minute
                    case .second: return .second
                    }
                }
            }
            let option: Option

            public static var year: Field { Field(option: .year) }
            public static var month: Field { Field(option: .month) }
            public static var week: Field { Field(option: .week) }
            public static var day: Field { Field(option: .day) }
            public static var hour: Field { Field(option: .hour) }
            public static var minute: Field { Field(option: .minute) }
            public static var second: Field { Field(option: .second) }
        }

        public struct Style: Codable, Hashable, Sendable {
            enum Option: Int, Codable, Hashable {
                case wide, abbreviated, condensedAbbreviated, narrow, spellOut
            }
            let option: Option

            public static var wide: Style { Style(option: .wide) }
            public static var abbreviated: Style { Style(option: .abbreviated) }
            public static var condensedAbbreviated: Style { Style(option: .condensedAbbreviated) }
            public static var narrow: Style { Style(option: .narrow) }
            public static var spellOut: Style { Style(option: .spellOut) }

            var unitsStyle: DateComponentsFormatter.UnitsStyle {
                switch option {
                case .wide: return .full
                case .abbreviated: return .abbreviated
                case .condensedAbbreviated: return .short
                case .narrow: return .brief
                case .spellOut: return .spellOut
                }
            }
        }

        public var style: Style
        public var fields: Set<Field>?
        public var calendar: Calendar
        public var locale: Locale
        public var isPositive: Bool

        public init(style: Style, locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent,
                    fields: Set<Field>? = nil)
        {
            self.style = style
            self.locale = locale
            self.calendar = calendar
            self.fields = fields
            self.isPositive = true
        }

        public func format(_ v: Range<Date>) -> String {
            let f = DateComponentsFormatter()
            f.unitsStyle = style.unitsStyle
            var cal = calendar
            cal.locale = locale
            f.calendar = cal
            let options = (fields ?? Set(Field.Option.allCases.map { Field(option: $0) })).map(\.option).sorted()
            var units: NSCalendar.Unit = []
            for o in options {
                units.insert(o.unit)
            }
            f.allowedUnits = units
            f.zeroFormattingBehavior = .dropAll
            return f.string(from: v.lowerBound, to: v.upperBound) ?? ""
        }

        public func calendar(_ calendar: Calendar) -> ComponentsFormatStyle {
            var s = self
            s.calendar = calendar
            return s
        }

        public func locale(_ locale: Locale) -> ComponentsFormatStyle {
            var s = self
            s.locale = locale
            return s
        }
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension FormatStyle where Self == Date.ComponentsFormatStyle {
    public static func components(style: Date.ComponentsFormatStyle.Style,
                                  fields: Set<Date.ComponentsFormatStyle.Field>? = nil) -> Self
    {
        Date.ComponentsFormatStyle(style: style, fields: fields)
    }

    public static var timeDuration: Date.ComponentsFormatStyle {
        Date.ComponentsFormatStyle(style: .condensedAbbreviated, fields: [.hour, .minute, .second])
    }
}

/// The input just before or after a range, a second at a time (the components shown change at most once a second).
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
extension Date.ComponentsFormatStyle: DiscreteFormatStyle {
    public func discreteInput(before input: Range<Date>) -> Range<Date>? {
        input.lowerBound..<input.upperBound.addingTimeInterval(-1)
    }

    public func discreteInput(after input: Range<Date>) -> Range<Date>? {
        input.lowerBound..<input.upperBound.addingTimeInterval(1)
    }

    public func input(before input: Range<Date>) -> Range<Date>? {
        input.lowerBound..<input.upperBound.nextDown
    }

    public func input(after input: Range<Date>) -> Range<Date>? {
        input.lowerBound..<input.upperBound.nextUp
    }
}
