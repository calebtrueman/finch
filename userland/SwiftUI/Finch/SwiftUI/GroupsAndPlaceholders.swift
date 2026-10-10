// SPDX-License-Identifier: MIT OR Apache-2.0
//
// DisclosureGroup, ControlGroup, ContentUnavailableView, scrollIndicators and
// contentMargins, to Apple's interface, drawn as on macOS: a disclosure group is its label
// after a disclosure triangle, its content indented under it while expanded; a control group
// is its controls side by side in one bordered strip; a content-unavailable view is its
// label (large), description and actions centered in the space it has.

import AppKit
import SwiftUICore

// MARK: - DisclosureGroup

@available(OpenSwiftUI_v2_0, *)
@MainActor
@preconcurrency
public struct DisclosureGroup<Label, Content>: View where Label: View, Content: View {
    var label: Label
    var content: () -> Content
    var isExpanded: Binding<Bool>?
    @State private var expanded = false

    public init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content
        self.isExpanded = nil
    }

    public init(isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content
        self.isExpanded = isExpanded
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        let open = isExpanded ?? $expanded
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(verbatim: open.wrappedValue ? "\u{25BE}" : "\u{25B8}")
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                label
            }
            .contentShape(Rectangle())
            .onTapGesture { open.wrappedValue.toggle() }
            if open.wrappedValue {
                content().padding(.leading, 16)
            }
        }
    }
}

@available(*, unavailable) extension DisclosureGroup: Sendable {}

@available(OpenSwiftUI_v2_0, *)
extension DisclosureGroup where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content) { Text(titleKey) }
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(isExpanded: isExpanded, content: content) { Text(titleKey) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ label: S, @ViewBuilder content: @escaping () -> Content) where S: StringProtocol {
        self.init(content: content) { Text(label) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ label: S, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content)
        where S: StringProtocol {
        self.init(isExpanded: isExpanded, content: content) { Text(label) }
    }
}

// MARK: - ControlGroup

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public struct ControlGroup<Content>: View where Content: View {
    var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        HStack(spacing: 12) { content }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .fixedSize()
    }
}

@available(*, unavailable) extension ControlGroup: Sendable {}

@available(OpenSwiftUI_v4_0, *)
public struct LabeledControlGroupContent<Content, Label>: View where Content: View, Label: View {
    var content: Content
    var label: Label

    @MainActor
    @preconcurrency
    public var body: some View { content }
}

@available(*, unavailable) extension LabeledControlGroupContent: Sendable {}

@available(OpenSwiftUI_v4_0, *)
extension ControlGroup {
    nonisolated public init<C, L>(@ViewBuilder content: () -> C, @ViewBuilder label: () -> L)
        where Content == LabeledControlGroupContent<C, L>, C: View, L: View {
        self.init { LabeledControlGroupContent(content: content(), label: label()) }
    }
}

@available(OpenSwiftUI_v3_0, *)
public struct ControlGroupStyleConfiguration {
    @MainActor
    @preconcurrency
    public struct Content: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    @MainActor
    @preconcurrency
    public struct Label: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    public let content = Content()
    public let label = Label()
}

@available(*, unavailable) extension ControlGroupStyleConfiguration: Sendable {}

@available(OpenSwiftUI_v3_0, *)
extension ControlGroup where Content == ControlGroupStyleConfiguration.Content {
    nonisolated public init(_ configuration: ControlGroupStyleConfiguration) {
        self.init { configuration.content }
    }
}

// MARK: - ContentUnavailableView

@available(OpenSwiftUI_v5_0, *)
@MainActor
@preconcurrency
public struct ContentUnavailableView<Label, Description, Actions>: View
    where Label: View, Description: View, Actions: View {
    var label: Label
    var description: Description
    var actions: Actions

    public init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description = { EmptyView() },
                @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        VStack(spacing: 8) {
            label
                .labelStyle(.titleAndIcon)
                .font(.title2.bold())
                .imageScale(.large)
            description
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@available(*, unavailable) extension ContentUnavailableView: Sendable {}

@available(OpenSwiftUI_v5_0, *)
extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    nonisolated public init(_ title: LocalizedStringKey, image name: String, description: Text? = nil) {
        self.init { SwiftUI.Label(title, image: name) } description: { description }
    }

    nonisolated public init(_ title: LocalizedStringKey, systemImage name: String, description: Text? = nil) {
        self.init { SwiftUI.Label(title, systemImage: name) } description: { description }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, image name: String, description: Text? = nil) where S: StringProtocol {
        self.init { SwiftUI.Label(title, image: name) } description: { description }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, systemImage name: String, description: Text? = nil) where S: StringProtocol {
        self.init { SwiftUI.Label(title, systemImage: name) } description: { description }
    }
}

// MARK: - Scroll indicators and content margins

@available(OpenSwiftUI_v4_0, *)
public struct ScrollIndicatorVisibility {
    enum Kind { case automatic, visible, hidden, never }
    var kind: Kind

    public static var automatic: ScrollIndicatorVisibility { .init(kind: .automatic) }
    public static var visible: ScrollIndicatorVisibility { .init(kind: .visible) }
    public static var hidden: ScrollIndicatorVisibility { .init(kind: .hidden) }
    public static var never: ScrollIndicatorVisibility { .init(kind: .never) }
}

@available(*, unavailable) extension ScrollIndicatorVisibility: Sendable {}

private struct _FinchScrollIndicatorsKey: EnvironmentKey {
    static var defaultValue: Axis.Set { [] }
}

extension EnvironmentValues {
    /// The axes whose scroll indicators are hidden.
    var _finchHiddenScrollIndicators: Axis.Set {
        get { self[_FinchScrollIndicatorsKey.self] }
        set { self[_FinchScrollIndicatorsKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    nonisolated public func scrollIndicators(_ visibility: ScrollIndicatorVisibility,
                                             axes: Axis.Set = [.vertical, .horizontal]) -> some View {
        transformEnvironment(\._finchHiddenScrollIndicators) { hidden in
            switch visibility.kind {
            case .hidden, .never: hidden.formUnion(axes)
            case .visible, .automatic: hidden.subtract(axes)
            }
        }
    }
}

@available(OpenSwiftUI_v5_0, *)
public struct ContentMarginPlacement {
    enum Kind { case automatic, scrollContent, scrollIndicators }
    var kind: Kind

    public static var automatic: ContentMarginPlacement { .init(kind: .automatic) }
    public static var scrollContent: ContentMarginPlacement { .init(kind: .scrollContent) }
    public static var scrollIndicators: ContentMarginPlacement { .init(kind: .scrollIndicators) }
}

@available(*, unavailable) extension ContentMarginPlacement: Sendable {}

private struct _FinchContentMarginsKey: EnvironmentKey {
    static var defaultValue: EdgeInsets { EdgeInsets() }
}

extension EnvironmentValues {
    /// Margins scroll views put around their content.
    var _finchContentMargins: EdgeInsets {
        get { self[_FinchContentMarginsKey.self] }
        set { self[_FinchContentMarginsKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v5_0, *)
extension View {
    nonisolated public func contentMargins(_ edges: Edge.Set = .all, _ insets: EdgeInsets,
                                           for placement: ContentMarginPlacement = .automatic) -> some View {
        transformEnvironment(\._finchContentMargins) { margins in
            guard placement.kind != .scrollIndicators else { return }
            if edges.contains(.top) { margins.top = insets.top }
            if edges.contains(.leading) { margins.leading = insets.leading }
            if edges.contains(.bottom) { margins.bottom = insets.bottom }
            if edges.contains(.trailing) { margins.trailing = insets.trailing }
        }
    }

    nonisolated public func contentMargins(_ edges: Edge.Set = .all, _ length: CGFloat?,
                                           for placement: ContentMarginPlacement = .automatic) -> some View {
        let l = length ?? 0
        return contentMargins(edges, EdgeInsets(top: l, leading: l, bottom: l, trailing: l), for: placement)
    }

    nonisolated public func contentMargins(_ length: CGFloat, for placement: ContentMarginPlacement = .automatic) -> some View {
        contentMargins(.all, EdgeInsets(top: length, leading: length, bottom: length, trailing: length), for: placement)
    }
}
