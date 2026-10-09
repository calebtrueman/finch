// SPDX-License-Identifier: MIT OR Apache-2.0
// Morphology and InflectionRule (automatic grammar agreement), with the API
// of Apple's Foundation (the SDK's Foundation.swiftinterface). Apple keeps
// them beside swift-foundation in Foundation's private half; swift-foundation
// refers to them from its attribute scopes. Finch doesn't inflect text yet:
// the types carry their values and code, and canInflect answers false.

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public struct Morphology: Sendable {
    public init() {}

    public enum GrammaticalGender: Int, Hashable, Sendable {
        case feminine = 1, masculine, neuter
    }
    public var grammaticalGender: GrammaticalGender?

    public enum PartOfSpeech: Int, Hashable, Sendable {
        case determiner = 1, pronoun, letter, adverb, particle, adjective, adposition, verb, noun,
             conjunction, numeral, interjection, preposition, abbreviation
    }
    public var partOfSpeech: PartOfSpeech?

    public enum GrammaticalNumber: Int, Hashable, Sendable {
        case singular = 1, zero, plural, pluralTwo, pluralFew, pluralMany
    }
    public var number: GrammaticalNumber?

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public enum GrammaticalCase: Int, Hashable, Sendable {
        case nominative = 1, accusative, dative, genitive, prepositional, ablative, adessive, allative,
             elative, illative, essive, inessive, locative, translative
    }
    private var _grammaticalCase: Int?
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public var grammaticalCase: GrammaticalCase? {
        get { _grammaticalCase.flatMap(GrammaticalCase.init(rawValue:)) }
        set { _grammaticalCase = newValue?.rawValue }
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public enum GrammaticalPerson: Int, Hashable, Sendable {
        case first = 1, second, third
    }
    private var _grammaticalPerson: Int?
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public var grammaticalPerson: GrammaticalPerson? {
        get { _grammaticalPerson.flatMap(GrammaticalPerson.init(rawValue:)) }
        set { _grammaticalPerson = newValue?.rawValue }
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public enum PronounType: Int, Hashable, Sendable {
        case personal = 1, reflexive, possessive
    }
    private var _pronounType: Int?
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public var pronounType: PronounType? {
        get { _pronounType.flatMap(PronounType.init(rawValue:)) }
        set { _pronounType = newValue?.rawValue }
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public enum Determination: Int, Hashable, Sendable {
        case independent = 1, dependent
    }
    private var _determination: Int?
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public var determination: Determination? {
        get { _determination.flatMap(Determination.init(rawValue:)) }
        set { _determination = newValue?.rawValue }
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public enum Definiteness: Int, Hashable, Sendable {
        case indefinite = 1, definite
    }
    private var _definiteness: Int?
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    public var definiteness: Definiteness? {
        get { _definiteness.flatMap(Definiteness.init(rawValue:)) }
        set { _definiteness = newValue?.rawValue }
    }

    fileprivate var customPronouns: [String: CustomPronoun] = [:]
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public enum InflectionRule: Sendable {
    case automatic
    case explicit(Morphology)
    public init(morphology: Morphology) { self = .explicit(morphology) }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Morphology: Hashable {}
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension InflectionRule: Hashable {}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Morphology: Codable {
    private enum CodingKeys: String, CodingKey {
        case grammaticalGender, partOfSpeech, number, grammaticalCase, grammaticalPerson,
             pronounType, determination, definiteness, customPronouns
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grammaticalGender = try c.decodeIfPresent(GrammaticalGender.self, forKey: .grammaticalGender)
        partOfSpeech = try c.decodeIfPresent(PartOfSpeech.self, forKey: .partOfSpeech)
        number = try c.decodeIfPresent(GrammaticalNumber.self, forKey: .number)
        _grammaticalCase = try c.decodeIfPresent(Int.self, forKey: .grammaticalCase)
        _grammaticalPerson = try c.decodeIfPresent(Int.self, forKey: .grammaticalPerson)
        _pronounType = try c.decodeIfPresent(Int.self, forKey: .pronounType)
        _determination = try c.decodeIfPresent(Int.self, forKey: .determination)
        _definiteness = try c.decodeIfPresent(Int.self, forKey: .definiteness)
        customPronouns = try c.decodeIfPresent([String: CustomPronoun].self, forKey: .customPronouns) ?? [:]
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(grammaticalGender, forKey: .grammaticalGender)
        try c.encodeIfPresent(partOfSpeech, forKey: .partOfSpeech)
        try c.encodeIfPresent(number, forKey: .number)
        try c.encodeIfPresent(_grammaticalCase, forKey: .grammaticalCase)
        try c.encodeIfPresent(_grammaticalPerson, forKey: .grammaticalPerson)
        try c.encodeIfPresent(_pronounType, forKey: .pronounType)
        try c.encodeIfPresent(_determination, forKey: .determination)
        try c.encodeIfPresent(_definiteness, forKey: .definiteness)
        if !customPronouns.isEmpty { try c.encode(customPronouns, forKey: .customPronouns) }
    }
}
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Morphology.GrammaticalGender: Codable {}
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Morphology.GrammaticalNumber: Codable {}
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Morphology.PartOfSpeech: Codable {}
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Morphology.GrammaticalCase: Codable {}
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Morphology.Determination: Codable {}
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Morphology.Definiteness: Codable {}
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Morphology.GrammaticalPerson: Codable {}
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Morphology.PronounType: Codable {}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension InflectionRule: Codable {
    private enum CodingKeys: String, CodingKey { case morphology }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let m = try c.decodeIfPresent(Morphology.self, forKey: .morphology) {
            self = .explicit(m)
        } else {
            self = .automatic
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if case .explicit(let m) = self { try c.encode(m, forKey: .morphology) }
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension InflectionRule {
    public static func canInflect(language: String) -> Bool { false }
    public static var canInflectPreferredLocalization: Bool { false }
}

@available(macOS, introduced: 12.0, deprecated: 14.0, message: "Use TermOfAddress instead")
@available(iOS, introduced: 15.0, deprecated: 17.0, message: "Use TermOfAddress instead")
@available(tvOS, introduced: 15.0, deprecated: 17.0, message: "Use TermOfAddress instead")
@available(watchOS, introduced: 8.0, deprecated: 10.0, message: "Use TermOfAddress instead")
extension Morphology {
    public func customPronoun(forLanguage language: String) -> CustomPronoun? {
        customPronouns[language]
    }
    public mutating func setCustomPronoun(_ pronoun: CustomPronoun?, forLanguage language: String) throws {
        customPronouns[language] = pronoun
    }

    public struct CustomPronoun: Sendable, Codable, Hashable, Equatable {
        public init() {}
        public static func isSupported(forLanguage language: String) -> Bool { language.hasPrefix("en") }
        public static func requiredKeys(forLanguage language: String) -> [PartialKeyPath<CustomPronoun>] {
            isSupported(forLanguage: language)
                ? [\.subjectForm, \.objectForm, \.possessiveForm, \.possessiveAdjectiveForm, \.reflexiveForm] : []
        }
        public var subjectForm: String? {
            get { _subjectForm } set { _subjectForm = newValue }
        }
        public var objectForm: String? {
            get { _objectForm } set { _objectForm = newValue }
        }
        public var possessiveForm: String? {
            get { _possessiveForm } set { _possessiveForm = newValue }
        }
        public var possessiveAdjectiveForm: String? {
            get { _possessiveAdjectiveForm } set { _possessiveAdjectiveForm = newValue }
        }
        public var reflexiveForm: String? {
            get { _reflexiveForm } set { _reflexiveForm = newValue }
        }
        private var _subjectForm: String?
        private var _objectForm: String?
        private var _possessiveForm: String?
        private var _possessiveAdjectiveForm: String?
        private var _reflexiveForm: String?
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Morphology {
    public struct Pronoun: Sendable, Equatable, Hashable, Codable {
        public var pronoun: String
        public var morphology: Morphology
        public var dependentMorphology: Morphology?
        public init(pronoun: String, morphology: Morphology, dependentMorphology: Morphology? = nil) {
            self.pronoun = pronoun
            self.morphology = morphology
            self.dependentMorphology = dependentMorphology
        }
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Morphology {
    public var isUnspecified: Bool { self == Morphology() }
    public static let user = Morphology()
}

extension NSAttributedString.Key {
    /// The attribute name of AssumedFallbackInflectionAttribute (Apple's
    /// private NSAssumedFallbackInflection key).
    internal static let _assumedFallbackInflection = NSAttributedString.Key("NSAssumedFallbackInflection")
}
