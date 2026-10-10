// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ScrollViewReader and ScrollViewProxy, to Apple's interface. The scroll views inside a
// reader have their identified views report where they are (ScrollTargets.swift in
// SwiftUICore), and register with the reader; scrollTo(_:anchor:) scrolls the one holding the
// view: just enough to show it, or with the anchor of the view at the same anchor of the
// visible area.

import AppKit
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

/// A scroll view that knows where its identified views are.
@MainActor
protocol _FinchScrollTargetView: AnyObject {
    var targets: [AnyHashable: CGRect] { get }
    func scroll(toShow rect: CGRect, anchor: UnitPoint?)
}

/// A reader's scroll views.
final class _FinchScrollReaderBox {
    private var scrollViews: [() -> (any _FinchScrollTargetView)?] = []

    func register(_ scrollView: any _FinchScrollTargetView) {
        guard !scrollViews.contains(where: { $0() === scrollView }) else { return }
        scrollViews.append { [weak scrollView] in scrollView }
    }

    @MainActor
    func scrollTo(_ id: AnyHashable, anchor: UnitPoint?) {
        scrollViews.removeAll { $0() == nil }
        for scrollView in scrollViews.compactMap({ $0() }) {
            if let rect = scrollView.targets[id] {
                scrollView.scroll(toShow: rect, anchor: anchor)
                return
            }
        }
    }
}

private struct _FinchScrollReaderKey: EnvironmentKey {
    static var defaultValue: _FinchScrollReaderBox? { nil }
}

extension EnvironmentValues {
    var _finchScrollReader: _FinchScrollReaderBox? {
        get { self[_FinchScrollReaderKey.self] }
        set { self[_FinchScrollReaderKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v2_0, *)
public struct ScrollViewProxy {
    var box: _FinchScrollReaderBox

    public func scrollTo<ID>(_ id: ID, anchor: UnitPoint? = nil) where ID: Hashable {
        let box = box
        MainActor.assumeIsolated { box.scrollTo(AnyHashable(id), anchor: anchor) }
    }
}

@available(*, unavailable) extension ScrollViewProxy: Sendable {}

@available(OpenSwiftUI_v2_0, *)
@frozen
public struct ScrollViewReader<Content>: View where Content: View {
    public var content: (ScrollViewProxy) -> Content

    @inlinable
    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {
        self.content = content
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchScrollReaderBody(content: content)
    }
}

@available(*, unavailable) extension ScrollViewReader: Sendable {}

struct _FinchScrollReaderBody<Content: View>: View {
    var content: (ScrollViewProxy) -> Content
    @State private var box = _FinchScrollReaderBox()

    var body: some View {
        content(ScrollViewProxy(box: box))
            .environment(\._finchScrollReader, box)
    }
}
