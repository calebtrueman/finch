// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Where identified views are, for ScrollViewReader: inside a scroll view that asks for them,
// a view given an id (IDView, so `id(_:)` and ForEach's elements) reports its frame in the
// scroll view's content, by its id. Elsewhere nothing is reported.

public import OpenCoreGraphicsShims
package import OpenAttributeGraphShims

/// The frames of the identified views in a scroll view's content (its global space: the
/// content is hosted on its own).
package struct _FinchScrollTargetsKey: PreferenceKey {
    package static var defaultValue: [AnyHashable: CGRect] { [:] }

    package static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

private struct _FinchReportsScrollTargetsKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    /// Whether identified views report their frames (inside a scroll view a reader can scroll).
    package var _finchReportsScrollTargets: Bool {
        get { self[_FinchReportsScrollTargetsKey.self] }
        set { self[_FinchReportsScrollTargetsKey.self] = newValue }
    }
}

/// Reports a view's frame by its id, when asked to (the content as it is; behind it, a
/// reader of its frame or nothing).
package struct _FinchScrollTargetModifier: ViewModifier {
    var id: AnyHashable

    package init(id: AnyHashable) {
        self.id = id
    }

    package func body(content: Content) -> some View {
        content.background(_FinchScrollTargetReporter(id: id))
    }
}

private struct _FinchScrollTargetReporter: View {
    var id: AnyHashable
    @Environment(\._finchReportsScrollTargets) private var reports

    var body: some View {
        if reports {
            let id = id
            GeometryReader { proxy in
                Color.clear.preference(key: _FinchScrollTargetsKey.self, value: [id: proxy.frame(in: .global)])
            }
        }
    }
}

/// An identified view's content with its frame reported.
package struct _FinchReportedContent<Content: View, ID: Hashable>: Rule {
    @Attribute var view: IDView<Content, ID>

    package init(view: Attribute<IDView<Content, ID>>) {
        _view = view
    }

    package var value: ModifiedContent<Content, _FinchScrollTargetModifier> {
        view.content.modifier(_FinchScrollTargetModifier(id: AnyHashable(view.id)))
    }
}

/// Content (an identified view's, as cached for its id) with its frame reported.
package struct _FinchReportedChild<Content: View>: Rule {
    @Attribute var content: Content
    let id: AnyHashable

    package init(content: Attribute<Content>, id: AnyHashable) {
        _content = content
        self.id = id
    }

    package var value: ModifiedContent<Content, _FinchScrollTargetModifier> {
        content.modifier(_FinchScrollTargetModifier(id: id))
    }
}
