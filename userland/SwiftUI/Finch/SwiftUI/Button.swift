// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Button, to Apple's interface: a label that performs its action when tapped. Upstream's is
// an empty placeholder. Button styles come later; the label is drawn as given.

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct Button<Label>: View where Label: View {
    var action: @MainActor () -> Void
    var label: Label

    @preconcurrency
    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        label
            .contentShape(Rectangle())
            .onTapGesture { action() }
    }
}

@available(*, unavailable)
extension Button: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension Button where Label == Text {
    @preconcurrency
    nonisolated public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.label = Text(titleKey)
    }

    @preconcurrency
    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, action: @escaping @MainActor () -> Void) where S: StringProtocol {
        self.action = action
        self.label = Text(title)
    }
}
