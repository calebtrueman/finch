// SPDX-License-Identifier: MIT OR Apache-2.0
// AttributedString.MarkdownSourcePosition: Apple's Foundation declares it
// beside its Markdown parser (not part of swift-foundation). Finch's has the
// public API of Apple's (the SDK's Foundation.swiftinterface) and the offsets
// swift-foundation's NSRange(_:in:) reads.

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
extension AttributedString {
    public struct MarkdownSourcePosition: Hashable, Codable, Sendable {
        public let startLine: Int
        public let startColumn: Int
        public let endLine: Int
        public let endColumn: Int

        /// Offsets of a position in the Markdown source, when the parser
        /// recorded them.
        internal struct Offsets: Hashable, Sendable {
            var utf8: Int
            var utf16: Int
            var utf8NextCodePoint: Int
            var utf16CurrentCodePointLength: Int
        }
        internal var startOffsets: Offsets? { nil }
        internal var endOffsets: Offsets? { nil }

        public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
            self.startLine = startLine
            self.startColumn = startColumn
            self.endLine = endLine
            self.endColumn = endColumn
        }

        private enum CodingKeys: String, CodingKey {
            case startLine, startColumn, endLine, endColumn
        }

        /// The offsets of the (1-based, inclusive) line and UTF-8 column
        /// bounds within `text`.
        internal func calculateOffsets<S: StringProtocol>(within text: S) -> (start: Offsets, end: Offsets)? {
            func offsets(line: Int, column: Int) -> Offsets? {
                var currentLine = 1
                var utf8 = 0
                var utf16 = 0
                var lineStartUTF8 = 0
                for scalar in text.unicodeScalars {
                    if currentLine == line && utf8 - lineStartUTF8 + 1 >= column {
                        break
                    }
                    let u8 = UTF8.width(scalar)
                    utf8 += u8
                    utf16 += UTF16.width(scalar)
                    if scalar == "\n" {
                        currentLine += 1
                        lineStartUTF8 = utf8
                    }
                }
                guard currentLine == line else { return nil }
                // The code point containing the column, and where the next one starts.
                var next = utf8
                var length = 0
                var seen = 0
                for scalar in text.unicodeScalars {
                    let u8 = UTF8.width(scalar)
                    if seen + u8 > utf8 {
                        next = seen + u8
                        length = UTF16.width(scalar)
                        break
                    }
                    seen += u8
                }
                return Offsets(utf8: utf8, utf16: utf16, utf8NextCodePoint: next,
                               utf16CurrentCodePointLength: length)
            }
            guard let start = offsets(line: startLine, column: startColumn),
                  let end = offsets(line: endLine, column: endColumn) else { return nil }
            return (start, end)
        }
    }
}
