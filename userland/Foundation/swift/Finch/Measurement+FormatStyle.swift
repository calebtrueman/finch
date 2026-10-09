// SPDX-License-Identifier: MIT OR Apache-2.0
// Measurement.FormatStyle: Apple's is in Foundation's private half. Finch's
// has the width, locale and number style of Apple's API (no usage yet) and
// formats through MeasurementFormatter; Duration.UnitsFormatStyle uses its
// UnitWidth (as in swift-foundation's package stub).

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension Measurement where UnitType: Dimension {
    public struct FormatStyle: Foundation.FormatStyle, Sendable {
        public struct UnitWidth: Codable, Hashable, Sendable {
            public static var wide: Self { .init(option: .wide) }
            public static var abbreviated: Self { .init(option: .abbreviated) }
            public static var narrow: Self { .init(option: .narrow) }

            enum Option: Int, Codable, Hashable {
                case wide
                case abbreviated
                case narrow
            }
            var option: Option

            var skeleton: String {
                switch option {
                case .wide: return "unit-width-full-name"
                case .abbreviated: return "unit-width-short"
                case .narrow: return "unit-width-narrow"
                }
            }
        }

        public var width: UnitWidth
        public var locale: Locale
        public var numberFormatStyle: FloatingPointFormatStyle<Double>?

        public init(width: UnitWidth, locale: Locale = .autoupdatingCurrent,
                    numberFormatStyle: FloatingPointFormatStyle<Double>? = nil) {
            self.width = width
            self.locale = locale
            self.numberFormatStyle = numberFormatStyle
        }

        public func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        public func format(_ measurement: Measurement<UnitType>) -> String {
            let formatter = MeasurementFormatter()
            formatter.locale = locale
            formatter.unitOptions = .providedUnit
            switch width.option {
            case .wide: formatter.unitStyle = .long
            case .abbreviated: formatter.unitStyle = .medium
            case .narrow: formatter.unitStyle = .short
            }
            return formatter.string(from: measurement)
        }
    }
}
