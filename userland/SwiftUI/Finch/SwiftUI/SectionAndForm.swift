// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Section, Form and form styles, to Apple's interface.
//
// A section is a header, content and footer, as several views: in a stack they follow each
// other; in a container that asks for sections (a list, a grouped form) the header and footer
// carry the section traits, so the container can draw them as such (upstream's groupViewList
// does this, as Apple's sections do). A collapsed section leaves its content out.
//
// A form draws its content as the form style in force makes it: columns (the macOS default)
// one row after another, grouped each section's rows in a box under its header.

import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - Section

@available(OpenSwiftUI_v1_0, *)
public struct Section<Parent, Content, Footer> {
    var header: Parent
    var content: Content
    var footer: Footer
    var isExpanded: Binding<Bool>?

    init(header: Parent, content: Content, footer: Footer, isExpanded: Binding<Bool>?) {
        self.header = header
        self.content = content
        self.footer = footer
        self.isExpanded = isExpanded
    }
}

@available(*, unavailable)
extension Section: Sendable {}

/// A section's content, or none while it is collapsed.
private struct SectionContent<Parent, Content, Footer>: Rule {
    @Attribute var section: Section<Parent, Content, Footer>

    var value: Content? {
        section.isExpanded?.wrappedValue == false ? nil : section.content
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Section: View, PrimitiveView where Parent: View, Content: View, Footer: View {
    public typealias Body = Never

    nonisolated public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        .multiView(inputs: inputs) { _, inputs in
            _makeViewList(view: view, inputs: _ViewListInputs(inputs.base))
        }
    }

    nonisolated public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let content = _GraphValue(SectionContent(section: view.value))
        return .groupViewList(parent: view[\.header], footer: view[\.footer].value, inputs: inputs) { _, inputs in
            Content?._makeViewList(view: content, inputs: inputs)
        }
    }

    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        _ViewListOutputs.groupViewListCount(inputs: inputs, contentType: Content?.self, headerType: Parent.self,
                                            footerType: Footer.self)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Section where Parent: View, Content: View, Footer: View {
    public init(header: Parent, footer: Footer, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content(), footer: footer, isExpanded: nil)
    }

    @available(OpenSwiftUI_v7_0, *)
    @usableFromInline
    static func create(isExpanded: Binding<Bool>? = nil, content: Content, header: Parent, footer: Footer) -> Section {
        Section(header: header, content: content, footer: footer, isExpanded: isExpanded)
    }

    /// Sections can't be collapsed by default from macOS 14 (this was for earlier ones).
    public func collapsible(_ collapsible: Bool) -> some View {
        self
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Section where Parent == EmptyView, Content: View, Footer: View {
    public init(footer: Footer, @ViewBuilder content: () -> Content) {
        self.init(header: EmptyView(), content: content(), footer: footer, isExpanded: nil)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Section where Parent: View, Content: View, Footer == EmptyView {
    public init(header: Parent, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content(), footer: EmptyView(), isExpanded: nil)
    }

    @available(OpenSwiftUI_v5_0, *)
    public init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {
        self.init(header: header(), content: content(), footer: EmptyView(), isExpanded: isExpanded)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Section where Parent == EmptyView, Content: View, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {
        self.init(header: EmptyView(), content: content(), footer: EmptyView(), isExpanded: nil)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension Section where Parent == Text, Content: View, Footer == EmptyView {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(header: Text(titleKey), content: content(), footer: EmptyView(), isExpanded: nil)
    }

    @_disfavoredOverload
    public init<S>(_ title: S, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.init(header: Text(title), content: content(), footer: EmptyView(), isExpanded: nil)
    }

    @available(OpenSwiftUI_v5_0, *)
    public init(_ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(header: Text(titleKey), content: content(), footer: EmptyView(), isExpanded: isExpanded)
    }

    @available(OpenSwiftUI_v5_0, *)
    @_disfavoredOverload
    public init<S>(_ title: S, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.init(header: Text(title), content: content(), footer: EmptyView(), isExpanded: isExpanded)
    }
}

/// A child of a sectioned container: a section header, footer, or a row.
enum _FinchSectionPart {
    case header, footer, row

    init(_ child: _VariadicView.Children.Element) {
        if child[IsSectionHeaderTraitKey.self] {
            self = .header
        } else if child[IsSectionFooterTraitKey.self] {
            self = .footer
        } else {
            self = .row
        }
    }
}

/// The view list options of a container that draws sections.
let _finchSectionedViewListOptions = Int(_ViewListInputs.Options.requiresNonEmptyGroupParent.rawValue)

// MARK: - Form styles

@available(OpenSwiftUI_v4_0, *)
@MainActor
@preconcurrency
public protocol FormStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = FormStyleConfiguration
}

@available(OpenSwiftUI_v4_0, *)
public struct FormStyleConfiguration {
    public struct Content: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    public let content: FormStyleConfiguration.Content

    init() {
        content = Content()
    }
}

@available(*, unavailable) extension FormStyleConfiguration: Sendable {}
@available(*, unavailable) extension FormStyleConfiguration.Content: Sendable {}

/// A form style as the form applies it.
struct _FinchAnyFormStyle: @unchecked Sendable {
    let body: (FormStyleConfiguration) -> AnyView

    @MainActor
    init<S: FormStyle>(_ style: S) {
        body = { configuration in MainActor.assumeIsolated { AnyView(style.makeBody(configuration: configuration)) } }
    }
}

private struct _FinchFormStylesKey: EnvironmentKey {
    static var defaultValue: [_FinchAnyFormStyle] { [] }
}

extension EnvironmentValues {
    /// The form styles in force, innermost last.
    var _finchFormStyles: [_FinchAnyFormStyle] {
        get { self[_FinchFormStylesKey.self] }
        set { self[_FinchFormStylesKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    nonisolated public func formStyle<S>(_ style: S) -> some View where S: FormStyle {
        let box = MainActor.assumeIsolated { _FinchAnyFormStyle(style) }
        return transformEnvironment(\._finchFormStyles) { $0.append(box) }
    }
}

@available(OpenSwiftUI_v4_0, *)
public struct ColumnsFormStyle: FormStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.content
        }
        .padding(20)
    }
}

@available(OpenSwiftUI_v4_0, *)
public struct GroupedFormStyle: FormStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _VariadicView.Tree(_FinchGroupedFormRoot()) {
            configuration.content
        }
        .padding(20)
    }
}

@available(OpenSwiftUI_v4_0, *)
public struct AutomaticFormStyle: FormStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ColumnsFormStyle().makeBody(configuration: configuration)
    }
}

@available(*, unavailable) extension ColumnsFormStyle: Sendable {}
@available(*, unavailable) extension GroupedFormStyle: Sendable {}
@available(*, unavailable) extension AutomaticFormStyle: Sendable {}

extension FormStyle where Self == AutomaticFormStyle {
    @_alwaysEmitIntoClient public static var automatic: AutomaticFormStyle { .init() }
}

extension FormStyle where Self == ColumnsFormStyle {
    public static var columns: ColumnsFormStyle { .init() }
}

extension FormStyle where Self == GroupedFormStyle {
    public static var grouped: GroupedFormStyle { .init() }
}

/// A grouped form's sections: each header over a box of its rows, its footer under it.
struct _FinchGroupedFormRoot: _VariadicView_UnaryViewRoot {
    static var _viewListOptions: Int { _finchSectionedViewListOptions }

    struct Group {
        var header: Int?
        var rows: [Int] = []
        var footer: Int?
    }

    func body(children: _VariadicView.Children) -> some View {
        var groups: [Group] = []
        for (index, child) in children.enumerated() {
            switch _FinchSectionPart(child) {
            case .header:
                groups.append(Group(header: index))
            case .footer:
                if groups.isEmpty { groups.append(Group()) }
                groups[groups.count - 1].footer = index
            case .row:
                if groups.isEmpty || groups[groups.count - 1].footer != nil { groups.append(Group()) }
                groups[groups.count - 1].rows.append(index)
            }
        }
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(groups.indices, id: \.self) { g in
                let group = groups[g]
                VStack(alignment: .leading, spacing: 6) {
                    if let header = group.header {
                        children[header].font(.headline).padding(.leading, 4)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.rows.indices, id: \.self) { r in
                            if r > 0 { Divider() }
                            children[group.rows[r]]
                                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    if let footer = group.footer {
                        children[footer].font(.footnote).foregroundStyle(Color.secondary).padding(.leading, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Form

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct Form<Content>: View where Content: View {
    var content: Content

    nonisolated public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchStyledForm(content: content)
    }
}

@available(*, unavailable)
extension Form: Sendable {}

@available(OpenSwiftUI_v4_0, *)
extension Form where Content == FormStyleConfiguration.Content {
    /// The form a style is styling, as the styles outside it make it.
    nonisolated public init(_ configuration: FormStyleConfiguration) {
        content = configuration.content
    }
}

/// A form as its innermost style makes it, with the styles outside that one in force.
struct _FinchStyledForm<Content: View>: View {
    var content: Content
    @Environment(\._finchFormStyles) private var styles

    var body: some View {
        let style = styles.last ?? _FinchAnyFormStyle(AutomaticFormStyle())
        style.body(FormStyleConfiguration())
            .environment(\._finchFormStyles, Array(styles.dropLast()))
            .viewAlias(FormStyleConfiguration.Content.self) { content }
    }
}
