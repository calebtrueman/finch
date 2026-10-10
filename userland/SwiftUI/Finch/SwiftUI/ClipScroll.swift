// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Vertical scrolling within the view graph, for content that can't be hosted in an AppKit
// scroll view's document (a list's rows, which belong to the list's graph): the content at
// its full height, offset by the scroll position and clipped, with an overlay scroller. The
// mouse wheel scrolls it; an AppKit view over it takes the wheel's events and no others. In a
// ScrollViewReader, its identified rows report where they are and the reader scrolls it.

import AppKit
import SwiftUICore

struct _FinchClipScroll<Content: View>: View {
    var content: Content
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var target = _FinchClipScrollTarget()
    @Environment(\._finchScrollReader) private var reader

    private var maxOffset: CGFloat { max(0, contentHeight - viewportHeight) }

    var body: some View {
        let shown = min(offset, maxOffset)
        let target = target, reader = reader
        target.scroll = { [$offset] rect, anchor in
            MainActor.assumeIsolated {
                $offset.wrappedValue = target.offset(toShow: rect, anchor: anchor, from: $offset.wrappedValue)
            }
        }
        return content
            // in a reader: the identified rows say where they are, and the reader can find us
            .environment(\._finchReportsScrollTargets, reader != nil)
            .background(_FinchScrollRootReporter(enabled: reader != nil))
            .onPreferenceChange(_FinchScrollTargetsKey.self) { targets in
                MainActor.assumeIsolated {
                    let root = targets[_FinchScrollRootReporter.id]?.origin ?? .zero
                    target.targets = targets.mapValues { $0.offsetBy(dx: -root.x, dy: -root.y) }
                    reader?.register(target)
                }
            }
            // not for a scroll view around this one: its rows aren't in that one's content
            .transformPreference(_FinchScrollTargetsKey.self) { $0 = [:] }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0; target.contentHeight = $0 }
            .offset(y: -shown)
            // as small as offered: a frame's height is otherwise at least its content's
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0; target.viewport = $0; target.contentHeight = contentHeight }
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

/// A clip scroll as a reader's scroll target: where its rows are, and scrolling to one.
final class _FinchClipScrollTarget: _FinchScrollTargetView {
    var targets: [AnyHashable: CGRect] = [:]
    var viewport: CGFloat = 0
    var contentHeight: CGFloat = 0
    var scroll: (CGRect, UnitPoint?) -> Void = { _, _ in }

    func scroll(toShow rect: CGRect, anchor: UnitPoint?) {
        scroll(rect, anchor)
    }

    /// The offset showing the rect: just enough, or with its anchor at the viewport's.
    func offset(toShow rect: CGRect, anchor: UnitPoint?, from offset: CGFloat) -> CGFloat {
        var offset = offset
        if let anchor {
            offset = rect.minY + anchor.y * rect.height - anchor.y * viewport
        } else if rect.minY < offset {
            offset = rect.minY
        } else if rect.maxY > offset + viewport {
            offset = rect.maxY - viewport
        }
        return min(max(0, offset), max(0, contentHeight - viewport))
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
