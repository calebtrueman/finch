// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The titles of a picker's options, for the menu items of the AppKit pop-up button that shows
// them: the first Text of each option, in the order the content lays the options out. The
// content's containers (tuples, ForEach, groups, conditions) are walked; each other view is
// one option.

import SwiftUICore

/// A view that is a sequence of other views, as a variadic view lays it out.
protocol _FinchViewSequence {
    var _finchViews: [Any] { get }
}

extension TupleView: _FinchViewSequence {
    var _finchViews: [Any] { Mirror(reflecting: value).children.map(\.value) }
}

extension ForEach: _FinchViewSequence {
    var _finchViews: [Any] { data.map { content($0) } }
}

extension Group: _FinchViewSequence {
    var _finchViews: [Any] { [content] }
}

extension _ConditionalContent: _FinchViewSequence {
    var _finchViews: [Any] {
        switch storage {
        case let .trueContent(view): [view]
        case let .falseContent(view): [view]
        }
    }
}

extension Optional: _FinchViewSequence where Wrapped: View {
    var _finchViews: [Any] { map { [$0] } ?? [] }
}

extension EmptyView: _FinchViewSequence {
    var _finchViews: [Any] { [] }
}

/// A modified view, whose modifiers apply to each view of a sequence it wraps.
protocol _FinchModifiedView {
    var _finchContent: Any { get }
}

extension ModifiedContent: _FinchModifiedView {
    var _finchContent: Any { content }
}

/// The options of `content`, each its first Text (nil when it has none).
func _finchOptionTitles(_ content: Any) -> [Text?] {
    if let sequence = content as? _FinchViewSequence {
        return sequence._finchViews.flatMap(_finchOptionTitles)
    }
    if let modified = content as? _FinchModifiedView, modified._finchContent is _FinchViewSequence {
        return _finchOptionTitles(modified._finchContent)
    }
    return [_finchFirstText(content, depth: 0)]
}

private func _finchFirstText(_ view: Any, depth: Int) -> Text? {
    if let text = view as? Text {
        return text
    }
    guard depth < 8 else {
        return nil
    }
    for child in Mirror(reflecting: view).children {
        if let text = _finchFirstText(child.value, depth: depth + 1) {
            return text
        }
    }
    return nil
}
