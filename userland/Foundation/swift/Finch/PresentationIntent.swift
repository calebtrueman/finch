// SPDX-License-Identifier: MIT OR Apache-2.0
// PresentationIntent (block structure of Markdown-derived text), with the
// API of Apple's Foundation (the SDK's Foundation.swiftinterface). Apple keeps
// it in Foundation's private half; swift-foundation's attribute scopes refer
// to it. Finch's own implementation.

@available(macOS 12, iOS 15, watchOS 8, tvOS 15, *)
public struct PresentationIntent: Hashable, Codable, CustomDebugStringConvertible, Sendable {
    /// Innermost first, as Apple's: components[0] is the block itself and
    /// the rest are its ancestors.
    public var components: [IntentType]

    public var count: Int { components.count }

    public var debugDescription: String {
        components.map(\.debugDescription).joined(separator: ", ")
    }

    public enum Kind: Hashable, Codable, CustomDebugStringConvertible, Sendable {
        case paragraph
        case header(level: Int)
        case orderedList
        case unorderedList
        case listItem(ordinal: Int)
        case codeBlock(languageHint: String?)
        case blockQuote
        case thematicBreak
        case table(columns: [TableColumn])
        case tableHeaderRow
        case tableRow(rowIndex: Int)
        case tableCell(columnIndex: Int)

        public var debugDescription: String {
            switch self {
            case .paragraph: return "paragraph"
            case .header(let level): return "header \(level)"
            case .orderedList: return "orderedList"
            case .unorderedList: return "unorderedList"
            case .listItem(let ordinal): return "listItem \(ordinal)"
            case .codeBlock(let hint): return "codeBlock '\(hint ?? "")'"
            case .blockQuote: return "blockQuote"
            case .thematicBreak: return "thematicBreak"
            case .table(let columns): return "table \(columns.map { $0.alignment.rawValue })"
            case .tableHeaderRow: return "tableHeaderRow"
            case .tableRow(let row): return "tableRow \(row)"
            case .tableCell(let column): return "tableCell \(column)"
            }
        }
    }

    public struct TableColumn: Hashable, Codable, Sendable {
        public enum Alignment: Int, Hashable, Codable, Sendable {
            case left, center, right
        }
        public var alignment: Alignment
        public init(alignment: Alignment) { self.alignment = alignment }
    }

    public struct IntentType: Hashable, Codable, CustomDebugStringConvertible, Sendable {
        public var kind: Kind
        public var identity: Int
        public var debugDescription: String { "\(kind.debugDescription) (id \(identity))" }
    }

    public init(_ kind: Kind, identity: Int, parent: PresentationIntent? = nil) {
        components = [IntentType(kind: kind, identity: identity)] + (parent?.components ?? [])
    }

    public init(types: [IntentType]) {
        components = types
    }

    public var isValid: Bool {
        Set(components.map(\.identity)).count == components.count
    }

    public var indentationLevel: Int {
        components.reduce(0) { level, component in
            switch component.kind {
            case .orderedList, .unorderedList, .blockQuote: return level + 1
            default: return level
            }
        }
    }
}
