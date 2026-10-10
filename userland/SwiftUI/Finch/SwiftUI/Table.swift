// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Table, TableColumn and their row and column content, to Apple's interface, drawn as a macOS
// table: a header of the columns' titles (a sortable column's title sorts by it when clicked,
// again to reverse), then a row per value, each cell its column's content for the value, rows
// alternating in shade and the selected ones in the accent color. Columns take their widths
// (or share what's left), and the rows scroll under the header. The columns and rows are read
// from the content (tuples, conditions, ForEach-built rows), as menus are.

public import Foundation
import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

// MARK: - Content protocols

@available(OpenSwiftUI_v3_0, *)
public struct _TableColumnInputs {}

@available(OpenSwiftUI_v3_0, *)
public struct _TableColumnOutputs {}

@available(OpenSwiftUI_v3_0, *)
public struct _TableRowInputs {}

@available(OpenSwiftUI_v3_0, *)
public struct _TableRowOutputs {}

@available(*, unavailable) extension _TableColumnInputs: Sendable {}
@available(*, unavailable) extension _TableColumnOutputs: Sendable {}
@available(*, unavailable) extension _TableRowInputs: Sendable {}
@available(*, unavailable) extension _TableRowOutputs: Sendable {}

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public protocol TableColumnContent<TableRowValue, TableColumnSortComparator> {
    associatedtype TableRowValue: Identifiable = Self.TableColumnBody.TableRowValue
    associatedtype TableColumnSortComparator: SortComparator = Self.TableColumnBody.TableColumnSortComparator
    associatedtype TableColumnBody: TableColumnContent

    nonisolated var tableColumnBody: Self.TableColumnBody { get }

    nonisolated static func _makeContent(content: _GraphValue<Self>, inputs: _TableColumnInputs) -> _TableColumnOutputs

    nonisolated static func _tableColumnCount(inputs: _TableColumnInputs) -> Int?
}

@available(OpenSwiftUI_v3_0, *)
extension TableColumnContent where TableColumnSortComparator == TableColumnBody.TableColumnSortComparator,
    TableRowValue == TableColumnBody.TableRowValue {
    nonisolated public static func _makeContent(content: _GraphValue<Self>, inputs: _TableColumnInputs) -> _TableColumnOutputs {
        _TableColumnOutputs()
    }
}

@available(OpenSwiftUI_v3_0, *)
extension TableColumnContent {
    nonisolated public static func _tableColumnCount(inputs: _TableColumnInputs) -> Int? { nil }
}

extension TableColumnContent where TableColumnBody == Never {
    nonisolated public var tableColumnBody: Never { fatalError("\(Self.self) has no body") }
}

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public protocol TableRowContent<TableRowValue> {
    associatedtype TableRowValue: Identifiable = Self.TableRowBody.TableRowValue
    associatedtype TableRowBody: TableRowContent

    @MainActor
    @preconcurrency
    var tableRowBody: Self.TableRowBody { get }

    nonisolated static func _makeRows(content: _GraphValue<Self>, inputs: _TableRowInputs) -> _TableRowOutputs

    nonisolated static func _tableRowCount(inputs: _TableRowInputs) -> Int?

    nonisolated static func _containsOutlineSymbol(inputs: _TableRowInputs) -> Bool
}

@available(OpenSwiftUI_v3_0, *)
extension TableRowContent {
    nonisolated public static func _makeRows(content: _GraphValue<Self>, inputs: _TableRowInputs) -> _TableRowOutputs {
        _TableRowOutputs()
    }

    nonisolated public static func _tableRowCount(inputs: _TableRowInputs) -> Int? { nil }

    nonisolated public static func _containsOutlineSymbol(inputs: _TableRowInputs) -> Bool { false }
}

extension TableRowContent where TableRowBody == Never {
    public var tableRowBody: Never { fatalError("\(Self.self) has no body") }
}

@available(OpenSwiftUI_v3_0, *)
extension Never {
    public typealias TableRowValue = Never
}

@available(OpenSwiftUI_v3_0, *)
extension Never: TableColumnContent {
    public typealias TableColumnSortComparator = Never
    public typealias TableColumnBody = Never

    nonisolated public static func _tableColumnCount(inputs: _TableColumnInputs) -> Int? { 0 }
}

@available(OpenSwiftUI_v3_0, *)
extension Never: TableRowContent {
    public typealias TableRowBody = Never

    nonisolated public static func _tableRowCount(inputs: _TableRowInputs) -> Int? { 0 }

    nonisolated public static func _containsOutlineSymbol(inputs: _TableRowInputs) -> Bool { false }
}

// MARK: - Columns

/// A column, read from the content: its title, its cell for a row's value, its width, and
/// how it sorts (if it does).
struct _FinchTableColumn<Value> {
    var title: Text
    var cell: (Value) -> AnyView
    var width: (min: CGFloat?, ideal: CGFloat?, max: CGFloat?)
    /// The column's comparator, type-erased (nil: the column doesn't sort).
    var comparator: Any?
}

@MainActor
protocol _FinchTableColumns {
    func _finchColumns<Value>(of _: Value.Type) -> [_FinchTableColumn<Value>]
}

@MainActor
func _finchTableColumnsOf<Value>(_ content: Any, _ value: Value.Type) -> [_FinchTableColumn<Value>] {
    (content as? _FinchTableColumns)?._finchColumns(of: value) ?? []
}

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public struct TableColumn<RowValue, Sort, Content, Label>: TableColumnContent
    where RowValue: Identifiable, Sort: SortComparator, Content: View, Label: View {
    public typealias TableRowValue = RowValue
    public typealias TableColumnSortComparator = Sort
    public typealias TableColumnBody = Never

    var label: Label
    var content: (RowValue) -> Content
    var comparator: Sort?
    var columnWidth: (min: CGFloat?, ideal: CGFloat?, max: CGFloat?) = (nil, nil, nil)

    nonisolated init(label: Label, comparator: Sort?, content: @escaping (RowValue) -> Content) {
        self.label = label
        self.comparator = comparator
        self.content = content
    }

    nonisolated public static func _makeContent(content: _GraphValue<TableColumn>, inputs: _TableColumnInputs) -> _TableColumnOutputs {
        _TableColumnOutputs()
    }

    nonisolated public static func _tableColumnCount(inputs: _TableColumnInputs) -> Int? { 1 }

    nonisolated public func width(_ width: CGFloat? = nil) -> TableColumn {
        var column = self
        column.columnWidth = (width, width, width)
        return column
    }

    nonisolated public func width(min: CGFloat? = nil, ideal: CGFloat? = nil, max: CGFloat? = nil) -> TableColumn {
        var column = self
        column.columnWidth = (min, ideal, max)
        return column
    }

    @_alwaysEmitIntoClient
    nonisolated public func width() -> TableColumn { self }
}

@available(*, unavailable) extension TableColumn: Sendable {}

extension TableColumn: _FinchTableColumns {
    func _finchColumns<Value>(of _: Value.Type) -> [_FinchTableColumn<Value>] {
        let content = content
        let title = _finchOptionTitles(label).first.flatMap { $0 } ?? Text(verbatim: "")
        return [_FinchTableColumn(title: title, cell: { value in
            (value as? RowValue).map { AnyView(content($0)) } ?? AnyView(EmptyView())
        }, width: columnWidth, comparator: comparator)]
    }
}

@available(OpenSwiftUI_v3_0, *)
extension TableColumn where Sort == Never, Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: nil, content: content)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, @ViewBuilder content: @escaping (RowValue) -> Content) where S: StringProtocol {
        self.init(label: Text(title), comparator: nil, content: content)
    }

    nonisolated public init(_ text: Text, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: nil, content: content)
    }

    nonisolated public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, String>) where Content == Text {
        self.init(label: Text(titleKey), comparator: nil, content: { Text($0[keyPath: value]) })
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, value: KeyPath<RowValue, String>) where Content == Text, S: StringProtocol {
        self.init(label: Text(title), comparator: nil, content: { Text($0[keyPath: value]) })
    }

    nonisolated public init(_ text: Text, value: KeyPath<RowValue, String>) where Content == Text {
        self.init(label: text, comparator: nil, content: { Text($0[keyPath: value]) })
    }
}

@available(OpenSwiftUI_v3_0, *)
extension TableColumn where RowValue == Sort.Compared, Label == Text {
    nonisolated public init(_ titleKey: LocalizedStringKey, sortUsing comparator: Sort,
                            @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(titleKey), comparator: comparator, content: content)
    }

    @_disfavoredOverload
    nonisolated public init<S>(_ title: S, sortUsing comparator: Sort, @ViewBuilder content: @escaping (RowValue) -> Content)
        where S: StringProtocol {
        self.init(label: Text(title), comparator: comparator, content: content)
    }

    nonisolated public init(_ text: Text, sortUsing comparator: Sort, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: comparator, content: content)
    }
}

@available(OpenSwiftUI_v3_0, *)
extension TableColumn where Sort == KeyPathComparator<RowValue>, Label == Text {
    public init<V>(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, V>, @ViewBuilder content: @escaping (RowValue) -> Content)
        where V: Comparable {
        self.init(label: Text(titleKey), comparator: KeyPathComparator(value), content: content)
    }

    @_disfavoredOverload
    public init<S, V>(_ title: S, value: KeyPath<RowValue, V>, @ViewBuilder content: @escaping (RowValue) -> Content)
        where S: StringProtocol, V: Comparable {
        self.init(label: Text(title), comparator: KeyPathComparator(value), content: content)
    }

    public init<V>(_ text: Text, value: KeyPath<RowValue, V>, @ViewBuilder content: @escaping (RowValue) -> Content)
        where V: Comparable {
        self.init(label: text, comparator: KeyPathComparator(value), content: content)
    }

    public init<V, C>(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, V>, comparator: C,
                      @ViewBuilder content: @escaping (RowValue) -> Content) where V == C.Compared, C: SortComparator {
        self.init(label: Text(titleKey), comparator: KeyPathComparator(value, comparator: comparator), content: content)
    }

    @_disfavoredOverload
    public init<S, V, C>(_ title: S, value: KeyPath<RowValue, V>, comparator: C,
                         @ViewBuilder content: @escaping (RowValue) -> Content)
        where S: StringProtocol, V == C.Compared, C: SortComparator {
        self.init(label: Text(title), comparator: KeyPathComparator(value, comparator: comparator), content: content)
    }

    public init<V, C>(_ text: Text, value: KeyPath<RowValue, V>, comparator: C,
                      @ViewBuilder content: @escaping (RowValue) -> Content) where V == C.Compared, C: SortComparator {
        self.init(label: text, comparator: KeyPathComparator(value, comparator: comparator), content: content)
    }

    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, String>,
                comparator: String.StandardComparator = .localizedStandard) where Content == Text {
        self.init(label: Text(titleKey), comparator: KeyPathComparator(value, comparator: comparator),
                  content: { Text($0[keyPath: value]) })
    }

    @_disfavoredOverload
    public init<S>(_ title: S, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard)
        where Content == Text, S: StringProtocol {
        self.init(label: Text(title), comparator: KeyPathComparator(value, comparator: comparator),
                  content: { Text($0[keyPath: value]) })
    }

    public init(_ text: Text, value: KeyPath<RowValue, String>, comparator: String.StandardComparator = .localizedStandard)
        where Content == Text {
        self.init(label: text, comparator: KeyPathComparator(value, comparator: comparator), content: { Text($0[keyPath: value]) })
    }
}

@available(OpenSwiftUI_v3_0, *)
@frozen
public struct TupleTableColumnContent<RowValue, Sort, T>: TableColumnContent where RowValue: Identifiable, Sort: SortComparator {
    public typealias TableRowValue = RowValue
    public typealias TableColumnSortComparator = Sort
    public typealias TableColumnBody = Never

    public var value: T

    @inlinable
    init(_ value: T, valueType: RowValue.Type, sortType: Sort.Type) {
        self.value = value
    }

    nonisolated public static func _makeContent(content: _GraphValue<TupleTableColumnContent>, inputs: _TableColumnInputs)
        -> _TableColumnOutputs {
        _TableColumnOutputs()
    }

    nonisolated public static func _tableColumnCount(inputs: _TableColumnInputs) -> Int? { nil }
}

@available(*, unavailable) extension TupleTableColumnContent: Sendable {}

extension TupleTableColumnContent: _FinchTableColumns {
    func _finchColumns<Value>(of type: Value.Type) -> [_FinchTableColumn<Value>] {
        Mirror(reflecting: value).children.flatMap { _finchTableColumnsOf($0.value, type) }
    }
}

extension _ConditionalContent: _FinchTableColumns {
    func _finchColumns<Value>(of type: Value.Type) -> [_FinchTableColumn<Value>] {
        switch storage {
        case let .trueContent(content): _finchTableColumnsOf(content, type)
        case let .falseContent(content): _finchTableColumnsOf(content, type)
        }
    }
}

extension Optional: _FinchTableColumns {
    func _finchColumns<Value>(of type: Value.Type) -> [_FinchTableColumn<Value>] {
        map { _finchTableColumnsOf($0, type) } ?? []
    }
}

@available(OpenSwiftUI_v3_0, *)
extension _ConditionalContent: TableColumnContent
    where TrueContent: TableColumnContent, FalseContent: TableColumnContent,
    TrueContent.TableRowValue == FalseContent.TableRowValue,
    TrueContent.TableColumnSortComparator == FalseContent.TableColumnSortComparator {
    public typealias TableRowValue = TrueContent.TableRowValue
    public typealias TableColumnSortComparator = TrueContent.TableColumnSortComparator
    public typealias TableColumnBody = Never

    @usableFromInline
    init(storage: Storage) {
        self.init(__storage: storage)
    }

    nonisolated public static func _makeContent(content: _GraphValue<_ConditionalContent<TrueContent, FalseContent>>,
                                                inputs: _TableColumnInputs) -> _TableColumnOutputs {
        _TableColumnOutputs()
    }

    nonisolated public static func _tableColumnCount(inputs: _TableColumnInputs) -> Int? { nil }
}

@available(OpenSwiftUI_v3_0, *)
extension _ConditionalContent: TableRowContent
    where TrueContent: TableRowContent, FalseContent: TableRowContent, TrueContent.TableRowValue == FalseContent.TableRowValue {
    public typealias TableRowValue = TrueContent.TableRowValue
    public typealias TableRowBody = Never

    @usableFromInline
    init(storage: Storage) {
        self.init(__storage: storage)
    }
}

extension _ConditionalContent: _FinchTableRows {
    var _finchRowValues: [Any] {
        switch storage {
        case let .trueContent(content): _finchTableRowsOf(content)
        case let .falseContent(content): _finchTableRowsOf(content)
        }
    }
}

@available(OpenSwiftUI_v3_0, *)
extension Optional: TableColumnContent where Wrapped: TableColumnContent {
    public typealias TableRowValue = Wrapped.TableRowValue
    public typealias TableColumnSortComparator = Wrapped.TableColumnSortComparator
    public typealias TableColumnBody = Never

    nonisolated public static func _makeContent(content: _GraphValue<Optional<Wrapped>>, inputs: _TableColumnInputs)
        -> _TableColumnOutputs {
        _TableColumnOutputs()
    }

    nonisolated public static func _tableColumnCount(inputs: _TableColumnInputs) -> Int? { nil }
}

@available(OpenSwiftUI_v3_0, *)
extension Optional: TableRowContent where Wrapped: TableRowContent {
    public typealias TableRowValue = Wrapped.TableRowValue
    public typealias TableRowBody = Never
}

extension Optional: _FinchTableRows {
    var _finchRowValues: [Any] { map { _finchTableRowsOf($0) } ?? [] }
}

// MARK: - Rows

@MainActor
protocol _FinchTableRows {
    var _finchRowValues: [Any] { get }
}

@MainActor
func _finchTableRowsOf(_ content: Any) -> [Any] {
    if let rows = content as? _FinchTableRows { return rows._finchRowValues }
    if let rows = content as? any TableRowContent { return _finchTableRowBody(rows) }
    return []
}

@MainActor
private func _finchTableRowBody<R: TableRowContent>(_ rows: R) -> [Any] {
    guard R.TableRowBody.self != Never.self else { return [] }
    return _finchTableRowsOf(rows.tableRowBody)
}

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public struct TableRow<Value>: TableRowContent where Value: Identifiable {
    public typealias TableRowValue = Value
    public typealias TableRowBody = Never

    var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    nonisolated public static func _tableRowCount(inputs: _TableRowInputs) -> Int? { 1 }

    nonisolated public static func _makeRows(content: _GraphValue<TableRow>, inputs: _TableRowInputs) -> _TableRowOutputs {
        _TableRowOutputs()
    }

    nonisolated public static func _containsOutlineSymbol(inputs: _TableRowInputs) -> Bool { false }
}

@available(*, unavailable) extension TableRow: Sendable {}

extension TableRow: _FinchTableRows {
    var _finchRowValues: [Any] { [value] }
}

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public struct TableForEachContent<Data>: TableRowContent where Data: RandomAccessCollection, Data.Element: Identifiable {
    public typealias TableRowValue = Data.Element

    var data: Data

    @MainActor
    @preconcurrency
    public var tableRowBody: some TableRowContent {
        TupleTableRowContent<Data.Element, [TableRow<Data.Element>]>(data.map(TableRow.init), ofType: Data.Element.self)
    }
}

@available(*, unavailable) extension TableForEachContent: Sendable {}

extension TableForEachContent: _FinchTableRows {
    var _finchRowValues: [Any] { data.map { $0 as Any } }
}

@available(OpenSwiftUI_v3_0, *)
@frozen
public struct TupleTableRowContent<Value, T>: TableRowContent where Value: Identifiable {
    public typealias TableRowValue = Value
    public typealias TableRowBody = Never

    public var value: T

    @inlinable
    init(_ value: T, ofType: Value.Type) {
        self.value = value
    }

    nonisolated public static func _makeRows(content: _GraphValue<TupleTableRowContent>, inputs: _TableRowInputs) -> _TableRowOutputs {
        _TableRowOutputs()
    }

    nonisolated public static func _tableRowCount(inputs: _TableRowInputs) -> Int? { nil }

    nonisolated public static func _containsOutlineSymbol(inputs: _TableRowInputs) -> Bool { false }
}

@available(*, unavailable) extension TupleTableRowContent: Sendable {}

extension TupleTableRowContent: _FinchTableRows {
    var _finchRowValues: [Any] {
        if let rows = value as? [Any] { return rows.flatMap(_finchTableRowsOf) }
        return Mirror(reflecting: value).children.flatMap { _finchTableRowsOf($0.value) }
    }
}

// MARK: - Builders

@available(OpenSwiftUI_v3_0, *)
@resultBuilder
public struct TableColumnBuilder<RowValue, Sort> where RowValue: Identifiable, Sort: SortComparator {
    @_alwaysEmitIntoClient
    public static func buildExpression<Content, Label>(_ column: TableColumn<RowValue, Sort, Content, Label>)
        -> TableColumn<RowValue, Sort, Content, Label> where Content: View, Label: View {
        column
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildExpression<Content, Label>(_ column: TableColumn<RowValue, Never, Content, Label>)
        -> TableColumn<RowValue, Never, Content, Label> where Content: View, Label: View {
        column
    }

    @_alwaysEmitIntoClient
    public static func buildExpression<Column>(_ column: Column) -> Column
        where RowValue == Column.TableRowValue, Sort == Column.TableColumnSortComparator, Column: TableColumnContent {
        column
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildExpression<Column>(_ column: Column) -> Column
        where RowValue == Column.TableRowValue, Column: TableColumnContent, Column.TableColumnSortComparator == Never {
        column
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<Column>(_ column: Column) -> Column
        where RowValue == Column.TableRowValue, Sort == Column.TableColumnSortComparator, Column: TableColumnContent {
        column
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<Column>(_ column: Column) -> Column
        where RowValue == Column.TableRowValue, Column: TableColumnContent, Column.TableColumnSortComparator == Never {
        column
    }

    @_alwaysEmitIntoClient
    public static func buildIf<C>(_ content: C?) -> C?
        where RowValue == C.TableRowValue, Sort == C.TableColumnSortComparator, C: TableColumnContent {
        content
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildIf<C>(_ content: C?) -> C?
        where RowValue == C.TableRowValue, C: TableColumnContent, C.TableColumnSortComparator == Never {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildEither<T, F>(first: T) -> _ConditionalContent<T, F>
        where RowValue == T.TableRowValue, Sort == T.TableColumnSortComparator, T: TableColumnContent, F: TableColumnContent,
        T.TableColumnSortComparator == F.TableColumnSortComparator, T.TableRowValue == F.TableRowValue {
        _ConditionalContent<T, F>(storage: .trueContent(first))
    }

    @_alwaysEmitIntoClient
    public static func buildEither<T, F>(second: F) -> _ConditionalContent<T, F>
        where RowValue == T.TableRowValue, Sort == T.TableColumnSortComparator, T: TableColumnContent, F: TableColumnContent,
        T.TableColumnSortComparator == F.TableColumnSortComparator, T.TableRowValue == F.TableRowValue {
        _ConditionalContent<T, F>(storage: .falseContent(second))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1>(_ c0: C0, _ c1: C1) -> TupleTableColumnContent<RowValue, Sort, (C0, C1)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C0.TableRowValue == C1.TableRowValue {
        TupleTableColumnContent((c0, c1), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1>(_ c0: C0, _ c1: C1) -> TupleTableColumnContent<RowValue, Never, (C0, C1)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue {
        TupleTableColumnContent((c0, c1), valueType: RowValue.self, sortType: Never.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2>(_ c0: C0, _ c1: C1, _ c2: C2) -> TupleTableColumnContent<RowValue, Sort, (C0, C1, C2)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue {
        TupleTableColumnContent((c0, c1, c2), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1, C2>(_ c0: C0, _ c1: C1, _ c2: C2) -> TupleTableColumnContent<RowValue, Never, (C0, C1, C2)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue, C2.TableColumnSortComparator == Never, C1.TableRowValue == C2.TableRowValue {
        TupleTableColumnContent((c0, c1, c2), valueType: RowValue.self, sortType: Never.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> TupleTableColumnContent<RowValue, Sort, (C0, C1, C2, C3)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1, C2, C3>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> TupleTableColumnContent<RowValue, Never, (C0, C1, C2, C3)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue, C2.TableColumnSortComparator == Never, C1.TableRowValue == C2.TableRowValue, C3.TableColumnSortComparator == Never, C2.TableRowValue == C3.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3), valueType: RowValue.self, sortType: Never.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> TupleTableColumnContent<RowValue, Sort, (C0, C1, C2, C3, C4)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1, C2, C3, C4>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> TupleTableColumnContent<RowValue, Never, (C0, C1, C2, C3, C4)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue, C2.TableColumnSortComparator == Never, C1.TableRowValue == C2.TableRowValue, C3.TableColumnSortComparator == Never, C2.TableRowValue == C3.TableRowValue, C4.TableColumnSortComparator == Never, C3.TableRowValue == C4.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4), valueType: RowValue.self, sortType: Never.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5) -> TupleTableColumnContent<RowValue, Sort, (C0, C1, C2, C3, C4, C5)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1, C2, C3, C4, C5>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5) -> TupleTableColumnContent<RowValue, Never, (C0, C1, C2, C3, C4, C5)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue, C2.TableColumnSortComparator == Never, C1.TableRowValue == C2.TableRowValue, C3.TableColumnSortComparator == Never, C2.TableRowValue == C3.TableRowValue, C4.TableColumnSortComparator == Never, C3.TableRowValue == C4.TableRowValue, C5.TableColumnSortComparator == Never, C4.TableRowValue == C5.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5), valueType: RowValue.self, sortType: Never.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> TupleTableColumnContent<RowValue, Sort, (C0, C1, C2, C3, C4, C5, C6)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C6: TableColumnContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue, C5.TableRowValue == C6.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5, c6), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> TupleTableColumnContent<RowValue, Never, (C0, C1, C2, C3, C4, C5, C6)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C6: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue, C2.TableColumnSortComparator == Never, C1.TableRowValue == C2.TableRowValue, C3.TableColumnSortComparator == Never, C2.TableRowValue == C3.TableRowValue, C4.TableColumnSortComparator == Never, C3.TableRowValue == C4.TableRowValue, C5.TableColumnSortComparator == Never, C4.TableRowValue == C5.TableRowValue, C6.TableColumnSortComparator == Never, C5.TableRowValue == C6.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5, c6), valueType: RowValue.self, sortType: Never.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7) -> TupleTableColumnContent<RowValue, Sort, (C0, C1, C2, C3, C4, C5, C6, C7)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C6: TableColumnContent, C7: TableColumnContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue, C5.TableRowValue == C6.TableRowValue, C6.TableRowValue == C7.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5, c6, c7), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7) -> TupleTableColumnContent<RowValue, Never, (C0, C1, C2, C3, C4, C5, C6, C7)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C6: TableColumnContent, C7: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue, C2.TableColumnSortComparator == Never, C1.TableRowValue == C2.TableRowValue, C3.TableColumnSortComparator == Never, C2.TableRowValue == C3.TableRowValue, C4.TableColumnSortComparator == Never, C3.TableRowValue == C4.TableRowValue, C5.TableColumnSortComparator == Never, C4.TableRowValue == C5.TableRowValue, C6.TableColumnSortComparator == Never, C5.TableRowValue == C6.TableRowValue, C7.TableColumnSortComparator == Never, C6.TableRowValue == C7.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5, c6, c7), valueType: RowValue.self, sortType: Never.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7, C8>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8) -> TupleTableColumnContent<RowValue, Sort, (C0, C1, C2, C3, C4, C5, C6, C7, C8)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C6: TableColumnContent, C7: TableColumnContent, C8: TableColumnContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue, C5.TableRowValue == C6.TableRowValue, C6.TableRowValue == C7.TableRowValue, C7.TableRowValue == C8.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5, c6, c7, c8), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7, C8>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8) -> TupleTableColumnContent<RowValue, Never, (C0, C1, C2, C3, C4, C5, C6, C7, C8)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C6: TableColumnContent, C7: TableColumnContent, C8: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue, C2.TableColumnSortComparator == Never, C1.TableRowValue == C2.TableRowValue, C3.TableColumnSortComparator == Never, C2.TableRowValue == C3.TableRowValue, C4.TableColumnSortComparator == Never, C3.TableRowValue == C4.TableRowValue, C5.TableColumnSortComparator == Never, C4.TableRowValue == C5.TableRowValue, C6.TableColumnSortComparator == Never, C5.TableRowValue == C6.TableRowValue, C7.TableColumnSortComparator == Never, C6.TableRowValue == C7.TableRowValue, C8.TableColumnSortComparator == Never, C7.TableRowValue == C8.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5, c6, c7, c8), valueType: RowValue.self, sortType: Never.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7, C8, C9>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9) -> TupleTableColumnContent<RowValue, Sort, (C0, C1, C2, C3, C4, C5, C6, C7, C8, C9)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C6: TableColumnContent, C7: TableColumnContent, C8: TableColumnContent, C9: TableColumnContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue, C5.TableRowValue == C6.TableRowValue, C6.TableRowValue == C7.TableRowValue, C7.TableRowValue == C8.TableRowValue, C8.TableRowValue == C9.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5, c6, c7, c8, c9), valueType: RowValue.self, sortType: Sort.self)
    }

    @_alwaysEmitIntoClient @_disfavoredOverload
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7, C8, C9>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9) -> TupleTableColumnContent<RowValue, Never, (C0, C1, C2, C3, C4, C5, C6, C7, C8, C9)>
        where RowValue == C0.TableRowValue, C0: TableColumnContent, C1: TableColumnContent, C2: TableColumnContent, C3: TableColumnContent, C4: TableColumnContent, C5: TableColumnContent, C6: TableColumnContent, C7: TableColumnContent, C8: TableColumnContent, C9: TableColumnContent, C0.TableColumnSortComparator == Never, C1.TableColumnSortComparator == Never, C0.TableRowValue == C1.TableRowValue, C2.TableColumnSortComparator == Never, C1.TableRowValue == C2.TableRowValue, C3.TableColumnSortComparator == Never, C2.TableRowValue == C3.TableRowValue, C4.TableColumnSortComparator == Never, C3.TableRowValue == C4.TableRowValue, C5.TableColumnSortComparator == Never, C4.TableRowValue == C5.TableRowValue, C6.TableColumnSortComparator == Never, C5.TableRowValue == C6.TableRowValue, C7.TableColumnSortComparator == Never, C6.TableRowValue == C7.TableRowValue, C8.TableColumnSortComparator == Never, C7.TableRowValue == C8.TableRowValue, C9.TableColumnSortComparator == Never, C8.TableRowValue == C9.TableRowValue {
        TupleTableColumnContent((c0, c1, c2, c3, c4, c5, c6, c7, c8, c9), valueType: RowValue.self, sortType: Never.self)
    }
}

@available(*, unavailable) extension TableColumnBuilder: Sendable {}

@available(OpenSwiftUI_v3_0, *)
@resultBuilder
public struct TableRowBuilder<Value> where Value: Identifiable {
    @_alwaysEmitIntoClient
    public static func buildExpression<Content>(_ content: Content) -> Content
        where Value == Content.TableRowValue, Content: TableRowContent {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C>(_ content: C) -> C where Value == C.TableRowValue, C: TableRowContent {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildIf<C>(_ content: C?) -> C? where Value == C.TableRowValue, C: TableRowContent {
        content
    }

    @_alwaysEmitIntoClient
    public static func buildEither<T, F>(first: T) -> _ConditionalContent<T, F>
        where Value == T.TableRowValue, T: TableRowContent, F: TableRowContent, T.TableRowValue == F.TableRowValue {
        _ConditionalContent<T, F>(storage: .trueContent(first))
    }

    @_alwaysEmitIntoClient
    public static func buildEither<T, F>(second: F) -> _ConditionalContent<T, F>
        where Value == T.TableRowValue, T: TableRowContent, F: TableRowContent, T.TableRowValue == F.TableRowValue {
        _ConditionalContent<T, F>(storage: .falseContent(second))
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1>(_ c0: C0, _ c1: C1) -> TupleTableRowContent<Value, (C0, C1)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C0.TableRowValue == C1.TableRowValue {
        TupleTableRowContent((c0, c1), ofType: Value.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2>(_ c0: C0, _ c1: C1, _ c2: C2) -> TupleTableRowContent<Value, (C0, C1, C2)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C2: TableRowContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue {
        TupleTableRowContent((c0, c1, c2), ofType: Value.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> TupleTableRowContent<Value, (C0, C1, C2, C3)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C2: TableRowContent, C3: TableRowContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue {
        TupleTableRowContent((c0, c1, c2, c3), ofType: Value.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> TupleTableRowContent<Value, (C0, C1, C2, C3, C4)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C2: TableRowContent, C3: TableRowContent, C4: TableRowContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue {
        TupleTableRowContent((c0, c1, c2, c3, c4), ofType: Value.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5) -> TupleTableRowContent<Value, (C0, C1, C2, C3, C4, C5)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C2: TableRowContent, C3: TableRowContent, C4: TableRowContent, C5: TableRowContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue {
        TupleTableRowContent((c0, c1, c2, c3, c4, c5), ofType: Value.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> TupleTableRowContent<Value, (C0, C1, C2, C3, C4, C5, C6)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C2: TableRowContent, C3: TableRowContent, C4: TableRowContent, C5: TableRowContent, C6: TableRowContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue, C5.TableRowValue == C6.TableRowValue {
        TupleTableRowContent((c0, c1, c2, c3, c4, c5, c6), ofType: Value.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7) -> TupleTableRowContent<Value, (C0, C1, C2, C3, C4, C5, C6, C7)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C2: TableRowContent, C3: TableRowContent, C4: TableRowContent, C5: TableRowContent, C6: TableRowContent, C7: TableRowContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue, C5.TableRowValue == C6.TableRowValue, C6.TableRowValue == C7.TableRowValue {
        TupleTableRowContent((c0, c1, c2, c3, c4, c5, c6, c7), ofType: Value.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7, C8>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8) -> TupleTableRowContent<Value, (C0, C1, C2, C3, C4, C5, C6, C7, C8)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C2: TableRowContent, C3: TableRowContent, C4: TableRowContent, C5: TableRowContent, C6: TableRowContent, C7: TableRowContent, C8: TableRowContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue, C5.TableRowValue == C6.TableRowValue, C6.TableRowValue == C7.TableRowValue, C7.TableRowValue == C8.TableRowValue {
        TupleTableRowContent((c0, c1, c2, c3, c4, c5, c6, c7, c8), ofType: Value.self)
    }

    @_alwaysEmitIntoClient
    public static func buildBlock<C0, C1, C2, C3, C4, C5, C6, C7, C8, C9>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9) -> TupleTableRowContent<Value, (C0, C1, C2, C3, C4, C5, C6, C7, C8, C9)>
        where Value == C0.TableRowValue, C0: TableRowContent, C1: TableRowContent, C2: TableRowContent, C3: TableRowContent, C4: TableRowContent, C5: TableRowContent, C6: TableRowContent, C7: TableRowContent, C8: TableRowContent, C9: TableRowContent, C0.TableRowValue == C1.TableRowValue, C1.TableRowValue == C2.TableRowValue, C2.TableRowValue == C3.TableRowValue, C3.TableRowValue == C4.TableRowValue, C4.TableRowValue == C5.TableRowValue, C5.TableRowValue == C6.TableRowValue, C6.TableRowValue == C7.TableRowValue, C7.TableRowValue == C8.TableRowValue, C8.TableRowValue == C9.TableRowValue {
        TupleTableRowContent((c0, c1, c2, c3, c4, c5, c6, c7, c8, c9), ofType: Value.self)
    }
}

@available(*, unavailable) extension TableRowBuilder: Sendable {}

// MARK: - Table

/// What a table selects: nothing, one row, or a set of rows.
enum _FinchTableSelection {
    case none
    case single(get: () -> AnyHashable?, set: (AnyHashable?) -> Void)
    case multiple(get: () -> Set<AnyHashable>, set: (Set<AnyHashable>) -> Void)

    func contains(_ id: AnyHashable) -> Bool {
        switch self {
        case .none: false
        case let .single(get, _): get() == id
        case let .multiple(get, _): get().contains(id)
        }
    }

    func select(_ id: AnyHashable) {
        switch self {
        case .none: break
        case let .single(_, set): set(id)
        case let .multiple(_, set): set([id])
        }
    }
}

/// The sort order binding, type-erased: the comparators and how to set them.
struct _FinchTableSortOrder {
    var get: () -> [Any]
    var set: ([Any]) -> Void
}

@available(OpenSwiftUI_v3_0, *)
@MainActor
@preconcurrency
public struct Table<Value, Rows, Columns>: View
    where Value == Rows.TableRowValue, Rows: TableRowContent, Columns: TableColumnContent,
    Rows.TableRowValue == Columns.TableRowValue {
    var rows: Rows
    var columns: Columns
    var selection: _FinchTableSelection = .none
    var sortOrder: _FinchTableSortOrder?

    nonisolated init(rows: Rows, columns: Columns, selection: _FinchTableSelection, sortOrder: _FinchTableSortOrder?) {
        self.rows = rows
        self.columns = columns
        self.selection = selection
        self.sortOrder = sortOrder
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchTableView(columns: _finchTableColumnsOf(columns, Value.self),
                        rows: _finchTableRowsOf(rows).compactMap { $0 as? Value },
                        selection: selection, sortOrder: sortOrder)
    }
}

@available(*, unavailable) extension Table: Sendable {}

private func _finchSelection<ID: Hashable>(_ binding: Binding<ID?>) -> _FinchTableSelection {
    .single(get: { binding.wrappedValue.map(AnyHashable.init) }, set: { binding.wrappedValue = $0?.base as? ID })
}

private func _finchSelection<ID: Hashable>(_ binding: Binding<Set<ID>>) -> _FinchTableSelection {
    .multiple(get: { Set(binding.wrappedValue.map(AnyHashable.init)) },
              set: { binding.wrappedValue = Set($0.compactMap { $0.base as? ID }) })
}

private func _finchSortOrder<Sort>(_ binding: Binding<[Sort]>) -> _FinchTableSortOrder {
    _FinchTableSortOrder(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0.compactMap { $0 as? Sort } })
}

@available(OpenSwiftUI_v3_0, *)
extension Table {
    @usableFromInline
    nonisolated init(@TableColumnBuilder<Value, Never> columns: () -> Columns, @TableRowBuilder<Value> rows: () -> Rows) {
        self.init(rows: rows(), columns: columns(), selection: .none, sortOrder: nil)
    }

    @usableFromInline
    nonisolated init(selection: Binding<Value.ID?>, @TableColumnBuilder<Value, Never> columns: () -> Columns,
                     @TableRowBuilder<Value> rows: () -> Rows) {
        self.init(rows: rows(), columns: columns(), selection: _finchSelection(selection), sortOrder: nil)
    }

    @usableFromInline
    nonisolated init(selection: Binding<Set<Value.ID>>, @TableColumnBuilder<Value, Never> columns: () -> Columns,
                     @TableRowBuilder<Value> rows: () -> Rows) {
        self.init(rows: rows(), columns: columns(), selection: _finchSelection(selection), sortOrder: nil)
    }

    nonisolated public init<Sort>(sortOrder: Binding<[Sort]>, @TableColumnBuilder<Value, Sort> columns: () -> Columns,
                                  @TableRowBuilder<Value> rows: () -> Rows)
        where Sort: SortComparator, Columns.TableRowValue == Sort.Compared {
        self.init(rows: rows(), columns: columns(), selection: .none, sortOrder: _finchSortOrder(sortOrder))
    }

    nonisolated public init<Sort>(selection: Binding<Value.ID?>, sortOrder: Binding<[Sort]>,
                                  @TableColumnBuilder<Value, Sort> columns: () -> Columns, @TableRowBuilder<Value> rows: () -> Rows)
        where Sort: SortComparator, Columns.TableRowValue == Sort.Compared {
        self.init(rows: rows(), columns: columns(), selection: _finchSelection(selection), sortOrder: _finchSortOrder(sortOrder))
    }

    nonisolated public init<Sort>(selection: Binding<Set<Value.ID>>, sortOrder: Binding<[Sort]>,
                                  @TableColumnBuilder<Value, Sort> columns: () -> Columns, @TableRowBuilder<Value> rows: () -> Rows)
        where Sort: SortComparator, Columns.TableRowValue == Sort.Compared {
        self.init(rows: rows(), columns: columns(), selection: _finchSelection(selection), sortOrder: _finchSortOrder(sortOrder))
    }
}

@available(OpenSwiftUI_v3_0, *)
extension Table {
    nonisolated public init<Data>(_ data: Data, @TableColumnBuilder<Value, Never> columns: () -> Columns)
        where Rows == TableForEachContent<Data>, Data: RandomAccessCollection, Columns.TableRowValue == Data.Element {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: .none, sortOrder: nil)
    }

    nonisolated public init<Data>(_ data: Data, selection: Binding<Value.ID?>, @TableColumnBuilder<Value, Never> columns: () -> Columns)
        where Rows == TableForEachContent<Data>, Data: RandomAccessCollection, Columns.TableRowValue == Data.Element {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: _finchSelection(selection), sortOrder: nil)
    }

    nonisolated public init<Data>(_ data: Data, selection: Binding<Set<Value.ID>>,
                                  @TableColumnBuilder<Value, Never> columns: () -> Columns)
        where Rows == TableForEachContent<Data>, Data: RandomAccessCollection, Columns.TableRowValue == Data.Element {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: _finchSelection(selection), sortOrder: nil)
    }

    nonisolated public init<Data, Sort>(_ data: Data, sortOrder: Binding<[Sort]>, @TableColumnBuilder<Value, Sort> columns: () -> Columns)
        where Rows == TableForEachContent<Data>, Data: RandomAccessCollection, Sort: SortComparator,
        Columns.TableRowValue == Data.Element, Data.Element == Sort.Compared {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: .none, sortOrder: _finchSortOrder(sortOrder))
    }

    nonisolated public init<Data, Sort>(_ data: Data, selection: Binding<Value.ID?>, sortOrder: Binding<[Sort]>,
                                        @TableColumnBuilder<Value, Sort> columns: () -> Columns)
        where Rows == TableForEachContent<Data>, Data: RandomAccessCollection, Sort: SortComparator,
        Columns.TableRowValue == Data.Element, Data.Element == Sort.Compared {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: _finchSelection(selection),
                  sortOrder: _finchSortOrder(sortOrder))
    }

    nonisolated public init<Data, Sort>(_ data: Data, selection: Binding<Set<Value.ID>>, sortOrder: Binding<[Sort]>,
                                        @TableColumnBuilder<Value, Sort> columns: () -> Columns)
        where Rows == TableForEachContent<Data>, Data: RandomAccessCollection, Sort: SortComparator,
        Columns.TableRowValue == Data.Element, Data.Element == Sort.Compared {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: _finchSelection(selection),
                  sortOrder: _finchSortOrder(sortOrder))
    }
}

// MARK: - Drawing

/// The table: a header of titles over scrolling rows of cells.
struct _FinchTableView<Value: Identifiable>: View {
    var columns: [_FinchTableColumn<Value>]
    var rows: [Value]
    var selection: _FinchTableSelection
    var sortOrder: _FinchTableSortOrder?

    private static var rowHeight: CGFloat { 24 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, value in
                        row(value, index: index)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { index in
                let column = columns[index]
                cell(index) {
                    HStack(spacing: 4) {
                        column.title.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        if let mark = sortMark(index) {
                            Text(verbatim: mark).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { sort(by: index) }
                if index < columns.count - 1 { Divider() }
            }
        }
        .frame(height: 22)
    }

    private func row(_ value: Value, index: Int) -> some View {
        let id = AnyHashable(value.id)
        let selected = selection.contains(id)
        return HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { column in
                cell(column) { columns[column].cell(value) }
                if column < columns.count - 1 { Spacer().frame(width: 1) }
            }
        }
        .frame(height: Self.rowHeight)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : index % 2 == 1 ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection.select(id) }
    }

    /// A column's cell: at its width (or sharing what's left), its content leading.
    @ViewBuilder
    private func cell<C: View>(_ index: Int, @ViewBuilder _ content: () -> C) -> some View {
        let width = columns[index].width
        content()
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: width.min ?? width.ideal, idealWidth: width.ideal, maxWidth: width.max ?? .infinity,
                   alignment: .leading)
    }

    /// The column's sort mark, if it's the sort order's first.
    private func sortMark(_ index: Int) -> String? {
        guard let comparator = columns[index].comparator, let first = sortOrder?.get().first else { return nil }
        guard _finchSameComparator(first, comparator) else { return nil }
        return _finchOrder(of: first) == .forward ? "\u{25B2}" : "\u{25BC}"
    }

    /// Clicking a sortable column's title: sorts by it, or reverses it if it's sorting already.
    private func sort(by index: Int) {
        guard let sortOrder, let comparator = columns[index].comparator else { return }
        var order = sortOrder.get()
        if let first = order.first, _finchSameComparator(first, comparator) {
            order[0] = _finchReversed(first)
        } else {
            order.removeAll { _finchSameComparator($0, comparator) }
            order.insert(comparator, at: 0)
        }
        sortOrder.set(order)
    }
}

/// Whether two comparators sort by the same thing (ignoring their order).
private func _finchSameComparator(_ a: Any, _ b: Any) -> Bool {
    func reset(_ c: Any) -> AnyHashable? {
        guard var comparator = c as? any SortComparator else { return nil }
        comparator.order = .forward
        return (comparator as? AnyHashable) ?? AnyHashable(String(reflecting: comparator))
    }
    return reset(a) == reset(b)
}

private func _finchOrder(of comparator: Any) -> SortOrder {
    (comparator as? any SortComparator)?.order ?? .forward
}

private func _finchReversed(_ comparator: Any) -> Any {
    guard var c = comparator as? any SortComparator else { return comparator }
    c.order = c.order == .forward ? .reverse : .forward
    return c
}
