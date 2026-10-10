// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Glass and glassEffect, to Apple's interface. Finch draws glass as a translucent fill of
// the shape behind the view, lightly edged (tinted glass takes the tint); there is no
// refraction or blur of what is behind it.

public import OpenCoreGraphicsShims

@available(OpenSwiftUI_v7_0, *)
public struct Glass: Equatable, Sendable {
    enum Kind: Equatable { case regular, clear, identity }
    var kind: Kind
    var tintColor: Color?
    var isInteractive = false

    public static var regular: Glass { Glass(kind: .regular) }
    public static var clear: Glass { Glass(kind: .clear) }
    public static var identity: Glass { Glass(kind: .identity) }

    public func tint(_ color: Color?) -> Glass {
        var glass = self
        glass.tintColor = color
        return glass
    }

    public func interactive(_ isEnabled: Bool = true) -> Glass {
        var glass = self
        glass.isInteractive = isEnabled
        return glass
    }

    public static func == (a: Glass, b: Glass) -> Bool {
        a.kind == b.kind && a.tintColor == b.tintColor && a.isInteractive == b.isInteractive
    }
}

/// The default shape of a glass effect: a capsule.
@available(OpenSwiftUI_v7_0, *)
public struct DefaultGlassEffectShape: Shape {
    public init() {}

    nonisolated public func path(in rect: CGRect) -> Path {
        Capsule().path(in: rect)
    }

    nonisolated public static var role: ShapeRole { .fill }

    nonisolated public var layoutDirectionBehavior: LayoutDirectionBehavior { .fixed }
}

@available(OpenSwiftUI_v7_0, *)
extension View {
    nonisolated public func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View {
        let opacity: Double = switch glass.kind {
        case .regular: 0.55
        case .clear: 0.25
        case .identity: 0
        }
        let fill = (glass.tintColor ?? Color.white).opacity(opacity)
        return background {
            ZStack {
                shape.fill(fill)
                shape.stroke(Color.white.opacity(glass.kind == .identity ? 0 : 0.5), lineWidth: 0.5)
            }
        }
    }
}
