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

/// A pop-up button's item: its title, and what to show when the title isn't a Text.
struct _FinchPopUpItem {
    var title: Text?
    var fallback: String
}

/// A pop-up button over NSPopUpButton, for a picker: an item for each option, the selected
/// one shown (none when the selection matches no option, or several).
struct _FinchPopUpButton: NSViewRepresentable {
    var items: [_FinchPopUpItem]
    var selectedIndex: Int?
    var select: (Int) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = items.map { $0.title?._resolveText(in: context.environment) ?? $0.fallback }
        if button.itemArray.map(\.title) != titles {
            // items one by one: addItems(withTitles:) merges items with the same title
            button.removeAllItems()
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        let index = selectedIndex ?? -1
        if button.indexOfSelectedItem != index { button.selectItem(at: index) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchPopUpButton
        init(_ parent: _FinchPopUpButton) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            if index >= 0 && index < parent.items.count { parent.select(index) }
        }
    }
}

/// A segmented control over NSSegmentedControl, for a segmented picker: a segment for each
/// option, the selected one selected.
struct _FinchSegmentedControl: NSViewRepresentable {
    var items: [_FinchPopUpItem]
    var selectedIndex: Int?
    var select: (Int) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.changed(_:)))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let titles = items.map { $0.title?._resolveText(in: context.environment) ?? $0.fallback }
        if control.segmentCount != titles.count {
            control.segmentCount = titles.count
        }
        for (index, title) in titles.enumerated() where control.label(forSegment: index) != title {
            control.setLabel(title, forSegment: index)
        }
        let index = selectedIndex ?? -1
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchSegmentedControl
        init(_ parent: _FinchSegmentedControl) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            if index >= 0 && index < parent.items.count { parent.select(index) }
        }
    }
}

/// A radio button over NSButton, for a radio group picker's option.
struct _FinchRadioButton: NSViewRepresentable {
    var item: _FinchPopUpItem
    var isOn: Bool
    var select: () -> Void

    func makeNSView(context: Context) -> NSButton {
        NSButton(radioButtonWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        let title = item.title?._resolveText(in: context.environment) ?? item.fallback
        if button.title != title { button.title = title }
        let state: NSControl.StateValue = isOn ? .on : .off
        if button.state != state { button.state = state }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: _FinchRadioButton
        init(_ parent: _FinchRadioButton) { self.parent = parent }

        @objc func clicked(_ sender: NSButton) { parent.select() }
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
    /// How the field is framed: a square bezel (the default), a rounded one, or none.
    enum Border {
        case square, rounded, none
    }

    var model: _FinchTextFieldModel
    var border: Border = .square

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: model.get())
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.isEditable = true
        field.usesSingleLineMode = !model.multiline
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        switch border {
        case .square, .rounded:
            if !field.isBezeled { field.isBezeled = true }
            if !field.drawsBackground { field.drawsBackground = true }
            let style: NSTextField.BezelStyle = border == .rounded ? .roundedBezel : .squareBezel
            if field.bezelStyle != style { field.bezelStyle = style }
        case .none:
            if field.isBezeled { field.isBezeled = false }
            if field.isBordered { field.isBordered = false }
            if field.drawsBackground { field.drawsBackground = false }
        }
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
