// SPDX-License-Identifier: MIT OR Apache-2.0
//
// LazyVGrid, LazyHGrid and GridItem, to Apple's interface. A grid lays its views out in
// tracks (columns of a vertical grid, rows of a horizontal one) sized as Apple's are: fixed
// tracks take their size, then flexible and adaptive ones share what's left (an adaptive item
// becomes as many tracks of at least its minimum as fit); views fill the tracks in order, a
// line at a time, each line as long as its longest view. Every view is made, not only those
// scrolled into view.

import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

@available(OpenSwiftUI_v2_0, *)
public struct GridItem: Sendable {
    public enum Size: Sendable {
        case fixed(_: CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }

    public var size: Size
    public var spacing: CGFloat?
    public var alignment: Alignment?

    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }
}

/// The grid's layout. `vertical`: tracks are columns, lines are rows.
struct _FinchGridLayout: Layout {
    var items: [GridItem]
    var vertical: Bool
    var lineSpacing: CGFloat?
    var alignment: Alignment

    struct Track {
        var length: CGFloat
        var spacing: CGFloat
        var alignment: Alignment
    }

    /// The tracks across `available` points (nil: each flexible track as long as its views want).
    func tracks(across available: CGFloat?, subviews: Subviews) -> [Track] {
        let defaultSpacing: CGFloat = 8
        // fixed lengths and spacings first
        var fixed: CGFloat = 0
        var flexibleCount = 0
        for (index, item) in items.enumerated() {
            if index < items.count - 1 { fixed += item.spacing ?? defaultSpacing }
            switch item.size {
            case let .fixed(length): fixed += length
            default: flexibleCount += 1
            }
        }
        let share = available.map { max(0, $0 - fixed) / CGFloat(max(flexibleCount, 1)) }
        var tracks: [Track] = []
        for item in items {
            let spacing = item.spacing ?? defaultSpacing
            let align = item.alignment ?? alignment
            switch item.size {
            case let .fixed(length):
                tracks.append(Track(length: length, spacing: spacing, alignment: align))
            case let .flexible(minimum, maximum):
                let ideal = share ?? idealLength(subviews: subviews)
                tracks.append(Track(length: min(max(ideal, minimum), maximum), spacing: spacing, alignment: align))
            case let .adaptive(minimum, maximum):
                guard let share else {
                    tracks.append(Track(length: max(minimum, min(idealLength(subviews: subviews), maximum)),
                                        spacing: spacing, alignment: align))
                    continue
                }
                let count = max(1, Int((share + spacing) / (minimum + spacing)))
                let length = min(maximum, (share - spacing * CGFloat(count - 1)) / CGFloat(count))
                for _ in 0 ..< count {
                    tracks.append(Track(length: max(length, minimum), spacing: spacing, alignment: align))
                }
            }
        }
        return tracks
    }

    /// The length across the tracks the views want, without a proposal.
    private func idealLength(subviews: Subviews) -> CGFloat {
        subviews.map { size(of: $0.sizeThatFits(.unspecified)).across }.max() ?? 0
    }

    /// A size as (across the tracks, along them).
    private func size(of s: CGSize) -> (across: CGFloat, along: CGFloat) {
        vertical ? (s.width, s.height) : (s.height, s.width)
    }

    /// The views' lines: their lengths along the grid.
    private func lines(_ tracks: [Track], subviews: Subviews) -> [CGFloat] {
        guard !tracks.isEmpty else { return [] }
        return stride(from: 0, to: subviews.count, by: tracks.count).map { start in
            (start ..< min(start + tracks.count, subviews.count)).map { index in
                let track = tracks[index - start]
                let proposal = vertical ? ProposedViewSize(width: track.length, height: nil)
                                        : ProposedViewSize(width: nil, height: track.length)
                return size(of: subviews[index].sizeThatFits(proposal)).along
            }.max() ?? 0
        }
    }

    private var spacingBetweenLines: CGFloat { lineSpacing ?? 8 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = vertical ? proposal.width : proposal.height
        let tracks = tracks(across: available, subviews: subviews)
        let across = tracks.map(\.length).reduce(0, +) + tracks.dropLast().map(\.spacing).reduce(0, +)
        let lines = lines(tracks, subviews: subviews)
        let along = lines.reduce(0, +) + spacingBetweenLines * CGFloat(max(lines.count - 1, 0))
        let width = vertical ? (available.map { max($0, across) } ?? across) : along
        let height = vertical ? along : (available.map { max($0, across) } ?? across)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let available = vertical ? bounds.width : bounds.height
        let tracks = tracks(across: available, subviews: subviews)
        guard !tracks.isEmpty else { return }
        let across = tracks.map(\.length).reduce(0, +) + tracks.dropLast().map(\.spacing).reduce(0, +)
        // the tracks placed by the grid's alignment within what it has
        let fraction: CGFloat = vertical
            ? (alignment.horizontal == .leading ? 0 : alignment.horizontal == .trailing ? 1 : 0.5)
            : (alignment.vertical == .top ? 0 : alignment.vertical == .bottom ? 1 : 0.5)
        let lead = (available - across) * fraction
        let lines = lines(tracks, subviews: subviews)
        var along: CGFloat = 0
        for (line, length) in lines.enumerated() {
            var offset = max(0, lead)
            for column in 0 ..< tracks.count {
                let index = line * tracks.count + column
                guard index < subviews.count else { break }
                let track = tracks[column]
                let cell = vertical
                    ? CGRect(x: bounds.minX + offset, y: bounds.minY + along, width: track.length, height: length)
                    : CGRect(x: bounds.minX + along, y: bounds.minY + offset, width: length, height: track.length)
                let proposal = ProposedViewSize(width: cell.width, height: cell.height)
                let size = subviews[index].sizeThatFits(proposal)
                let x: CGFloat = switch track.alignment.horizontal {
                case .leading: cell.minX
                case .trailing: cell.maxX - size.width
                default: cell.midX - size.width / 2
                }
                let y: CGFloat = switch track.alignment.vertical {
                case .top: cell.minY
                case .bottom: cell.maxY - size.height
                default: cell.midY - size.height / 2
                }
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: proposal)
                offset += track.length + track.spacing
            }
            along += length + spacingBetweenLines
        }
    }
}

/// A grid as a view: its layout over its content.
struct _FinchGridView<Content: View>: View {
    var layout: _FinchGridLayout
    var content: Content

    var body: some View {
        layout { content }
    }
}

@available(OpenSwiftUI_v2_0, *)
public struct LazyVGrid<Content>: View, PrimitiveView where Content: View {
    var columns: [GridItem]
    var alignment: HorizontalAlignment
    var spacing: CGFloat?
    var pinnedViews: PinnedScrollableViews
    var content: Content

    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.alignment = alignment
        self.spacing = spacing
        self.pinnedViews = pinnedViews
        self.content = content()
    }

    private struct Grid: Rule {
        @Attribute var grid: LazyVGrid

        var value: _FinchGridView<Content> {
            _FinchGridView(layout: _FinchGridLayout(items: grid.columns, vertical: true, lineSpacing: grid.spacing,
                                                    alignment: Alignment(horizontal: grid.alignment, vertical: .center)),
                           content: grid.content)
        }
    }

    nonisolated public static func _makeView(view: _GraphValue<LazyVGrid<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        _FinchGridView<Content>._makeView(view: _GraphValue(Grid(grid: view.value)), inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<LazyVGrid<Content>>, inputs: _ViewListInputs) -> _ViewListOutputs {
        _FinchGridView<Content>._makeViewList(view: _GraphValue(Grid(grid: view.value)), inputs: inputs)
    }

    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        _FinchGridView<Content>._viewListCount(inputs: inputs)
    }

    public typealias Body = Never
}

@available(*, unavailable) extension LazyVGrid: Sendable {}

@available(OpenSwiftUI_v2_0, *)
public struct LazyHGrid<Content>: View, PrimitiveView where Content: View {
    var rows: [GridItem]
    var alignment: VerticalAlignment
    var spacing: CGFloat?
    var pinnedViews: PinnedScrollableViews
    var content: Content

    public init(rows: [GridItem], alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.alignment = alignment
        self.spacing = spacing
        self.pinnedViews = pinnedViews
        self.content = content()
    }

    private struct Grid: Rule {
        @Attribute var grid: LazyHGrid

        var value: _FinchGridView<Content> {
            _FinchGridView(layout: _FinchGridLayout(items: grid.rows, vertical: false, lineSpacing: grid.spacing,
                                                    alignment: Alignment(horizontal: .center, vertical: grid.alignment)),
                           content: grid.content)
        }
    }

    nonisolated public static func _makeView(view: _GraphValue<LazyHGrid<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        _FinchGridView<Content>._makeView(view: _GraphValue(Grid(grid: view.value)), inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<LazyHGrid<Content>>, inputs: _ViewListInputs) -> _ViewListOutputs {
        _FinchGridView<Content>._makeViewList(view: _GraphValue(Grid(grid: view.value)), inputs: inputs)
    }

    nonisolated public static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        _FinchGridView<Content>._viewListCount(inputs: inputs)
    }

    public typealias Body = Never
}

@available(*, unavailable) extension LazyHGrid: Sendable {}
