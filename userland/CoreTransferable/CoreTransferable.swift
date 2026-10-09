// SPDX-License-Identifier: MIT OR Apache-2.0
//
// CoreTransferable: how a type says what forms it can be sent and received in (data, files,
// another transferable type, Codable), to Apple's interface. Each representation flattens to
// a list of entries, one per content type, holding the closures that export an item to data
// or a file and import one back; the Transferable conveniences, and NSItemProvider's
// registering and loading, go through those entries in their declared order.

import Combine
import Foundation
import UniformTypeIdentifiers

// MARK: - The protocols

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public protocol TransferRepresentation<Item>: Sendable {
    associatedtype Item: Transferable
    associatedtype Body: TransferRepresentation
    @TransferRepresentationBuilder<Item> var body: Body { get }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
@preconcurrency
public protocol Transferable: Sendable {
    associatedtype Representation: TransferRepresentation
    @TransferRepresentationBuilder<Self> static var transferRepresentation: Representation { get }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
@_originallyDefinedIn(module: "SwiftUI", iOS 18.0)
@_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
@_originallyDefinedIn(module: "SwiftUI", tvOS 18.0)
@_originallyDefinedIn(module: "SwiftUI", watchOS 11.0)
extension Never {
    public typealias Body = Never
    public var body: Never {
        switch self {}
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension Never: TransferRepresentation {
    public typealias Item = Never
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension Never: Transferable {
    public typealias Representation = Never
    public static var transferRepresentation: Never { fatalError("Never has no transfer representation") }
}

// MARK: - Entries

/// One content type a representation offers, and how to move an item through it.
struct TransferEntry<Item>: @unchecked Sendable {
    var contentType: UTType
    var exportsData: ((Item) async throws -> Data)?
    var importsData: ((Data) async throws -> Item)?
    var exportsFile: ((Item) async throws -> SentTransferredFile)?
    var importsFile: ((ReceivedTransferredFile) async throws -> Item)?
    var visibility = TransferRepresentationVisibility.all
    var suggestedFileName: ((Item) -> String?)?
    var condition: ((Item) -> Bool)?

    var canExport: Bool { exportsData != nil || exportsFile != nil }
    var canImport: Bool { importsData != nil || importsFile != nil }

    /// The item as data in this entry's type (a file export is read back).
    func data(of item: Item) async throws -> Data {
        if let exportsData { return try await exportsData(item) }
        if let exportsFile { return try Data(contentsOf: try await exportsFile(item).file) }
        throw TransferError.notExportable(contentType)
    }

    /// An item from data in this entry's type (a file import gets a temporary copy).
    func item(from data: Data) async throws -> Item {
        if let importsData { return try await importsData(data) }
        if let importsFile {
            let url = temporaryFile(type: contentType)
            try data.write(to: url)
            return try await importsFile(ReceivedTransferredFile(file: url, isOriginalFile: false))
        }
        throw TransferError.notImportable(contentType)
    }
}

enum TransferError: Error, CustomStringConvertible {
    case notExportable(UTType?)
    case notImportable(UTType?)

    var description: String {
        switch self {
        case .notExportable(let t): "no representation exports \(t?.identifier ?? "any type")"
        case .notImportable(let t): "no representation imports \(t?.identifier ?? "any type")"
        }
    }
}

func temporaryFile(type: UTType, name: String? = nil) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoreTransferable-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var file = dir.appendingPathComponent(name ?? "Item")
    if file.pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
        file.appendPathExtension(ext)
    }
    return file
}

/// Representations that list their entries directly.
protocol PrimitiveTransferRepresentation: TransferRepresentation {
    var entries: [TransferEntry<Item>] { get }
}

extension PrimitiveTransferRepresentation {
    var erasedEntries: Any { entries }
}

/// A representation's entries, type-erased (for representations known only as existentials).
func erasedEntries<R: TransferRepresentation>(of representation: R) -> Any { entries(of: representation) }

/// A representation's entries: its own, or its body's.
func entries<R: TransferRepresentation>(of representation: R) -> [TransferEntry<R.Item>] {
    if let primitive = representation as? any PrimitiveTransferRepresentation {
        return primitive.erasedEntries as! [TransferEntry<R.Item>]
    }
    if R.Body.self == Never.self { return [] }
    return entries(of: representation.body) as! [TransferEntry<R.Item>]
}

func entries<T: Transferable>(of type: T.Type) -> [TransferEntry<T>] {
    if T.self == Never.self { return [] }
    return entries(of: T.transferRepresentation) as! [TransferEntry<T>]
}

// MARK: - The builder

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
@resultBuilder
public struct TransferRepresentationBuilder<Item> where Item: Transferable {
    public static func buildExpression<Encoder, Decoder>(_ content: CodableRepresentation<Item, Encoder, Decoder>)
        -> CodableRepresentation<Item, Encoder, Decoder>
        where Item: Decodable, Item: Encodable, Encoder: TopLevelEncoder, Decoder: TopLevelDecoder,
              Encoder.Output == Data, Decoder.Input == Data {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildExpression<R>(_ content: R) -> R where Item == R.Item, R: TransferRepresentation {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<Content>(_ content: Content) -> Content where Item == Content.Item, Content: TransferRepresentation {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2>(_ c1: C1, _ c2: C2) -> TupleTransferRepresentation<Item, (C1, C2)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C1.Item == C2.Item {
        TupleTransferRepresentation<Item, (C1, C2)>((c1, c2))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2, C3>(_ c1: C1, _ c2: C2, _ c3: C3) -> TupleTransferRepresentation<Item, (C1, C2, C3)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C3: TransferRepresentation,
              C1.Item == C2.Item, C2.Item == C3.Item {
        TupleTransferRepresentation<Item, (C1, C2, C3)>((c1, c2, c3))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2, C3, C4>(_ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4)
        -> TupleTransferRepresentation<Item, (C1, C2, C3, C4)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C3: TransferRepresentation,
              C4: TransferRepresentation, C1.Item == C2.Item, C2.Item == C3.Item, C3.Item == C4.Item {
        TupleTransferRepresentation<Item, (C1, C2, C3, C4)>((c1, c2, c3, c4))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2, C3, C4, C5>(_ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5)
        -> TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C3: TransferRepresentation,
              C4: TransferRepresentation, C5: TransferRepresentation,
              C1.Item == C2.Item, C2.Item == C3.Item, C3.Item == C4.Item, C4.Item == C5.Item {
        TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5)>((c1, c2, c3, c4, c5))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2, C3, C4, C5, C6>(_ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6)
        -> TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C3: TransferRepresentation,
              C4: TransferRepresentation, C5: TransferRepresentation, C6: TransferRepresentation,
              C1.Item == C2.Item, C2.Item == C3.Item, C3.Item == C4.Item, C4.Item == C5.Item, C5.Item == C6.Item {
        TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6)>((c1, c2, c3, c4, c5, c6))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2, C3, C4, C5, C6, C7>(_ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7)
        -> TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6, C7)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C3: TransferRepresentation,
              C4: TransferRepresentation, C5: TransferRepresentation, C6: TransferRepresentation, C7: TransferRepresentation,
              C1.Item == C2.Item, C2.Item == C3.Item, C3.Item == C4.Item, C4.Item == C5.Item, C5.Item == C6.Item,
              C6.Item == C7.Item {
        TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6, C7)>((c1, c2, c3, c4, c5, c6, c7))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2, C3, C4, C5, C6, C7, C8>(_ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6,
                                                                 _ c7: C7, _ c8: C8)
        -> TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6, C7, C8)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C3: TransferRepresentation,
              C4: TransferRepresentation, C5: TransferRepresentation, C6: TransferRepresentation, C7: TransferRepresentation,
              C8: TransferRepresentation, C1.Item == C2.Item, C2.Item == C3.Item, C3.Item == C4.Item, C4.Item == C5.Item,
              C5.Item == C6.Item, C6.Item == C7.Item, C7.Item == C8.Item {
        TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6, C7, C8)>((c1, c2, c3, c4, c5, c6, c7, c8))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2, C3, C4, C5, C6, C7, C8, C9>(_ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5,
                                                                     _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9)
        -> TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6, C7, C8, C9)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C3: TransferRepresentation,
              C4: TransferRepresentation, C5: TransferRepresentation, C6: TransferRepresentation, C7: TransferRepresentation,
              C8: TransferRepresentation, C9: TransferRepresentation, C1.Item == C2.Item, C2.Item == C3.Item,
              C3.Item == C4.Item, C4.Item == C5.Item, C5.Item == C6.Item, C6.Item == C7.Item, C7.Item == C8.Item,
              C8.Item == C9.Item {
        TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6, C7, C8, C9)>((c1, c2, c3, c4, c5, c6, c7, c8, c9))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C1, C2, C3, C4, C5, C6, C7, C8, C9, C10>(_ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5,
                                                                          _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9, _ c10: C10)
        -> TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6, C7, C8, C9, C10)>
        where Item == C1.Item, C1: TransferRepresentation, C2: TransferRepresentation, C3: TransferRepresentation,
              C4: TransferRepresentation, C5: TransferRepresentation, C6: TransferRepresentation, C7: TransferRepresentation,
              C8: TransferRepresentation, C9: TransferRepresentation, C10: TransferRepresentation, C1.Item == C2.Item,
              C2.Item == C3.Item, C3.Item == C4.Item, C4.Item == C5.Item, C5.Item == C6.Item, C6.Item == C7.Item,
              C7.Item == C8.Item, C8.Item == C9.Item, C9.Item == C10.Item {
        TupleTransferRepresentation<Item, (C1, C2, C3, C4, C5, C6, C7, C8, C9, C10)>((c1, c2, c3, c4, c5, c6, c7, c8, c9, c10))
    }
}

// MARK: - Representations

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct TupleTransferRepresentation<Item, Value>: TransferRepresentation where Item: Transferable, Value: Sendable {
    @usableFromInline internal var value: Value

    @usableFromInline
    internal init(_ value: Value) { self.value = value }

    public var body: some TransferRepresentation { _EntryList<Item>(entries: tupleEntries()) }

    /// Each element of the tuple's entries, in order.
    func tupleEntries() -> [TransferEntry<Item>] {
        Mirror(reflecting: value).children.flatMap { child -> [TransferEntry<Item>] in
            guard let representation = child.value as? any TransferRepresentation else { return [] }
            return (erasedEntries(of: representation) as? [TransferEntry<Item>]) ?? []
        }
    }
}

/// Entries already worked out (what composite representations' bodies are).
struct _EntryList<Item: Transferable>: PrimitiveTransferRepresentation, @unchecked Sendable {
    typealias Body = Never
    var entries: [TransferEntry<Item>]
    var body: Never { return fatalError() }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct DataRepresentation<Item>: TransferRepresentation, PrimitiveTransferRepresentation where Item: Transferable {
    public typealias Body = Never
    let entry: TransferEntry<Item>

    public init(contentType: UTType, exporting: @escaping @Sendable (Item) async throws -> Data,
                importing: @escaping @Sendable (Data) async throws -> Item) {
        entry = TransferEntry(contentType: contentType, exportsData: exporting, importsData: importing)
    }

    public init(exportedContentType: UTType, exporting: @escaping @Sendable (Item) async throws -> Data) {
        entry = TransferEntry(contentType: exportedContentType, exportsData: exporting)
    }

    public init(importedContentType: UTType, importing: @escaping @Sendable (Data) async throws -> Item) {
        entry = TransferEntry(contentType: importedContentType, importsData: importing)
    }

    public var body: Never { return fatalError() }
    var entries: [TransferEntry<Item>] { [entry] }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct SentTransferredFile: Sendable {
    public let file: URL
    public let allowAccessingOriginalFile: Bool

    public init(_ file: URL, allowAccessingOriginalFile: Bool = false) {
        self.file = file
        self.allowAccessingOriginalFile = allowAccessingOriginalFile
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct ReceivedTransferredFile: Sendable {
    public let file: URL
    public let isOriginalFile: Bool
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct FileRepresentation<Item>: TransferRepresentation, PrimitiveTransferRepresentation where Item: Transferable {
    public typealias Body = Never
    let entry: TransferEntry<Item>

    public init(contentType: UTType, shouldAttemptToOpenInPlace: Bool = false,
                exporting: @escaping @Sendable (Item) async throws -> SentTransferredFile,
                importing: @escaping @Sendable (ReceivedTransferredFile) async throws -> Item) {
        entry = TransferEntry(contentType: contentType, exportsFile: exporting, importsFile: importing)
    }

    public init(exportedContentType: UTType, shouldAllowToOpenInPlace: Bool = false,
                exporting: @escaping @Sendable (Item) async throws -> SentTransferredFile) {
        entry = TransferEntry(contentType: exportedContentType, exportsFile: exporting)
    }

    public init(importedContentType: UTType, shouldAttemptToOpenInPlace: Bool = false,
                importing: @escaping @Sendable (ReceivedTransferredFile) async throws -> Item) {
        entry = TransferEntry(contentType: importedContentType, importsFile: importing)
    }

    public var body: Never { return fatalError() }
    var entries: [TransferEntry<Item>] { [entry] }
}

/// An item sent and received as another transferable type: the proxy's entries, converted.
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct ProxyRepresentation<Item, ProxyRepresentation>: TransferRepresentation, PrimitiveTransferRepresentation
    where Item: Transferable, ProxyRepresentation: Transferable {
    public typealias Body = Never
    let exporting: (@Sendable (Item) async throws -> ProxyRepresentation)?
    let importing: (@Sendable (ProxyRepresentation) async throws -> Item)?

    public init(importing: @escaping @Sendable (ProxyRepresentation) throws -> Item) {
        exporting = nil
        self.importing = { try importing($0) }
    }

    @available(iOS 16.1, macOS 13.0, tvOS 16.1, watchOS 9.1, *)
    public init(importing: @escaping @Sendable (ProxyRepresentation) async throws -> Item) {
        exporting = nil
        self.importing = importing
    }

    public init(exporting: @escaping @Sendable (Item) throws -> ProxyRepresentation) {
        self.exporting = { try exporting($0) }
        importing = nil
    }

    public init(exporting: @escaping @Sendable (Item) async throws -> ProxyRepresentation) {
        self.exporting = exporting
        importing = nil
    }

    public init(exporting: @escaping @Sendable (Item) throws -> ProxyRepresentation,
                importing: @escaping @Sendable (ProxyRepresentation) throws -> Item) {
        self.exporting = { try exporting($0) }
        self.importing = { try importing($0) }
    }

    public init(exporting: @escaping @Sendable (Item) async throws -> ProxyRepresentation,
                importing: @escaping @Sendable (ProxyRepresentation) async throws -> Item) {
        self.exporting = exporting
        self.importing = importing
    }

    @available(iOS 17.2, macOS 14.2, tvOS 17.2, watchOS 10.2, *)
    public init(exporting: @escaping @Sendable (Item) throws -> ProxyRepresentation,
                importing: @escaping @Sendable (ProxyRepresentation) async throws -> Item) {
        self.exporting = { try exporting($0) }
        self.importing = importing
    }

    public var body: Never { return fatalError() }

    var entries: [TransferEntry<Item>] {
        CoreTransferable.entries(of: ProxyRepresentation.self).map { proxy in
            var e = TransferEntry<Item>(contentType: proxy.contentType)
            e.visibility = proxy.visibility
            if let exporting, proxy.canExport {
                e.exportsData = { item in try await proxy.data(of: try await exporting(item)) }
            }
            if let importing, proxy.canImport {
                e.importsData = { data in try await importing(try await proxy.item(from: data)) }
            }
            return e
        }
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
@preconcurrency
public struct CodableRepresentation<Item, Encoder, Decoder>: TransferRepresentation, PrimitiveTransferRepresentation, Sendable
    where Item: Transferable, Item: Decodable, Item: Encodable, Encoder: TopLevelEncoder, Encoder: Sendable,
          Decoder: TopLevelDecoder, Decoder: Sendable, Encoder.Output == Data, Decoder.Input == Data {
    public typealias Body = Never
    let contentType: UTType
    let encoder: Encoder
    let decoder: Decoder

    public init(for itemType: Item.Type = Item.self, contentType: UTType) where Encoder == JSONEncoder, Decoder == JSONDecoder {
        self.contentType = contentType
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public init(for itemType: Item.Type = Item.self, contentType: UTType, encoder: Encoder, decoder: Decoder) {
        self.contentType = contentType
        self.encoder = encoder
        self.decoder = decoder
    }

    public var body: Never { return fatalError() }

    var entries: [TransferEntry<Item>] {
        let encoder = self.encoder, decoder = self.decoder
        return [TransferEntry(contentType: contentType, exportsData: { try encoder.encode($0) },
                              importsData: { try decoder.decode(Item.self, from: $0) })]
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct TransferRepresentationVisibility: Sendable, Equatable {
    let level: Int
    public static let all = TransferRepresentationVisibility(level: 0)
    @available(macOS, unavailable)
    public static let team = TransferRepresentationVisibility(level: 1)
    @available(iOS, unavailable)
    @available(tvOS, unavailable)
    @available(watchOS, unavailable)
    public static let group = TransferRepresentationVisibility(level: 2)
    public static let ownProcess = TransferRepresentationVisibility(level: 3)
}

/// A representation whose entries are its base's, changed.
struct _ModifiedRepresentation<Base: TransferRepresentation>: PrimitiveTransferRepresentation, @unchecked Sendable {
    typealias Item = Base.Item
    typealias Body = Never
    let base: Base
    let modify: (inout TransferEntry<Base.Item>) -> Void

    var body: Never { return fatalError() }
    var entries: [TransferEntry<Item>] {
        CoreTransferable.entries(of: base).map { e in
            var e = e
            modify(&e)
            return e
        }
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct _ConditionalTransferRepresentation<Base>: TransferRepresentation, PrimitiveTransferRepresentation
    where Base: TransferRepresentation {
    public typealias Item = Base.Item
    public typealias Body = Never
    let base: Base
    let condition: @Sendable (Base.Item) -> Bool

    public var body: Never { return fatalError() }
    var entries: [TransferEntry<Item>] {
        let condition = self.condition
        return CoreTransferable.entries(of: base).map { e in
            var e = e
            let previous = e.condition
            e.condition = { item in (previous?(item) ?? true) && condition(item) }
            return e
        }
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension TransferRepresentation {
    public func visibility(_ visibility: TransferRepresentationVisibility) -> some TransferRepresentation<Item> {
        _ModifiedRepresentation(base: self) { $0.visibility = visibility }
    }

    public func exportingCondition(_ condition: @escaping @Sendable (Item) -> Bool) -> _ConditionalTransferRepresentation<Self> {
        _ConditionalTransferRepresentation(base: self, condition: condition)
    }

    public func suggestedFileName(_ fileName: String) -> some TransferRepresentation<Item> {
        _ModifiedRepresentation(base: self) { $0.suggestedFileName = { _ in fileName } }
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    public func suggestedFileName(_ fileName: @escaping @Sendable (Item) -> String?) -> some TransferRepresentation<Item> {
        _ModifiedRepresentation(base: self) { $0.suggestedFileName = fileName }
    }
}

// MARK: - Moving items

@available(iOS 18.2, macOS 15.2, tvOS 18.2, watchOS 11.2, visionOS 2.2, *)
extension Transferable {
    public static func exportedContentTypes(visibility: TransferRepresentationVisibility = .all) -> [UTType] {
        unique(entries(of: Self.self).filter { $0.canExport && $0.visibility.level <= visibility.level }.map(\.contentType))
    }

    public static func importedContentTypes() -> [UTType] {
        unique(entries(of: Self.self).filter(\.canImport).map(\.contentType))
    }

    public func exportedContentTypes(_ visibility: TransferRepresentationVisibility = .all) -> [UTType] {
        unique(exportEntries().filter { $0.visibility.level <= visibility.level }.map(\.contentType))
    }

    public func importedContentTypes() -> [UTType] { Self.importedContentTypes() }

    public init(importing file: URL, contentType: UTType?) async throws {
        let candidates = entries(of: Self.self).filter { $0.canImport && matches($0.contentType, contentType) }
        for e in candidates {
            if let importsFile = e.importsFile {
                self = try await importsFile(ReceivedTransferredFile(file: file, isOriginalFile: true))
                return
            }
            if let importsData = e.importsData {
                self = try await importsData(try Data(contentsOf: file))
                return
            }
        }
        throw TransferError.notImportable(contentType)
    }

    public init(importing data: Data, contentType: UTType?) async throws {
        guard let e = entries(of: Self.self).first(where: { $0.canImport && matches($0.contentType, contentType) }) else {
            throw TransferError.notImportable(contentType)
        }
        self = try await e.item(from: data)
    }

    public func export(to destinationDirectory: URL, contentType: UTType?) async throws -> URL {
        guard let e = exportEntries().first(where: { matches($0.contentType, contentType) }) else {
            throw TransferError.notExportable(contentType)
        }
        let name = e.suggestedFileName?(self) ?? "Item"
        var dest = destinationDirectory.appendingPathComponent(name)
        if dest.pathExtension.isEmpty, let ext = e.contentType.preferredFilenameExtension {
            dest.appendPathExtension(ext)
        }
        if let exportsFile = e.exportsFile {
            let sent = try await exportsFile(self)
            try FileManager.default.copyItem(at: sent.file, to: dest)
        } else {
            try await e.data(of: self).write(to: dest)
        }
        return dest
    }

    public func withExportedFile<Result>(contentType: UTType?, fileHandler: (URL) async throws -> Result) async throws -> Result {
        let dir = temporaryFile(type: .data).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await fileHandler(try await export(to: dir, contentType: contentType))
    }

    public var suggestedFilename: String? {
        exportEntries().lazy.compactMap { $0.suggestedFileName?(self) }.first
    }

    public func exported(as contentType: UTType?) async throws -> Data {
        guard let e = exportEntries().first(where: { matches($0.contentType, contentType) }) else {
            throw TransferError.notExportable(contentType)
        }
        return try await e.data(of: self)
    }

    /// The entries this item can be exported through (their conditions hold for it).
    func exportEntries() -> [TransferEntry<Self>] {
        entries(of: Self.self).filter { $0.canExport && ($0.condition?(self) ?? true) }
    }
}

/// A content type matches the one asked for, or any when none is.
func matches(_ type: UTType, _ wanted: UTType?) -> Bool {
    guard let wanted else { return true }
    return type.conforms(to: wanted) || wanted.conforms(to: type)
}

func unique(_ types: [UTType]) -> [UTType] {
    var seen = Set<UTType>()
    return types.filter { seen.insert($0).inserted }
}

// MARK: - Foundation's types

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension Data: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .data, exporting: { $0 }, importing: { $0 })
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension String: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .utf8PlainText, exporting: { Data($0.utf8) }, importing: { data in
            guard let s = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return s
        })
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension URL: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .url, exporting: { url in
            Data((url.isFileURL ? url.absoluteString : url.absoluteString).utf8)
        }, importing: { data in
            guard let s = String(data: data, encoding: .utf8), let url = URL(string: s) else { throw CocoaError(.fileReadCorruptFile) }
            return url
        })
    }
}

@available(iOS 16.1, macOS 13.0, tvOS 16.1, watchOS 9.1, *)
extension AttributedString: Transferable {
    /// Its text, as plain text (rich text formats need the text system, above Foundation).
    @available(iOS 16.1, macOS 13.0, tvOS 16.1, watchOS 9.1, *)
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .utf8PlainText, exporting: { Data(String($0.characters).utf8) }, importing: { data in
            guard let s = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return AttributedString(s)
        })
    }
}

// MARK: - NSItemProvider

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension NSItemProvider {
    /// Registers each type the item exports, in order, made when a type is loaded.
    public func register<T>(_ transferable: @autoclosure @escaping @Sendable () -> T) where T: Transferable {
        for e in entries(of: T.self) where e.canExport {
            registerDataRepresentation(forTypeIdentifier: e.contentType.identifier, visibility: .all) { completion in
                let item = transferable()
                Task {
                    do { completion(try await e.data(of: item), nil) } catch { completion(nil, error) }
                }
                return nil
            }
        }
    }

    /// Loads the first type the provider has that T imports.
    public func loadTransferable<T>(type transferableType: T.Type,
                                    completionHandler: @escaping @Sendable (Result<T, any Error>) -> Void) -> Progress
        where T: Transferable {
        let available = registeredTypeIdentifiers
        guard let e = entries(of: T.self).first(where: { e in e.canImport && available.contains { UTType($0).map { matches($0, e.contentType) } ?? false } }),
              let identifier = available.first(where: { UTType($0).map { matches($0, e.contentType) } ?? false }) else {
            completionHandler(.failure(TransferError.notImportable(nil)))
            return Progress(totalUnitCount: 0)
        }
        return loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
            guard let data else {
                completionHandler(.failure(error ?? TransferError.notImportable(e.contentType)))
                return
            }
            Task {
                do { completionHandler(.success(try await e.item(from: data))) } catch { completionHandler(.failure(error)) }
            }
        }
    }
}
