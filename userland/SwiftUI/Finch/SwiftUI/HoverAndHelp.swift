// SPDX-License-Identifier: MIT OR Apache-2.0
//
// onHover(perform:) and help(_:), to Apple's interface, through AppKit as Apple's are on
// macOS: an AppKit view over the content, which takes no clicks, tracks the mouse entering
// and leaving (a tracking area) and carries the help text as its tooltip.

import AppKit
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct _HoverRegionModifier: ViewModifier {
    public let callback: (Bool) -> Void

    @inlinable
    public init(_ callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }

    nonisolated public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        Child.Value._makeView(modifier: _GraphValue(Child(modifier: modifier.value)), inputs: inputs, body: body)
    }

    nonisolated public static func _makeViewList(
        modifier: _GraphValue<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        Child.Value._makeViewList(modifier: _GraphValue(Child(modifier: modifier.value)), inputs: inputs, body: body)
    }

    nonisolated public static func _viewListCount(
        inputs: _ViewListCountInputs,
        body: (_ViewListCountInputs) -> Int?
    ) -> Int? {
        Child.Value._viewListCount(inputs: inputs, body: body)
    }

    private struct Child: Rule, AsyncAttribute {
        @Attribute var modifier: _HoverRegionModifier

        var value: InnerModifier { InnerModifier(callback: modifier.callback) }
    }

    private struct InnerModifier: ViewModifier {
        var callback: (Bool) -> Void

        func body(content: Content) -> some View {
            content.overlay(_FinchMouseRegion(hovered: callback, toolTip: nil))
        }
    }
}

@available(*, unavailable)
extension _HoverRegionModifier: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension View {
    @inlinable
    nonisolated public func onHover(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(_HoverRegionModifier(action))
    }

    nonisolated public func help(_ textKey: LocalizedStringKey) -> some View {
        modifier(_FinchHelpModifier(text: Text(textKey)))
    }

    nonisolated public func help(_ text: Text) -> some View {
        modifier(_FinchHelpModifier(text: text))
    }

    @_disfavoredOverload
    nonisolated public func help<S>(_ text: S) -> some View where S: StringProtocol {
        modifier(_FinchHelpModifier(text: Text(text)))
    }
}

/// The help text as the tooltip of an AppKit view over the content, resolved in its
/// environment, and as its accessibility help.
struct _FinchHelpModifier: ViewModifier {
    var text: Text
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        content
            .overlay(_FinchMouseRegion(hovered: nil, toolTip: text._resolveText(in: environment)))
            .accessibilityHint(text)
    }
}

/// An AppKit view over a SwiftUI view that takes no clicks: it tells when the mouse enters
/// and leaves it, and shows a tooltip.
struct _FinchMouseRegion: NSViewRepresentable {
    var hovered: ((Bool) -> Void)?
    var toolTip: String?

    final class RegionView: NSView {
        var hovered: ((Bool) -> Void)?
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                     owner: self, userInfo: nil)
            addTrackingArea(new)
            area = new
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { hovered?(true) }

        override func mouseExited(with event: NSEvent) { hovered?(false) }
    }

    func makeNSView(context: Context) -> RegionView { RegionView() }

    func updateNSView(_ view: RegionView, context: Context) {
        view.hovered = hovered
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}
