// SPDX-License-Identifier: MIT OR Apache-2.0
//
// DeveloperToolsSupport: what Xcode's generated code and previews link against, to Apple's
// interface. Asset catalogue resources (ImageResource, ColorResource) name an asset in a
// bundle. Design-time values are the fallbacks the code was written with: Finch has no
// preview canvas, so previews, library items and preview traits are kept but unused.

import CoreGraphics
import Foundation

// MARK: - Design-time values

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public func __designTimeBoolean<T>(_ key: String, fallback: T) -> T where T: ExpressibleByBooleanLiteral { fallback }

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public func __designTimeFloat<T>(_ key: String, fallback: T) -> T where T: ExpressibleByFloatLiteral { fallback }

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public func __designTimeInteger<T>(_ key: String, fallback: T) -> T where T: ExpressibleByIntegerLiteral { fallback }

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public func __designTimeString<T>(_ key: String, fallback: T) -> T where T: ExpressibleByStringLiteral { fallback }

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public func __designTimeString<T>(_ key: String, fallback: T) -> T where T: ExpressibleByExtendedGraphemeClusterLiteral { fallback }

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public func __designTimeApplyIncrementalValues(_ updates: [[String: any Sendable]]) {}

// MARK: - Library items

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
public struct LibraryItem {
    @available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
    public struct Category {
        let name: String
        public static let effect = Category(name: "effect")
        public static let layout = Category(name: "layout")
        public static let control = Category(name: "control")
        public static let other = Category(name: "other")
    }

    let title: String?
    let visible: Bool
    let category: Category
    let matchingSignature: String?

    public init<SnippetExpressionType>(_ snippet: @autoclosure () -> SnippetExpressionType, visible: Bool = true,
                                       title: String? = nil, category: Category = .other, matchingSignature: String? = nil) {
        self.title = title
        self.visible = visible
        self.category = category
        self.matchingSignature = matchingSignature
    }
}

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
@resultBuilder
public struct LibraryContentBuilder {
    public static func buildBlock(_ segments: [LibraryItem]...) -> [LibraryItem] { segments.flatMap { $0 } }
    public static func buildExpression(_ item: LibraryItem) -> [LibraryItem] { [item] }
    public static func buildExpression(_ items: [LibraryItem]) -> [LibraryItem] { items }
}

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
public protocol LibraryContentProvider {
    associatedtype ModifierBase = Any
    @LibraryContentBuilder var views: [LibraryItem] { get }
    @LibraryContentBuilder func modifiers(base: ModifierBase) -> [LibraryItem]
}

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
extension LibraryContentProvider {
    public var views: [LibraryItem] { [] }
    public func modifiers(base: ModifierBase) -> [LibraryItem] { [] }
}

// MARK: - Previews

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public struct Preview {
    /// What the frameworks that make previews (SwiftUI, AppKit) put in: a name and the
    /// value that builds the preview's content.
    @_spi(Finch) public nonisolated let name: String?
    @_spi(Finch) public nonisolated let content: (any Sendable)?

    @_spi(Finch) public nonisolated init(name: String?, content: (any Sendable)?) {
        self.name = name
        self.content = content
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Preview: @unchecked Sendable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Preview {
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    public enum ViewTraits {}
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
@resultBuilder
public struct PreviewBodyBuilder<Content> {
    public static func buildBlock(_ content: Content) -> Content { content }
    @available(*, unavailable, message: "This builder requires exactly one content expression")
    public static func buildBlock(_: Content...) -> Content { fatalError() }
    @available(*, unavailable, message: "This builder does not support control flow statements")
    public static func buildOptional(_: Content?) -> Content { fatalError() }
    @available(*, unavailable, message: "This builder does not support control flow statements")
    public static func buildEither(first: Content) -> Content { fatalError() }
    @available(*, unavailable, message: "This builder does not support control flow statements")
    public static func buildEither(second: Content) -> Content { fatalError() }
    @available(*, unavailable, message: "This builder does not support control flow statements")
    public static func buildLimitedAvailability(_: Content) -> Content { fatalError() }
}

@available(*, unavailable)
extension PreviewBodyBuilder: Sendable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@resultBuilder
public struct PreviewMacroBodyBuilder<Content> {
    public static func buildBlock(_ content: Content) -> Content { content }
    @available(*, unavailable, message: "This builder requires exactly one content expression")
    public static func buildBlock(_: Content...) -> Content { fatalError() }
    @available(*, unavailable, message: "This builder does not support control flow statements")
    public static func buildOptional(_: Content?) -> Content { fatalError() }
    @available(*, unavailable, message: "This builder does not support control flow statements")
    public static func buildEither(first: Content) -> Content { fatalError() }
    @available(*, unavailable, message: "This builder does not support control flow statements")
    public static func buildEither(second: Content) -> Content { fatalError() }
    @available(*, unavailable, message: "This builder does not support control flow statements")
    public static func buildLimitedAvailability(_: Content) -> Content { fatalError() }
}

@available(*, unavailable)
extension PreviewMacroBodyBuilder: Sendable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public protocol PreviewRegistry {
    static var fileID: String { get }
    static var line: Int { get }
    static var column: Int { get }
    @MainActor static func makePreview() throws -> Preview
    @available(*, deprecated, message: "This method is not called. Please implement makePreview() instead.")
    static var preview: Preview { get }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension PreviewRegistry {
    public static var preview: Preview { Preview(name: nil, content: nil) }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct PreviewUnavailable: Error {
    public init() {}
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public struct PreviewTrait<T> {
    @_spi(Finch) public var names: [String]

    nonisolated init(names: [String]) { self.names = names }

    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public init(_ traits: PreviewTrait<T>...) {
        names = traits.flatMap(\.names)
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension PreviewTrait: @unchecked Sendable {}

extension PreviewTrait where T == Preview.ViewTraits {
    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    @MainActor public static var assistiveAccess: PreviewTrait<Preview.ViewTraits> { PreviewTrait(names: ["assistiveAccess"]) }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension PreviewTrait where T == Preview.ViewTraits {
    @MainActor public static var defaultLayout: PreviewTrait<Preview.ViewTraits> { PreviewTrait(names: ["defaultLayout"]) }
    @MainActor public static var sizeThatFitsLayout: PreviewTrait<Preview.ViewTraits> { PreviewTrait(names: ["sizeThatFitsLayout"]) }
    @MainActor public static func fixedLayout(width: CGFloat, height: CGFloat) -> PreviewTrait<T> {
        PreviewTrait(names: ["fixedLayout(\(width), \(height))"])
    }
    @MainActor public static var portrait: PreviewTrait<Preview.ViewTraits> { PreviewTrait(names: ["portrait"]) }
    @MainActor public static var landscapeLeft: PreviewTrait<Preview.ViewTraits> { PreviewTrait(names: ["landscapeLeft"]) }
    @MainActor public static var landscapeRight: PreviewTrait<Preview.ViewTraits> { PreviewTrait(names: ["landscapeRight"]) }
    @MainActor public static var portraitUpsideDown: PreviewTrait<Preview.ViewTraits> { PreviewTrait(names: ["portraitUpsideDown"]) }
}

@available(iOS 13.0, macCatalyst 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
@_originallyDefinedIn(module: "SwiftUI", iOS 17.0)
@_originallyDefinedIn(module: "SwiftUI", macCatalyst 17.0)
@_originallyDefinedIn(module: "SwiftUI", macOS 14.0)
@_originallyDefinedIn(module: "SwiftUI", tvOS 17.0)
@_originallyDefinedIn(module: "SwiftUI", watchOS 10.0)
public enum PreviewLayout: Sendable {
    case device
    case sizeThatFits
    case fixed(width: CGFloat, height: CGFloat)
}

// MARK: - Asset catalogue resources

/// An asset by name in a bundle (SPI that the UI frameworks read resources through).
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@_spi(Private)
public struct NamedResource: Hashable, @unchecked Sendable {
    public let name: String
    public let bundle: Bundle

    init(name: String, bundle: Bundle) {
        self.name = name
        self.bundle = bundle
    }
}

/// Where a resource's asset is.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@_spi(Private)
public enum ResourceReference: Hashable, Sendable {
    case named(NamedResource)
}

/// A named colour in an asset catalogue, as Xcode's generated asset symbols make them.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct ColorResource: Hashable, Sendable {
    @_spi(Private) public var reference: ResourceReference

    public init(name: String, bundle: Bundle) {
        reference = .named(NamedResource(name: name, bundle: bundle))
    }
}

/// A named image in an asset catalogue, as Xcode's generated asset symbols make them.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct ImageResource: Hashable, Sendable {
    @_spi(Private) public var reference: ResourceReference

    public init(name: String, bundle: Bundle) {
        reference = .named(NamedResource(name: name, bundle: bundle))
    }
}
