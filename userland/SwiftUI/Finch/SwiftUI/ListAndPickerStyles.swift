// SPDX-License-Identifier: MIT OR Apache-2.0
//
// List and picker styles, to Apple's interface: the style protocols (whose requirements are
// Apple's underscored ones), the macOS styles, and listStyle(_:) and pickerStyle(_:). A
// style puts its kind in the environment, which Finch's List and Picker read: Apple's make
// their views through the requirements, which nothing outside SwiftUI implements.

import AppKit
import SwiftUICore

// MARK: - Lists

@available(OpenSwiftUI_v1_0, *)
public protocol ListStyle {
    static func _makeView<SelectionValue>(value: _GraphValue<_ListValue<Self, SelectionValue>>, inputs: _ViewInputs) -> _ViewOutputs
        where SelectionValue: Hashable
    static func _makeViewList<SelectionValue>(value: _GraphValue<_ListValue<Self, SelectionValue>>, inputs: _ViewListInputs)
        -> _ViewListOutputs where SelectionValue: Hashable
}

@available(OpenSwiftUI_v1_0, *)
public struct _ListValue<Style, SelectionValue> where Style: ListStyle, SelectionValue: Hashable {}

@available(*, unavailable)
extension _ListValue: Sendable {}

/// How Finch's List draws, as each style asks.
enum _FinchListKind: Equatable {
    case inset, plain, sidebar, bordered
}

struct _FinchListStyleAppearance: Equatable {
    var kind: _FinchListKind = .inset
    var alternatesRowBackgrounds = false
}

protocol _FinchListStyle: ListStyle {
    var appearance: _FinchListStyleAppearance { get }
}

extension _FinchListStyle {
    nonisolated public static func _makeView<SelectionValue>(value: _GraphValue<_ListValue<Self, SelectionValue>>,
                                                             inputs: _ViewInputs) -> _ViewOutputs where SelectionValue: Hashable {
        preconditionFailure("Finch's List draws its style from the environment")
    }

    nonisolated public static func _makeViewList<SelectionValue>(value: _GraphValue<_ListValue<Self, SelectionValue>>,
                                                                 inputs: _ViewListInputs) -> _ViewListOutputs
        where SelectionValue: Hashable {
        preconditionFailure("Finch's List draws its style from the environment")
    }
}

private struct _FinchListStyleKey: EnvironmentKey {
    static var defaultValue: _FinchListStyleAppearance { .init() }
}

extension EnvironmentValues {
    var _finchListStyle: _FinchListStyleAppearance {
        get { self[_FinchListStyleKey.self] }
        set { self[_FinchListStyleKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func listStyle<S>(_ style: S) -> some View where S: ListStyle {
        environment(\._finchListStyle, (style as? any _FinchListStyle)?.appearance ?? .init())
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct DefaultListStyle: ListStyle, _FinchListStyle {
    public init() {}
    var appearance: _FinchListStyleAppearance { .init(kind: .inset) }
}

@available(OpenSwiftUI_v1_0, *)
public struct SidebarListStyle: ListStyle, _FinchListStyle {
    public init() {}
    var appearance: _FinchListStyleAppearance { .init(kind: .sidebar) }
}

@available(OpenSwiftUI_v2_0, *)
public struct InsetListStyle: ListStyle, _FinchListStyle {
    var alternates = false
    public init() {}
    public init(alternatesRowBackgrounds: Bool) { alternates = alternatesRowBackgrounds }
    var appearance: _FinchListStyleAppearance { .init(kind: .inset, alternatesRowBackgrounds: alternates) }
}

@available(OpenSwiftUI_v1_0, *)
public struct PlainListStyle: ListStyle, _FinchListStyle {
    public init() {}
    var appearance: _FinchListStyleAppearance { .init(kind: .plain) }
}

@available(OpenSwiftUI_v3_0, *)
public struct BorderedListStyle: ListStyle, _FinchListStyle {
    var alternates = false
    public init() {}
    public init(alternatesRowBackgrounds: Bool) { alternates = alternatesRowBackgrounds }
    var appearance: _FinchListStyleAppearance { .init(kind: .bordered, alternatesRowBackgrounds: alternates) }
}

@available(OpenSwiftUI_v1_0, *)
public struct __UniversalListStyle: ListStyle, _FinchListStyle {
    public init() {}
    var appearance: _FinchListStyleAppearance { .init(kind: .inset) }
}

@available(*, unavailable) extension DefaultListStyle: Sendable {}
@available(*, unavailable) extension SidebarListStyle: Sendable {}
@available(*, unavailable) extension InsetListStyle: Sendable {}
@available(*, unavailable) extension PlainListStyle: Sendable {}
@available(*, unavailable) extension BorderedListStyle: Sendable {}
@available(*, unavailable) extension __UniversalListStyle: Sendable {}

extension ListStyle where Self == DefaultListStyle {
    @_alwaysEmitIntoClient public static var automatic: DefaultListStyle { .init() }
}

extension ListStyle where Self == SidebarListStyle {
    @_alwaysEmitIntoClient public static var sidebar: SidebarListStyle { .init() }
}

extension ListStyle where Self == InsetListStyle {
    @_alwaysEmitIntoClient public static var inset: InsetListStyle { .init() }
}

extension ListStyle where Self == PlainListStyle {
    @_alwaysEmitIntoClient public static var plain: PlainListStyle { .init() }
}

extension ListStyle where Self == BorderedListStyle {
    @_alwaysEmitIntoClient public static var bordered: BorderedListStyle { .init() }
}

// MARK: - Pickers

@available(OpenSwiftUI_v1_0, *)
public protocol PickerStyle {
    static func _makeView<SelectionValue>(value: _GraphValue<_PickerValue<Self, SelectionValue>>, inputs: _ViewInputs) -> _ViewOutputs
        where SelectionValue: Hashable
    static func _makeViewList<SelectionValue>(value: _GraphValue<_PickerValue<Self, SelectionValue>>, inputs: _ViewListInputs)
        -> _ViewListOutputs where SelectionValue: Hashable
}

@available(OpenSwiftUI_v1_0, *)
public struct _PickerValue<Style, SelectionValue> where Style: PickerStyle, SelectionValue: Hashable {}

@available(*, unavailable)
extension _PickerValue: Sendable {}

/// How Finch's Picker shows its options, as each style asks.
enum _FinchPickerKind: Equatable {
    case menu, segmented, radioGroup, inline
}

protocol _FinchPickerStyle: PickerStyle {
    var kind: _FinchPickerKind { get }
}

extension _FinchPickerStyle {
    public static func _makeView<SelectionValue>(value: _GraphValue<_PickerValue<Self, SelectionValue>>,
                                                 inputs: _ViewInputs) -> _ViewOutputs where SelectionValue: Hashable {
        preconditionFailure("Finch's Picker draws its style from the environment")
    }

    public static func _makeViewList<SelectionValue>(value: _GraphValue<_PickerValue<Self, SelectionValue>>,
                                                     inputs: _ViewListInputs) -> _ViewListOutputs where SelectionValue: Hashable {
        preconditionFailure("Finch's Picker draws its style from the environment")
    }
}

private struct _FinchPickerStyleKey: EnvironmentKey {
    static var defaultValue: _FinchPickerKind { .menu }
}

extension EnvironmentValues {
    var _finchPickerStyle: _FinchPickerKind {
        get { self[_FinchPickerStyleKey.self] }
        set { self[_FinchPickerStyleKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    nonisolated public func pickerStyle<S>(_ style: S) -> some View where S: PickerStyle {
        environment(\._finchPickerStyle, (style as? any _FinchPickerStyle)?.kind ?? .menu)
    }
}

@available(OpenSwiftUI_v1_0, *)
public struct DefaultPickerStyle: PickerStyle, _FinchPickerStyle {
    public init() {}
    var kind: _FinchPickerKind { .menu }
}

@available(OpenSwiftUI_v2_0, *)
public struct MenuPickerStyle: PickerStyle, _FinchPickerStyle {
    public init() {}
    var kind: _FinchPickerKind { .menu }
}

@available(OpenSwiftUI_v1_0, *)
public struct PopUpButtonPickerStyle: PickerStyle, _FinchPickerStyle {
    public init() {}
    var kind: _FinchPickerKind { .menu }
}

@available(OpenSwiftUI_v1_0, *)
public struct SegmentedPickerStyle: PickerStyle, _FinchPickerStyle {
    public init() {}
    var kind: _FinchPickerKind { .segmented }
}

@available(OpenSwiftUI_v1_0, *)
public struct RadioGroupPickerStyle: PickerStyle, _FinchPickerStyle {
    public init() {}
    var kind: _FinchPickerKind { .radioGroup }
}

@available(OpenSwiftUI_v2_0, *)
public struct InlinePickerStyle: PickerStyle, _FinchPickerStyle {
    public init() {}
    var kind: _FinchPickerKind { .inline }
}

@available(OpenSwiftUI_v5_0, *)
public struct PalettePickerStyle: PickerStyle, _FinchPickerStyle {
    public init() {}
    var kind: _FinchPickerKind { .segmented }
}

@available(*, unavailable) extension DefaultPickerStyle: Sendable {}
@available(*, unavailable) extension MenuPickerStyle: Sendable {}
@available(*, unavailable) extension PopUpButtonPickerStyle: Sendable {}
@available(*, unavailable) extension SegmentedPickerStyle: Sendable {}
@available(*, unavailable) extension RadioGroupPickerStyle: Sendable {}
@available(*, unavailable) extension InlinePickerStyle: Sendable {}
@available(*, unavailable) extension PalettePickerStyle: Sendable {}

extension PickerStyle where Self == DefaultPickerStyle {
    @_alwaysEmitIntoClient public static var automatic: DefaultPickerStyle { .init() }
}

extension PickerStyle where Self == MenuPickerStyle {
    @_alwaysEmitIntoClient public static var menu: MenuPickerStyle { .init() }
}

extension PickerStyle where Self == SegmentedPickerStyle {
    @_alwaysEmitIntoClient public static var segmented: SegmentedPickerStyle { .init() }
}

extension PickerStyle where Self == RadioGroupPickerStyle {
    @_alwaysEmitIntoClient public static var radioGroup: RadioGroupPickerStyle { .init() }
}

extension PickerStyle where Self == InlinePickerStyle {
    @_alwaysEmitIntoClient public static var inline: InlinePickerStyle { .init() }
}

extension PickerStyle where Self == PalettePickerStyle {
    @_alwaysEmitIntoClient public static var palette: PalettePickerStyle { .init() }
}
