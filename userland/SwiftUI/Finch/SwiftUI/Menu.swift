// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Menu, menu styles and contextMenu, to Apple's interface, shown as AppKit menus as Apple's
// are on macOS. A menu's content is read as menu items: buttons (their actions), toggles
// (checkmarks), dividers, sections (a header and their items), pickers (their options,
// checked when selected) and menus (submenus), through the content's containers (tuples,
// ForEach, groups, conditions). A Menu is a pull-down button; a context menu is an AppKit
// view over the content that takes right-clicks and nothing else.

import AppKit
import SwiftUICore

// MARK: - Items

/// A menu item, as a menu's content describes it.
struct _FinchMenuItem {
    enum Kind {
        case action(() -> Void)
        case toggle(isOn: Bool, set: (Bool) -> Void)
        case submenu([_FinchMenuItem])
        case separator
        case header
        case label
    }

    var kind: Kind
    var title: Text?
    var fallback = ""
    var isDestructive = false
    var isCancel = false
    var shortcut: KeyboardShortcut?
}

/// A view with a keyboard shortcut (keyboardShortcut(_:) writes it into the environment).
protocol _FinchShortcutCarrier {
    var _finchShortcut: KeyboardShortcut? { get }
}

extension ModifiedContent: _FinchShortcutCarrier where Modifier == _EnvironmentKeyWritingModifier<KeyboardShortcut?> {
    var _finchShortcut: KeyboardShortcut? {
        modifier.keyPath == \EnvironmentValues.keyboardShortcut ? modifier.value : nil
    }
}

/// A view that is one or more menu items.
protocol _FinchMenuItems {
    var _finchMenuItems: [_FinchMenuItem] { get }
}

/// The menu items `content` describes.
func _finchMenuItemsOf(_ content: Any) -> [_FinchMenuItem] {
    if let items = content as? _FinchMenuItems {
        return items._finchMenuItems
    }
    if let sequence = content as? _FinchViewSequence {
        return sequence._finchViews.flatMap(_finchMenuItemsOf)
    }
    if let modified = content as? _FinchModifiedView {
        var items = _finchMenuItemsOf(modified._finchContent)
        if let shortcut = (content as? _FinchShortcutCarrier)?._finchShortcut {
            for index in items.indices where items[index].shortcut == nil { items[index].shortcut = shortcut }
        }
        return items
    }
    if content is Divider {
        return [_FinchMenuItem(kind: .separator)]
    }
    // anything else with text in it: a label
    if let text = _finchOptionTitles(content).first ?? nil {
        return [_FinchMenuItem(kind: .label, title: text)]
    }
    return []
}

extension Button: _FinchMenuItems {
    var _finchMenuItems: [_FinchMenuItem] {
        let action = action
        return [_FinchMenuItem(kind: .action { action() }, title: _finchOptionTitles(label).first ?? nil,
                               isDestructive: role == .destructive, isCancel: role == .cancel)]
    }
}

extension Toggle: _FinchMenuItems {
    var _finchMenuItems: [_FinchMenuItem] {
        let state: Binding<ToggleState> = $toggleState
        return [_FinchMenuItem(kind: .toggle(isOn: state.wrappedValue == ToggleState.on,
                                             set: { state.wrappedValue = $0 ? ToggleState.on : ToggleState.off }),
                               title: _finchOptionTitles(label).first ?? nil)]
    }
}

extension Section: _FinchMenuItems {
    var _finchMenuItems: [_FinchMenuItem] {
        var items = [_FinchMenuItem(kind: .separator)]
        if let title = _finchOptionTitles(header).first ?? nil {
            items.append(_FinchMenuItem(kind: .header, title: title))
        }
        items += _finchMenuItemsOf(content)
        items.append(_FinchMenuItem(kind: .separator))
        return items
    }
}

extension Menu: _FinchMenuItems {
    var _finchMenuItems: [_FinchMenuItem] {
        [_FinchMenuItem(kind: .submenu(_finchMenuItemsOf(content)), title: _finchOptionTitles(label).first ?? nil)]
    }
}

extension Picker: _FinchMenuItems {
    /// A picker in a menu: its options inline, the selected one checked.
    var _finchMenuItems: [_FinchMenuItem] {
        let selection = selection
        let selected = Set(selection.get())
        let titles = _finchOptionTitles(content)
        let tags = _finchOptionTags(content, as: SelectionValue.self)
        return tags.indices.map { index in
            let tag = tags[index]
            return _FinchMenuItem(kind: .toggle(isOn: tag.map(selected.contains) ?? false, set: { _ in
                if let tag { selection.set(tag) }
            }), title: index < titles.count ? titles[index] : nil, fallback: tag.map { String(describing: $0) } ?? "")
        }
    }
}

/// The tags of a picker's options, in the order of their titles.
func _finchOptionTags<Value: Hashable>(_ content: Any, as _: Value.Type) -> [Value?] {
    if let sequence = content as? _FinchViewSequence {
        return sequence._finchViews.flatMap { _finchOptionTags($0, as: Value.self) }
    }
    if let tagged = content as? _FinchTaggedView {
        return [tagged._finchTag as? Value]
    }
    if let modified = content as? _FinchModifiedView, modified._finchContent is _FinchViewSequence {
        return _finchOptionTags(modified._finchContent, as: Value.self)
    }
    return [nil]
}

/// A view with a tag (`tag(_:)`), as an option.
protocol _FinchTaggedView {
    var _finchTag: Any { get }
}

extension ModifiedContent: _FinchTaggedView where Modifier: _FinchTagModifier {
    var _finchTag: Any { modifier._finchTagValue }
}

protocol _FinchTagModifier {
    var _finchTagValue: Any { get }
}

extension _TagTraitWritingModifier: _FinchTagModifier {
    var _finchTagValue: Any { tag }
}

/// An NSMenu of items, their titles resolved in an environment.
@MainActor
func _finchMenu(_ items: [_FinchMenuItem], environment: EnvironmentValues) -> NSMenu {
    let menu = NSMenu()
    var lastWasSeparator = true
    for item in items {
        let title = item.title?._resolveText(in: environment) ?? item.fallback
        switch item.kind {
        case .separator:
            if !lastWasSeparator { menu.addItem(.separator()) }
            lastWasSeparator = true
            continue
        case let .action(action):
            menu.addItem(_FinchMenuActionItem(title: title) { action() })
        case let .toggle(isOn, set):
            let menuItem = _FinchMenuActionItem(title: title) { set(!isOn) }
            menuItem.state = isOn ? .on : .off
            menu.addItem(menuItem)
        case let .submenu(children):
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.submenu = _finchMenu(children, environment: environment)
            menu.addItem(menuItem)
        case .header:
            menu.addItem(NSMenuItem.sectionHeader(title: title))
        case .label:
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            menu.addItem(menuItem)
        }
        if let shortcut = item.shortcut, let added = menu.items.last {
            added.keyEquivalent = String(shortcut.key.character).lowercased()
            var mask: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { mask.insert(.command) }
            if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
            if shortcut.modifiers.contains(.option) { mask.insert(.option) }
            if shortcut.modifiers.contains(.control) { mask.insert(.control) }
            added.keyEquivalentModifierMask = mask
        }
        lastWasSeparator = false
    }
    while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    return menu
}

/// A menu item that runs a closure.
final class _FinchMenuActionItem: NSMenuItem {
    private var run: () -> Void = {}

    convenience init(title: String, run: @escaping () -> Void) {
        self.init(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        self.run = run
        target = self
    }

    @objc private func runAction(_ sender: Any?) { run() }
}

// MARK: - Menu

@available(OpenSwiftUI_v2_0, *)
@MainActor
@preconcurrency
public struct Menu<Label, Content>: View where Label: View, Content: View {
    var label: Label
    var content: Content
    var primaryAction: (() -> Void)?

    nonisolated init(label: Label, content: Content, primaryAction: (() -> Void)?) {
        self.label = label
        self.content = content
        self.primaryAction = primaryAction
    }

    nonisolated public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.init(label: label(), content: content(), primaryAction: nil)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) where Label == Text {
        self.init(label: Text(titleKey), content: content(), primaryAction: nil)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, @ViewBuilder content: () -> Content) where Label == Text, S: StringProtocol {
        self.init(label: Text(title), content: content(), primaryAction: nil)
    }

    @available(OpenSwiftUI_v3_0, *)
    nonisolated public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label,
                            primaryAction: @escaping () -> Void) {
        self.init(label: label(), content: content(), primaryAction: primaryAction)
    }

    @available(OpenSwiftUI_v3_0, *)
    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content,
                            primaryAction: @escaping () -> Void) where Label == Text {
        self.init(label: Text(titleKey), content: content(), primaryAction: primaryAction)
    }

    @available(OpenSwiftUI_v3_0, *)
    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, @ViewBuilder content: () -> Content, primaryAction: @escaping () -> Void)
        where Label == Text, S: StringProtocol {
        self.init(label: Text(title), content: content(), primaryAction: primaryAction)
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchMenuButton(title: _finchOptionTitles(label).first ?? nil, items: _finchMenuItemsOf(content),
                         primaryAction: primaryAction)
            .fixedSize()
    }
}

@available(*, unavailable)
extension Menu: Sendable {}

@available(OpenSwiftUI_v2_0, *)
extension Menu where Label == MenuStyleConfiguration.Label, Content == MenuStyleConfiguration.Content {
    nonisolated public init(_ configuration: MenuStyleConfiguration) {
        self.init(label: configuration.label, content: configuration.content, primaryAction: nil)
    }
}

/// A pull-down button showing a menu (or, with a primary action, a button that runs it and
/// shows the menu from its arrow).
struct _FinchMenuButton: NSViewRepresentable {
    var title: Text?
    var items: [_FinchMenuItem]
    var primaryAction: (() -> Void)?
    @Environment(\._finchMenuStyleBordered) private var bordered

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let menu = _finchMenu(items, environment: context.environment)
        // a pull-down's first item is its title
        menu.insertItem(NSMenuItem(title: title?._resolveText(in: context.environment) ?? "", action: nil, keyEquivalent: ""),
                        at: 0)
        button.menu = menu
        button.isBordered = bordered
        // a hidden menu indicator: no arrow
        let arrow: NSPopUpButton.ArrowPosition = context.environment.menuIndicatorVisibility == .hidden ? .noArrow : .arrowAtBottom
        if let cell = button.cell as? NSPopUpButtonCell, cell.arrowPosition != arrow { cell.arrowPosition = arrow }
    }
}

// MARK: - Menu styles

@available(OpenSwiftUI_v2_0, *)
@MainActor
@preconcurrency
public protocol MenuStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = MenuStyleConfiguration
}

@available(OpenSwiftUI_v2_0, *)
public struct MenuStyleConfiguration {
    public struct Label: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    public struct Content: ViewAlias {
        public typealias Body = Never
        package init() {}
    }

    var label = Label()
    var content = Content()
}

@available(*, unavailable) extension MenuStyleConfiguration: Sendable {}
@available(*, unavailable) extension MenuStyleConfiguration.Label: Sendable {}
@available(*, unavailable) extension MenuStyleConfiguration.Content: Sendable {}

private struct _FinchMenuStyleBorderedKey: EnvironmentKey {
    static var defaultValue: Bool { true }
}

extension EnvironmentValues {
    /// Whether menus are drawn as bordered buttons (the borderless style draws them bare).
    var _finchMenuStyleBordered: Bool {
        get { self[_FinchMenuStyleBorderedKey.self] }
        set { self[_FinchMenuStyleBorderedKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v2_0, *)
extension View {
    nonisolated public func menuStyle<S>(_ style: S) -> some View where S: MenuStyle {
        environment(\._finchMenuStyleBordered, !(style is BorderlessButtonMenuStyle))
    }
}

@available(OpenSwiftUI_v2_0, *)
public struct DefaultMenuStyle: MenuStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { Menu(configuration) }
}

@available(OpenSwiftUI_v4_0, *)
public struct ButtonMenuStyle: MenuStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { Menu(configuration) }
}

@available(OpenSwiftUI_v2_0, *)
public struct BorderedButtonMenuStyle: MenuStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { Menu(configuration) }
}

@available(OpenSwiftUI_v2_0, *)
public struct BorderlessButtonMenuStyle: MenuStyle {
    public init() {}
    public init(showsMenuIndicator: Bool) {}
    public func makeBody(configuration: Configuration) -> some View { Menu(configuration) }
}

@available(*, unavailable) extension DefaultMenuStyle: Sendable {}
@available(*, unavailable) extension ButtonMenuStyle: Sendable {}
@available(*, unavailable) extension BorderedButtonMenuStyle: Sendable {}
@available(*, unavailable) extension BorderlessButtonMenuStyle: Sendable {}

extension MenuStyle where Self == DefaultMenuStyle {
    @_alwaysEmitIntoClient public static var automatic: DefaultMenuStyle { .init() }
}

extension MenuStyle where Self == ButtonMenuStyle {
    @_alwaysEmitIntoClient public static var button: ButtonMenuStyle { .init() }
}

extension MenuStyle where Self == BorderlessButtonMenuStyle {
    @_alwaysEmitIntoClient public static var borderlessButton: BorderlessButtonMenuStyle { .init() }
}

// MARK: - Context menus

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func contextMenu<MenuItems>(@ViewBuilder menuItems: () -> MenuItems) -> some View where MenuItems: View {
        let items = menuItems()
        return overlay(_FinchContextMenuRegion(items: { _finchMenuItemsOf(items) }))
    }

    @available(OpenSwiftUI_v4_0, *)
    nonisolated public func contextMenu<M, P>(@ViewBuilder menuItems: () -> M, @ViewBuilder preview: () -> P) -> some View
        where M: View, P: View {
        let items = menuItems()
        return overlay(_FinchContextMenuRegion(items: { _finchMenuItemsOf(items) }))
    }
}

/// An AppKit view over a SwiftUI view that takes right-clicks (and Control-clicks) and shows
/// a menu; other events go through to the view.
struct _FinchContextMenuRegion: NSViewRepresentable {
    var items: () -> [_FinchMenuItem]

    final class RegionView: NSView {
        var makeMenu: () -> NSMenu? = { nil }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard frame.contains(point), let event = NSApp.currentEvent else { return nil }
            let contextClick = event.type == .rightMouseDown || event.type == .rightMouseUp ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return contextClick ? self : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

        override func rightMouseDown(with event: NSEvent) {
            if let menu = makeMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }

        override func mouseDown(with event: NSEvent) {
            if let menu = makeMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }
    }

    func makeNSView(context: Context) -> RegionView { RegionView() }

    func updateNSView(_ view: RegionView, context: Context) {
        let items = items
        let environment = context.environment
        view.makeMenu = { MainActor.assumeIsolated { _finchMenu(items(), environment: environment) } }
    }
}
