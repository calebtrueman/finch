// SPDX-License-Identifier: MIT OR Apache-2.0
//
// List, to Apple's interface: on macOS, the content's views as rows on the control
// background, the selected rows highlighted with the accent colour. A row is selected by
// clicking it (with the Command key, added to or removed from a multiple selection), and is
// identified by its tag, or by its identity in a ForEach, as Apple's are. Hierarchical lists
// (OutlineGroup) and editing aren't here yet.

import AppKit
import SwiftUICore

/// What a list selects: nothing, one value (which may be required), or a set.
struct _FinchListSelection<Value: Hashable> {
    var isSelected: (Value) -> Bool
    var select: (Value) -> Void

    static var none: Self { Self(isSelected: { _ in false }, select: { _ in }) }

    init(isSelected: @escaping (Value) -> Bool, select: @escaping (Value) -> Void) {
        self.isSelected = isSelected
        self.select = select
    }

    init(_ binding: Binding<Value>) {
        self.init(isSelected: { binding.wrappedValue == $0 }, select: { binding.wrappedValue = $0 })
    }

    init(_ binding: Binding<Value?>?) {
        guard let binding else {
            self = .none
            return
        }
        self.init(isSelected: { binding.wrappedValue == $0 }, select: { binding.wrappedValue = $0 })
    }

    init(_ binding: Binding<Set<Value>>?) {
        guard let binding else {
            self = .none
            return
        }
        self.init(isSelected: { binding.wrappedValue.contains($0) }, select: { value in
            // Command-click adds or removes a row; a click alone selects just that row
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                if binding.wrappedValue.contains(value) {
                    binding.wrappedValue.remove(value)
                } else {
                    binding.wrappedValue.insert(value)
                }
            } else {
                binding.wrappedValue = [value]
            }
        })
    }
}

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct List<SelectionValue, Content>: View where SelectionValue: Hashable, Content: View {
    var selection: _FinchListSelection<SelectionValue>
    var content: Content

    nonisolated init(selection: _FinchListSelection<SelectionValue>, content: Content) {
        self.selection = selection
        self.content = content
    }

    @available(watchOS, unavailable)
    nonisolated public init(selection: Binding<Set<SelectionValue>>?, @ViewBuilder content: () -> Content) {
        self.init(selection: _FinchListSelection(selection), content: content())
    }

    nonisolated public init(selection: Binding<SelectionValue?>?, @ViewBuilder content: () -> Content) {
        self.init(selection: _FinchListSelection(selection), content: content())
    }

    @available(OpenSwiftUI_v4_0, *)
    @_disfavoredOverload
    nonisolated public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: _FinchListSelection(selection), content: content())
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _VariadicView.Tree(_FinchListRoot(selection: selection)) {
            content
        }
    }
}

@available(*, unavailable)
extension List: Sendable {}

/// The rows, over the content as variadic children.
struct _FinchListRoot<Value: Hashable>: _VariadicView_UnaryViewRoot {
    var selection: _FinchListSelection<Value>

    /// Section headers and footers come marked, to draw as such.
    static var _viewListOptions: Int { _finchSectionedViewListOptions }

    func body(children: _VariadicView.Children) -> some View {
        _FinchListRows(children: children, selection: selection)
    }
}

/// The rows as the list style in force draws them: inset (rounded selections, inset from
/// the edges, the default), plain (edge to edge), sidebar (on the sidebar's background) or
/// bordered (in a border), alternating row backgrounds when the style asks.
struct _FinchListRows<Value: Hashable>: View {
    var children: _VariadicView.Children
    var selection: _FinchListSelection<Value>
    @Environment(\._finchListStyle) private var style

    var body: some View {
        let inset: CGFloat = style.kind == .plain ? 0 : 6
        let radius: CGFloat = style.kind == .plain ? 0 : 5
        _FinchClipScroll(content: VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                switch _FinchSectionPart(child) {
                case .header:
                    child.font(.subheadline.weight(.semibold)).foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8 + inset).padding(.top, index == 0 ? 2 : 10).padding(.bottom, 2)
                case .footer:
                    child.font(.footnote).foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8 + inset).padding(.vertical, 2)
                case .row:
                    row(child, index: index, inset: inset, radius: radius)
                }
            }
        }
        .padding(.vertical, style.kind == .plain ? 0 : 6))
        .background(background)
        .overlay(style.kind == .bordered ? Rectangle().stroke(Color(nsColor: .separatorColor)) : nil)
        .clipped()
    }

    @ViewBuilder
    private func row(_ child: _VariadicView.Children.Element, index: Int, inset: CGFloat, radius: CGFloat) -> some View {
                let value = _finchTag(of: child, as: Value.self)
                let selected = value.map(selection.isSelected) ?? false
                let alternate = style.alternatesRowBackgrounds && index % 2 == 1
                child
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(selected ? Color.accentColor
                                           : alternate ? Color.primary.opacity(0.04) : Color.clear)
                    )
                    .padding(.horizontal, inset)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let value { selection.select(value) }
                    }
    }

    private var background: Color {
        switch style.kind {
        case .plain: Color.clear
        case .sidebar: Color(nsColor: .underPageBackgroundColor)
        case .inset, .bordered: Color(nsColor: .controlBackgroundColor)
        }
    }
}

// MARK: - Rows from data

@available(OpenSwiftUI_v1_0, *)
extension List {
    @available(OpenSwiftUI_v4_0, *)
    @_disfavoredOverload
    nonisolated public init<Data, RowContent>(_ data: Data, selection: Binding<SelectionValue>,
                                              @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, Data.Element.ID, RowContent>, Data: RandomAccessCollection, RowContent: View,
        Data.Element: Identifiable {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data, content: rowContent))
    }

    @available(OpenSwiftUI_v4_0, *)
    @_disfavoredOverload
    nonisolated public init<Data, ID, RowContent>(_ data: Data, id: KeyPath<Data.Element, ID>, selection: Binding<SelectionValue>,
                                                  @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, ID, RowContent>, Data: RandomAccessCollection, ID: Hashable, RowContent: View {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data, id: id, content: rowContent))
    }

    @_semantics("swiftui.requires_constant_range")
    nonisolated public init<RowContent>(_ data: Range<Int>, selection: Binding<Set<SelectionValue>>?,
                                        @ViewBuilder rowContent: @escaping (Int) -> RowContent)
        where Content == ForEach<Range<Int>, Int, HStack<RowContent>>, RowContent: View {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data) { item in HStack { rowContent(item) } })
    }

    @available(OpenSwiftUI_v4_0, *)
    @_semantics("swiftui.requires_constant_range")
    @_disfavoredOverload
    nonisolated public init<RowContent>(_ data: Range<Int>, selection: Binding<SelectionValue>,
                                        @ViewBuilder rowContent: @escaping (Int) -> RowContent)
        where Content == ForEach<Range<Int>, Int, HStack<RowContent>>, RowContent: View {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data) { item in HStack { rowContent(item) } })
    }

    // what apps built before rows lost their HStack still call

    @usableFromInline
    @_disfavoredOverload
    nonisolated init<Data, RowContent>(_ data: Data, selection: Binding<Set<SelectionValue>>?,
                                       @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, Data.Element.ID, HStack<RowContent>>, Data: RandomAccessCollection, RowContent: View,
        Data.Element: Identifiable {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data) { item in HStack { rowContent(item) } })
    }

    @usableFromInline
    @_disfavoredOverload
    nonisolated init<Data, ID, RowContent>(_ data: Data, id: KeyPath<Data.Element, ID>, selection: Binding<Set<SelectionValue>>?,
                                           @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, ID, HStack<RowContent>>, Data: RandomAccessCollection, ID: Hashable, RowContent: View {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data, id: id) { item in HStack { rowContent(item) } })
    }

    @usableFromInline
    @_disfavoredOverload
    nonisolated init<Data, RowContent>(_ data: Data, selection: Binding<SelectionValue?>?,
                                       @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, Data.Element.ID, HStack<RowContent>>, Data: RandomAccessCollection, RowContent: View,
        Data.Element: Identifiable {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data) { item in HStack { rowContent(item) } })
    }

    @usableFromInline
    @_disfavoredOverload
    nonisolated init<Data, ID, RowContent>(_ data: Data, id: KeyPath<Data.Element, ID>, selection: Binding<SelectionValue?>?,
                                           @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, ID, HStack<RowContent>>, Data: RandomAccessCollection, ID: Hashable, RowContent: View {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data, id: id) { item in HStack { rowContent(item) } })
    }

    @usableFromInline
    @_disfavoredOverload
    @_semantics("swiftui.requires_constant_range")
    nonisolated init<RowContent>(_ data: Range<Int>, selection: Binding<SelectionValue?>?,
                                 @ViewBuilder rowContent: @escaping (Int) -> RowContent)
        where Content == ForEach<Range<Int>, Int, HStack<RowContent>>, RowContent: View {
        self.init(selection: _FinchListSelection(selection), content: ForEach(data) { item in HStack { rowContent(item) } })
    }
}

@available(OpenSwiftUI_v1_0, *)
extension List where SelectionValue == Never {
    nonisolated public init(@ViewBuilder content: () -> Content) {
        self.init(selection: .none, content: content())
    }

    @usableFromInline
    @_disfavoredOverload
    nonisolated init<Data, RowContent>(_ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, Data.Element.ID, HStack<RowContent>>, Data: RandomAccessCollection, RowContent: View,
        Data.Element: Identifiable {
        self.init(selection: .none, content: ForEach(data) { item in HStack { rowContent(item) } })
    }

    @usableFromInline
    @_disfavoredOverload
    nonisolated init<Data, ID, RowContent>(_ data: Data, id: KeyPath<Data.Element, ID>,
                                           @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, ID, HStack<RowContent>>, Data: RandomAccessCollection, ID: Hashable, RowContent: View {
        self.init(selection: .none, content: ForEach(data, id: id) { item in HStack { rowContent(item) } })
    }

    @usableFromInline
    @_semantics("swiftui.requires_constant_range")
    @_disfavoredOverload
    nonisolated init<RowContent>(_ data: Range<Int>, @ViewBuilder rowContent: @escaping (Int) -> RowContent)
        where Content == ForEach<Range<Int>, Int, HStack<RowContent>>, RowContent: View {
        self.init(selection: .none, content: ForEach(data) { item in HStack { rowContent(item) } })
    }
}
