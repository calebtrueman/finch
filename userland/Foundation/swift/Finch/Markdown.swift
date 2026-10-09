// SPDX-License-Identifier: MIT OR Apache-2.0
// AttributedString(markdown:): Apple's Foundation parses with cmark-gfm in
// its private half. Finch has the same API (the SDK's
// Foundation.swiftinterface) over its own small parser: inline emphasis,
// strong emphasis, code, strikethrough, links and backslash escapes, and
// with .full syntax paragraphs, ATX headers, block quotes, thematic breaks,
// lists and fenced code blocks, recorded as presentationIntent as Apple's
// parser records them (blocks are not separated by newlines).

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AttributedString {
    public struct MarkdownParsingOptions: Sendable {
        public enum FailurePolicy: Int, Sendable {
            case throwError
            case returnPartiallyParsedIfPossible
        }
        public enum InterpretedSyntax: Int, Sendable {
            case full
            case inlineOnly
            case inlineOnlyPreservingWhitespace
        }
        public var allowsExtendedAttributes: Bool
        public var interpretedSyntax: InterpretedSyntax
        public var failurePolicy: FailurePolicy
        public var languageCode: String?
        private var _appliesSourcePositionAttributes = false
        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
        public var appliesSourcePositionAttributes: Bool {
            get { _appliesSourcePositionAttributes }
            set { _appliesSourcePositionAttributes = newValue }
        }

        public init(allowsExtendedAttributes: Bool = false, interpretedSyntax: InterpretedSyntax = .full,
                    failurePolicy: FailurePolicy = .throwError, languageCode: String? = nil) {
            self.allowsExtendedAttributes = allowsExtendedAttributes
            self.interpretedSyntax = interpretedSyntax
            self.failurePolicy = failurePolicy
            self.languageCode = languageCode
        }

        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
        public init(allowsExtendedAttributes: Bool = false, interpretedSyntax: InterpretedSyntax = .full,
                    failurePolicy: FailurePolicy = .throwError, languageCode: String? = nil,
                    appliesSourcePositionAttributes: Bool = false) {
            self.init(allowsExtendedAttributes: allowsExtendedAttributes, interpretedSyntax: interpretedSyntax,
                      failurePolicy: failurePolicy, languageCode: languageCode)
            self._appliesSourcePositionAttributes = appliesSourcePositionAttributes
        }
    }

    public init<S: AttributeScope>(markdown: String, including scope: KeyPath<AttributeScopes, S.Type>,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = _FinchMarkdown.parse(markdown, options: options, baseURL: baseURL)
    }
    public init(markdown: String, options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = _FinchMarkdown.parse(markdown, options: options, baseURL: baseURL)
    }
    public init<S: AttributeScope>(markdown: String, including scope: S.Type,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = _FinchMarkdown.parse(markdown, options: options, baseURL: baseURL)
    }
    public init<S: AttributeScope>(markdown: Data, including scope: KeyPath<AttributeScopes, S.Type>,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(_FinchMarkdown.text(markdown), options: options, baseURL: baseURL)
    }
    public init(markdown: Data, options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(_FinchMarkdown.text(markdown), options: options, baseURL: baseURL)
    }
    public init<S: AttributeScope>(markdown: Data, including scope: S.Type,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self = try _FinchMarkdown.parse(_FinchMarkdown.text(markdown), options: options, baseURL: baseURL)
    }
    public init<S: AttributeScope>(contentsOf url: URL, including scope: KeyPath<AttributeScopes, S.Type>,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        try self.init(markdown: Data(contentsOf: url), options: options, baseURL: baseURL ?? url)
    }
    public init(contentsOf url: URL, options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        try self.init(markdown: Data(contentsOf: url), options: options, baseURL: baseURL ?? url)
    }
    public init<S: AttributeScope>(contentsOf url: URL, including scope: S.Type,
                                   options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        try self.init(markdown: Data(contentsOf: url), options: options, baseURL: baseURL ?? url)
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension InlinePresentationIntent: Hashable, Codable {}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
internal enum _FinchMarkdown {
    static func text(_ data: Data) throws -> String {
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return s
    }

    static func parse(_ source: String, options: AttributedString.MarkdownParsingOptions,
                      baseURL: URL?) -> AttributedString {
        switch options.interpretedSyntax {
        case .inlineOnlyPreservingWhitespace:
            return inline(source, baseURL: baseURL)
        case .inlineOnly:
            // Line breaks inside a paragraph become spaces, as in Markdown.
            let joined = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return inline(joined, baseURL: baseURL)
        case .full:
            return blocks(source, baseURL: baseURL)
        }
    }

    // MARK: Blocks

    private static func blocks(_ source: String, baseURL: URL?) -> AttributedString {
        var result = AttributedString()
        var identity = 0
        func nextID() -> Int { identity += 1; return identity }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            var run = inline(text, baseURL: baseURL)
            run.presentationIntent = PresentationIntent(.paragraph, identity: nextID())
            result += run
            paragraph = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.hasPrefix("```") {
                flushParagraph()
                let hint = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                var run = AttributedString(code.joined(separator: "\n") + "\n")
                run.presentationIntent = PresentationIntent(.codeBlock(languageHint: hint.isEmpty ? nil : hint),
                                                            identity: nextID())
                result += run
            } else if let level = headerLevel(trimmed) {
                flushParagraph()
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                var run = inline(text, baseURL: baseURL)
                run.presentationIntent = PresentationIntent(.header(level: level), identity: nextID())
                result += run
            } else if trimmed.count >= 3, Set(trimmed.filter { $0 != " " }).count == 1,
                      let c = trimmed.first, c == "-" || c == "*" || c == "_",
                      trimmed.filter({ $0 != " " }).count >= 3 {
                flushParagraph()
                var run = AttributedString("\u{2028}")
                run.presentationIntent = PresentationIntent(.thematicBreak, identity: nextID())
                result += run
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let quote = PresentationIntent(.blockQuote, identity: nextID())
                var run = inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces), baseURL: baseURL)
                run.presentationIntent = PresentationIntent(.paragraph, identity: nextID(), parent: quote)
                result += run
            } else if let (ordinal, text) = listItem(trimmed) {
                flushParagraph()
                let list = PresentationIntent(ordinal == nil ? .unorderedList : .orderedList, identity: nextID())
                var n = 1
                var j = i
                var item: (Int?, String)? = (ordinal, text)
                while let (ord, t) = item {
                    let li = PresentationIntent(.listItem(ordinal: ord ?? n), identity: nextID(), parent: list)
                    var run = inline(t, baseURL: baseURL)
                    run.presentationIntent = PresentationIntent(.paragraph, identity: nextID(), parent: li)
                    result += run
                    n += 1
                    j += 1
                    item = j < lines.count ? listItem(lines[j].trimmingCharacters(in: .whitespaces)) : nil
                }
                i = j - 1
            } else {
                paragraph.append(line)
            }
            i += 1
        }
        flushParagraph()
        return result
    }

    private static func headerLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    private static func listItem(_ line: String) -> (Int?, String)? {
        if let c = line.first, c == "-" || c == "*" || c == "+", line.dropFirst().first == " " {
            return (nil, String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if let c = rest.first, c == "." || c == ")", rest.dropFirst().first == " " {
                return (Int(digits), String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    // MARK: Inlines

    private static func inline(_ text: String, baseURL: URL?) -> AttributedString {
        var result = AttributedString()
        let chars = Array(text)
        var plain = ""
        var intent: InlinePresentationIntent = []
        func flush() {
            guard !plain.isEmpty else { return }
            var run = AttributedString(plain)
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            result += run
            plain = ""
        }
        var i = 0
        // Delimiters that are open, innermost last.
        var open: [(String, InlinePresentationIntent)] = []
        func closes(_ d: String, at i: Int) -> Bool {
            guard i + d.count <= chars.count, String(chars[i ..< i + d.count]) == d else { return false }
            return open.last?.0 == d
        }
        func hasCloser(_ d: String, after i: Int) -> Bool {
            var j = i + d.count
            while j + d.count <= chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if String(chars[j ..< j + d.count]) == d { return j > i + d.count }
                j += 1
            }
            return false
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                plain.append(chars[i + 1]); i += 2; continue
            }
            if c == "`" {
                let ticks = chars[i...].prefix(while: { $0 == "`" }).count
                let delim = String(repeating: "`", count: ticks)
                if let end = find(delim, in: chars, from: i + ticks) {
                    flush()
                    var code = String(chars[i + ticks ..< end])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    var run = AttributedString(code)
                    run.inlinePresentationIntent = intent.union(.code)
                    result += run
                    i = end + ticks
                    continue
                }
            }
            if c == "[", let close = matching(chars, from: i, open: "[", close: "]"),
               close + 1 < chars.count, chars[close + 1] == "(",
               let paren = matching(chars, from: close + 1, open: "(", close: ")") {
                flush()
                let label = String(chars[i + 1 ..< close])
                var target = String(chars[close + 2 ..< paren]).trimmingCharacters(in: .whitespaces)
                if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
                if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
                var run = inline(label, baseURL: baseURL)
                if !intent.isEmpty {
                    for r in run.runs {
                        run[r.range].inlinePresentationIntent = (r.inlinePresentationIntent ?? []).union(intent)
                    }
                }
                run.link = URL(string: target, relativeTo: baseURL)
                result += run
                i = paren + 1
                continue
            }
            if c == "*" || c == "_" || c == "~" {
                let run = chars[i...].prefix(while: { $0 == c }).count
                let take = c == "~" ? (run >= 2 ? 2 : 0) : min(run, 2)
                if take > 0 {
                    let d = String(repeating: String(c), count: take)
                    let kind: InlinePresentationIntent =
                        c == "~" ? .strikethrough : (take == 2 ? .stronglyEmphasized : .emphasized)
                    if closes(d, at: i) {
                        flush()
                        open.removeLast()
                        intent.remove(kind)
                        i += take
                        continue
                    }
                    if hasCloser(d, after: i), i + take < chars.count, chars[i + take] != " " {
                        flush()
                        open.append((d, kind))
                        intent.insert(kind)
                        i += take
                        continue
                    }
                }
            }
            plain.append(c)
            i += 1
        }
        // Unclosed delimiters were never opened (hasCloser), so nothing is left.
        flush()
        return result
    }

    private static func find(_ delim: String, in chars: [Character], from start: Int) -> Int? {
        var j = start
        let d = Array(delim)
        while j + d.count <= chars.count {
            if Array(chars[j ..< j + d.count]) == d { return j }
            j += 1
        }
        return nil
    }

    private static func matching(_ chars: [Character], from start: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        var j = start
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == open { depth += 1 }
            if chars[j] == close { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }
}

/// For Foundation's Objective-C half (-[NSBundle localizedAttributedStringForKey:value:table:]):
/// inline Markdown as an NSAttributedString, or nil if it doesn't parse. Returned retained.
@_cdecl("_FinchAttributedStringFromInlineMarkdown")
func _FinchAttributedStringFromInlineMarkdown(_ string: NSString) -> Unmanaged<NSAttributedString>? {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard let parsed = try? AttributedString(markdown: string as String, options: options) else { return nil }
    return Unmanaged.passRetained(NSAttributedString(parsed))
}
