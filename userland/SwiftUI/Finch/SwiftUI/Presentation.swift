// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Sheets, alerts, confirmation dialogs and popovers, to Apple's interface, presented as
// Apple's are on macOS: a sheet is an AppKit sheet window over the presenting view's window,
// hosting the content; an alert or a confirmation dialog is an NSAlert sheet whose buttons
// are the actions' buttons; a popover is an NSPopover from the presenting view's bounds.
// A presentation follows its binding: set, it is shown; cleared (by the app, by `dismiss`,
// by a button), it goes away and `onDismiss` runs. The presented content inherits the
// presenter's environment values (as a scroll view's content does) and gets `dismiss`.

import AppKit
public import Foundation
import SwiftUICore

// MARK: - Dismissing

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public struct DismissAction {
    var action: (() -> Void)?

    @MainActor
    @preconcurrency
    public func callAsFunction() {
        action?()
    }
}

private struct _FinchDismissKey: EnvironmentKey {
    static var defaultValue: (() -> Void)? { nil }
}

@available(OpenSwiftUI_v3_0, *)
extension EnvironmentValues {
    /// Dismisses the presentation the view is in (nothing, outside one).
    public var dismiss: DismissAction {
        DismissAction(action: _finchDismiss)
    }

    /// Whether the view is in a presentation.
    public var isPresented: Bool {
        _finchDismiss != nil
    }

    var _finchDismiss: (() -> Void)? {
        get { self[_FinchDismissKey.self] }
        set { self[_FinchDismissKey.self] = newValue }
    }
}

// MARK: - Presenting

/// What a presenter shows while its binding is set.
enum _FinchPresentation {
    case sheet(content: () -> AnyView)
    case popover(content: () -> AnyView, arrowEdges: Edge.Set?)
    case alert(title: Text?, message: Text?, buttons: [_FinchAlertButton])
}

/// A button of an alert or a confirmation dialog.
struct _FinchAlertButton {
    var title: Text?
    var fallback = ""
    var action: () -> Void = {}
    var isCancel = false
    var isDestructive = false

    /// The buttons a dialog's actions describe (its buttons; an OK button when there are none).
    static func of(_ actions: Any?) -> [_FinchAlertButton] {
        let buttons = (actions.map(_finchMenuItemsOf) ?? []).compactMap { item -> _FinchAlertButton? in
            guard case let .action(action) = item.kind else { return nil }
            return _FinchAlertButton(title: item.title, fallback: item.fallback, action: action, isCancel: item.isCancel,
                                     isDestructive: item.isDestructive)
        }
        return buttons.isEmpty ? [_FinchAlertButton(fallback: "OK")] : buttons
    }
}

/// The text a message view shows, its texts joined.
func _finchMessageText(_ message: Any) -> Text? {
    let texts = _finchOptionTitles(message).compactMap { $0 }
    guard var text = texts.first else { return nil }
    for next in texts.dropFirst() {
        text = text + Text(verbatim: "\n") + next
    }
    return text
}

/// An AppKit view behind the presenting view that shows and dismisses its presentation as
/// the binding says. It takes no events.
struct _FinchPresenter: NSViewRepresentable {
    var isPresented: Binding<Bool>
    var presentation: () -> _FinchPresentation
    var onDismiss: (() -> Void)?

    /// A sheet: no title bar, as on macOS, and key while shown.
    final class SheetWindow: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>?
        var onDismiss: (() -> Void)?
        var sheet: NSWindow?
        var sheetController: NSHostingController<AnyView>?
        var alert: NSAlert?
        var popover: NSPopover?
        var popoverController: NSHostingController<AnyView>?
        var pending = false

        var isShowing: Bool { sheet != nil || alert != nil || popover != nil }

        /// The presentation went away (the binding was cleared, or the user closed it).
        func didDismiss() {
            sheet = nil
            sheetController = nil
            alert = nil
            popover = nil
            popoverController = nil
            // after the update that dismissed it, so what they change is shown
            let isPresented = isPresented, onDismiss = onDismiss
            DispatchQueue.main.async {
                if isPresented?.wrappedValue == true {
                    isPresented?.wrappedValue = false
                }
                onDismiss?()
            }
        }

        nonisolated func popoverDidClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard popover != nil else { return }
                didDismiss()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = isPresented
        coordinator.onDismiss = onDismiss
        let environment = context.environment
        if isPresented.wrappedValue {
            if coordinator.isShowing {
                refresh(coordinator, environment: environment)
            } else {
                present(in: view, coordinator: coordinator, environment: environment)
            }
        } else if coordinator.isShowing {
            dismiss(coordinator)
        }
    }

    /// The content as presented: the presenter's environment values, and a `dismiss` that
    /// clears the binding.
    private func hosted(_ content: AnyView, environment: EnvironmentValues) -> AnyView {
        let isPresented = isPresented
        return AnyView(content
            ._finchInheriting(environment)
            .environment(\._finchDismiss, { isPresented.wrappedValue = false }))
    }

    private func present(in view: AnchorView, coordinator: Coordinator, environment: EnvironmentValues) {
        guard let window = view.window else {
            // not in a window yet: once it is
            guard !coordinator.pending else { return }
            coordinator.pending = true
            DispatchQueue.main.async {
                coordinator.pending = false
                if self.isPresented.wrappedValue, !coordinator.isShowing, view.window != nil {
                    self.present(in: view, coordinator: coordinator, environment: environment)
                }
            }
            return
        }
        switch presentation() {
        case let .sheet(content):
            let controller = NSHostingController(rootView: hosted(content(), environment: environment))
            let size = controller.host.sizeThatFits(_ProposedSize(width: nil, height: nil))
            let sheet = SheetWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                    backing: .buffered, defer: false)
            sheet.contentViewController = controller
            sheet.setContentSize(size)
            coordinator.sheet = sheet
            coordinator.sheetController = controller
            window.beginSheet(sheet) { _ in
                MainActor.assumeIsolated {
                    if coordinator.sheet === sheet { coordinator.didDismiss() }
                }
            }
        case let .popover(content, arrowEdges):
            let controller = NSHostingController(rootView: hosted(content(), environment: environment))
            let size = controller.host.sizeThatFits(_ProposedSize(width: nil, height: nil))
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.contentSize = size
            popover.delegate = coordinator
            coordinator.popover = popover
            coordinator.popoverController = controller
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: Self.edge(for: arrowEdges, flipped: view.isFlipped))
        case let .alert(title, message, buttons):
            let alert = NSAlert()
            alert.messageText = title?._resolveText(in: environment) ?? ""
            alert.informativeText = message?._resolveText(in: environment) ?? ""
            // the default button first (rightmost); cancel buttons after the others
            let ordered = buttons.filter { !$0.isCancel } + buttons.filter(\.isCancel)
            for button in ordered {
                let title = button.title?._resolveText(in: environment) ?? button.fallback
                let added = alert.addButton(withTitle: title.isEmpty && button.isCancel ? "Cancel" : title)
                if button.isCancel { added.keyEquivalent = "\u{1b}" }
                added.hasDestructiveAction = button.isDestructive
            }
            coordinator.alert = alert
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    guard coordinator.alert === alert else { return }
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    coordinator.didDismiss()
                    if index >= 0, index < ordered.count { ordered[index].action() }
                }
            }
        }
    }

    /// While shown, the content follows the presenter's updates.
    private func refresh(_ coordinator: Coordinator, environment: EnvironmentValues) {
        switch presentation() {
        case let .sheet(content):
            coordinator.sheetController?.rootView = hosted(content(), environment: environment)
        case let .popover(content, _):
            coordinator.popoverController?.rootView = hosted(content(), environment: environment)
        case .alert:
            break
        }
    }

    private func dismiss(_ coordinator: Coordinator) {
        if let sheet = coordinator.sheet {
            coordinator.sheet = nil
            sheet.sheetParent?.endSheet(sheet)
        } else if let alert = coordinator.alert {
            coordinator.alert = nil
            alert.window.sheetParent?.endSheet(alert.window)
        } else if let popover = coordinator.popover {
            coordinator.popover = nil
            popover.close()
        }
        coordinator.didDismiss()
    }

    /// The edge of the presenting view a popover shows from, for the edges its arrow may
    /// point from (an arrow on the top edge: the popover is below the view).
    private static func edge(for arrowEdges: Edge.Set?, flipped: Bool) -> NSRectEdge {
        let below: NSRectEdge = flipped ? .maxY : .minY
        let above: NSRectEdge = flipped ? .minY : .maxY
        guard let arrowEdges, !arrowEdges.isEmpty else { return below }
        if arrowEdges.contains(.top) { return below }
        if arrowEdges.contains(.bottom) { return above }
        if arrowEdges.contains(.leading) { return .maxX }
        return .minX
    }
}

extension View {
    func _finchPresenting(_ isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                          _ presentation: @escaping () -> _FinchPresentation) -> some View {
        background(_FinchPresenter(isPresented: isPresented, presentation: presentation, onDismiss: onDismiss))
    }
}

/// A binding that is set while an optional is, and clears it.
func _finchIsPresented<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}

// MARK: - Sheets

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func sheet<Item, Content>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                 @ViewBuilder content: @escaping (Item) -> Content) -> some View
        where Item: Identifiable, Content: View {
        _finchPresenting(_finchIsPresented(item), onDismiss: onDismiss) {
            .sheet(content: { item.wrappedValue.map { AnyView(content($0)) } ?? AnyView(EmptyView()) })
        }
    }

    nonisolated public func sheet<Content>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                           @ViewBuilder content: @escaping () -> Content) -> some View
        where Content: View {
        _finchPresenting(isPresented, onDismiss: onDismiss) {
            .sheet(content: { AnyView(content()) })
        }
    }
}

// MARK: - Popovers

@available(OpenSwiftUI_v1_0, *)
public enum PopoverAttachmentAnchor {
    case rect(Anchor<CGRect>.Source)
    case point(UnitPoint)
}

@available(*, unavailable)
extension PopoverAttachmentAnchor: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension View {
    @usableFromInline
    nonisolated func popover<Item, Content>(item: Binding<Item?>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
                                            arrowEdge: Edge, @ViewBuilder content: @escaping (Item) -> Content) -> some View
        where Item: Identifiable, Content: View {
        popoverCore(item: item, attachmentAnchor: attachmentAnchor, arrowEdges: Edge.Set(arrowEdge), content: content)
    }

    @usableFromInline
    nonisolated func popover<Item, Content>(item: Binding<Item?>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
                                            @ViewBuilder content: @escaping (Item) -> Content) -> some View
        where Item: Identifiable, Content: View {
        popoverCore(item: item, attachmentAnchor: attachmentAnchor, arrowEdges: nil, content: content)
    }

    @usableFromInline
    nonisolated func popover<Content>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
                                      arrowEdge: Edge, @ViewBuilder content: @escaping () -> Content) -> some View
        where Content: View {
        popoverCore(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdges: Edge.Set(arrowEdge),
                    isDetachable: false, content: content)
    }

    @usableFromInline
    nonisolated func popover<Content>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
                                      @ViewBuilder content: @escaping () -> Content) -> some View
        where Content: View {
        popoverCore(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdges: nil, isDetachable: false,
                    content: content)
    }

    @usableFromInline
    nonisolated func popoverCore<Content>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor,
                                          arrowEdges: Edge.Set?, isDetachable: Bool,
                                          @ViewBuilder content: @escaping () -> Content) -> some View
        where Content: View {
        _finchPresenting(isPresented) {
            .popover(content: { AnyView(content()) }, arrowEdges: arrowEdges)
        }
    }

    @usableFromInline
    nonisolated func popoverCore<Item, Content>(item: Binding<Item?>, attachmentAnchor: PopoverAttachmentAnchor,
                                                arrowEdges: Edge.Set?, @ViewBuilder content: @escaping (Item) -> Content) -> some View
        where Item: Identifiable, Content: View {
        _finchPresenting(_finchIsPresented(item)) {
            .popover(content: { item.wrappedValue.map { AnyView(content($0)) } ?? AnyView(EmptyView()) },
                     arrowEdges: arrowEdges)
        }
    }

    @_alwaysEmitIntoClient
    nonisolated public func popover<Item, Content>(item: Binding<Item?>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
                                                   arrowEdge: Edge? = nil,
                                                   @ViewBuilder content: @escaping (Item) -> Content) -> some View
        where Item: Identifiable, Content: View {
        popoverCore(item: item, attachmentAnchor: attachmentAnchor, arrowEdges: arrowEdge.map { .init($0) }, content: content)
    }

    @_alwaysEmitIntoClient
    nonisolated public func popover<Content>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
                                             arrowEdge: Edge? = nil, @ViewBuilder content: @escaping () -> Content) -> some View
        where Content: View {
        popoverCore(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdges: arrowEdge.map { .init($0) },
                    isDetachable: false, content: content)
    }
}

// MARK: - Alerts

extension View {
    fileprivate func _finchAlert(_ title: Text?, isPresented: Binding<Bool>, actions: @escaping () -> Any?,
                                 message: @escaping () -> Any?) -> some View {
        _finchPresenting(isPresented) {
            .alert(title: title, message: message().flatMap(_finchMessageText), buttons: _FinchAlertButton.of(actions()))
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension View {
    nonisolated public func alert<A>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                     @ViewBuilder actions: () -> A) -> some View where A: View {
        alert(Text(titleKey), isPresented: isPresented, actions: actions)
    }

    @_disfavoredOverload
    nonisolated public func alert<S, A>(_ title: S, isPresented: Binding<Bool>,
                                        @ViewBuilder actions: () -> A) -> some View where S: StringProtocol, A: View {
        alert(Text(title), isPresented: isPresented, actions: actions)
    }

    nonisolated public func alert<A>(_ title: Text, isPresented: Binding<Bool>,
                                     @ViewBuilder actions: () -> A) -> some View where A: View {
        let actions = actions()
        return _finchAlert(title, isPresented: isPresented, actions: { actions }, message: { nil })
    }

    nonisolated public func alert<A, M>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                        @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View
        where A: View, M: View {
        alert(Text(titleKey), isPresented: isPresented, actions: actions, message: message)
    }

    @_disfavoredOverload
    nonisolated public func alert<S, A, M>(_ title: S, isPresented: Binding<Bool>,
                                           @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View
        where S: StringProtocol, A: View, M: View {
        alert(Text(title), isPresented: isPresented, actions: actions, message: message)
    }

    nonisolated public func alert<A, M>(_ title: Text, isPresented: Binding<Bool>,
                                        @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View
        where A: View, M: View {
        let actions = actions()
        let message = message()
        return _finchAlert(title, isPresented: isPresented, actions: { actions }, message: { message })
    }

    nonisolated public func alert<A, T>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, presenting data: T?,
                                        @ViewBuilder actions: (T) -> A) -> some View where A: View {
        alert(Text(titleKey), isPresented: isPresented, presenting: data, actions: actions)
    }

    @_disfavoredOverload
    nonisolated public func alert<S, A, T>(_ title: S, isPresented: Binding<Bool>, presenting data: T?,
                                           @ViewBuilder actions: (T) -> A) -> some View where S: StringProtocol, A: View {
        alert(Text(title), isPresented: isPresented, presenting: data, actions: actions)
    }

    nonisolated public func alert<A, T>(_ title: Text, isPresented: Binding<Bool>, presenting data: T?,
                                        @ViewBuilder actions: (T) -> A) -> some View where A: View {
        let actions = data.map(actions)
        return _finchAlert(title, isPresented: data == nil ? .constant(false) : isPresented,
                           actions: { actions }, message: { nil })
    }

    nonisolated public func alert<A, M, T>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, presenting data: T?,
                                           @ViewBuilder actions: (T) -> A, @ViewBuilder message: (T) -> M) -> some View
        where A: View, M: View {
        alert(Text(titleKey), isPresented: isPresented, presenting: data, actions: actions, message: message)
    }

    @_disfavoredOverload
    nonisolated public func alert<S, A, M, T>(_ title: S, isPresented: Binding<Bool>, presenting data: T?,
                                              @ViewBuilder actions: (T) -> A, @ViewBuilder message: (T) -> M) -> some View
        where S: StringProtocol, A: View, M: View {
        alert(Text(title), isPresented: isPresented, presenting: data, actions: actions, message: message)
    }

    nonisolated public func alert<A, M, T>(_ title: Text, isPresented: Binding<Bool>, presenting data: T?,
                                           @ViewBuilder actions: (T) -> A, @ViewBuilder message: (T) -> M) -> some View
        where A: View, M: View {
        let actions = data.map(actions)
        let message = data.map(message)
        return _finchAlert(title, isPresented: data == nil ? .constant(false) : isPresented,
                           actions: { actions }, message: { message })
    }

    nonisolated public func alert<E, A>(isPresented: Binding<Bool>, error: E?,
                                        @ViewBuilder actions: () -> A) -> some View where E: LocalizedError, A: View {
        let actions = actions()
        let title = error.map { Text(verbatim: $0.errorDescription ?? $0.localizedDescription) }
        let message = error.flatMap(Self._finchErrorMessage)
        return _finchAlert(title, isPresented: error == nil ? .constant(false) : isPresented,
                           actions: { actions }, message: { message })
    }

    nonisolated public func alert<E, A, M>(isPresented: Binding<Bool>, error: E?, @ViewBuilder actions: (E) -> A,
                                           @ViewBuilder message: (E) -> M) -> some View
        where E: LocalizedError, A: View, M: View {
        let actions = error.map(actions)
        let message = error.map(message)
        let title = error.map { Text(verbatim: $0.errorDescription ?? $0.localizedDescription) }
        return _finchAlert(title, isPresented: error == nil ? .constant(false) : isPresented,
                           actions: { actions }, message: { message })
    }

    private nonisolated static func _finchErrorMessage<E: LocalizedError>(_ error: E) -> Text? {
        let lines = [error.failureReason, error.recoverySuggestion].compactMap { $0 }
        return lines.isEmpty ? nil : Text(verbatim: lines.joined(separator: "\n"))
    }
}

// MARK: - Alert (the original alert type)

@available(OpenSwiftUI_v1_0, *)
public struct Alert {
    var title: Text
    var message: Text?
    var buttons: [Button]

    public init(title: Text, message: Text? = nil, dismissButton: Button? = nil) {
        self.title = title
        self.message = message
        self.buttons = dismissButton.map { [$0] } ?? []
    }

    public init(title: Text, message: Text? = nil, primaryButton: Button, secondaryButton: Button) {
        self.title = title
        self.message = message
        self.buttons = [primaryButton, secondaryButton]
    }

    public struct Button {
        enum Style { case `default`, cancel, destructive }
        var label: Text?
        var style: Style
        var action: (() -> Void)?

        public static func `default`(_ label: Text, action: (() -> Void)? = {}) -> Button {
            Button(label: label, style: .default, action: action)
        }

        public static func cancel(_ label: Text, action: (() -> Void)? = {}) -> Button {
            Button(label: label, style: .cancel, action: action)
        }

        public static func cancel(_ action: (() -> Void)? = {}) -> Button {
            Button(label: nil, style: .cancel, action: action)
        }

        public static func destructive(_ label: Text, action: (() -> Void)? = {}) -> Button {
            Button(label: label, style: .destructive, action: action)
        }
    }

    var _finchButtons: [_FinchAlertButton] {
        guard !buttons.isEmpty else { return [_FinchAlertButton(fallback: "OK")] }
        return buttons.map { button in
            _FinchAlertButton(title: button.label, fallback: button.style == .cancel ? "Cancel" : "OK",
                              action: button.action ?? {}, isCancel: button.style == .cancel,
                              isDestructive: button.style == .destructive)
        }
    }
}

@available(*, unavailable)
extension Alert: Sendable {}

@available(*, unavailable)
extension Alert.Button: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func alert<Item>(item: Binding<Item?>, content: (Item) -> Alert) -> some View where Item: Identifiable {
        let alert = item.wrappedValue.map(content)
        return _finchPresenting(_finchIsPresented(item)) {
            .alert(title: alert?.title, message: alert?.message, buttons: alert?._finchButtons ?? [])
        }
    }

    nonisolated public func alert(isPresented: Binding<Bool>, content: () -> Alert) -> some View {
        let alert = content()
        return _finchPresenting(isPresented) {
            .alert(title: alert.title, message: alert.message, buttons: alert._finchButtons)
        }
    }
}

// MARK: - Confirmation dialogs

// On macOS a confirmation dialog is an alert sheet; the title is shown whatever its
// visibility (Apple shows it on macOS unless hidden, and hiding leaves only the message).
@available(OpenSwiftUI_v3_0, *)
extension View {
    nonisolated public func confirmationDialog<A>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                                  titleVisibility: Visibility = .automatic,
                                                  @ViewBuilder actions: () -> A) -> some View where A: View {
        confirmationDialog(Text(titleKey), isPresented: isPresented, titleVisibility: titleVisibility, actions: actions)
    }

    @_disfavoredOverload
    nonisolated public func confirmationDialog<S, A>(_ title: S, isPresented: Binding<Bool>,
                                                     titleVisibility: Visibility = .automatic,
                                                     @ViewBuilder actions: () -> A) -> some View where S: StringProtocol, A: View {
        confirmationDialog(Text(title), isPresented: isPresented, titleVisibility: titleVisibility, actions: actions)
    }

    nonisolated public func confirmationDialog<A>(_ title: Text, isPresented: Binding<Bool>,
                                                  titleVisibility: Visibility = .automatic,
                                                  @ViewBuilder actions: () -> A) -> some View where A: View {
        let actions = actions()
        return _finchAlert(titleVisibility == .hidden ? nil : title, isPresented: isPresented,
                           actions: { actions }, message: { nil })
    }

    nonisolated public func confirmationDialog<A, M>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                                     titleVisibility: Visibility = .automatic,
                                                     @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View
        where A: View, M: View {
        confirmationDialog(Text(titleKey), isPresented: isPresented, titleVisibility: titleVisibility, actions: actions,
                           message: message)
    }

    @_disfavoredOverload
    nonisolated public func confirmationDialog<S, A, M>(_ title: S, isPresented: Binding<Bool>,
                                                        titleVisibility: Visibility = .automatic,
                                                        @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View
        where S: StringProtocol, A: View, M: View {
        confirmationDialog(Text(title), isPresented: isPresented, titleVisibility: titleVisibility, actions: actions,
                           message: message)
    }

    nonisolated public func confirmationDialog<A, M>(_ title: Text, isPresented: Binding<Bool>,
                                                     titleVisibility: Visibility = .automatic,
                                                     @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View
        where A: View, M: View {
        let actions = actions()
        let message = message()
        return _finchAlert(titleVisibility == .hidden ? nil : title, isPresented: isPresented,
                           actions: { actions }, message: { message })
    }

    nonisolated public func confirmationDialog<A, T>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                                     titleVisibility: Visibility = .automatic, presenting data: T?,
                                                     @ViewBuilder actions: (T) -> A) -> some View where A: View {
        confirmationDialog(Text(titleKey), isPresented: isPresented, titleVisibility: titleVisibility, presenting: data,
                           actions: actions)
    }

    @_disfavoredOverload
    nonisolated public func confirmationDialog<S, A, T>(_ title: S, isPresented: Binding<Bool>,
                                                        titleVisibility: Visibility = .automatic, presenting data: T?,
                                                        @ViewBuilder actions: (T) -> A) -> some View
        where S: StringProtocol, A: View {
        confirmationDialog(Text(title), isPresented: isPresented, titleVisibility: titleVisibility, presenting: data,
                           actions: actions)
    }

    nonisolated public func confirmationDialog<A, T>(_ title: Text, isPresented: Binding<Bool>,
                                                     titleVisibility: Visibility = .automatic, presenting data: T?,
                                                     @ViewBuilder actions: (T) -> A) -> some View where A: View {
        let actions = data.map(actions)
        return _finchAlert(titleVisibility == .hidden ? nil : title,
                           isPresented: data == nil ? .constant(false) : isPresented,
                           actions: { actions }, message: { nil })
    }

    nonisolated public func confirmationDialog<A, M, T>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                                        titleVisibility: Visibility = .automatic, presenting data: T?,
                                                        @ViewBuilder actions: (T) -> A,
                                                        @ViewBuilder message: (T) -> M) -> some View where A: View, M: View {
        confirmationDialog(Text(titleKey), isPresented: isPresented, titleVisibility: titleVisibility, presenting: data,
                           actions: actions, message: message)
    }

    @_disfavoredOverload
    nonisolated public func confirmationDialog<S, A, M, T>(_ title: S, isPresented: Binding<Bool>,
                                                           titleVisibility: Visibility = .automatic, presenting data: T?,
                                                           @ViewBuilder actions: (T) -> A,
                                                           @ViewBuilder message: (T) -> M) -> some View
        where S: StringProtocol, A: View, M: View {
        confirmationDialog(Text(title), isPresented: isPresented, titleVisibility: titleVisibility, presenting: data,
                           actions: actions, message: message)
    }

    nonisolated public func confirmationDialog<A, M, T>(_ title: Text, isPresented: Binding<Bool>,
                                                        titleVisibility: Visibility = .automatic, presenting data: T?,
                                                        @ViewBuilder actions: (T) -> A,
                                                        @ViewBuilder message: (T) -> M) -> some View where A: View, M: View {
        let actions = data.map(actions)
        let message = data.map(message)
        return _finchAlert(titleVisibility == .hidden ? nil : title,
                           isPresented: data == nil ? .constant(false) : isPresented,
                           actions: { actions }, message: { message })
    }
}
