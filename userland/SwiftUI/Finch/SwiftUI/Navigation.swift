// SPDX-License-Identifier: MIT OR Apache-2.0
//
// NavigationStack, NavigationPath, NavigationLink, navigationDestination,
// NavigationSplitView and NavigationView, to Apple's interface, as Apple's work on macOS:
// a stack shows its root or the page on top of it, with a back button in the window's
// toolbar; links push values (shown by the destination registered for their type) or
// views; a split view puts its sidebar, content and detail side by side, links in the
// sidebar replacing what the detail column shows. Pages under the top one stay (covered),
// so they keep their state; only the top page's title and toolbar items are the window's.

import AppKit
import SwiftUICore

// MARK: - NavigationPath

@available(OpenSwiftUI_v4_0, *)
public struct NavigationPath {
    var elements: [AnyHashable]

    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }

    public init() {
        elements = []
    }

    public init<S>(_ elements: S) where S: Sequence, S.Element: Hashable {
        self.elements = elements.map(AnyHashable.init)
    }

    public init<S>(_ elements: S) where S: Sequence, S.Element: Decodable, S.Element: Encodable, S.Element: Hashable {
        self.elements = elements.map(AnyHashable.init)
    }

    public init(_ codable: CodableRepresentation) {
        elements = codable.elements
    }

    public mutating func append<V>(_ value: V) where V: Hashable {
        elements.append(AnyHashable(value))
    }

    public mutating func append<V>(_ value: V) where V: Decodable, V: Encodable, V: Hashable {
        elements.append(AnyHashable(value))
    }

    public mutating func removeLast(_ k: Int = 1) {
        elements.removeLast(k)
    }

    /// The path as data, when every element is Codable: each element's type name and JSON.
    public var codable: CodableRepresentation? {
        var encoded: [AnyHashable] = []
        for element in elements {
            guard element.base is any Codable else { return nil }
            encoded.append(element)
        }
        return CodableRepresentation(elements: encoded)
    }

    public struct CodableRepresentation: Codable {
        var elements: [AnyHashable]

        init(elements: [AnyHashable]) {
            self.elements = elements
        }

        public init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var elements: [AnyHashable] = []
            while !container.isAtEnd {
                let name = try container.decode(String.self)
                let json = try container.decode(String.self)
                guard let type = _typeByName(name) as? any (Decodable & Hashable).Type else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "no type \(name)")
                }
                elements.append(AnyHashable(try JSONDecoder().decode(type, from: Data(json.utf8))))
            }
            self.elements = elements
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            for element in elements {
                guard let value = element.base as? any Encodable else { continue }
                try container.encode(_typeName(type(of: element.base), qualified: true))
                try container.encode(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
            }
        }
    }
}

@available(*, unavailable) extension NavigationPath: Sendable {}

@available(OpenSwiftUI_v4_0, *)
extension NavigationPath: Equatable {
    public static func == (lhs: NavigationPath, rhs: NavigationPath) -> Bool {
        lhs.elements == rhs.elements
    }
}

@available(OpenSwiftUI_v4_0, *)
extension NavigationPath.CodableRepresentation: Equatable {
    public static func == (lhs: NavigationPath.CodableRepresentation, rhs: NavigationPath.CodableRepresentation) -> Bool {
        lhs.elements == rhs.elements
    }
}

// MARK: - The navigator

/// The destinations registered in a stack (or split view) for the types of values pushed.
final class _FinchDestinations {
    var views: [ObjectIdentifier: (Any) -> AnyView] = [:]
}

/// What links and destinations in a stack act on.
struct _FinchNavigator {
    var push: (AnyHashable) -> Void
    var pushView: (AnyView) -> Void
    var pop: () -> Void
    var destinations: _FinchDestinations
}

private struct _FinchNavigatorKey: EnvironmentKey {
    static var defaultValue: _FinchNavigator? { nil }
}

private struct _FinchNavigationCoveredKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    var _finchNavigator: _FinchNavigator? {
        get { self[_FinchNavigatorKey.self] }
        set { self[_FinchNavigatorKey.self] = newValue }
    }

    /// Whether the view is in a page another covers (its title and toolbar aren't the window's).
    var _finchNavigationCovered: Bool {
        get { self[_FinchNavigationCoveredKey.self] }
        set { self[_FinchNavigationCoveredKey.self] = newValue }
    }
}

/// A stack's path, read and changed: its own state or the app's binding.
struct _FinchPathAccess {
    var get: () -> [AnyHashable]
    var append: (AnyHashable) -> Void
    var removeLast: () -> Void
}

/// A stack: the root and the pages pushed on it, the top one showing.
struct _FinchNavigationStackView<Root: View>: View {
    var root: Root
    var path: _FinchPathAccess?
    @State private var own: [AnyHashable] = []
    @State private var views: [AnyView] = []
    @State private var destinations = _FinchDestinations()
    @Environment(\._finchNavigationCovered) private var covered

    var body: some View {
        let own = $own, views = $views
        let access = path ?? _FinchPathAccess(get: { own.wrappedValue }, append: { own.wrappedValue.append($0) },
                                              removeLast: { own.wrappedValue.removeLast() })
        let navigator = _FinchNavigator(
            push: access.append,
            pushView: { views.wrappedValue.append($0) },
            pop: {
                if !views.wrappedValue.isEmpty { views.wrappedValue.removeLast() } else if !access.get().isEmpty { access.removeLast() }
            },
            destinations: destinations)
        let pages = access.get().map { value in
            destinations.views[ObjectIdentifier(type(of: value.base))]?(value.base) ?? AnyView(EmptyView())
        } + views.wrappedValue
        return _FinchPages(root: AnyView(root), pages: pages, covered: covered)
            .environment(\._finchNavigator, navigator)
            .toolbar {
                if !pages.isEmpty && !covered {
                    ToolbarItem(placement: .navigation) {
                        Button { navigator.pop() } label: {
                            Text(verbatim: "\u{2039}").font(.system(size: 22)).frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .help("Back")
                    }
                }
            }
    }
}

/// A root and pages over it, all but the top one covered (hidden, kept).
struct _FinchPages: View {
    var root: AnyView
    var pages: [AnyView]
    var covered: Bool

    var body: some View {
        ZStack {
            page(root, top: pages.isEmpty)
            ForEach(pages.indices, id: \.self) { index in
                page(pages[index], top: index == pages.count - 1)
            }
        }
    }

    private func page(_ view: AnyView, top: Bool) -> some View {
        view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(top ? 1 : 0)
            .allowsHitTesting(top)
            .environment(\._finchNavigationCovered, covered || !top)
    }
}

// MARK: - NavigationStack

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct NavigationStack<Data, Root>: View where Root: View {
    var root: Root
    var path: _FinchPathAccess?

    @MainActor
    @preconcurrency
    public init(@ViewBuilder root: () -> Root) where Data == NavigationPath {
        self.root = root()
        self.path = nil
    }

    @MainActor
    @preconcurrency
    public init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) where Data == NavigationPath {
        self.root = root()
        self.path = _FinchPathAccess(get: { path.wrappedValue.elements }, append: { path.wrappedValue.elements.append($0) },
                                     removeLast: { path.wrappedValue.elements.removeLast() })
    }

    @MainActor
    @preconcurrency
    public init(path: Binding<Data>, @ViewBuilder root: () -> Root)
        where Data: MutableCollection, Data: RandomAccessCollection, Data: RangeReplaceableCollection, Data.Element: Hashable {
        self.root = root()
        self.path = _FinchPathAccess(
            get: { path.wrappedValue.map(AnyHashable.init) },
            append: { value in
                if let element = value.base as? Data.Element { path.wrappedValue.append(element) }
            },
            removeLast: { path.wrappedValue.removeLast() })
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchNavigationStackView(root: root, path: path)
    }
}

@available(*, unavailable) extension NavigationStack: Sendable {}

// MARK: - navigationDestination

/// Registers a destination with the stack around it, for values of a type. (An AppKit view,
/// so it's updated whenever the view it's behind is.)
struct _FinchDestinationRegistrar<D: Hashable, C: View>: NSViewRepresentable {
    var destination: (D) -> C

    final class RegistrarView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> RegistrarView { RegistrarView() }

    func updateNSView(_ view: RegistrarView, context: Context) {
        let destination = destination
        context.environment._finchNavigator?.destinations.views[ObjectIdentifier(D.self)] = {
            AnyView(destination($0 as! D))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RegistrarView, context: Context) -> CGSize? { .zero }
}

/// Pushes a view while a binding is set, and clears it when popped.
struct _FinchPresentedDestination<V: View>: View {
    var isPresented: Binding<Bool>
    var destination: V
    @Environment(\._finchNavigator) private var navigator
    @State private var pushed = false

    var body: some View {
        let isPresented = isPresented
        return EmptyView()
            .onChange(of: isPresented.wrappedValue, initial: true) { _, presented in
                if presented, !pushed {
                    pushed = true
                    navigator?.pushView(AnyView(destination.onDisappear {
                        pushed = false
                        isPresented.wrappedValue = false
                    }))
                } else if !presented, pushed {
                    pushed = false
                    navigator?.pop()
                }
            }
    }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    nonisolated public func navigationDestination<D, C>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View
        where D: Hashable, C: View {
        background(_FinchDestinationRegistrar(destination: destination))
    }

    nonisolated public func navigationDestination<V>(isPresented: Binding<Bool>, @ViewBuilder destination: () -> V) -> some View
        where V: View {
        background(_FinchPresentedDestination(isPresented: isPresented, destination: destination()))
    }

    nonisolated public func navigationDestination<D, C>(item: Binding<D?>, @ViewBuilder destination: @escaping (D) -> C) -> some View
        where D: Hashable, C: View {
        let isPresented = Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return background(_FinchPresentedDestination(isPresented: isPresented,
                                                     destination: item.wrappedValue.map { AnyView(destination($0)) } ?? AnyView(EmptyView())))
    }
}

// MARK: - NavigationLink

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct NavigationLink<Label, Destination>: View where Label: View, Destination: View {
    enum Target {
        case value(AnyHashable?)
        case view(Destination, isActive: Binding<Bool>?)
    }

    var label: Label
    var target: Target

    nonisolated init(label: Label, target: Target) {
        self.label = label
        self.target = target
    }

    public init(destination: Destination, @ViewBuilder label: () -> Label) {
        self.init(label: label(), target: .view(destination, isActive: nil))
    }

    public init(destination: Destination, isActive: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.init(label: label(), target: .view(destination, isActive: isActive))
    }

    public init<V>(destination: Destination, tag: V, selection: Binding<V?>, @ViewBuilder label: () -> Label) where V: Hashable {
        let isActive = Binding(get: { selection.wrappedValue == tag }, set: { selection.wrappedValue = $0 ? tag : nil })
        self.init(label: label(), target: .view(destination, isActive: isActive))
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchNavigationLinkButton(label: AnyView(label), push: { navigator in
            switch target {
            case let .value(value):
                if let value { navigator?.push(value) }
            case let .view(destination, isActive):
                isActive?.wrappedValue = true
                navigator?.pushView(AnyView(destination.onDisappear { isActive?.wrappedValue = false }))
            }
        })
    }
}

@available(*, unavailable) extension NavigationLink: Sendable {}

/// A link: its label, as a button that pushes (as a row's content, in a list).
struct _FinchNavigationLinkButton: View {
    var label: AnyView
    var push: (_FinchNavigator?) -> Void
    @Environment(\._finchNavigator) private var navigator

    var body: some View {
        let navigator = navigator
        Button { push(navigator) } label: {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@available(OpenSwiftUI_v4_0, *)
extension NavigationLink where Destination == Never {
    nonisolated public init<P>(value: P?, @ViewBuilder label: () -> Label) where P: Hashable {
        self.init(label: label(), target: .value(value.map(AnyHashable.init)))
    }

    nonisolated public init<P>(_ titleKey: LocalizedStringKey, value: P?) where Label == Text, P: Hashable {
        self.init(label: Text(titleKey), target: .value(value.map(AnyHashable.init)))
    }

    @_disfavoredOverload
    nonisolated public init<S, P>(_ title: S, value: P?) where Label == Text, S: StringProtocol, P: Hashable {
        self.init(label: Text(title), target: .value(value.map(AnyHashable.init)))
    }

    nonisolated public init<P>(value: P?, @ViewBuilder label: () -> Label) where P: Decodable, P: Encodable, P: Hashable {
        self.init(label: label(), target: .value(value.map(AnyHashable.init)))
    }

    nonisolated public init<P>(_ titleKey: LocalizedStringKey, value: P?) where Label == Text, P: Decodable, P: Encodable, P: Hashable {
        self.init(label: Text(titleKey), target: .value(value.map(AnyHashable.init)))
    }

    @_disfavoredOverload
    nonisolated public init<S, P>(_ title: S, value: P?) where Label == Text, S: StringProtocol, P: Decodable, P: Encodable, P: Hashable {
        self.init(label: Text(title), target: .value(value.map(AnyHashable.init)))
    }
}

@available(OpenSwiftUI_v1_0, *)
extension NavigationLink where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, destination: Destination) {
        self.init(label: Text(titleKey), target: .view(destination, isActive: nil))
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, destination: Destination) where S: StringProtocol {
        self.init(label: Text(title), target: .view(destination, isActive: nil))
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, destination: Destination, isActive: Binding<Bool>) {
        self.init(label: Text(titleKey), target: .view(destination, isActive: isActive))
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, destination: Destination, isActive: Binding<Bool>) where S: StringProtocol {
        self.init(label: Text(title), target: .view(destination, isActive: isActive))
    }

    nonisolated public init<V>(_ titleKey: LocalizedStringKey, destination: Destination, tag: V, selection: Binding<V?>)
        where V: Hashable {
        let isActive = Binding(get: { selection.wrappedValue == tag }, set: { selection.wrappedValue = $0 ? tag : nil })
        self.init(label: Text(titleKey), target: .view(destination, isActive: isActive))
    }

    @_disfavoredOverload
    nonisolated public init<S, V>(_ title: S, destination: Destination, tag: V, selection: Binding<V?>)
        where S: StringProtocol, V: Hashable {
        let isActive = Binding(get: { selection.wrappedValue == tag }, set: { selection.wrappedValue = $0 ? tag : nil })
        self.init(label: Text(title), target: .view(destination, isActive: isActive))
    }
}

// MARK: - NavigationSplitView

@available(OpenSwiftUI_v4_0, *)
public struct NavigationSplitViewVisibility: Equatable, Codable, Sendable {
    enum Kind: String, Codable {
        case detailOnly, doubleColumn, all, automatic
    }

    var kind: Kind

    public static var detailOnly: NavigationSplitViewVisibility { .init(kind: .detailOnly) }
    public static var doubleColumn: NavigationSplitViewVisibility { .init(kind: .doubleColumn) }
    public static var all: NavigationSplitViewVisibility { .init(kind: .all) }
    public static var automatic: NavigationSplitViewVisibility { .init(kind: .automatic) }

    public static func == (lhs: NavigationSplitViewVisibility, rhs: NavigationSplitViewVisibility) -> Bool {
        lhs.kind == rhs.kind
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kind)
    }

    public init(from decoder: any Decoder) throws {
        kind = try decoder.singleValueContainer().decode(Kind.self)
    }

    init(kind: Kind) {
        self.kind = kind
    }
}

@available(OpenSwiftUI_v5_0, *)
public struct NavigationSplitViewColumn: Hashable, Sendable {
    enum Kind { case sidebar, content, detail }
    var kind: Kind

    public static var sidebar: NavigationSplitViewColumn { .init(kind: .sidebar) }
    public static var content: NavigationSplitViewColumn { .init(kind: .content) }
    public static var detail: NavigationSplitViewColumn { .init(kind: .detail) }

    public static func == (a: NavigationSplitViewColumn, b: NavigationSplitViewColumn) -> Bool {
        a.kind == b.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
    }
}

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public struct NavigationSplitView<Sidebar, Content, Detail>: View where Sidebar: View, Content: View, Detail: View {
    var sidebar: Sidebar
    var content: Content
    var detail: Detail
    var columnVisibility: Binding<NavigationSplitViewVisibility>?

    nonisolated init(sidebar: Sidebar, content: Content, detail: Detail, columnVisibility: Binding<NavigationSplitViewVisibility>?) {
        self.sidebar = sidebar
        self.content = content
        self.detail = detail
        self.columnVisibility = columnVisibility
    }

    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.init(sidebar: sidebar(), content: content(), detail: detail(), columnVisibility: nil)
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar,
                @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.init(sidebar: sidebar(), content: content(), detail: detail(), columnVisibility: columnVisibility)
    }

    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) where Content == EmptyView {
        self.init(sidebar: sidebar(), content: EmptyView(), detail: detail(), columnVisibility: nil)
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar,
                @ViewBuilder detail: () -> Detail) where Content == EmptyView {
        self.init(sidebar: sidebar(), content: EmptyView(), detail: detail(), columnVisibility: columnVisibility)
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchSplitView(sidebar: AnyView(sidebar), content: Content.self == EmptyView.self ? nil : AnyView(content),
                        detail: AnyView(detail), columnVisibility: columnVisibility)
    }
}

@available(*, unavailable) extension NavigationSplitView: Sendable {}

@available(OpenSwiftUI_v5_0, *)
extension NavigationSplitView {
    nonisolated public init(preferredCompactColumn: Binding<NavigationSplitViewColumn>, @ViewBuilder sidebar: () -> Sidebar,
                            @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.init(sidebar: sidebar(), content: content(), detail: detail(), columnVisibility: nil)
    }

    nonisolated public init(columnVisibility: Binding<NavigationSplitViewVisibility>,
                            preferredCompactColumn: Binding<NavigationSplitViewColumn>, @ViewBuilder sidebar: () -> Sidebar,
                            @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.init(sidebar: sidebar(), content: content(), detail: detail(), columnVisibility: columnVisibility)
    }

    nonisolated public init(preferredCompactColumn: Binding<NavigationSplitViewColumn>, @ViewBuilder sidebar: () -> Sidebar,
                            @ViewBuilder detail: () -> Detail) where Content == EmptyView {
        self.init(sidebar: sidebar(), content: EmptyView(), detail: detail(), columnVisibility: nil)
    }

    nonisolated public init(columnVisibility: Binding<NavigationSplitViewVisibility>,
                            preferredCompactColumn: Binding<NavigationSplitViewColumn>, @ViewBuilder sidebar: () -> Sidebar,
                            @ViewBuilder detail: () -> Detail) where Content == EmptyView {
        self.init(sidebar: sidebar(), content: EmptyView(), detail: detail(), columnVisibility: columnVisibility)
    }
}

/// A column's width, as `navigationSplitViewColumnWidth` gives it.
struct _FinchColumnWidth: Equatable {
    var min: CGFloat?
    var ideal: CGFloat
    var max: CGFloat?
}

struct _FinchColumnWidthKey: PreferenceKey {
    static var defaultValue: _FinchColumnWidth? { nil }

    static func reduce(value: inout _FinchColumnWidth?, nextValue: () -> _FinchColumnWidth?) {
        value = value ?? nextValue()
    }
}

/// The split view: the columns side by side, divided, the sidebar on the sidebar's
/// background. Values pushed in the sidebar or content columns replace the detail column's
/// pages; the detail column is a stack.
struct _FinchSplitView: View {
    var sidebar: AnyView
    var content: AnyView?
    var detail: AnyView
    var columnVisibility: Binding<NavigationSplitViewVisibility>?
    @State private var sidebarWidth: _FinchColumnWidth?
    @State private var contentWidth: _FinchColumnWidth?
    @State private var pages: [AnyHashable] = []
    @State private var views: [AnyView] = []
    @State private var destinations = _FinchDestinations()

    var body: some View {
        let pagesBinding = $pages, viewsBinding = $views
        // links in the sidebar and content columns show their value alone in the detail column
        let navigator = _FinchNavigator(
            push: { value in
                viewsBinding.wrappedValue = []
                pagesBinding.wrappedValue = [value]
            },
            pushView: { view in
                pagesBinding.wrappedValue = []
                viewsBinding.wrappedValue = [view]
            },
            pop: {
                if !viewsBinding.wrappedValue.isEmpty { viewsBinding.wrappedValue.removeLast() } else if !pagesBinding.wrappedValue.isEmpty {
                    pagesBinding.wrappedValue.removeLast()
                }
            },
            destinations: destinations)
        let visibility = columnVisibility?.wrappedValue ?? .automatic
        let showsSidebar = visibility != .detailOnly
        let showsContent = content != nil && visibility != .detailOnly
        let detailPages = pages.map { value in
            destinations.views[ObjectIdentifier(type(of: value.base))]?(value.base) ?? AnyView(EmptyView())
        } + views
        return HStack(spacing: 0) {
            if showsSidebar {
                column(sidebar, width: sidebarWidth, default: _FinchColumnWidth(min: 180, ideal: 220, max: 400))
                    .onPreferenceChange(_FinchColumnWidthKey.self) { sidebarWidth = $0 }
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .environment(\._finchListStyle, SidebarListStyle().appearance)
                Divider()
            }
            if showsContent, let content {
                column(content, width: contentWidth, default: _FinchColumnWidth(min: 200, ideal: 260, max: 500))
                    .onPreferenceChange(_FinchColumnWidthKey.self) { contentWidth = $0 }
                Divider()
            }
            _FinchPages(root: detail, pages: detailPages, covered: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\._finchNavigator, navigator)
    }

    private func column(_ view: AnyView, width: _FinchColumnWidth?, default fallback: _FinchColumnWidth) -> some View {
        let width = width ?? fallback
        return view.frame(minWidth: width.min ?? width.ideal, idealWidth: width.ideal, maxWidth: width.ideal,
                          maxHeight: .infinity, alignment: .topLeading)
    }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    nonisolated public func navigationSplitViewColumnWidth(_ width: CGFloat) -> some View {
        preference(key: _FinchColumnWidthKey.self, value: _FinchColumnWidth(min: width, ideal: width, max: width))
    }

    nonisolated public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View {
        preference(key: _FinchColumnWidthKey.self, value: _FinchColumnWidth(min: min, ideal: ideal, max: max))
    }
}

// MARK: - NavigationView (the original navigation container)

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct NavigationView<Content>: View where Content: View {
    var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// On macOS, the views side by side as columns (the first a sidebar), links showing their
    /// destinations in the last.
    @MainActor
    @preconcurrency
    public var body: some View {
        let views = (content as? _FinchViewSequence)?._finchViews.compactMap { $0 as? any View }.map { AnyView($0) }
            ?? [AnyView(content)]
        if views.count > 1 {
            _FinchSplitView(sidebar: views[0], content: views.count > 2 ? views[1] : nil, detail: views[views.count - 1],
                            columnVisibility: nil)
        } else {
            _FinchNavigationStackView(root: content, path: nil)
        }
    }
}

@available(*, unavailable) extension NavigationView: Sendable {}
