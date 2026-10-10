// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The AppKit controls SwiftUI's controls show on macOS, as Apple's do: a checkbox for a
// toggle, a text field for TextField. Each is an NSViewRepresentable over Finch's AppKit,
// bound to the control's state.

#if os(macOS)
import AppKit

/// A checkbox without a title (the toggle's label is drawn beside it).
struct _FinchCheckbox: NSViewRepresentable {
    @Binding var state: ToggleState

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator,
                              action: #selector(Coordinator.changed(_:)))
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        let value: NSControl.StateValue = switch state {
        case .on: .on
        case .off: .off
        case .mixed: .mixed
        }
        if button.state != value { button.state = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchCheckbox
        init(_ parent: _FinchCheckbox) { self.parent = parent }

        @objc func changed(_ sender: NSButton) {
            // a click on a mixed checkbox turns it on, as AppKit's does
            parent.state = sender.state == .off ? .off : .on
        }
    }
}

/// A horizontal slider over NSSlider, its value from 0 to 1 (a Slider's value, normalized
/// to its bounds), with tick marks it stops on when the slider has steps.
struct _FinchSlider: NSViewRepresentable {
    @Binding var value: Double
    var discreteValueCount: Int
    var onEditingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: context.coordinator,
                              action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if slider.numberOfTickMarks != discreteValueCount {
            slider.numberOfTickMarks = discreteValueCount
            slider.allowsTickMarkValuesOnly = discreteValueCount > 0
        }
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchSlider
        var editing = false
        init(_ parent: _FinchSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            if !editing {
                editing = true
                parent.onEditingChanged(true)
            }
            parent.value = sender.doubleValue
            // a continuous slider's last action is sent as the mouse goes up
            if NSApp.currentEvent?.type != .leftMouseDragged && NSApp.currentEvent?.type != .leftMouseDown {
                editing = false
                parent.onEditingChanged(false)
            }
        }
    }
}

/// What a TextField edits: its text (through get and set, so formatted values work too),
/// its placeholder, and what to tell as editing begins, ends and is committed.
struct _FinchTextFieldModel {
    var get: () -> String
    var set: (String) -> Void
    var placeholder: Text?
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var multiline = false
}

/// An editable text field over NSTextField.
struct _FinchTextField: NSViewRepresentable {
    var model: _FinchTextFieldModel

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: model.get())
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.isBordered = true
        field.isBezeled = true
        field.isEditable = true
        field.usesSingleLineMode = !model.multiline
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let text = model.get()
        // don't disturb the field while it is being edited to the same text
        if field.stringValue != text { field.stringValue = text }
        let placeholder = model.placeholder?._resolveText(in: context.environment)
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: _FinchTextField
        init(_ parent: _FinchTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) { parent.model.onEditingChanged(true) }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.model.set(field.stringValue)
        }

        func controlTextDidEndEditing(_ obj: Notification) { parent.model.onEditingChanged(false) }

        @objc func commit(_ sender: NSTextField) {
            parent.model.set(sender.stringValue)
            parent.model.onCommit()
        }
    }
}
#endif
