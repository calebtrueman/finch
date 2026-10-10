// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Button, to Apple's interface: a label that performs its action, drawn by the button style
// in force (on macOS, the bordered push button unless a style says otherwise; see
// ButtonStyles.swift). Upstream's is an empty placeholder.

import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct Button<Label>: View where Label: View {
    var action: () -> Void
    var role: ButtonRole?
    var label: Label

    nonisolated init(role: ButtonRole?, action: @escaping () -> Void, label: Label) {
        self.role = role
        self.action = action
        self.label = label
    }

    @preconcurrency
    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.init(role: nil, action: { MainActor.assumeIsolated { action() } }, label: label())
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchStyledButton(configuration: PrimitiveButtonStyleConfiguration(role: role, action: action), label: label)
    }
}

@available(*, unavailable)
extension Button: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension Button where Label == Text {
    @preconcurrency
    nonisolated public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {
        self.init(role: nil, action: { MainActor.assumeIsolated { action() } }, label: Text(titleKey))
    }

    @preconcurrency
    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, action: @escaping @MainActor () -> Void) where S: StringProtocol {
        self.init(role: nil, action: { MainActor.assumeIsolated { action() } }, label: Text(title))
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Button where Label == PrimitiveButtonStyleConfiguration.Label {
    /// The button a primitive style is styling, as the styles outside it make it.
    nonisolated public init(_ configuration: PrimitiveButtonStyleConfiguration) {
        self.init(role: configuration.role, action: configuration.trigger, label: configuration.label)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension Button {
    @preconcurrency
    nonisolated public init(role: ButtonRole?, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.init(role: role, action: { MainActor.assumeIsolated { action() } }, label: label())
    }
}

@available(OpenSwiftUI_v3_0, *)
extension Button where Label == Text {
    @preconcurrency
    nonisolated public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: { MainActor.assumeIsolated { action() } }, label: Text(titleKey))
    }

    @preconcurrency
    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void)
        where S: StringProtocol {
        self.init(role: role, action: { MainActor.assumeIsolated { action() } }, label: Text(title))
    }
}
