// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Toolbars and navigation titles, to Apple's interface, shown as Apple's are on macOS: a
// view's toolbar content becomes items of its window's NSToolbar (navigation items at the
// leading end, principal and status items in the middle, the rest at the trailing end), each
// hosting its SwiftUI content; a navigation title is the window's title. The content is read
// as toolbar items through its containers (tuples, groups, conditions, custom content's
// bodies), as a menu's is; every `toolbar` in a window adds its items to the one toolbar.

import AppKit
import SwiftUICore

// MARK: - ToolbarContent

@available(OpenSwiftUI_v2_0, *)
@MainActor
@preconcurrency
public protocol ToolbarContent {
    associatedtype Body: ToolbarContent

    @ToolbarContentBuilder
    @MainActor
    @preconcurrency
    var body: Body { get }

    nonisolated static func _makeToolbar(content: _GraphValue<Self>, inputs: _ToolbarInputs) -> _ToolbarOutputs

    nonisolated static func _makeContent(content: _GraphValue<Self>, inputs: _GraphInputs, resolved: inout _ToolbarItemList)
}

@available(OpenSwiftUI_v2_0, *)
public protocol CustomizableToolbarContent: ToolbarContent where Body: CustomizableToolbarContent {}

// Toolbars are read from the content itself (not built in the graph): these do nothing.
@available(OpenSwiftUI_v2_0, *)
extension ToolbarContent {
    nonisolated public static func _makeContent(content: _GraphValue<Self>, inputs: _GraphInputs,
                                                resolved: inout _ToolbarItemList) {}

    nonisolated public static func _makeToolbar(content: _GraphValue<Self>, inputs: _ToolbarInputs) -> _ToolbarOutputs {
        _ToolbarOutputs()
    }
}

extension ToolbarContent where Body == Never {
    public var body: Never { fatalError("\(Self.self) has no body") }
}

@available(OpenSwiftUI_v2_0, *)
extension Never: ToolbarContent, CustomizableToolbarContent {}

@available(OpenSwiftUI_v2_0, *)
public struct _ToolbarInputs {}

@available(*, unavailable) extension _ToolbarInputs: Sendable {}

@available(OpenSwiftUI_v2_0, *)
public struct _ToolbarOutputs {}

@available(*, unavailable) extension _ToolbarOutputs: Sendable {}

@available(OpenSwiftUI_v2_0, *)
public struct _ToolbarItemList {}

@available(*, unavailable) extension _ToolbarItemList: Sendable {}

// MARK: - Builder

@available(OpenSwiftUI_v2_0, *)
@resultBuilder
public struct ToolbarContentBuilder {
    @_alwaysEmitIntoClient
    public static func buildExpression<Content>(_ content: Content) -> Content where Content: ToolbarContent {
        content
    }

    public static func buildBlock<Content>(_ content: Content) -> some ToolbarContent where Content: ToolbarContent {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildExpression<Content>(_ content: Content) -> Content where Content: CustomizableToolbarContent {
        content
    }

    public static func buildBlock<Content>(_ content: Content) -> some CustomizableToolbarContent
        where Content: CustomizableToolbarContent {
        content
    }
}

@available(*, unavailable) extension ToolbarContentBuilder: Sendable {}

@available(OpenSwiftUI_v2_0, *)
extension ToolbarContentBuilder {
    public static func buildIf<Content>(_ content: Content?) -> Content? where Content: ToolbarContent {
        content
    }

    public static func buildIf<Content>(_ content: Content?) -> Content? where Content: CustomizableToolbarContent {
        content
    }

    public static func buildEither<TrueContent, FalseContent>(first: TrueContent) -> _ConditionalContent<TrueContent, FalseContent>
        where TrueContent: ToolbarContent, FalseContent: ToolbarContent {
        _ConditionalContent(__storage: .trueContent(first))
    }

    public static func buildEither<TrueContent, FalseContent>(first: TrueContent) -> _ConditionalContent<TrueContent, FalseContent>
        where TrueContent: CustomizableToolbarContent, FalseContent: CustomizableToolbarContent {
        _ConditionalContent(__storage: .trueContent(first))
    }

    public static func buildEither<TrueContent, FalseContent>(second: FalseContent) -> _ConditionalContent<TrueContent, FalseContent>
        where TrueContent: ToolbarContent, FalseContent: ToolbarContent {
        _ConditionalContent(__storage: .falseContent(second))
    }

    public static func buildEither<TrueContent, FalseContent>(second: FalseContent) -> _ConditionalContent<TrueContent, FalseContent>
        where TrueContent: CustomizableToolbarContent, FalseContent: CustomizableToolbarContent {
        _ConditionalContent(__storage: .falseContent(second))
    }
}

@usableFromInline
struct TupleToolbarContent<T>: ToolbarContent, CustomizableToolbarContent {
    var value: T

    @usableFromInline
    init(_ value: T) {
        self.value = value
    }

    @usableFromInline
    typealias Body = Never

    @usableFromInline
    nonisolated static func _makeToolbar(content: _GraphValue<TupleToolbarContent<T>>, inputs: _ToolbarInputs) -> _ToolbarOutputs {
        _ToolbarOutputs()
    }

    @usableFromInline
    nonisolated static func _makeContent(content: _GraphValue<TupleToolbarContent<T>>, inputs: _GraphInputs,
                                         resolved: inout _ToolbarItemList) {}
}

@available(*, unavailable) extension TupleToolbarContent: Sendable {}

extension Group: ToolbarContent where Content: ToolbarContent {
    nonisolated public init(@ToolbarContentBuilder content: () -> Content) {
        self = Group._make(content: content())
    }

    nonisolated public static func _makeToolbar(content: _GraphValue<Group<Content>>, inputs: _ToolbarInputs) -> _ToolbarOutputs {
        _ToolbarOutputs()
    }

    nonisolated public static func _makeContent(content: _GraphValue<Group<Content>>, inputs: _GraphInputs,
                                                resolved: inout _ToolbarItemList) {}
}

extension Group: CustomizableToolbarContent where Content: CustomizableToolbarContent {
    public init(@ToolbarContentBuilder content: () -> Content) {
        self = Group._make(content: content())
    }
}

extension _ConditionalContent: ToolbarContent where TrueContent: ToolbarContent, FalseContent: ToolbarContent {
    nonisolated public static func _makeToolbar(content: _GraphValue<_ConditionalContent<TrueContent, FalseContent>>,
                                                inputs: _ToolbarInputs) -> _ToolbarOutputs {
        _ToolbarOutputs()
    }
}

extension _ConditionalContent: CustomizableToolbarContent
    where TrueContent: CustomizableToolbarContent, FalseContent: CustomizableToolbarContent {}

extension Optional: ToolbarContent where Wrapped: ToolbarContent {
    nonisolated public static func _makeToolbar(content: _GraphValue<Optional<Wrapped>>, inputs: _ToolbarInputs) -> _ToolbarOutputs {
        _ToolbarOutputs()
    }
}

extension Optional: CustomizableToolbarContent where Wrapped: CustomizableToolbarContent {}

// MARK: - Placement

@available(OpenSwiftUI_v2_0, *)
public struct ToolbarItemPlacement {
    enum Kind {
        case automatic, principal, navigation, primaryAction, secondaryAction, status
        case confirmationAction, cancellationAction, destructiveAction, keyboard
    }

    var kind: Kind

    public static let automatic = ToolbarItemPlacement(kind: .automatic)
    public static let principal = ToolbarItemPlacement(kind: .principal)
    public static let navigation = ToolbarItemPlacement(kind: .navigation)
    public static let primaryAction = ToolbarItemPlacement(kind: .primaryAction)
    public static let secondaryAction = ToolbarItemPlacement(kind: .secondaryAction)
    public static let status = ToolbarItemPlacement(kind: .status)
    public static let confirmationAction = ToolbarItemPlacement(kind: .confirmationAction)
    public static let cancellationAction = ToolbarItemPlacement(kind: .cancellationAction)
    public static let destructiveAction = ToolbarItemPlacement(kind: .destructiveAction)
    public static let keyboard = ToolbarItemPlacement(kind: .keyboard)

    /// Where in the toolbar: leading, the middle, or trailing.
    var region: Int {
        switch kind {
        case .navigation: 0
        case .principal, .status: 1
        default: 2
        }
    }
}

@available(*, unavailable) extension ToolbarItemPlacement: Sendable {}

// MARK: - Items

@available(OpenSwiftUI_v2_0, *)
public struct ToolbarItem<ID, Content>: ToolbarContent where Content: View {
    var _id: ID
    var placement: ToolbarItemPlacement
    var showsByDefault: Bool
    var content: Content

    public typealias Body = Never

    nonisolated public static func _makeToolbar(content: _GraphValue<ToolbarItem<ID, Content>>, inputs: _ToolbarInputs) -> _ToolbarOutputs {
        _ToolbarOutputs()
    }

    nonisolated public static func _makeContent(content: _GraphValue<ToolbarItem<ID, Content>>, inputs: _GraphInputs,
                                                resolved: inout _ToolbarItemList) {}
}

@available(*, unavailable) extension ToolbarItem: Sendable {}

@available(OpenSwiftUI_v2_0, *)
extension ToolbarItem where ID == () {
    nonisolated public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.init(_id: (), placement: placement, showsByDefault: true, content: content())
    }
}

@available(OpenSwiftUI_v2_0, *)
extension ToolbarItem: CustomizableToolbarContent where ID == String {
    @_alwaysEmitIntoClient
    nonisolated public init(id: String, placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.init(id: id, placement: placement, showsByDefault: true, content: content)
    }

    nonisolated public init(id: String, placement: ToolbarItemPlacement = .automatic, showsByDefault: Bool,
                            @ViewBuilder content: () -> Content) {
        self.init(_id: id, placement: placement, showsByDefault: showsByDefault, content: content())
    }
}

@available(OpenSwiftUI_v2_0, *)
extension ToolbarItem: Identifiable where ID: Hashable {
    public var id: ID { _id }
}

@available(OpenSwiftUI_v2_0, *)
public struct ToolbarItemGroup<Content>: ToolbarContent where Content: View {
    var placement: ToolbarItemPlacement
    var content: Content

    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }

    public typealias Body = Never

    nonisolated public static func _makeToolbar(content: _GraphValue<ToolbarItemGroup<Content>>, inputs: _ToolbarInputs) -> _ToolbarOutputs {
        _ToolbarOutputs()
    }

    nonisolated public static func _makeContent(content: _GraphValue<ToolbarItemGroup<Content>>, inputs: _GraphInputs,
                                                resolved: inout _ToolbarItemList) {}
}

@available(*, unavailable) extension ToolbarItemGroup: Sendable {}

@available(OpenSwiftUI_v4_0, *)
extension ToolbarItemGroup {
    nonisolated public init<C, L>(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> C,
                                  @ViewBuilder label: () -> L) where Content == LabeledToolbarItemGroupContent<C, L>, C: View, L: View {
        self.placement = placement
        self.content = LabeledToolbarItemGroupContent(content: content(), label: label())
    }
}

/// A labeled group's content: on macOS, its items (the label names it when collapsed).
@available(OpenSwiftUI_v4_0, *)
public struct LabeledToolbarItemGroupContent<Content, Label>: View where Content: View, Label: View {
    var content: Content
    var label: Label

    @MainActor
    @preconcurrency
    public var body: some View { content }
}

@available(*, unavailable) extension LabeledToolbarItemGroupContent: Sendable {}

// MARK: - Reading the content

/// An item for the window's toolbar.
struct _FinchToolbarItem {
    var placement: ToolbarItemPlacement
    var content: AnyView
}

/// Toolbar content that is items (not content with a body).
@MainActor
protocol _FinchToolbarItems {
    var _finchToolbarItems: [_FinchToolbarItem] { get }
}

/// The items `content` describes.
@MainActor
func _finchToolbarItemsOf(_ content: Any) -> [_FinchToolbarItem] {
    if let items = content as? _FinchToolbarItems {
        return items._finchToolbarItems
    }
    if let content = content as? any ToolbarContent {
        return _finchToolbarBody(content)
    }
    return []
}

@MainActor
private func _finchToolbarBody<Content: ToolbarContent>(_ content: Content) -> [_FinchToolbarItem] {
    guard Content.Body.self != Never.self else { return [] }
    return _finchToolbarItemsOf(content.body)
}

extension ToolbarItem: _FinchToolbarItems {
    var _finchToolbarItems: [_FinchToolbarItem] {
        [_FinchToolbarItem(placement: placement, content: AnyView(content))]
    }
}

extension ToolbarItemGroup: _FinchToolbarItems {
    /// A group's views, each an item.
    var _finchToolbarItems: [_FinchToolbarItem] {
        _finchItemViews(content).compactMap { view in
            (view as? any View).map { _FinchToolbarItem(placement: placement, content: AnyView($0)) }
        }
    }
}

/// The views of a group's content, through its containers (an absent optional view is none).
private func _finchItemViews(_ content: Any) -> [Any] {
    guard let sequence = content as? _FinchViewSequence else { return [content] }
    return sequence._finchViews.flatMap(_finchItemViews)
}

extension TupleToolbarContent: _FinchToolbarItems {
    var _finchToolbarItems: [_FinchToolbarItem] {
        Mirror(reflecting: value).children.flatMap { _finchToolbarItemsOf($0.value) }
    }
}

extension Group: _FinchToolbarItems where Content: ToolbarContent {
    var _finchToolbarItems: [_FinchToolbarItem] { _finchToolbarItemsOf(content) }
}

extension _ConditionalContent: _FinchToolbarItems where TrueContent: ToolbarContent, FalseContent: ToolbarContent {
    var _finchToolbarItems: [_FinchToolbarItem] {
        switch storage {
        case let .trueContent(content): _finchToolbarItemsOf(content)
        case let .falseContent(content): _finchToolbarItemsOf(content)
        }
    }
}

extension Optional: _FinchToolbarItems where Wrapped: ToolbarContent {
    var _finchToolbarItems: [_FinchToolbarItem] { map(_finchToolbarItemsOf) ?? [] }
}

// MARK: - The window's toolbar

/// A window's NSToolbar: the items of every `toolbar` in the window, in their places.
@MainActor
final class _FinchWindowToolbar: NSObject, NSToolbarDelegate {
    private static var key = 0

    static func of(_ window: NSWindow) -> _FinchWindowToolbar {
        if let toolbar = objc_getAssociatedObject(window, &key) as? _FinchWindowToolbar {
            return toolbar
        }
        let toolbar = _FinchWindowToolbar()
        toolbar.window = window
        objc_setAssociatedObject(window, &key, toolbar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return toolbar
    }

    weak var window: NSWindow?
    /// Each `toolbar` modifier's items, in the order they came.
    private var sections: [(owner: ObjectIdentifier, items: [_FinchToolbarItem])] = []
    private var controllers: [NSToolbarItem.Identifier: NSHostingController<AnyView>] = [:]
    private var identifiers: [NSToolbarItem.Identifier] = []
    private var environment = EnvironmentValues()

    func set(_ items: [_FinchToolbarItem], for owner: ObjectIdentifier, environment: EnvironmentValues) {
        self.environment = environment
        if let index = sections.firstIndex(where: { $0.owner == owner }) {
            sections[index].items = items
        } else {
            sections.append((owner, items))
        }
        update()
    }

    func remove(_ owner: ObjectIdentifier) {
        sections.removeAll { $0.owner == owner }
        update()
    }

    private func update() {
        guard let window else { return }
        let all = sections.flatMap(\.items)
        var regions: [[(NSToolbarItem.Identifier, _FinchToolbarItem)]] = [[], [], []]
        for (index, item) in all.enumerated() {
            let identifier = NSToolbarItem.Identifier("org.finch.SwiftUI.toolbar.\(index)")
            regions[item.placement.region].append((identifier, item))
        }
        var order = regions[0].map(\.0)
        if !regions[1].isEmpty {
            order += [.flexibleSpace] + regions[1].map(\.0)
        }
        order += [.flexibleSpace] + regions[2].map(\.0)
        let rebuild = order != identifiers || window.toolbar?.delegate !== self
        if rebuild {
            // the old toolbar goes first, taking its item views with it; the new one gets new ones
            if window.toolbar?.delegate === self { window.toolbar = nil }
            controllers = [:]
        }
        for (identifier, item) in regions.joined() {
            // toolbar buttons are drawn bare, as Apple's are until the pointer is over them
            let content = AnyView(item.content.buttonStyle(.borderless)._finchInheriting(environment))
            if let controller = controllers[identifier] {
                controller.rootView = content
            } else {
                controllers[identifier] = NSHostingController(rootView: content)
            }
            if let controller = controllers[identifier] {
                let size = controller.host.sizeThatFits(_ProposedSize(width: nil, height: nil))
                controller.view.frame.size = NSSize(width: ceil(size.width), height: min(ceil(size.height), 28))
            }
        }
        let used = Set(regions.joined().map(\.0))
        controllers = controllers.filter { used.contains($0.key) }
        if all.isEmpty {
            if window.toolbar?.delegate === self { window.toolbar = nil }
            identifiers = []
            return
        }
        if rebuild {
            identifiers = order
            let toolbar = NSToolbar(identifier: "org.finch.SwiftUI.toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { identifiers }
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { identifiers }
    }

    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            guard let controller = controllers[itemIdentifier] else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = controller.view
            return item
        }
    }
}

/// An AppKit view behind the view with a `toolbar`, which gives its window's toolbar the
/// items. It takes no events.
struct _FinchToolbarHost: NSViewRepresentable {
    var items: () -> [_FinchToolbarItem]

    final class HostView: NSView {
        var update: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { update?() }
        }
    }

    final class Coordinator {
        weak var toolbar: _FinchWindowToolbar?

        @MainActor
        func remove() {
            toolbar?.remove(ObjectIdentifier(self))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView { HostView() }

    func updateNSView(_ view: HostView, context: Context) {
        let items = items
        let environment = context.environment
        let coordinator = context.coordinator
        // a covered page's items aren't the window's
        let covered = environment._finchNavigationCovered
        view.update = { [weak view] in
            guard let window = view?.window else { return }
            let toolbar = _FinchWindowToolbar.of(window)
            coordinator.toolbar = toolbar
            toolbar.set(covered ? [] : items(), for: ObjectIdentifier(coordinator), environment: environment)
        }
        view.update?()
    }

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        coordinator.remove()
    }
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    nonisolated public func toolbar<Content>(@ToolbarContentBuilder content: () -> Content) -> some View where Content: ToolbarContent {
        let content = content()
        return background(_FinchToolbarHost(items: { MainActor.assumeIsolated { _finchToolbarItemsOf(content) } }))
    }

    nonisolated public func toolbar<Content>(id: String, @ToolbarContentBuilder content: () -> Content) -> some View
        where Content: CustomizableToolbarContent {
        let content = content()
        return background(_FinchToolbarHost(items: { MainActor.assumeIsolated { _finchToolbarItemsOf(content) } }))
    }
}

// MARK: - Navigation titles

/// An AppKit view behind the view with a navigation title, which makes it its window's title.
struct _FinchWindowTitle: NSViewRepresentable {
    var title: Text

    final class TitleView: NSView {
        var title = ""

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            if let window, !title.isEmpty, window.title != title { window.title = title }
        }
    }

    func makeNSView(context: Context) -> TitleView { TitleView() }

    func updateNSView(_ view: TitleView, context: Context) {
        // a covered page's title isn't the window's
        guard !context.environment._finchNavigationCovered else { return }
        view.title = title._resolveText(in: context.environment)
        view.apply()
        // and once the window has its scene's title, which it gets after its content
        DispatchQueue.main.async { view.apply() }
    }
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    nonisolated public func navigationTitle(_ title: Text) -> some View {
        background(_FinchWindowTitle(title: title))
    }

    nonisolated public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View {
        navigationTitle(Text(titleKey))
    }

    @_disfavoredOverload
    nonisolated public func navigationTitle<S>(_ title: S) -> some View where S: StringProtocol {
        navigationTitle(Text(title))
    }

    @available(OpenSwiftUI_v4_0, *)
    nonisolated public func navigationTitle(_ title: Binding<String>) -> some View {
        navigationTitle(Text(title.wrappedValue))
    }
}
