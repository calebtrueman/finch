// SPDX-License-Identifier: MIT OR Apache-2.0
//
// TextField, to Apple's interface: on macOS, an AppKit text field. Its title is the
// placeholder when there is no prompt, as Apple's is on macOS. Formatted values go
// through their format style or formatter: the field shows the formatted value and sets
// the binding when what is typed parses. (Text selection bindings aren't there yet.)

public import Foundation
import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct TextField<Label>: View where Label: View {
    var model: _FinchTextFieldModel
    var label: Label

    nonisolated init(model: _FinchTextFieldModel, label: Label) {
        self.model = model
        self.label = label
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchStyledTextField(model: model, label: label)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension TextField where Label == _TextFieldStyleLabel {
    /// The field a style is styling: drawn as the default field, under the style's own views.
    var _finchStyledField: some View {
        _FinchTextField(model: model, border: .square)
    }
}

// MARK: - Styles

@available(OpenSwiftUI_v1_0, *)
public protocol TextFieldStyle {
    associatedtype _Body: View
    @ViewBuilder func _body(configuration: TextField<Self._Label>) -> Self._Body
    typealias _Label = _TextFieldStyleLabel
}

@available(OpenSwiftUI_v1_0, *)
public struct _TextFieldStyleLabel: ViewAlias {
    public typealias Body = Never
    package init() {}
}

@available(*, unavailable)
extension _TextFieldStyleLabel: Sendable {}

/// A text field style as the field applies it.
struct _FinchAnyTextFieldStyle: @unchecked Sendable {
    let body: (TextField<_TextFieldStyleLabel>) -> AnyView
    /// The bezel of Finch's own styles, which draw the field themselves.
    let border: _FinchTextField.Border?

    init<S: TextFieldStyle>(_ style: S) {
        body = { AnyView(style._body(configuration: $0)) }
        border = (style as? any _FinchTextFieldStyle)?.border
    }
}

protocol _FinchTextFieldStyle: TextFieldStyle {
    var border: _FinchTextField.Border { get }
}

private struct _FinchTextFieldStylesKey: EnvironmentKey {
    static var defaultValue: [_FinchAnyTextFieldStyle] { [] }
}

extension EnvironmentValues {
    var _finchTextFieldStyles: [_FinchAnyTextFieldStyle] {
        get { self[_FinchTextFieldStylesKey.self] }
        set { self[_FinchTextFieldStylesKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func textFieldStyle<S>(_ style: S) -> some View where S: TextFieldStyle {
        transformEnvironment(\._finchTextFieldStyles) { $0.append(_FinchAnyTextFieldStyle(style)) }
    }
}

/// A text field as the style in force makes it: Finch's styles set the field's bezel; another
/// style's views wrap the field, drawn with the styles outside it.
struct _FinchStyledTextField<Label: View>: View {
    var model: _FinchTextFieldModel
    var label: Label
    @Environment(\._finchTextFieldStyles) private var styles

    var body: some View {
        if let style = styles.last, style.border == nil {
            return AnyView(style.body(TextField(model: model, label: _TextFieldStyleLabel()))
                .environment(\._finchTextFieldStyles, Array(styles.dropLast()))
                .viewAlias(_TextFieldStyleLabel.self) { label })
        } else {
            return AnyView(_FinchTextField(model: model, border: styles.last?.border ?? .square))
        }
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct DefaultTextFieldStyle: TextFieldStyle, _FinchTextFieldStyle {
    public init() {}
    public func _body(configuration: TextField<_Label>) -> some View { configuration._finchStyledField }
    var border: _FinchTextField.Border { .square }
}

@available(OpenSwiftUI_v1_0, *)
public struct RoundedBorderTextFieldStyle: TextFieldStyle, _FinchTextFieldStyle {
    public init() {}
    public func _body(configuration: TextField<_Label>) -> some View { configuration._finchStyledField }
    var border: _FinchTextField.Border { .rounded }
}

@available(OpenSwiftUI_v1_0, *)
public struct PlainTextFieldStyle: TextFieldStyle, _FinchTextFieldStyle {
    public init() {}
    public func _body(configuration: TextField<_Label>) -> some View { configuration._finchStyledField }
    var border: _FinchTextField.Border { .none }
}

@available(OpenSwiftUI_v1_0, *)
public struct SquareBorderTextFieldStyle: TextFieldStyle, _FinchTextFieldStyle {
    public init() {}
    public func _body(configuration: TextField<_Label>) -> some View { configuration._finchStyledField }
    var border: _FinchTextField.Border { .square }
}

@available(*, unavailable) extension DefaultTextFieldStyle: Sendable {}
@available(*, unavailable) extension RoundedBorderTextFieldStyle: Sendable {}
@available(*, unavailable) extension PlainTextFieldStyle: Sendable {}
@available(*, unavailable) extension SquareBorderTextFieldStyle: Sendable {}

extension TextFieldStyle where Self == DefaultTextFieldStyle {
    @_alwaysEmitIntoClient public static var automatic: DefaultTextFieldStyle { .init() }
}

extension TextFieldStyle where Self == RoundedBorderTextFieldStyle {
    @_alwaysEmitIntoClient public static var roundedBorder: RoundedBorderTextFieldStyle { .init() }
}

extension TextFieldStyle where Self == PlainTextFieldStyle {
    @_alwaysEmitIntoClient public static var plain: PlainTextFieldStyle { .init() }
}

extension TextFieldStyle where Self == SquareBorderTextFieldStyle {
    @_alwaysEmitIntoClient public static var squareBorder: SquareBorderTextFieldStyle { .init() }
}

@available(*, unavailable)
extension TextField: Sendable {}

// MARK: - Text

private func textModel(_ text: Binding<String>, placeholder: Text?, multiline: Bool = false,
                       onEditingChanged: @escaping (Bool) -> Void = { _ in },
                       onCommit: @escaping () -> Void = {}) -> _FinchTextFieldModel {
    _FinchTextFieldModel(get: { text.wrappedValue }, set: { text.wrappedValue = $0 }, placeholder: placeholder,
                         onEditingChanged: onEditingChanged, onCommit: onCommit, multiline: multiline)
}

@available(OpenSwiftUI_v1_0, *)
extension TextField where Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, text: Binding<String>, onEditingChanged: @escaping (Bool) -> Void,
                            onCommit: @escaping () -> Void) {
        let title = Text(titleKey)
        self.init(model: textModel(text, placeholder: title, onEditingChanged: onEditingChanged, onCommit: onCommit), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, text: Binding<String>, onEditingChanged: @escaping (Bool) -> Void,
                               onCommit: @escaping () -> Void) where S: StringProtocol {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: label, onEditingChanged: onEditingChanged, onCommit: onCommit), label: label)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {
        let title = Text(titleKey)
        self.init(model: textModel(text, placeholder: prompt ?? title), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, text: Binding<String>, prompt: Text?) where S: StringProtocol {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: prompt ?? label), label: label)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) {
        let title = Text(titleKey)
        self.init(model: textModel(text, placeholder: title, multiline: axis == .vertical), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, text: Binding<String>, axis: Axis) where S: StringProtocol {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: label, multiline: axis == .vertical), label: label)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?, axis: Axis) {
        let title = Text(titleKey)
        self.init(model: textModel(text, placeholder: prompt ?? title, multiline: axis == .vertical), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, text: Binding<String>, prompt: Text?, axis: Axis) where S: StringProtocol {
        let label = Text(title)
        self.init(model: textModel(text, placeholder: prompt ?? label, multiline: axis == .vertical), label: label)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension TextField {
    nonisolated public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        self.init(model: textModel(text, placeholder: prompt), label: label())
    }

    nonisolated public init(text: Binding<String>, prompt: Text? = nil, axis: Axis, @ViewBuilder label: () -> Label) {
        self.init(model: textModel(text, placeholder: prompt, multiline: axis == .vertical), label: label())
    }
}

// MARK: - Formatted values

private func formatModel<F>(_ value: Binding<F.FormatInput>, format: F, placeholder: Text?) -> _FinchTextFieldModel
    where F: ParseableFormatStyle, F.FormatOutput == String {
    _FinchTextFieldModel(get: { format.format(value.wrappedValue) }, set: { s in
        if let v = try? format.parseStrategy.parse(s) { value.wrappedValue = v }
    }, placeholder: placeholder)
}

private func optionalFormatModel<F>(_ value: Binding<F.FormatInput?>, format: F, placeholder: Text?) -> _FinchTextFieldModel
    where F: ParseableFormatStyle, F.FormatOutput == String {
    _FinchTextFieldModel(get: { value.wrappedValue.map { format.format($0) } ?? "" }, set: { s in
        value.wrappedValue = s.isEmpty ? nil : try? format.parseStrategy.parse(s)
    }, placeholder: placeholder)
}

private func formatterModel<V>(_ value: Binding<V>, formatter: Formatter, placeholder: Text?,
                               onEditingChanged: @escaping (Bool) -> Void = { _ in },
                               onCommit: @escaping () -> Void = {}) -> _FinchTextFieldModel {
    _FinchTextFieldModel(get: { formatter.string(for: value.wrappedValue) ?? "" }, set: { s in
        var object: AnyObject?
        if formatter.getObjectValue(&object, for: s, errorDescription: nil), let v = object as? V {
            value.wrappedValue = v
        }
    }, placeholder: placeholder, onEditingChanged: onEditingChanged, onCommit: onCommit)
}

@available(OpenSwiftUI_v3_0, *)
extension TextField where Label == Text {
    nonisolated public init<F>(_ titleKey: LocalizedStringKey, value: Binding<F.FormatInput>, format: F, prompt: Text? = nil)
        where F: ParseableFormatStyle, F.FormatOutput == String {
        let title = Text(titleKey)
        self.init(model: formatModel(value, format: format, placeholder: prompt ?? title), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S, F>(_ title: S, value: Binding<F.FormatInput>, format: F, prompt: Text? = nil)
        where S: StringProtocol, F: ParseableFormatStyle, F.FormatOutput == String {
        let label = Text(title)
        self.init(model: formatModel(value, format: format, placeholder: prompt ?? label), label: label)
    }

    nonisolated public init<F>(_ titleKey: LocalizedStringKey, value: Binding<F.FormatInput?>, format: F, prompt: Text? = nil)
        where F: ParseableFormatStyle, F.FormatOutput == String {
        let title = Text(titleKey)
        self.init(model: optionalFormatModel(value, format: format, placeholder: prompt ?? title), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S, F>(_ title: S, value: Binding<F.FormatInput?>, format: F, prompt: Text? = nil)
        where S: StringProtocol, F: ParseableFormatStyle, F.FormatOutput == String {
        let label = Text(title)
        self.init(model: optionalFormatModel(value, format: format, placeholder: prompt ?? label), label: label)
    }

    nonisolated public init<V>(_ titleKey: LocalizedStringKey, value: Binding<V>, formatter: Formatter, prompt: Text?) {
        let title = Text(titleKey)
        self.init(model: formatterModel(value, formatter: formatter, placeholder: prompt ?? title), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S, V>(_ title: S, value: Binding<V>, formatter: Formatter, prompt: Text?) where S: StringProtocol {
        let label = Text(title)
        self.init(model: formatterModel(value, formatter: formatter, placeholder: prompt ?? label), label: label)
    }

    nonisolated public init<V>(_ titleKey: LocalizedStringKey, value: Binding<V>, formatter: Formatter,
                               onEditingChanged: @escaping (Bool) -> Void, onCommit: @escaping () -> Void) {
        let title = Text(titleKey)
        self.init(model: formatterModel(value, formatter: formatter, placeholder: title, onEditingChanged: onEditingChanged,
                                        onCommit: onCommit), label: title)
    }

    @_disfavoredOverload
    nonisolated public init<S, V>(_ title: S, value: Binding<V>, formatter: Formatter,
                                  onEditingChanged: @escaping (Bool) -> Void, onCommit: @escaping () -> Void)
        where S: StringProtocol {
        let label = Text(title)
        self.init(model: formatterModel(value, formatter: formatter, placeholder: label, onEditingChanged: onEditingChanged,
                                        onCommit: onCommit), label: label)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension TextField {
    nonisolated public init<F>(value: Binding<F.FormatInput>, format: F, prompt: Text? = nil, @ViewBuilder label: () -> Label)
        where F: ParseableFormatStyle, F.FormatOutput == String {
        self.init(model: formatModel(value, format: format, placeholder: prompt), label: label())
    }

    nonisolated public init<F>(value: Binding<F.FormatInput?>, format: F, prompt: Text? = nil, @ViewBuilder label: () -> Label)
        where F: ParseableFormatStyle, F.FormatOutput == String {
        self.init(model: optionalFormatModel(value, format: format, placeholder: prompt), label: label())
    }

    nonisolated public init<V>(value: Binding<V>, formatter: Formatter, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        self.init(model: formatterModel(value, formatter: formatter, placeholder: prompt), label: label())
    }
}
