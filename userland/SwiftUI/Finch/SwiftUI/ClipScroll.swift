// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Vertical scrolling within the view graph, for content that can't be hosted in an AppKit
// scroll view's document (a list's rows, which belong to the list's graph): the content at
// its full height, offset by the scroll position and clipped, with an overlay scroller. The
// mouse wheel scrolls it; an AppKit view over it takes the wheel's events and no others.

import AppKit
import SwiftUICore

struct _FinchClipScroll<Content: View>: View {
    var content: Content
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var maxOffset: CGFloat { max(0, contentHeight - viewportHeight) }

    var body: some View {
        let shown = min(offset, maxOffset)
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            .offset(y: -shown)
            // as small as offered: a frame's height is otherwise at least its content's
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if maxOffset > 0 {
                    // the scroller's knob: the visible part of the content, where it is
                    let knob = max(16, viewportHeight * viewportHeight / contentHeight)
                    Capsule()
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: 6, height: knob)
                        .offset(x: -3, y: 3 + (viewportHeight - knob - 6) * shown / maxOffset)
                }
            }
            .overlay(_FinchScrollWheelCatcher { delta in
                offset = min(max(0, min(offset, maxOffset) - delta), maxOffset)
            })
    }
}

/// Takes the mouse wheel's events over a view, and lets every other event through.
struct _FinchScrollWheelCatcher: NSViewRepresentable {
    var scrolled: (CGFloat) -> Void

    final class WheelView: NSView {
        var scrolled: (CGFloat) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel && frame.contains(point) ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            scrolled(delta)
        }
    }

    func makeNSView(context: Context) -> WheelView { WheelView() }

    func updateNSView(_ view: WheelView, context: Context) {
        view.scrolled = scrolled
    }
}
