// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Rectangle anchor sources (`Anchor<CGRect>.Source.rect(_:)` and `.bounds`), to Apple's
// interface, as the point sources are: a rectangle in the view's space, taken to the global
// space when the anchor is prepared.

public import OpenCoreGraphicsShims

/// A view's bounds: its size at the origin, when prepared.
private struct BoundsAnchor: AnchorProtocol {
    static var defaultAnchor: CGRect { .zero }

    func prepare(geometry: AnchorGeometry) -> CGRect {
        CGRect(origin: .zero, size: geometry.size).prepare(geometry: geometry)
    }

    static func hashValue(_ value: CGRect, into hasher: inout Hasher) {
        CGRect.hashValue(value, into: &hasher)
    }
}

extension CGRect: AnchorProtocol {
    package static var defaultAnchor: CGRect { .zero }

    package func prepare(geometry: AnchorGeometry) -> CGRect {
        var rect = self
        rect.convert(to: .global, transform: geometry.transform)
        return rect
    }

    package static func hashValue(_ value: CGRect, into hasher: inout Hasher) {
        hasher.combine(value.origin.x)
        hasher.combine(value.origin.y)
        hasher.combine(value.size.width)
        hasher.combine(value.size.height)
    }
}

@available(OpenSwiftUI_v1_0, *)
extension Anchor.Source where Value == CGRect {
    public static func rect(_ r: CGRect) -> Anchor<Value>.Source {
        .init(anchor: r)
    }

    public static var bounds: Anchor<CGRect>.Source {
        .init(anchor: BoundsAnchor())
    }
}
