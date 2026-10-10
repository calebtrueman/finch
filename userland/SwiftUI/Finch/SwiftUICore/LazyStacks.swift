// SPDX-License-Identifier: MIT OR Apache-2.0
//
// LazyVStack, LazyHStack and PinnedScrollableViews, to Apple's interface. A lazy stack lays
// out as the stack it is lazy about: every view is made, not only those scrolled into view
// (pinned section headers aren't pinned yet).

import OpenAttributeGraphShims
public import OpenCoreGraphicsShims

@available(OpenSwiftUI_v2_0, *)
public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1 << 0)
    public static let sectionFooters = PinnedScrollableViews(rawValue: 1 << 1)
}

@available(OpenSwiftUI_v2_0, *)
public struct LazyVStack<Content>: View, PrimitiveView where Content: View {
    var alignment: HorizontalAlignment
    var spacing: CGFloat?
    var pinnedViews: PinnedScrollableViews
    var content: Content

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.pinnedViews = pinnedViews
        self.content = content()
    }

    private struct Stack: Rule {
        @Attribute var lazy: LazyVStack

        var value: VStack<Content> {
            VStack(alignment: lazy.alignment, spacing: lazy.spacing) { lazy.content }
        }
    }

    nonisolated public static func _makeView(view: _GraphValue<LazyVStack<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        VStack<Content>._makeView(view: _GraphValue(Stack(lazy: view.value)), inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<LazyVStack<Content>>, inputs: _ViewListInputs) -> _ViewListOutputs {
        VStack<Content>._makeViewList(view: _GraphValue(Stack(lazy: view.value)), inputs: inputs)
    }

    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        VStack<Content>._viewListCount(inputs: inputs)
    }

    public typealias Body = Never
}

@available(*, unavailable) extension LazyVStack: Sendable {}

@available(OpenSwiftUI_v2_0, *)
public struct LazyHStack<Content>: View, PrimitiveView where Content: View {
    var alignment: VerticalAlignment
    var spacing: CGFloat?
    var pinnedViews: PinnedScrollableViews
    var content: Content

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.pinnedViews = pinnedViews
        self.content = content()
    }

    private struct Stack: Rule {
        @Attribute var lazy: LazyHStack

        var value: HStack<Content> {
            HStack(alignment: lazy.alignment, spacing: lazy.spacing) { lazy.content }
        }
    }

    nonisolated public static func _makeView(view: _GraphValue<LazyHStack<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        HStack<Content>._makeView(view: _GraphValue(Stack(lazy: view.value)), inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<LazyHStack<Content>>, inputs: _ViewListInputs) -> _ViewListOutputs {
        HStack<Content>._makeViewList(view: _GraphValue(Stack(lazy: view.value)), inputs: inputs)
    }

    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        HStack<Content>._viewListCount(inputs: inputs)
    }

    public typealias Body = Never
}

@available(*, unavailable) extension LazyHStack: Sendable {}
