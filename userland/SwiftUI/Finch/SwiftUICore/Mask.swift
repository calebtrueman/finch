// SPDX-License-Identifier: MIT OR Apache-2.0
//
// mask(_:) and mask(alignment:_:), to Apple's interface (_MaskEffect, _MaskAlignmentEffect).
// The mask view is laid out in the content's frame (placed by the alignment) and its display
// list masks the content's: the content shows where the mask is opaque. The views the
// display list makes keep the mask as their mask view.

package import OpenAttributeGraphShims
public import OpenCoreGraphicsShims

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct _MaskEffect<Mask>: ViewModifier, PrimitiveViewModifier, MultiViewModifier where Mask: View {
    public var mask: Mask

    @inlinable
    public init(mask: Mask) {
        self.mask = mask
    }

    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        _finchMakeMask(mask: _GraphValue(AlignedMask(effect: modifier.value)), inputs: inputs, body: body)
    }

    private struct AlignedMask: Rule {
        @Attribute var effect: _MaskEffect

        var value: ModifiedContent<Mask, _FlexFrameLayout> {
            effect.mask.modifier(_FlexFrameLayout(maxWidth: .infinity, maxHeight: .infinity, alignment: .center))
        }
    }

    public typealias Body = Never
}

@available(OpenSwiftUI_v3_0, *)
@frozen
public struct _MaskAlignmentEffect<Mask>: ViewModifier, PrimitiveViewModifier, MultiViewModifier where Mask: View {
    public var alignment: Alignment
    public var mask: Mask

    @inlinable
    public init(alignment: Alignment, mask: Mask) {
        self.mask = mask
        self.alignment = alignment
    }

    nonisolated public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs,
                                             body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        _finchMakeMask(mask: _GraphValue(AlignedMask(effect: modifier.value)), inputs: inputs, body: body)
    }

    private struct AlignedMask: Rule {
        @Attribute var effect: _MaskAlignmentEffect

        var value: ModifiedContent<Mask, _FlexFrameLayout> {
            effect.mask.modifier(_FlexFrameLayout(maxWidth: .infinity, maxHeight: .infinity, alignment: effect.alignment))
        }
    }

    public typealias Body = Never
}

@available(*, unavailable) extension _MaskAlignmentEffect: Sendable {}

/// The content, and the mask laid out in its frame, their display lists one masking the other.
private func _finchMakeMask<M: View>(mask: _GraphValue<M>, inputs: _ViewInputs,
                                     body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
    guard inputs.preferences.requiresDisplayList else {
        return body(_Graph(), inputs)
    }
    var childInputs = inputs
    if inputs.needsGeometry {
        childInputs.containerPosition = inputs.animatedPosition()
    }
    var outputs = body(_Graph(), childInputs)
    let maskOutputs = M.makeDebuggableView(view: mask, inputs: childInputs)
    let identity = DisplayList.Identity()
    inputs.pushIdentity(identity)
    outputs.displayList = Attribute(MaskDisplayList(
        identity: identity,
        position: inputs.animatedPosition(),
        size: inputs.animatedSize(),
        containerPosition: inputs.containerPosition,
        content: .init(outputs.displayList),
        mask: .init(maskOutputs.displayList),
        options: inputs.displayListOptions))
    return outputs
}

private struct MaskDisplayList: Rule, AsyncAttribute {
    let identity: DisplayList.Identity
    @Attribute var position: ViewOrigin
    @Attribute var size: ViewSize
    @Attribute var containerPosition: ViewOrigin
    @OptionalAttribute var content: DisplayList?
    @OptionalAttribute var mask: DisplayList?
    let options: DisplayList.Options

    var value: DisplayList {
        let content = content ?? .init()
        guard !content.isEmpty else { return .init() }
        let version = DisplayList.Version(forUpdate: ())
        var item = DisplayList.Item(
            .effect(.mask(mask ?? .init()), content),
            frame: CGRect(origin: CGPoint(position - containerPosition), size: size.value),
            identity: identity,
            version: version)
        item.canonicalize(options: options)
        return DisplayList(item)
    }
}

@available(*, unavailable) extension _MaskEffect: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension _MaskEffect: Equatable where Mask: Equatable {
    public static func == (a: _MaskEffect<Mask>, b: _MaskEffect<Mask>) -> Bool {
        a.mask == b.mask
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    @inlinable
    nonisolated public func mask<Mask>(_ mask: Mask) -> some View where Mask: View {
        modifier(_MaskEffect(mask: mask))
    }

    @available(OpenSwiftUI_v3_0, *)
    @inlinable
    nonisolated public func mask<Mask>(alignment: Alignment = .center, @ViewBuilder _ mask: () -> Mask) -> some View
        where Mask: View {
        modifier(_MaskAlignmentEffect(alignment: alignment, mask: mask()))
    }
}
