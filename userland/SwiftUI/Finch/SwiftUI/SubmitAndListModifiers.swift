// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Submitting (onSubmit, SubmitTriggers, submitScope, SubmitLabel), list rows' modifiers
// (listRowBackground, listRowInsets, row and section separators, defaultMinListRowHeight),
// scrollContentBackground, menuIndicator and textSelection, to Apple's interface.
//
// A text field runs the submit actions around it when Return commits it. A list draws a row's
// background and insets from the row's traits, its rows at least the minimum row height, and
// its background unless scroll content backgrounds are hidden. macOS lists draw no row
// separators, so the separator modifiers change nothing.

import AppKit
import SwiftUICore

// MARK: - Submitting

@available(OpenSwiftUI_v3_0, *)
public struct SubmitTriggers: OptionSet, Sendable {
    public typealias RawValue = Int
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let text = SubmitTriggers(rawValue: 1 << 0)
    public static let search = SubmitTriggers(rawValue: 1 << 1)
}

struct _FinchSubmitAction {
    var triggers: SubmitTriggers
    var action: () -> Void
}

private struct _FinchSubmitActionsKey: EnvironmentKey {
    static var defaultValue: [_FinchSubmitAction] { [] }
}

extension EnvironmentValues {
    /// The submit actions around a view, innermost first.
    var _finchSubmitActions: [_FinchSubmitAction] {
        get { self[_FinchSubmitActionsKey.self] }
        set { self[_FinchSubmitActionsKey.self] = newValue }
    }

    /// Runs the submit actions for a trigger.
    func _finchSubmit(_ trigger: SubmitTriggers) {
        for submit in _finchSubmitActions where submit.triggers.contains(trigger) {
            submit.action()
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension View {
    nonisolated public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping () -> Void) -> some View {
        transformEnvironment(\._finchSubmitActions) { $0.append(_FinchSubmitAction(triggers: triggers, action: action)) }
    }

    /// A blocking scope keeps the submit actions around it from its views.
    nonisolated public func submitScope(_ isBlocking: Bool = true) -> some View {
        transformEnvironment(\._finchSubmitActions) { if isBlocking { $0 = [] } }
    }

    /// The label of the return key (on macOS, keyboards have none to label).
    nonisolated public func submitLabel(_ submitLabel: SubmitLabel) -> some View {
        modifier(EmptyModifier())
    }
}

@available(OpenSwiftUI_v3_0, *)
public struct SubmitLabel: Sendable {
    enum Kind { case done, go, send, join, route, search, `return`, next, `continue` }
    var kind: Kind

    public static var done: SubmitLabel { .init(kind: .done) }
    public static var go: SubmitLabel { .init(kind: .go) }
    public static var send: SubmitLabel { .init(kind: .send) }
    public static var join: SubmitLabel { .init(kind: .join) }
    public static var route: SubmitLabel { .init(kind: .route) }
    public static var search: SubmitLabel { .init(kind: .search) }
    public static var `return`: SubmitLabel { .init(kind: .return) }
    public static var next: SubmitLabel { .init(kind: .next) }
    public static var `continue`: SubmitLabel { .init(kind: .continue) }
}

// MARK: - List rows

@usableFromInline
struct ListRowBackgroundTraitKey: _ViewTraitKey {
    @inlinable
    static var defaultValue: AnyView? { nil }

    @usableFromInline
    typealias Value = AnyView?
}

@available(*, unavailable) extension ListRowBackgroundTraitKey: Sendable {}

@usableFromInline
struct ClipsListRowBackgroundTraitKey: _ViewTraitKey {
    @inlinable
    static var defaultValue: Bool { false }

    @usableFromInline
    typealias Value = Bool
}

@available(*, unavailable) extension ClipsListRowBackgroundTraitKey: Sendable {}

@usableFromInline
struct ListRowInsetsTraitKey: _ViewTraitKey {
    @inlinable
    static var defaultValue: EdgeInsets? { nil }

    @usableFromInline
    typealias Value = EdgeInsets?
}

@available(*, unavailable) extension ListRowInsetsTraitKey: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension View {
    @inlinable
    nonisolated public func listRowBackground<V>(_ view: V?) -> some View where V: View {
        _trait(ListRowBackgroundTraitKey.self, view.map { AnyView($0) })
    }

    @inlinable
    nonisolated public func listRowInsets(_ insets: EdgeInsets?) -> some View {
        _trait(ListRowInsetsTraitKey.self, insets)
    }

    @available(OpenSwiftUI_v6_0, *)
    nonisolated public func listRowInsets(_ edges: Edge.Set = .all, _ length: CGFloat?) -> some View {
        let insets = length.map { length in
            EdgeInsets(top: edges.contains(.top) ? length : 0, leading: edges.contains(.leading) ? length : 0,
                       bottom: edges.contains(.bottom) ? length : 0, trailing: edges.contains(.trailing) ? length : 0)
        }
        return _trait(ListRowInsetsTraitKey.self, insets)
    }

    @available(OpenSwiftUI_v3_0, *)
    nonisolated public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        modifier(EmptyModifier())
    }

    @available(OpenSwiftUI_v3_0, *)
    nonisolated public func listRowSeparatorTint(_ color: Color?, edges: VerticalEdge.Set = .all) -> some View {
        modifier(EmptyModifier())
    }

    @available(OpenSwiftUI_v3_0, *)
    nonisolated public func listSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        modifier(EmptyModifier())
    }

    @available(OpenSwiftUI_v3_0, *)
    nonisolated public func listSectionSeparatorTint(_ color: Color?, edges: VerticalEdge.Set = .all) -> some View {
        modifier(EmptyModifier())
    }
}

private struct _FinchDefaultMinListRowHeightKey: EnvironmentKey {
    static var defaultValue: CGFloat { 24 }
}

private struct _FinchDefaultMinListHeaderHeightKey: EnvironmentKey {
    static var defaultValue: CGFloat? { nil }
}

@available(OpenSwiftUI_v1_0, *)
extension EnvironmentValues {
    public var defaultMinListRowHeight: CGFloat {
        get { self[_FinchDefaultMinListRowHeightKey.self] }
        set { self[_FinchDefaultMinListRowHeightKey.self] = newValue }
    }

    public var defaultMinListHeaderHeight: CGFloat? {
        get { self[_FinchDefaultMinListHeaderHeightKey.self] }
        set { self[_FinchDefaultMinListHeaderHeightKey.self] = newValue }
    }
}

// MARK: - Scroll content backgrounds

private struct _FinchScrollContentBackgroundKey: EnvironmentKey {
    static var defaultValue: Visibility { .automatic }
}

extension EnvironmentValues {
    var _finchScrollContentBackground: Visibility {
        get { self[_FinchScrollContentBackgroundKey.self] }
        set { self[_FinchScrollContentBackgroundKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v4_0, *)
extension View {
    nonisolated public func scrollContentBackground(_ visibility: Visibility) -> some View {
        environment(\._finchScrollContentBackground, visibility)
    }
}

// MARK: - Menu indicators

private struct _FinchMenuIndicatorKey: EnvironmentKey {
    static var defaultValue: Visibility { .automatic }
}

@available(OpenSwiftUI_v3_0, *)
extension EnvironmentValues {
    public var menuIndicatorVisibility: Visibility {
        get { self[_FinchMenuIndicatorKey.self] }
        set { self[_FinchMenuIndicatorKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension View {
    @inlinable
    nonisolated public func menuIndicator(_ visibility: Visibility) -> some View {
        environment(\.menuIndicatorVisibility, visibility)
    }
}

// MARK: - Text selection

@available(OpenSwiftUI_v3_0, *)
extension View {
    /// Whether text in the view can be selected (Finch's text can't be selected yet).
    nonisolated public func textSelection<S>(_ selectability: S) -> some View where S: TextSelectability {
        modifier(EmptyModifier())
    }
}
