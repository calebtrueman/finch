// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The geometry the historical overlay (CoreGraphics.swift) expected the importer to supply,
// written in Swift. As in Apple's CoreGraphics, it's inlined into clients
// (@_alwaysEmitIntoClient), so it has no symbols of its own.

extension CGRect {
    @_alwaysEmitIntoClient public static var null: CGRect {
        return CGRect(x: CGFloat.infinity, y: CGFloat.infinity, width: 0, height: 0)
    }
    @_alwaysEmitIntoClient public static var infinite: CGRect {
        let big = CGFloat.greatestFiniteMagnitude
        return CGRect(x: -big / 2, y: -big / 2, width: big, height: big)
    }
    @_alwaysEmitIntoClient public var minX: CGFloat { return Swift.min(origin.x, origin.x + size.width) }
    @_alwaysEmitIntoClient public var midX: CGFloat { return origin.x + size.width / 2 }
    @_alwaysEmitIntoClient public var maxX: CGFloat { return Swift.max(origin.x, origin.x + size.width) }
    @_alwaysEmitIntoClient public var minY: CGFloat { return Swift.min(origin.y, origin.y + size.height) }
    @_alwaysEmitIntoClient public var midY: CGFloat { return origin.y + size.height / 2 }
    @_alwaysEmitIntoClient public var maxY: CGFloat { return Swift.max(origin.y, origin.y + size.height) }
    @_alwaysEmitIntoClient public var width: CGFloat { return Swift.abs(size.width) }
    @_alwaysEmitIntoClient public var height: CGFloat { return Swift.abs(size.height) }
    @_alwaysEmitIntoClient public func equalTo(_ rect2: CGRect) -> Bool { return standardized == rect2.standardized }
    @_alwaysEmitIntoClient public var standardized: CGRect {
        if isNull { return .null }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
    @_alwaysEmitIntoClient public var isNull: Bool { return origin.x.isInfinite || origin.y.isInfinite }
    @_alwaysEmitIntoClient public var isEmpty: Bool { return isNull || size.width == 0 || size.height == 0 }
    @_alwaysEmitIntoClient public var isInfinite: Bool { return self == .infinite }
    @_alwaysEmitIntoClient public func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        if isNull { return .null }
        let r = standardized
        let w = r.size.width - 2 * dx, h = r.size.height - 2 * dy
        if w < 0 || h < 0 { return .null }
        return CGRect(x: r.origin.x + dx, y: r.origin.y + dy, width: w, height: h)
    }
    @_alwaysEmitIntoClient public var integral: CGRect {
        if isNull { return self }
        let x0 = minX.rounded(.down), y0 = minY.rounded(.down)
        return CGRect(x: x0, y: y0, width: maxX.rounded(.up) - x0, height: maxY.rounded(.up) - y0)
    }
    @_alwaysEmitIntoClient public func union(_ r2: CGRect) -> CGRect {
        if isNull { return r2 }
        if r2.isNull { return self }
        let x0 = Swift.min(minX, r2.minX), y0 = Swift.min(minY, r2.minY)
        return CGRect(x: x0, y: y0, width: Swift.max(maxX, r2.maxX) - x0, height: Swift.max(maxY, r2.maxY) - y0)
    }
    @_alwaysEmitIntoClient public func intersection(_ r2: CGRect) -> CGRect {
        if isNull || r2.isNull { return .null }
        let x0 = Swift.max(minX, r2.minX), y0 = Swift.max(minY, r2.minY)
        let x1 = Swift.min(maxX, r2.maxX), y1 = Swift.min(maxY, r2.maxY)
        if x1 < x0 || y1 < y0 { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    @_alwaysEmitIntoClient public func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        if isNull { return self }
        return CGRect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
    }
    @_alwaysEmitIntoClient public func contains(_ point: CGPoint) -> Bool {
        return !isNull && point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
    @_alwaysEmitIntoClient public func contains(_ rect2: CGRect) -> Bool {
        return union(rect2) == self || (!rect2.isNull && rect2.isEmpty && contains(rect2.origin))
    }
    @_alwaysEmitIntoClient public func intersects(_ rect2: CGRect) -> Bool { return !intersection(rect2).isNull }
}

/// CGRectDivide, in Swift: the slice off one edge, and what remains.
@usableFromInline internal func _finchDivided(_ r: CGRect, atDistance d: CGFloat, from edge: CGRectEdge)
    -> (slice: CGRect, remainder: CGRect)
{
    if r.isNull { return (.null, .null) }
    let s = r.standardized
    switch edge {
    case .minXEdge:
        let a = Swift.max(0, Swift.min(d, s.width))
        return (CGRect(x: s.minX, y: s.minY, width: a, height: s.height),
                CGRect(x: s.minX + a, y: s.minY, width: s.width - a, height: s.height))
    case .maxXEdge:
        let a = Swift.max(0, Swift.min(d, s.width))
        return (CGRect(x: s.maxX - a, y: s.minY, width: a, height: s.height),
                CGRect(x: s.minX, y: s.minY, width: s.width - a, height: s.height))
    case .minYEdge:
        let a = Swift.max(0, Swift.min(d, s.height))
        return (CGRect(x: s.minX, y: s.minY, width: s.width, height: a),
                CGRect(x: s.minX, y: s.minY + a, width: s.width, height: s.height - a))
    case .maxYEdge:
        let a = Swift.max(0, Swift.min(d, s.height))
        return (CGRect(x: s.minX, y: s.maxY - a, width: s.width, height: a),
                CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height - a))
    @unknown default:
        return (r, r)
    }
}
