// SPDX-License-Identifier: MIT OR Apache-2.0
//
// allowsHitTesting(_:), to Apple's interface: a view that doesn't take hit tests lets events
// through to what is behind it. Its content's responders are gathered under one whose
// allowsHitTesting follows the modifier, which hit testing skips when it is false.

import OpenAttributeGraphShims

@available(OpenSwiftUI_v1_0, *)
@frozen
public struct _AllowsHitTestingModifier: Equatable {
    public var allowsHitTesting: Bool

    @inlinable
    public init(allowsHitTesting: Bool) {
        self.allowsHitTesting = allowsHitTesting
    }

    nonisolated public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        var outputs = body(_Graph(), inputs)
        if inputs.preferences.requiresViewResponders {
            let filter = AllowsHitTestingFilter(
                modifier: modifier.value,
                children: outputs.viewResponders(),
                responder: AllowsHitTestingResponder(inputs: inputs)
            )
            outputs.preferences.viewResponders = Attribute(filter)
        }
        return outputs
    }

    public static func == (a: _AllowsHitTestingModifier, b: _AllowsHitTestingModifier) -> Bool {
        a.allowsHitTesting == b.allowsHitTesting
    }
}

@available(OpenSwiftUI_v1_0, *)
extension _AllowsHitTestingModifier: ViewModifier, MultiViewModifier, PrimitiveViewModifier {}

@available(OpenSwiftUI_v1_0, *)
extension View {
    @inlinable
    nonisolated public func allowsHitTesting(_ enabled: Bool) -> some View {
        modifier(_AllowsHitTestingModifier(allowsHitTesting: enabled))
    }
}

private final class AllowsHitTestingResponder: DefaultLayoutViewResponder {
    var allows = true

    override var allowsHitTesting: Bool { allows }
}

private struct AllowsHitTestingFilter: StatefulRule {
    @Attribute var modifier: _AllowsHitTestingModifier
    @Attribute var children: [ViewResponder]
    let responder: AllowsHitTestingResponder

    typealias Value = [ViewResponder]

    mutating func updateValue() {
        responder.allows = modifier.allowsHitTesting
        let (children, changed) = $children.changedValue()
        if changed {
            responder.children = children
        }
        if !hasValue {
            value = [responder]
        }
    }
}
