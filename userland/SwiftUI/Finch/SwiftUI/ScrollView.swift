// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ScrollView, to Apple's interface: on macOS an AppKit scroll view whose document is the
// content, hosted, as Apple's is. Along the scrolling axes the content takes its ideal size
// (at least the visible size); across them it fits the scroll view. The scroll view takes
// what it is offered along the scrolling axes and its content's size across them.
// (Scroll position, ScrollViewReader and scroll targets aren't here yet.)

import AppKit
import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
@MainActor
@preconcurrency
public struct ScrollView<Content>: View where Content: View {
    public var content: Content
    var configuration: _FinchScrollConfiguration

    public var axes: Axis.Set {
        get { configuration.axes }
        set { configuration.axes = newValue }
    }

    public var showsIndicators: Bool {
        get { configuration.showsIndicators }
        set { configuration.showsIndicators = newValue }
    }

    nonisolated public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.configuration = _FinchScrollConfiguration(axes: axes, showsIndicators: showsIndicators)
    }

    @MainActor
    @preconcurrency
    public var body: some View {
        _FinchScrollView(content: content, configuration: configuration)
    }
}

@available(*, unavailable)
extension ScrollView: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension ScrollView {
    public var _contentInsets: EdgeInsets {
        get { configuration.contentInsets }
        set { configuration.contentInsets = newValue }
    }

    public var _automaticallyAdjustsContentInsets: Bool {
        get { configuration.automaticallyAdjustsContentInsets }
        set { configuration.automaticallyAdjustsContentInsets = newValue }
    }

    public var _alwaysBounceAxes: Axis.Set {
        get { configuration.alwaysBounceAxes }
        set { configuration.alwaysBounceAxes = newValue }
    }

    @usableFromInline
    nonisolated func scrollDisabled(_ disabled: Bool) -> ScrollView<Content> {
        var view = self
        view.configuration.isScrollDisabled = disabled
        return view
    }
}

struct _FinchScrollConfiguration {
    var axes: Axis.Set
    var showsIndicators: Bool
    var contentInsets = EdgeInsets()
    var automaticallyAdjustsContentInsets = true
    var alwaysBounceAxes: Axis.Set = []
    var isScrollDisabled = false
}

/// The AppKit scroll view, its document the hosted content.
struct _FinchScrollView<Content: View>: NSViewRepresentable {
    var content: Content
    var configuration: _FinchScrollConfiguration

    final class ScrollView: NSScrollView {
        var controller: NSHostingController<AnyView>?
        var axes: Axis.Set = .vertical
        var insets = EdgeInsets()

        /// The content's size for a width or height (nil: its ideal).
        func contentSize(width: CGFloat?, height: CGFloat?) -> CGSize {
            guard let controller else { return .zero }
            return controller.host.sizeThatFits(_ProposedSize(width: width, height: height))
        }

        override func tile() {
            super.tile()
            guard let document = documentView else { return }
            let visible = contentView.bounds.size
            let fit = contentSize(width: axes.contains(.horizontal) ? nil : visible.width - insets.leading - insets.trailing,
                                  height: axes.contains(.vertical) ? nil : visible.height - insets.top - insets.bottom)
            let size = NSSize(width: axes.contains(.horizontal) ? max(fit.width + insets.leading + insets.trailing, visible.width)
                                                                  : visible.width,
                              height: axes.contains(.vertical) ? max(fit.height + insets.top + insets.bottom, visible.height)
                                                               : visible.height)
            if document.frame.size != size {
                document.setFrameSize(size)
            }
        }
    }

    /// The document view: flipped, so the content starts at the top.
    final class DocumentView: NSView {
        override var isFlipped: Bool { true }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            subviews.first?.frame = bounds
        }
    }

    func makeNSView(context: Context) -> ScrollView {
        let scrollView = ScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let controller = NSHostingController(rootView: AnyView(EmptyView()))
        let document = DocumentView()
        document.addSubview(controller.view)
        scrollView.documentView = document
        scrollView.controller = controller
        return scrollView
    }

    func updateNSView(_ scrollView: ScrollView, context: Context) {
        // the values the content inherits; not the whole environment, which holds the
        // outer graph's own state
        let environment = context.environment
        scrollView.controller?.rootView = AnyView(
            content
                .padding(configuration.contentInsets)
                .environment(\.font, environment.font)
                .environment(\.isEnabled, environment.isEnabled)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.locale, environment.locale)
                .environment(\.multilineTextAlignment, environment.multilineTextAlignment)
                .environment(\.lineLimit, environment.lineLimit)
                .environment(\.controlSize, environment.controlSize)
                .environment(\._finchButtonStyles, environment._finchButtonStyles)
        )
        scrollView.axes = configuration.axes
        scrollView.insets = configuration.contentInsets
        scrollView.hasVerticalScroller = configuration.axes.contains(.vertical) && configuration.showsIndicators
        scrollView.hasHorizontalScroller = configuration.axes.contains(.horizontal) && configuration.showsIndicators
        scrollView.tile()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: ScrollView, context: Context) -> CGSize? {
        let axes = configuration.axes
        // across the scrolling axes, the content's size; along them, what is offered (or the
        // content's ideal size, when nothing is)
        let fit = scrollView.contentSize(width: axes.contains(.horizontal) ? nil : proposal.width,
                                         height: axes.contains(.vertical) ? nil : proposal.height)
        let insets = configuration.contentInsets
        return CGSize(width: axes.contains(.horizontal) ? (proposal.width ?? fit.width + insets.leading + insets.trailing)
                                                        : fit.width + insets.leading + insets.trailing,
                      height: axes.contains(.vertical) ? (proposal.height ?? fit.height + insets.top + insets.bottom)
                                                       : fit.height + insets.top + insets.bottom)
    }
}
