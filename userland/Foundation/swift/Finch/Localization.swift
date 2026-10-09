// SPDX-License-Identifier: MIT OR Apache-2.0
// String(localized:), String.LocalizationValue, LocalizedStringResource and
// AttributedString(localized:): Swift's localization API, which Apple's
// Foundation keeps in its private half. Finch's has the API of Apple's (the
// SDK's Foundation.swiftinterface, including the inlinable pieces clients
// compile in: _FormatSpecifiable, the format specifiers) over Bundle's
// string tables: a value is a format key ("Hello %@") and its arguments, the
// key is looked up in the bundle's table, and the result is formatted.
// Inflection (TermOfAddress, InflectionConcept) is carried, not applied.

// MARK: - Format specifiers

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
@preconcurrency public protocol _FormatSpecifiable: Equatable, Sendable {
    associatedtype _Arg: CVarArg, Sendable
    var _arg: _Arg { get }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Int: _FormatSpecifiable { public var _arg: Int64 { Int64(self) } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Int8: _FormatSpecifiable { public var _arg: Int32 { Int32(self) } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Int16: _FormatSpecifiable { public var _arg: Int32 { Int32(self) } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Int32: _FormatSpecifiable { public var _arg: Int32 { self } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Int64: _FormatSpecifiable { public var _arg: Int64 { self } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension UInt: _FormatSpecifiable { public var _arg: UInt64 { UInt64(self) } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension UInt8: _FormatSpecifiable { public var _arg: UInt32 { UInt32(self) } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension UInt16: _FormatSpecifiable { public var _arg: UInt32 { UInt32(self) } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension UInt32: _FormatSpecifiable { public var _arg: UInt32 { self } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension UInt64: _FormatSpecifiable { public var _arg: UInt64 { self } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Float: _FormatSpecifiable { public var _arg: Float { self } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Double: _FormatSpecifiable { public var _arg: Double { self } }
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension CGFloat: _FormatSpecifiable { public var _arg: CGFloat { self } }

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
@_alwaysEmitIntoClient @_semantics("constant_evaluable")
internal func placeholderFormatSpecifier(_ placeholder: String.LocalizationValue.Placeholder) -> String {
    switch placeholder {
    case .int: return "%lld"
    case .uint: return "%llu"
    case .float: return "%f"
    case .double: return "%lf"
    case .object: return "%@"
    }
}

@_semantics("constant_evaluable") @_alwaysEmitIntoClient
internal func formatSpecifier<T>(_ type: T.Type) -> String {
    switch type {
    case is Int.Type: fallthrough
    case is Int64.Type: return "%lld"
    case is Int8.Type: fallthrough
    case is Int16.Type: fallthrough
    case is Int32.Type: return "%d"
    case is UInt.Type: fallthrough
    case is UInt64.Type: return "%llu"
    case is UInt8.Type: fallthrough
    case is UInt16.Type: fallthrough
    case is UInt32.Type: return "%u"
    case is Float.Type: return "%f"
    case is CGFloat.Type: fallthrough
    case is Double.Type: return "%lf"
    default: return "%@"
    }
}

// MARK: - String.LocalizationValue

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension String {
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public struct LocalizationOptions {
        public var replacements: [any CVarArg]?
        public init() {}
    }

    public struct LocalizationValue: Equatable, ExpressibleByStringInterpolation {
        /// The format key: literal text with a format specifier per argument.
        internal var key: String
        internal var arguments: [_Argument]

        internal enum _Argument: Equatable, @unchecked Sendable {
            case value(any CVarArg, String)   // the argument and its description, for ==
            case attributed(AttributedString)

            static func == (a: _Argument, b: _Argument) -> Bool {
                switch (a, b) {
                case (.value(_, let x), .value(_, let y)): return x == y
                case (.attributed(let x), .attributed(let y)): return x == y
                default: return false
                }
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
        public enum Placeholder: Codable, Hashable, Sendable {
            case int, uint, float, double, object
        }

        public init(_ value: String) {
            key = value.replacingOccurrences(of: "%", with: "%%")
            arguments = []
        }

        @_semantics("localization_key.init_literal")
        public init(stringLiteral value: String) {
            self.init(value)
        }

        @_semantics("localization_key.init_interpolation")
        public init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            internal var key = ""
            internal var arguments: [_Argument] = []

            @_semantics("localization.interpolation_init")
            public init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity + 2 * interpolationCount)
            }

            @_semantics("localization.interpolation.appendLiteral")
            public mutating func appendLiteral(_ literal: String) {
                key += literal.replacingOccurrences(of: "%", with: "%%")
            }

            @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation(_ string: String) {
                key += "%@"
                arguments.append(.value(string as NSString, string))
            }

            @_alwaysEmitIntoClient @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation(_ substring: Substring) {
                self.appendInterpolation(String(substring))
            }

            @available(*, deprecated, message: "Localized string interpolation produces an unlocalized, debug description for this type of value. Use String(describing:) to make this explicit and silence this warning or provide a different value that has built-in support or conforms to CustomLocalizedStringResourceConvertible.")
            @_alwaysEmitIntoClient @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation<T>(_ object: T) {
                self.appendInterpolation(String(describing: object))
            }

            @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation<Subject: NSObject>(_ subject: Subject) {
                key += "%@"
                arguments.append(.value(subject, subject.description))
            }

            @_transparent
            public mutating func appendInterpolation<T: _FormatSpecifiable>(_ value: T) {
                appendInterpolation(value, specifier: formatSpecifier(T.self))
            }

            @_semantics("localization.interpolation.appendInterpolation_param_specifier")
            public mutating func appendInterpolation<T: _FormatSpecifiable>(_ value: T, specifier: String) {
                key += specifier
                arguments.append(.value(value._arg, "\(value)"))
            }

            @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
            @_transparent
            public mutating func appendInterpolation(placeholder: Placeholder) {
                appendInterpolation(placeholder: placeholder, specifier: placeholderFormatSpecifier(placeholder))
            }

            @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
            @_semantics("localization.interpolation.appendInterpolation_param_specifier")
            public mutating func appendInterpolation(placeholder: Placeholder, specifier: String) {
                key += specifier
            }

            @preconcurrency @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation<T: Sendable, F: FormatStyle & Sendable>(_ value: T, format: F)
                where T == F.FormatInput, F.FormatOutput: StringProtocol {
                appendInterpolation(String(format.format(value)))
            }

            @preconcurrency @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation<T: Sendable, F: FormatStyle & Sendable>(_ value: T, format: F)
                where T == F.FormatInput, F.FormatOutput: AttributedStringProtocol {
                appendInterpolation(AttributedString(format.format(value)))
            }

            @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation(_ attrStr: AttributedString,
                                                     options: AttributedString.InterpolationOptions = []) {
                key += "%@"
                arguments.append(.attributed(attrStr))
            }

            @_alwaysEmitIntoClient @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation(_ attributedSubstring: AttributedSubstring,
                                                     options: AttributedString.InterpolationOptions = []) {
                self.appendInterpolation(AttributedString(attributedSubstring), options: options)
            }

            @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
            @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation<T: CustomLocalizedStringResourceConvertible>(_ value: T) {
                appendInterpolation(String(localized: value.localizedStringResource))
            }

            @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
            @_semantics("localization.interpolation.appendInterpolation_@_specifier")
            public mutating func appendInterpolation<C: Collection>(_ value: C, format: ListFormatStyle<StringStyle, [String]>)
                where C.Element: CustomLocalizedStringResourceConvertible {
                appendInterpolation(format.format(value.map { String(localized: $0.localizedStringResource) }))
            }
        }

        /// The value's text in the bundle's table (its key when there is no
        /// entry), formatted with its arguments.
        internal func resolve(table: String?, bundle: Bundle?, locale: Locale, replacements: [any CVarArg]? = nil) -> String {
            let format = (bundle ?? .main).localizedString(forKey: key, value: key, table: table)
            let args: [any CVarArg] = replacements ?? arguments.map {
                switch $0 {
                case .value(let v, _): return v
                case .attributed(let a): return String(a.characters) as NSString
                }
            }
            if args.isEmpty && !format.contains("%") { return format }
            return String(format: format, locale: locale, arguments: args)
        }
    }

    @_semantics("string.init_localized")
    public init(localized keyAndValue: LocalizationValue, table: String? = nil, bundle: Bundle? = nil,
                locale: Locale = .current, comment: StaticString? = nil) {
        self = keyAndValue.resolve(table: table, bundle: bundle, locale: locale)
    }

    @_semantics("string.init_localized")
    public init(localized key: StaticString, defaultValue: LocalizationValue, table: String? = nil,
                bundle: Bundle? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        var value = defaultValue
        let format = (bundle ?? .main).localizedString(forKey: key.description, value: defaultValue.key, table: table)
        value.key = format
        self = value.resolve(table: nil, bundle: _FinchIdentityBundle.shared, locale: locale)
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @_semantics("string.init_localized")
    public init(localized keyAndValue: LocalizationValue, options: LocalizationOptions, table: String? = nil,
                bundle: Bundle? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        self = keyAndValue.resolve(table: table, bundle: bundle, locale: locale, replacements: options.replacements)
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @_semantics("string.init_localized")
    public init(localized key: StaticString, defaultValue: LocalizationValue, options: LocalizationOptions,
                table: String? = nil, bundle: Bundle? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        var value = defaultValue
        value.key = (bundle ?? .main).localizedString(forKey: key.description, value: defaultValue.key, table: table)
        self = value.resolve(table: nil, bundle: _FinchIdentityBundle.shared, locale: locale,
                             replacements: options.replacements)
    }
}

/// A "bundle" whose table returns each key as is: for values whose format
/// has already been looked up.
private final class _FinchIdentityBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static let shared = _FinchIdentityBundle(path: "/")!
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String { key }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
extension String.LocalizationValue: @unchecked Sendable {}
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
extension String.LocalizationValue.StringInterpolation: @unchecked Sendable {}

// MARK: - Inflection concepts

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct TermOfAddress: Sendable, Equatable, Hashable {
    private var _language: String?
    public var language: Locale.Language? { _language.map { Locale.Language(identifier: $0) } }
    public private(set) var pronouns: [Morphology.Pronoun]
    private var _kind: Int

    private init(kind: Int, language: String? = nil, pronouns: [Morphology.Pronoun] = []) {
        _kind = kind
        _language = language
        self.pronouns = pronouns
    }
    public static let neutral = TermOfAddress(kind: 1)
    public static let feminine = TermOfAddress(kind: 2)
    public static let masculine = TermOfAddress(kind: 3)
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    public static let currentUser = TermOfAddress(kind: 4)
    public static func localized(language: Locale.Language, pronouns: [Morphology.Pronoun]) -> TermOfAddress {
        TermOfAddress(kind: 5, language: language.minimalIdentifier, pronouns: pronouns)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension TermOfAddress: Codable {}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum InflectionConcept: Sendable, Hashable, Equatable, Codable {
    case termsOfAddress([TermOfAddress])
    case localizedPhrase(String)
}

// MARK: - AttributedString(localized:)

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AttributedString {
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public struct LocalizationOptions {
        public var replacements: [any CVarArg]?
        private var _concepts: [Any]?
        @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
        public var concepts: [InflectionConcept]? {
            get { _concepts as? [InflectionConcept] }
            set { _concepts = newValue }
        }
        private var _inflect = false
        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        public var inflect: Bool {
            get { _inflect }
            set { _inflect = newValue }
        }
        public var applyReplacementIndexAttribute: Bool = false
        public init() {}

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
        public static func termsOfAddressConcept(_ termsOfAddress: [TermOfAddress]) -> LocalizationOptions {
            var options = LocalizationOptions()
            options.concepts = [.termsOfAddress(termsOfAddress)]
            return options
        }
        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
        public static func localizedPhraseConcept(_ phrase: String) -> LocalizationOptions {
            var options = LocalizationOptions()
            options.concepts = [.localizedPhrase(phrase)]
            return options
        }
    }

    public struct FormattingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let applyReplacementIndexAttribute = FormattingOptions(rawValue: 1 << 0)
    }

    public struct InterpolationOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let insertAttributesWithoutMerging = InterpolationOptions(rawValue: 1 << 0)
    }

    /// A localized string as an attributed string: its inline Markdown is
    /// interpreted, as Apple's does.
    fileprivate static func _localized(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }

    @_semantics("attributed_string.init_localized")
    public init(localized key: String.LocalizationValue, options: FormattingOptions = [], table: String? = nil,
                bundle: Bundle? = nil, locale: Locale? = nil, comment: StaticString? = nil) {
        self = Self._localized(String(localized: key, table: table, bundle: bundle, locale: locale ?? .current))
    }

    @_semantics("attributed_string.init_localized")
    public init(localized key: StaticString, defaultValue: String.LocalizationValue, options: FormattingOptions = [],
                table: String? = nil, bundle: Bundle? = nil, locale: Locale? = nil, comment: StaticString? = nil) {
        self = Self._localized(String(localized: key, defaultValue: defaultValue, table: table, bundle: bundle,
                                      locale: locale ?? .current))
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @_semantics("attributed_string.init_localized")
    public init(localized key: String.LocalizationValue, options: LocalizationOptions, table: String? = nil,
                bundle: Bundle? = nil, locale: Locale? = nil, comment: StaticString? = nil) {
        var o = String.LocalizationOptions()
        o.replacements = options.replacements
        self = Self._localized(String(localized: key, options: o, table: table, bundle: bundle, locale: locale ?? .current))
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @_semantics("attributed_string.init_localized")
    public init(localized key: StaticString, defaultValue: String.LocalizationValue, options: LocalizationOptions,
                table: String? = nil, bundle: Bundle? = nil, locale: Locale? = nil, comment: StaticString? = nil) {
        var o = String.LocalizationOptions()
        o.replacements = options.replacements
        self = Self._localized(String(localized: key, defaultValue: defaultValue, options: o, table: table,
                                      bundle: bundle, locale: locale ?? .current))
    }

    @_semantics("attributed_string.init_localized")
    public init<S: AttributeScope>(localized key: String.LocalizationValue, options: FormattingOptions = [],
                                   table: String? = nil, bundle: Bundle? = nil, locale: Locale? = nil,
                                   comment: StaticString? = nil, including scope: KeyPath<AttributeScopes, S.Type>) {
        self.init(localized: key, options: options, table: table, bundle: bundle, locale: locale, comment: comment)
    }

    @_semantics("attributed_string.init_localized")
    public init<S: AttributeScope>(localized key: StaticString, defaultValue: String.LocalizationValue,
                                   options: FormattingOptions = [], table: String? = nil, bundle: Bundle? = nil,
                                   locale: Locale? = nil, comment: StaticString? = nil,
                                   including scope: KeyPath<AttributeScopes, S.Type>) {
        self.init(localized: key, defaultValue: defaultValue, options: options, table: table, bundle: bundle,
                  locale: locale, comment: comment)
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @_semantics("attributed_string.init_localized")
    public init<S: AttributeScope>(localized key: String.LocalizationValue, options: LocalizationOptions,
                                   table: String? = nil, bundle: Bundle? = nil, locale: Locale? = nil,
                                   comment: StaticString? = nil, including scope: KeyPath<AttributeScopes, S.Type>) {
        self.init(localized: key, options: options, table: table, bundle: bundle, locale: locale, comment: comment)
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @_semantics("attributed_string.init_localized")
    public init<S: AttributeScope>(localized key: StaticString, defaultValue: String.LocalizationValue,
                                   options: LocalizationOptions, table: String? = nil, bundle: Bundle? = nil,
                                   locale: Locale? = nil, comment: StaticString? = nil,
                                   including scope: KeyPath<AttributeScopes, S.Type>) {
        self.init(localized: key, defaultValue: defaultValue, options: options, table: table, bundle: bundle,
                  locale: locale, comment: comment)
    }

    @_semantics("attributed_string.init_localized")
    public init<S: AttributeScope>(localized key: String.LocalizationValue, options: FormattingOptions = [],
                                   table: String? = nil, bundle: Bundle? = nil, locale: Locale? = nil,
                                   comment: StaticString? = nil, including scope: S.Type) {
        self.init(localized: key, options: options, table: table, bundle: bundle, locale: locale, comment: comment)
    }

    @_semantics("attributed_string.init_localized")
    public init<S: AttributeScope>(localized key: StaticString, defaultValue: String.LocalizationValue,
                                   options: FormattingOptions = [], table: String? = nil, bundle: Bundle? = nil,
                                   locale: Locale? = nil, comment: StaticString? = nil, including scope: S.Type) {
        self.init(localized: key, defaultValue: defaultValue, options: options, table: table, bundle: bundle,
                  locale: locale, comment: comment)
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @_semantics("attributed_string.init_localized")
    public init<S: AttributeScope>(localized key: String.LocalizationValue, options: LocalizationOptions,
                                   table: String? = nil, bundle: Bundle? = nil, locale: Locale? = nil,
                                   comment: StaticString? = nil, including scope: S.Type) {
        self.init(localized: key, options: options, table: table, bundle: bundle, locale: locale, comment: comment)
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @_semantics("attributed_string.init_localized")
    public init<S: AttributeScope>(localized key: StaticString, defaultValue: String.LocalizationValue,
                                   options: LocalizationOptions, table: String? = nil, bundle: Bundle? = nil,
                                   locale: Locale? = nil, comment: StaticString? = nil, including scope: S.Type) {
        self.init(localized: key, defaultValue: defaultValue, options: options, table: table, bundle: bundle,
                  locale: locale, comment: comment)
    }
}

// MARK: - LocalizedStringResource

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public protocol CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { get }
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct LocalizedStringResource: Equatable, Codable, CustomLocalizedStringResourceConvertible,
                                       ExpressibleByStringInterpolation {
    public let key: String
    public let defaultValue: String.LocalizationValue
    public let table: String?
    public var locale: Locale
    private let _bundle: BundleDescription
    public var bundle: BundleDescription { _bundle }

    public enum BundleDescription: Sendable {
        case main
        case forClass(AnyClass)
        case atURL(URL)

        internal var bundle: Bundle {
            switch self {
            case .main: return .main
            case .forClass(let c): return Bundle(for: c)
            case .atURL(let url): return Bundle(url: url) ?? .main
            }
        }
    }

    @_semantics("string.init_localized")
    public init(_ keyAndValue: String.LocalizationValue, table: String? = nil, locale: Locale = .current,
                bundle: BundleDescription = .main, comment: StaticString? = nil) {
        key = keyAndValue.key
        defaultValue = keyAndValue
        self.table = table
        self.locale = locale
        _bundle = bundle
    }

    @_semantics("string.init_localized")
    public init(_ key: StaticString, defaultValue: String.LocalizationValue, table: String? = nil,
                locale: Locale = .current, bundle: BundleDescription = .main, comment: StaticString? = nil) {
        self.key = key.description
        self.defaultValue = defaultValue
        self.table = table
        self.locale = locale
        _bundle = bundle
    }

    @_alwaysEmitIntoClient @_disfavoredOverload @_semantics("string.init_localized")
    public init(_ keyAndValue: String.LocalizationValue, table: String? = nil, locale: Locale = .current,
                bundle: Bundle, comment: StaticString? = nil) {
        self.init(keyAndValue, table: table, locale: locale, bundle: .atURL(bundle.bundleURL), comment: comment)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload @_semantics("string.init_localized")
    public init(_ key: StaticString, defaultValue: String.LocalizationValue, table: String? = nil,
                locale: Locale = .current, bundle: Bundle, comment: StaticString? = nil) {
        self.init(key, defaultValue: defaultValue, table: table, locale: locale, bundle: .atURL(bundle.bundleURL),
                  comment: comment)
    }

    @_semantics("localization_key.init_literal")
    public init(stringLiteral value: String) {
        self.init(String.LocalizationValue(stringLiteral: value))
    }

    @_semantics("localization_key.init_interpolation")
    public init(stringInterpolation: String.LocalizationValue.StringInterpolation) {
        self.init(String.LocalizationValue(stringInterpolation: stringInterpolation))
    }

    public var localizedStringResource: LocalizedStringResource { self }

    private enum CodingKeys: String, CodingKey { case key, defaultValue, table, locale, bundleURL }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(String(localized: self), forKey: .defaultValue)
        try c.encodeIfPresent(table, forKey: .table)
        try c.encode(locale, forKey: .locale)
        if case .atURL(let url) = _bundle { try c.encode(url, forKey: .bundleURL) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        defaultValue = String.LocalizationValue(try c.decode(String.self, forKey: .defaultValue))
        table = try c.decodeIfPresent(String.self, forKey: .table)
        locale = try c.decode(Locale.self, forKey: .locale)
        _bundle = try c.decodeIfPresent(URL.self, forKey: .bundleURL).map { .atURL($0) } ?? .main
    }

    public static func == (lhs: LocalizedStringResource, rhs: LocalizedStringResource) -> Bool {
        lhs.key == rhs.key && lhs.defaultValue == rhs.defaultValue && lhs.table == rhs.table && lhs.locale == rhs.locale
    }

    public typealias StringInterpolation = String.LocalizationValue.StringInterpolation
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
extension LocalizedStringResource: @unchecked Sendable {}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
extension String {
    @_disfavoredOverload
    public init(localized resource: LocalizedStringResource) {
        var value = resource.defaultValue
        value.key = resource.bundle.bundle.localizedString(forKey: resource.key, value: resource.defaultValue.key,
                                                          table: resource.table)
        self = value.resolve(table: nil, bundle: _FinchIdentityBundle.shared, locale: resource.locale)
    }

    @_disfavoredOverload
    public init(localized resource: LocalizedStringResource, options: LocalizationOptions) {
        var value = resource.defaultValue
        value.key = resource.bundle.bundle.localizedString(forKey: resource.key, value: resource.defaultValue.key,
                                                          table: resource.table)
        self = value.resolve(table: nil, bundle: _FinchIdentityBundle.shared, locale: resource.locale,
                             replacements: options.replacements)
    }
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
extension AttributedString {
    @_disfavoredOverload
    public init(localized resource: LocalizedStringResource) {
        self = Self._localized(String(localized: resource))
    }
    @_disfavoredOverload
    public init<S: AttributeScope>(localized resource: LocalizedStringResource,
                                   including scope: KeyPath<AttributeScopes, S.Type>) {
        self.init(localized: resource)
    }
    @_disfavoredOverload
    public init<S: AttributeScope>(localized resource: LocalizedStringResource, including scope: S.Type) {
        self.init(localized: resource)
    }
    @_disfavoredOverload
    public init(localized resource: LocalizedStringResource, options: LocalizationOptions) {
        var o = String.LocalizationOptions()
        o.replacements = options.replacements
        self = Self._localized(String(localized: resource, options: o))
    }
    @_disfavoredOverload
    public init<S: AttributeScope>(localized resource: LocalizedStringResource, options: LocalizationOptions,
                                   including scope: KeyPath<AttributeScopes, S.Type>) {
        self.init(localized: resource, options: options)
    }
    @_disfavoredOverload
    public init<S: AttributeScope>(localized resource: LocalizedStringResource, options: LocalizationOptions,
                                   including scope: S.Type) {
        self.init(localized: resource, options: options)
    }
}
