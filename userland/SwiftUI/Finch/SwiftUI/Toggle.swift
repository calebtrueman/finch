// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Toggle, to Apple's interface: on macOS, a checkbox with the label beside it (the default
// toggle style). Upstream's resolves through toggle styles that aren't finished; this
// replaces it, keeping its state: one Bool, or several shown as mixed when they differ.

import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct Toggle<Label>: View where Label: View {
    @Binding var toggleState: ToggleState
    var label: Label

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.init(toggledOn: [isOn], label: label)
    }

    @available(OpenSwiftUI_v4_0, *)
    public init<C>(sources: C, isOn: KeyPath<C.Element, Binding<Bool>>, @ViewBuilder label: () -> Label)
        where C: RandomAccessCollection {
        self.init(toggledOn: sources.lazy.map { $0[keyPath: isOn] }, label: label)
    }

    nonisolated init<C>(toggledOn: C, @ViewBuilder label: () -> Label) where C: Collection, C.Element == Binding<Bool> {
        self.label = label()
        _toggleState = Binding(get: {
            ToggleState.stateFor(item: true, in: toggledOn)
        }, set: { value in
            for binding in toggledOn {
                binding.wrappedValue = value == .on
            }
        })
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        HStack(spacing: 6) {
            _FinchCheckbox(state: $toggleState).fixedSize()
            label
        }
    }
}

@available(*, unavailable)
extension Toggle: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension Toggle where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(toggledOn: [isOn]) { Text(titleKey) }
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, isOn: Binding<Bool>) where S: StringProtocol {
        self.init(toggledOn: [isOn]) { Text(title) }
    }

    @available(OpenSwiftUI_v4_0, *)
    nonisolated public init<C>(_ titleKey: LocalizedStringKey, sources: C, isOn: KeyPath<C.Element, Binding<Bool>>)
        where C: RandomAccessCollection {
        self.init(toggledOn: sources.lazy.map { $0[keyPath: isOn] }) { Text(titleKey) }
    }

    @available(OpenSwiftUI_v4_0, *)
    @_disfavoredOverload
    nonisolated public init<S, C>(_ title: S, sources: C, isOn: KeyPath<C.Element, Binding<Bool>>)
        where S: StringProtocol, C: RandomAccessCollection {
        self.init(toggledOn: sources.lazy.map { $0[keyPath: isOn] }) { Text(title) }
    }
}
