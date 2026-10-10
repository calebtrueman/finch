// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Commands and the main menu, to Apple's interface (CommandGroup, CommandGroupPlacement,
// CommandMenu), as Apple's SwiftUI apps have them on macOS: a main menu of Apple's (the app
// menu, File, Edit, View, Window, Help), each menu a run of command groups; an app's commands
// add items before or after a group or replace it (CommandGroup), and add menus before the
// Window menu (CommandMenu). Commands are read from their content, as menus are (buttons,
// toggles, pickers, dividers, sections, submenus; keyboard shortcuts as key equivalents), and
// the main menu is built again when an app's commands change.

import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - Placements

@available(OpenSwiftUI_v2_0, *)
public struct CommandGroupPlacement: Sendable {
    let name: Text
    let id: UUID

    init(_ text: String) {
        name = Text(verbatim: text)
        id = UUID()
    }

    public static let appInfo = CommandGroupPlacement("App Info")
    public static let appSettings = CommandGroupPlacement("App Settings")
    public static let systemServices = CommandGroupPlacement("System Services")
    public static let appVisibility = CommandGroupPlacement("App Visibility")
    public static let appTermination = CommandGroupPlacement("App Termination")
    public static let newItem = CommandGroupPlacement("New Item")
    public static let saveItem = CommandGroupPlacement("Save Item")
    public static let importExport = CommandGroupPlacement("Import/Export Item")
    public static let printItem = CommandGroupPlacement("Print Item")
    public static let undoRedo = CommandGroupPlacement("Undo/Redo")
    public static let pasteboard = CommandGroupPlacement("Pasteboard")
    public static let textEditing = CommandGroupPlacement("Text Editing")
    public static let textFormatting = CommandGroupPlacement("Text Formatting")
    public static let toolbar = CommandGroupPlacement("Toolbar")
    public static let sidebar = CommandGroupPlacement("Sidebar")
    public static let windowSize = CommandGroupPlacement("Window Size")
    public static let windowList = CommandGroupPlacement("Window List")
    @available(OpenSwiftUI_v4_0, *)
    public static let singleWindowList = CommandGroupPlacement("Singleton Window List")
    public static let windowArrangement = CommandGroupPlacement("Window Arrangement")
    public static let help = CommandGroupPlacement("Help")

    static let appShortcuts = CommandGroupPlacement("App Shortcuts")
}

struct CommandGroupPlacementBox: Hashable {
    var placement: CommandGroupPlacement

    func hash(into hasher: inout Hasher) {
        hasher.combine(placement.id)
    }

    static func == (lhs: CommandGroupPlacementBox, rhs: CommandGroupPlacementBox) -> Bool {
        lhs.placement.id == rhs.placement.id
    }
}

// MARK: - CommandGroup and CommandMenu

@available(OpenSwiftUI_v2_0, *)
@MainActor
@preconcurrency
public struct CommandGroup<Content>: Commands where Content: View {
    var mutation: CommandOperation.Mutation
    var placement: CommandGroupPlacement
    var content: Content

    public init(before group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        mutation = .prepend
        placement = group
        content = addition()
    }

    public init(after group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        mutation = .append
        placement = group
        content = addition()
    }

    public init(replacing group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        mutation = .replace
        placement = group
        content = addition()
    }

    @MainActor
    @preconcurrency
    public var body: some Commands { EmptyCommands() }

    @MainActor
    @preconcurrency
    public func _resolve(into resolved: inout _ResolvedCommands) {}

    nonisolated public static func _makeCommands(content: _GraphValue<CommandGroup<Content>>,
                                                 inputs: _CommandsInputs) -> _CommandsOutputs {
        _CommandsOutputs()
    }
}

@available(*, unavailable) extension CommandGroup: Sendable {}

@available(OpenSwiftUI_v2_0, *)
@MainActor
@preconcurrency
public struct CommandMenu<Content>: Commands where Content: View {
    var name: Text
    var content: Content

    public init(_ nameKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(Text(nameKey), content: content)
    }

    public init(_ name: Text, @ViewBuilder content: () -> Content) {
        self.name = name
        self.content = content()
    }

    @_disfavoredOverload
    public init<S>(_ name: S, @ViewBuilder content: () -> Content) where S: StringProtocol {
        self.init(Text(name), content: content)
    }

    @MainActor
    @preconcurrency
    public var body: some Commands { EmptyCommands() }

    @MainActor
    @preconcurrency
    public func _resolve(into resolved: inout _ResolvedCommands) {}

    nonisolated public static func _makeCommands(content: _GraphValue<CommandMenu<Content>>,
                                                 inputs: _CommandsInputs) -> _CommandsOutputs {
        _CommandsOutputs()
    }
}

@available(*, unavailable) extension CommandMenu: Sendable {}

// MARK: - Reading commands

/// What commands do to the main menu.
enum _FinchCommandPart {
    case group(CommandOperation.Mutation, CommandGroupPlacement, [_FinchMenuItem])
    case menu(Text, [_FinchMenuItem])
}

@MainActor
protocol _FinchCommandParts {
    var _finchCommandParts: [_FinchCommandPart] { get }
}

/// The parts `commands` describes: through tuples and conditions, and custom commands' bodies.
@MainActor
func _finchCommandPartsOf(_ commands: Any) -> [_FinchCommandPart] {
    if let parts = commands as? _FinchCommandParts {
        return parts._finchCommandParts
    }
    if let commands = commands as? any Commands {
        return _finchCommandBody(commands)
    }
    return []
}

@MainActor
private func _finchCommandBody<C: Commands>(_ commands: C) -> [_FinchCommandPart] {
    guard C.Body.self != Never.self else { return [] }
    return _finchCommandPartsOf(commands.body)
}

extension CommandGroup: _FinchCommandParts {
    var _finchCommandParts: [_FinchCommandPart] {
        [.group(mutation, placement, _finchMenuItemsOf(content))]
    }
}

extension CommandMenu: _FinchCommandParts {
    var _finchCommandParts: [_FinchCommandPart] {
        [.menu(name, _finchMenuItemsOf(content))]
    }
}

extension TupleCommandContent: _FinchCommandParts {
    var _finchCommandParts: [_FinchCommandPart] {
        Mirror(reflecting: value).children.flatMap { _finchCommandPartsOf($0.value) }
    }
}

extension EmptyCommands: _FinchCommandParts {
    var _finchCommandParts: [_FinchCommandPart] { [] }
}

extension _ConditionalContent: _FinchCommandParts where TrueContent: Commands, FalseContent: Commands {
    var _finchCommandParts: [_FinchCommandPart] {
        switch storage {
        case let .trueContent(content): _finchCommandPartsOf(content)
        case let .falseContent(content): _finchCommandPartsOf(content)
        }
    }
}

extension Optional: _FinchCommandParts where Wrapped: Commands {
    var _finchCommandParts: [_FinchCommandPart] { map(_finchCommandPartsOf) ?? [] }
}

// MARK: - The main menu

/// The main menu: Apple's menus of command groups, and the app's commands applied to them.
@MainActor
enum _FinchMainMenu {
    /// The app's commands (each scene's `commands`, the latest of each type: an app's body
    /// may be read more than once).
    static var commands: [(ObjectIdentifier, Any)] = []
    private static var scheduled = false

    static func add(_ content: Any) {
        let key = ObjectIdentifier(type(of: content))
        if let index = commands.firstIndex(where: { $0.0 == key }) {
            commands[index].1 = content
        } else {
            commands.append((key, content))
        }
        scheduleInstall()
    }

    static func scheduleInstall() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async {
            scheduled = false
            install()
        }
    }

    /// A menu item that sends an action up the responder chain.
    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// Apple's menus: titles and their groups, each group's items.
    private static func standardMenus(appName: String) -> [(title: String, groups: [(CommandGroupPlacement, [NSMenuItem])])] {
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        return [
            (appName, [
                (.appInfo, [item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))]),
                (.appSettings, []),
                (.systemServices, [services]),
                (.appVisibility, [item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
                                  item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                                       [.command, .option]),
                                  item("Show All", #selector(NSApplication.unhideAllApplications(_:)))]),
                (.appTermination, [item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")]),
            ]),
            ("File", [
                (.newItem, []),
                (.saveItem, [item("Close", #selector(NSWindow.performClose(_:)), "w")]),
                (.importExport, []),
                (.printItem, []),
            ]),
            ("Edit", [
                (.undoRedo, [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift])]),
                (.pasteboard, [item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                               item("Paste", #selector(NSText.paste(_:)), "v"),
                               item("Delete", #selector(NSText.delete(_:))),
                               item("Select All", #selector(NSText.selectAll(_:)), "a")]),
                (.textEditing, []),
                (.textFormatting, []),
            ]),
            ("View", [
                (.toolbar, [item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])]),
                (.sidebar, []),
            ]),
            ("Window", [
                (.windowSize, [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                               item("Zoom", #selector(NSWindow.performZoom(_:)))]),
                (.windowList, []),
                (.singleWindowList, []),
                (.windowArrangement, [item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))]),
            ]),
            ("Help", [
                (.help, []),
            ]),
        ]
    }

    /// NSMenuItems for menu items read from commands.
    private static func menuItems(_ items: [_FinchMenuItem]) -> [NSMenuItem] {
        let menu = _finchMenu(items, environment: EnvironmentValues())
        let result = menu.items
        menu.removeAllItems()
        return result
    }

    static func install() {
        let appName = currentAppName()
        var menus = standardMenus(appName: appName)
        var extraMenus: [(Text, [_FinchMenuItem])] = []
        for (_, content) in commands {
            for part in _finchCommandPartsOf(content) {
                switch part {
                case let .menu(title, items):
                    extraMenus.append((title, items))
                case let .group(mutation, placement, items):
                    let added = menuItems(items)
                    for m in menus.indices {
                        for g in menus[m].groups.indices where menus[m].groups[g].0.id == placement.id {
                            switch mutation {
                            case .prepend: menus[m].groups[g].1.insert(contentsOf: added, at: 0)
                            case .replace: menus[m].groups[g].1 = added
                            default: menus[m].groups[g].1.append(contentsOf: added)
                            }
                        }
                    }
                }
            }
        }
        let main = NSMenu(title: "Main Menu")
        func add(_ title: String, _ groups: [[NSMenuItem]]) {
            let menu = NSMenu(title: title)
            for group in groups where !group.isEmpty {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                group.forEach(menu.addItem)
            }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
            if title == "Window" { NSApp.windowsMenu = menu }
            if title == "Help" { NSApp.helpMenu = menu }
        }
        for (title, groups) in menus {
            if title == "Window" {
                for (name, items) in extraMenus {
                    add(name._resolveText(in: EnvironmentValues()), [menuItems(items)])
                }
            }
            add(title, groups.map(\.1))
        }
        NSApp.mainMenu = main
    }
}

// MARK: - Scene + commands

/// A scene modifier that leaves the scene as it is (its commands go to the main menu).
struct _FinchCommandsSceneModifier: PrimitiveSceneModifier {
    nonisolated static func _makeScene(modifier: _GraphValue<Self>, inputs: _SceneInputs,
                                       body: @escaping (_Graph, _SceneInputs) -> _SceneOutputs) -> _SceneOutputs {
        body(_Graph(), inputs)
    }
}

@available(OpenSwiftUI_v2_0, *)
extension Scene {
    nonisolated public func commands<Content>(@CommandsBuilder content: () -> Content) -> some Scene where Content: Commands {
        let content = content()
        MainActor.assumeIsolated { _FinchMainMenu.add(content) }
        return modifier(_FinchCommandsSceneModifier())
    }
}
