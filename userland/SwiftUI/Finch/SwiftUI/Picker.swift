// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Picker, to Apple's interface: on macOS (the default, menu style), the label beside an AppKit
// pop-up button with an item for each option. The options are the content's views; each is
// chosen by its tag (`View.tag(_:)`), or by its identity in a ForEach when untagged, as
// Apple's are. With several sources, the button shows the value they share, or none.

import SwiftUICore

/// What a picker selects: the selected values of its sources (one for a plain binding), and
/// how to select a value in all of them.
struct _FinchPickerSelection<Value: Hashable> {
    var get: () -> [Value]
    var set: (Value) -> Void

    init(_ binding: Binding<Value>) {
        get = { [binding.wrappedValue] }
        set = { binding.wrappedValue = $0 }
    }

    init<C>(sources: C, selection: KeyPath<C.Element, Binding<Value>>) where C: RandomAccessCollection {
        get = { sources.map { $0[keyPath: selection].wrappedValue } }
        set = { value in sources.forEach { $0[keyPath: selection].wrappedValue = value } }
    }
}

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct Picker<Label, SelectionValue, Content>: View where Label: View, SelectionValue: Hashable, Content: View {
    var selection: _FinchPickerSelection<SelectionValue>
    var label: Label
    var content: Content

    nonisolated init(selection: _FinchPickerSelection<SelectionValue>, label: Label, content: Content) {
        self.selection = selection
        self.label = label
        self.content = content
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        HStack(spacing: 6) {
            label
            _VariadicView.Tree(_FinchPickerRoot(selection: selection, titles: _finchOptionTitles(content))) {
                content
            }
        }
    }
}

@available(*, unavailable)
extension Picker: Sendable {}

/// The pop-up button, over the options as variadic children.
struct _FinchPickerRoot<Value: Hashable>: _VariadicView_UnaryViewRoot {
    var selection: _FinchPickerSelection<Value>
    var titles: [Text?]

    func body(children: _VariadicView.Children) -> some View {
        let values = children.map { _finchTag(of: $0, as: Value.self) }
        let selected = Set(selection.get())
        let items = values.indices.map { index in
            _FinchPopUpItem(title: index < titles.count ? titles[index] : nil,
                            fallback: values[index].map { String(describing: $0) } ?? "")
        }
        return _FinchPopUpButton(items: items,
                                 selectedIndex: selected.count == 1 ? values.firstIndex { $0 == selected.first } : nil,
                                 select: { index in
                                     if let value = values[index] { selection.set(value) }
                                 })
            .fixedSize()
    }
}

/// A child's tag as `Value`, or its identity when it is untagged (a ForEach's element).
func _finchTag<Value: Hashable>(of child: _VariadicView.Children.Element, as _: Value.Type) -> Value? {
    if case let .tagged(value) = child[TagValueTraitKey<Value>.self] {
        return value
    }
    return child.id(as: Value.self)
}

// MARK: - Initializers

@available(OpenSwiftUI_v1_0, *)
extension Picker {
    nonisolated public init(selection: Binding<SelectionValue>, label: Label, @ViewBuilder content: () -> Content) {
        self.init(selection: _FinchPickerSelection(selection), label: label, content: content())
    }

    @available(OpenSwiftUI_v4_0, *)
    nonisolated public init<C>(sources: C, selection: KeyPath<C.Element, Binding<SelectionValue>>,
                               @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label)
        where C: RandomAccessCollection {
        self.init(selection: _FinchPickerSelection(sources: sources, selection: selection), label: label(), content: content())
    }

    @available(OpenSwiftUI_v6_0, *)
    nonisolated public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content,
                            @ViewBuilder label: () -> Label, @ViewBuilder currentValueLabel: () -> some View) {
        self.init(selection: _FinchPickerSelection(selection), label: label(), content: content())
    }

    @available(OpenSwiftUI_v6_0, *)
    nonisolated public init<C>(sources: C, selection: KeyPath<C.Element, Binding<SelectionValue>>,
                               @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label,
                               @ViewBuilder currentValueLabel: () -> some View) where C: RandomAccessCollection {
        self.init(selection: _FinchPickerSelection(sources: sources, selection: selection), label: label(), content: content())
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Picker where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>,
                            @ViewBuilder content: () -> Content) {
        self.init(selection: _FinchPickerSelection(selection), label: Text(titleKey), content: content())
    }

    @available(OpenSwiftUI_v4_0, *)
    nonisolated public init<C>(_ titleKey: LocalizedStringKey, sources: C, selection: KeyPath<C.Element, Binding<SelectionValue>>,
                               @ViewBuilder content: () -> Content) where C: RandomAccessCollection {
        self.init(selection: _FinchPickerSelection(sources: sources, selection: selection), label: Text(titleKey),
                  content: content())
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content)
        where S: StringProtocol {
        self.init(selection: _FinchPickerSelection(selection), label: Text(title), content: content())
    }

    @available(OpenSwiftUI_v4_0, *)
    @_disfavoredOverload
    nonisolated public init<C, S>(_ title: S, sources: C, selection: KeyPath<C.Element, Binding<SelectionValue>>,
                                  @ViewBuilder content: () -> Content) where C: RandomAccessCollection, S: StringProtocol {
        self.init(selection: _FinchPickerSelection(sources: sources, selection: selection), label: Text(title),
                  content: content())
    }

    @available(OpenSwiftUI_v6_0, *)
    nonisolated public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>,
                            @ViewBuilder content: () -> Content, @ViewBuilder currentValueLabel: () -> some View) {
        self.init(selection: _FinchPickerSelection(selection), label: Text(titleKey), content: content())
    }

    @available(OpenSwiftUI_v6_0, *)
    nonisolated public init<C>(_ titleKey: LocalizedStringKey, sources: C, selection: KeyPath<C.Element, Binding<SelectionValue>>,
                               @ViewBuilder content: () -> Content, @ViewBuilder currentValueLabel: () -> some View)
        where C: RandomAccessCollection {
        self.init(selection: _FinchPickerSelection(sources: sources, selection: selection), label: Text(titleKey),
                  content: content())
    }

    @available(OpenSwiftUI_v6_0, *)
    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content,
                               @ViewBuilder currentValueLabel: () -> some View) where S: StringProtocol {
        self.init(selection: _FinchPickerSelection(selection), label: Text(title), content: content())
    }

    @available(OpenSwiftUI_v6_0, *)
    @_disfavoredOverload
    nonisolated public init<C, S>(_ title: S, sources: C, selection: KeyPath<C.Element, Binding<SelectionValue>>,
                                  @ViewBuilder content: () -> Content, @ViewBuilder currentValueLabel: () -> some View)
        where C: RandomAccessCollection, S: StringProtocol {
        self.init(selection: _FinchPickerSelection(sources: sources, selection: selection), label: Text(title),
                  content: content())
    }
}
