// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Gradients (Gradient, LinearGradient, RadialGradient, EllipticalGradient,
// AngularGradient), to Apple's interface and layouts. As shape styles they resolve to a
// paint that CoreGraphics draws, clipped to the shape, into its layer's contents (shapes
// filled with a color are drawn by layers themselves). Used as a view, a gradient fills
// its frame.

public import OpenCoreGraphicsShims
import CoreGraphics

// MARK: - Gradient

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct Gradient: Equatable {
    @frozen
    public struct Stop: Equatable {
        public var color: Color
        public var location: CGFloat

        public init(color: Color, location: CGFloat) {
            self.color = color
            self.location = location
        }
    }

    public var stops: [Stop]

    public init(stops: [Stop]) {
        self.stops = stops
    }

    /// The colors evenly spaced from 0 to 1.
    public init(colors: [Color]) {
        let last = CGFloat(max(colors.count - 1, 1))
        stops = colors.enumerated().map { Stop(color: $1, location: CGFloat($0) / last) }
    }

    package init(_ resolved: ResolvedGradient) {
        stops = []
    }

    func resolved(in environment: EnvironmentValues) -> [_FinchGradientPaint.Stop] {
        stops.sorted { $0.location < $1.location }
            .map { _FinchGradientPaint.Stop(color: $0.color.resolve(in: environment), location: $0.location) }
    }
}

// MARK: - The paint

/// A paint CoreGraphics draws: into `bounds` (the shape's frame), already clipped to the shape.
package protocol _FinchCGPaint {
    func _finchDraw(in context: CGContext, bounds: CGRect)
}

package struct _FinchGradientPaint: ResolvedPaint, _FinchCGPaint {
    package struct Stop: Equatable {
        var color: Color.Resolved
        var location: CGFloat
    }

    enum Kind: Equatable {
        case linear(start: UnitPoint, end: UnitPoint)
        case radial(center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat)
        case elliptical(center: UnitPoint, startFraction: CGFloat, endFraction: CGFloat)
        case angular(center: UnitPoint, start: Double, end: Double)
    }

    var kind: Kind
    var stops: [Stop]

    package static var leafProtobufTag: CodableResolvedPaint.Tag? { nil }

    package func encode(to encoder: inout ProtobufEncoder) throws {}

    package var isClear: Bool { stops.allSatisfy { $0.color.opacity == 0 } }

    package var isCALayerCompatible: Bool { false }

    package func draw(path: Path, style: PathDrawingStyle, in context: GraphicsContext, bounds: CGRect?) {
        // into a graphics context: the gradient's middle color (graphics contexts draw shadings
        // through their own backend, which has none yet)
        if let middle = color(at: 0.5) {
            context.draw(path, with: .color(middle), style: style)
        }
    }

    /// The color at a location, between the stops around it.
    func color(at t: CGFloat) -> Color.Resolved? {
        guard let first = stops.first, let last = stops.last else { return nil }
        if t <= first.location { return first.color }
        if t >= last.location { return last.color }
        for (a, b) in zip(stops, stops.dropFirst()) where t <= b.location {
            let span = b.location - a.location
            let f = Float(span > 0 ? (t - a.location) / span : 0)
            return Color.Resolved(
                linearRed: a.color.linearRed + (b.color.linearRed - a.color.linearRed) * f,
                linearGreen: a.color.linearGreen + (b.color.linearGreen - a.color.linearGreen) * f,
                linearBlue: a.color.linearBlue + (b.color.linearBlue - a.color.linearBlue) * f,
                opacity: a.color.opacity + (b.color.opacity - a.color.opacity) * f)
        }
        return last.color
    }

    private var cgGradient: CGGradient? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGGradient(colorsSpace: space, colors: stops.map(\.color.cgColor) as CFArray,
                          locations: stops.map(\.location))
    }

    package func _finchDraw(in context: CGContext, bounds: CGRect) {
        guard !stops.isEmpty else { return }
        func point(_ p: UnitPoint) -> CGPoint {
            CGPoint(x: bounds.minX + p.x * bounds.width, y: bounds.minY + p.y * bounds.height)
        }
        let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch kind {
        case let .linear(start, end):
            guard let gradient = cgGradient else { return }
            context.drawLinearGradient(gradient, start: point(start), end: point(end), options: extend)
        case let .radial(center, startRadius, endRadius):
            guard let gradient = cgGradient else { return }
            let c = point(center)
            context.drawRadialGradient(gradient, startCenter: c, startRadius: startRadius, endCenter: c,
                                       endRadius: endRadius, options: extend)
        case let .elliptical(center, startFraction, endFraction):
            // a radial gradient in a space where the frame is a unit square
            guard let gradient = cgGradient, bounds.width > 0, bounds.height > 0 else { return }
            let c = point(center)
            context.saveGState()
            context.translateBy(x: c.x, y: c.y)
            context.scaleBy(x: bounds.width, y: bounds.height)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: startFraction, endCenter: .zero,
                                       endRadius: endFraction, options: extend)
            context.restoreGState()
        case let .angular(center, start, end):
            // wedges around the center, each the color at its angle
            let c = point(center)
            let radius = hypot(bounds.width, bounds.height) + 1
            let span = end > start ? end - start : 2 * .pi
            let wedges = 360
            for i in 0 ..< wedges {
                let a0 = start + span * Double(i) / Double(wedges)
                let a1 = start + span * Double(i + 1) / Double(wedges) + 0.002
                guard let color = color(at: CGFloat((Double(i) + 0.5) / Double(wedges))) else { continue }
                context.setFillColor(color.cgColor)
                context.move(to: c)
                context.addLine(to: CGPoint(x: c.x + radius * cos(a0), y: c.y + radius * sin(a0)))
                context.addLine(to: CGPoint(x: c.x + radius * cos(a1), y: c.y + radius * sin(a1)))
                context.closePath()
                context.fillPath()
            }
        }
    }

    package static func == (a: _FinchGradientPaint, b: _FinchGradientPaint) -> Bool {
        a.kind == b.kind && a.stops == b.stops
    }
}

/// Puts a gradient's paint in the style pack (and its first color where one color is asked for).
private func _finchApply(_ paint: @autoclosure () -> _FinchGradientPaint, gradient: Gradient,
                         to shape: inout _ShapeStyle_Shape) {
    switch shape.operation {
    case let .resolveStyle(name, levels):
        guard levels.lowerBound != levels.upperBound else { break }
        shape.stylePack[name, levels.lowerBound] = .init(.paint(_AnyResolvedPaint(paint())))
    case .fallbackColor:
        if let color = gradient.stops.first?.color { shape.result = .color(color) }
    case .prepareText:
        if let color = gradient.stops.first?.color { shape.result = .preparedText(.foregroundColor(color)) }
    default:
        break
    }
}

// MARK: - The gradient styles

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct LinearGradient: ShapeStyle, View, Sendable {
    package var gradient: Gradient
    package var startPoint: UnitPoint
    package var endPoint: UnitPoint

    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {
        self.gradient = gradient
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    @_alwaysEmitIntoClient
    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint)
    }

    @_alwaysEmitIntoClient
    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(stops: stops), startPoint: startPoint, endPoint: endPoint)
    }

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        let gradient = gradient, start = startPoint, end = endPoint, environment = shape.environment
        _finchApply(_FinchGradientPaint(kind: .linear(start: start, end: end), stops: gradient.resolved(in: environment)),
                    gradient: gradient, to: &shape)
    }

    public var body: _ShapeView<Rectangle, LinearGradient> {
        _ShapeView(shape: Rectangle(), style: self)
    }

    public typealias Resolved = Never
}

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct RadialGradient: ShapeStyle, View, Sendable {
    package var gradient: Gradient
    package var center: UnitPoint
    package var startRadius: CGFloat
    package var endRadius: CGFloat

    public init(gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.gradient = gradient
        self.center = center
        self.startRadius = startRadius
        self.endRadius = endRadius
    }

    @_alwaysEmitIntoClient
    public init(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.init(gradient: Gradient(colors: colors), center: center, startRadius: startRadius, endRadius: endRadius)
    }

    @_alwaysEmitIntoClient
    public init(stops: [Gradient.Stop], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.init(gradient: Gradient(stops: stops), center: center, startRadius: startRadius, endRadius: endRadius)
    }

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        let paint = _FinchGradientPaint(kind: .radial(center: center, startRadius: startRadius, endRadius: endRadius),
                                        stops: gradient.resolved(in: shape.environment))
        _finchApply(paint, gradient: gradient, to: &shape)
    }

    public var body: _ShapeView<Rectangle, RadialGradient> {
        _ShapeView(shape: Rectangle(), style: self)
    }

    public typealias Resolved = Never
}

@available(OpenSwiftUI_v3_0, *)
@frozen
public struct EllipticalGradient: ShapeStyle, View, Sendable {
    package var gradient: Gradient
    package var center: UnitPoint
    package var startRadiusFraction: CGFloat
    package var endRadiusFraction: CGFloat

    public init(gradient: Gradient, center: UnitPoint = .center, startRadiusFraction: CGFloat = 0,
                endRadiusFraction: CGFloat = 0.5) {
        self.gradient = gradient
        self.center = center
        self.startRadiusFraction = startRadiusFraction
        self.endRadiusFraction = endRadiusFraction
    }

    public init(colors: [Color], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0,
                endRadiusFraction: CGFloat = 0.5) {
        self.init(gradient: Gradient(colors: colors), center: center, startRadiusFraction: startRadiusFraction,
                  endRadiusFraction: endRadiusFraction)
    }

    public init(stops: [Gradient.Stop], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0,
                endRadiusFraction: CGFloat = 0.5) {
        self.init(gradient: Gradient(stops: stops), center: center, startRadiusFraction: startRadiusFraction,
                  endRadiusFraction: endRadiusFraction)
    }

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        let paint = _FinchGradientPaint(kind: .elliptical(center: center, startFraction: startRadiusFraction,
                                                          endFraction: endRadiusFraction),
                                        stops: gradient.resolved(in: shape.environment))
        _finchApply(paint, gradient: gradient, to: &shape)
    }

    public var body: _ShapeView<Rectangle, EllipticalGradient> {
        _ShapeView(shape: Rectangle(), style: self)
    }

    public typealias Resolved = Never
}

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct AngularGradient: ShapeStyle, View, Sendable {
    package var gradient: Gradient
    package var center: UnitPoint
    package var startAngle: Angle
    package var endAngle: Angle

    public init(gradient: Gradient, center: UnitPoint, startAngle: Angle = .zero, endAngle: Angle = .zero) {
        self.gradient = gradient
        self.center = center
        self.startAngle = startAngle
        self.endAngle = endAngle
    }

    @_alwaysEmitIntoClient
    public init(colors: [Color], center: UnitPoint, startAngle: Angle, endAngle: Angle) {
        self.init(gradient: Gradient(colors: colors), center: center, startAngle: startAngle, endAngle: endAngle)
    }

    @_alwaysEmitIntoClient
    public init(stops: [Gradient.Stop], center: UnitPoint, startAngle: Angle, endAngle: Angle) {
        self.init(gradient: Gradient(stops: stops), center: center, startAngle: startAngle, endAngle: endAngle)
    }

    /// A full turn from an angle (a conic gradient).
    public init(gradient: Gradient, center: UnitPoint, angle: Angle = .zero) {
        self.init(gradient: gradient, center: center, startAngle: angle, endAngle: angle + .degrees(360))
    }

    @_alwaysEmitIntoClient
    public init(colors: [Color], center: UnitPoint, angle: Angle = .zero) {
        self.init(gradient: Gradient(colors: colors), center: center, angle: angle)
    }

    @_alwaysEmitIntoClient
    public init(stops: [Gradient.Stop], center: UnitPoint, angle: Angle = .zero) {
        self.init(gradient: Gradient(stops: stops), center: center, angle: angle)
    }

    public func _apply(to shape: inout _ShapeStyle_Shape) {
        let paint = _FinchGradientPaint(kind: .angular(center: center, start: startAngle.radians, end: endAngle.radians),
                                        stops: gradient.resolved(in: shape.environment))
        _finchApply(paint, gradient: gradient, to: &shape)
    }

    public var body: _ShapeView<Rectangle, AngularGradient> {
        _ShapeView(shape: Rectangle(), style: self)
    }

    public typealias Resolved = Never
}
