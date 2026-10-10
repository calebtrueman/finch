// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Button styles, to Apple's interface: `buttonStyle(_:)` for primitive and plain styles, and
// the system styles as they look on macOS. The automatic style is the bordered push button;
// bordered and prominent buttons draw their bezel with AppKit's button cell, so they look as
// Finch's push buttons do. A style's `Button(configuration)` is the button as the styles
// around it make it, as Apple's is: each style is applied with the ones outside it in force.

import AppKit
import SwiftUICore

// MARK: - Styles in the environment

/// A button style, primitive or not, as the button applies it.
struct _FinchAnyButtonStyle: @unchecked Sendable {
    let body: (PrimitiveButtonStyleConfiguration) -> AnyView

    init<S: PrimitiveButtonStyle>(primitive style: S) {
        body = { AnyView(style.makeBody(configuration: $0)) }
    }

    init<S: ButtonStyle>(_ style: S) {
        body = { AnyView(_FinchButtonStyleHost(style: style, configuration: $0)) }
    }
}

private struct _FinchButtonStylesKey: EnvironmentKey {
    static var defaultValue: [_FinchAnyButtonStyle] { [] }
}

extension EnvironmentValues {
    /// The button styles in force, innermost last.
    var _finchButtonStyles: [_FinchAnyButtonStyle] {
        get { self[_FinchButtonStylesKey.self] }
        set { self[_FinchButtonStylesKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func buttonStyle<S>(_ style: S) -> some View where S: PrimitiveButtonStyle {
        transformEnvironment(\._finchButtonStyles) { $0.append(_FinchAnyButtonStyle(primitive: style)) }
    }

    nonisolated public func buttonStyle<S>(_ style: S) -> some View where S: ButtonStyle {
        transformEnvironment(\._finchButtonStyles) { $0.append(_FinchAnyButtonStyle(style)) }
    }
}

/// A button as its innermost style makes it, with the styles outside that one in force (for
/// the style's own `Button(configuration)`).
struct _FinchStyledButton<Label: View>: View {
    var configuration: PrimitiveButtonStyleConfiguration
    var label: Label
    @Environment(\._finchButtonStyles) private var styles

    var body: some View {
        let style = styles.last ?? _FinchAnyButtonStyle(primitive: DefaultButtonStyle())
        style.body(configuration)
            .environment(\._finchButtonStyles, Array(styles.dropLast()))
            .viewAlias(PrimitiveButtonStyleConfiguration.Label.self) { label }
    }
}

/// A `ButtonStyle` as a primitive one: the style's view, pressed while the mouse is down on
/// it, and the action when the mouse goes up over it.
struct _FinchButtonStyleHost<Style: ButtonStyle>: View {
    var style: Style
    var configuration: PrimitiveButtonStyleConfiguration
    @State private var isPressed = false

    var body: some View {
        style.makeBody(configuration: ButtonStyleConfiguration(isPressed: isPressed, role: configuration.role))
            .viewAlias(ButtonStyleConfiguration.Label.self) { configuration.label }
            .overlay(_FinchPressTracker(isPressed: $isPressed, action: configuration.trigger))
    }
}

/// Tracks the mouse over a button as AppKit's buttons do.
struct _FinchPressTracker: NSViewRepresentable {
    @Binding var isPressed: Bool
    var action: () -> Void

    final class TrackingView: NSView {
        var pressed: (Bool) -> Void = { _ in }
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            pressed(true)
        }

        override func mouseDragged(with event: NSEvent) {
            pressed(bounds.contains(convert(event.locationInWindow, from: nil)))
        }

        override func mouseUp(with event: NSEvent) {
            pressed(false)
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                action()
            }
        }
    }

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) {
        let binding = $isPressed
        view.pressed = { if binding.wrappedValue != $0 { binding.wrappedValue = $0 } }
        view.action = action
    }
}

// MARK: - The bordered bezel

/// A push button's bezel, drawn by AppKit's button cell.
struct _FinchBezel: NSViewRepresentable {
    var isPressed: Bool
    var isProminent: Bool
    var isEnabled: Bool

    final class BezelView: NSView {
        let cell = NSButtonCell(textCell: "")
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            cell.drawBezel(withFrame: bounds, in: self)
        }
    }

    func makeNSView(context: Context) -> BezelView {
        let view = BezelView()
        view.cell.bezelStyle = .push
        view.cell.setButtonType(.momentaryPushIn)
        return view
    }

    func updateNSView(_ view: BezelView, context: Context) {
        view.cell.isHighlighted = isPressed
        view.cell.isEnabled = isEnabled
        // the default button's bezel is the prominent one
        view.cell.keyEquivalent = isProminent ? "\r" : ""
        view.needsDisplay = true
    }
}

struct _FinchBorderedButtonStyle: ButtonStyle {
    var isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(minWidth: 32, minHeight: 22)
            .background(_FinchBezel(isPressed: configuration.isPressed, isProminent: isProminent, isEnabled: isEnabled))
    }
}

/// A button without a bezel: its label, dimmed while pressed.
struct _FinchUnborderedButtonStyle: ButtonStyle {
    var isLink: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isLink ? Color.accentColor : Color.primary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - The system styles

@available(OpenSwiftUI_v1_0, *)
public struct DefaultButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchButtonStyleHost(style: _FinchBorderedButtonStyle(isProminent: false), configuration: configuration)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct BorderedButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchButtonStyleHost(style: _FinchBorderedButtonStyle(isProminent: false), configuration: configuration)
    }
}

@available(OpenSwiftUI_v3_0, *)
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchButtonStyleHost(style: _FinchBorderedButtonStyle(isProminent: true), configuration: configuration)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct BorderlessButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchButtonStyleHost(style: _FinchUnborderedButtonStyle(isLink: false), configuration: configuration)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct PlainButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchButtonStyleHost(style: _FinchUnborderedButtonStyle(isLink: false), configuration: configuration)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct LinkButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _FinchButtonStyleHost(style: _FinchUnborderedButtonStyle(isLink: true), configuration: configuration)
    }
}

@available(*, unavailable) extension DefaultButtonStyle: Sendable {}
@available(*, unavailable) extension BorderedButtonStyle: Sendable {}
@available(*, unavailable) extension BorderedProminentButtonStyle: Sendable {}
@available(*, unavailable) extension BorderlessButtonStyle: Sendable {}
@available(*, unavailable) extension PlainButtonStyle: Sendable {}
@available(*, unavailable) extension LinkButtonStyle: Sendable {}

extension PrimitiveButtonStyle where Self == DefaultButtonStyle {
    @_alwaysEmitIntoClient
    public static var automatic: DefaultButtonStyle { .init() }
}

extension PrimitiveButtonStyle where Self == BorderedButtonStyle {
    @_alwaysEmitIntoClient
    public static var bordered: BorderedButtonStyle { .init() }
}

extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle {
    @_alwaysEmitIntoClient
    public static var borderedProminent: BorderedProminentButtonStyle { .init() }
}

extension PrimitiveButtonStyle where Self == BorderlessButtonStyle {
    @_alwaysEmitIntoClient
    public static var borderless: BorderlessButtonStyle { .init() }
}

extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    @_alwaysEmitIntoClient
    public static var plain: PlainButtonStyle { .init() }
}

extension PrimitiveButtonStyle where Self == LinkButtonStyle {
    @_alwaysEmitIntoClient
    public static var link: LinkButtonStyle { .init() }
}
