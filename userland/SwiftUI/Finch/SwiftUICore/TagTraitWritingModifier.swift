// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The tag modifier that `View.tag(_:includeOptional:)` uses from macOS 26, to Apple's
// interface: it writes the tag traits the earlier `tag(_:includeOptional:)` wrote, the tag
// and (when asked) the tag as an optional, for pickers and lists to read.

import OpenAttributeGraphShims

@available(OpenSwiftUI_v7_0, *)
@frozen
public struct _TagTraitWritingModifier<TagValue>: PrimitiveViewModifier where TagValue: Hashable {
    public let tag: TagValue
    public let includeOptional: Bool

    @_alwaysEmitIntoClient
    public init(tag: TagValue, includeOptional: Bool) {
        self.tag = tag
        self.includeOptional = includeOptional
    }

    nonisolated public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        body(_Graph(), inputs)
    }

    nonisolated public static func _makeViewList(
        modifier: _GraphValue<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        var inputs = inputs
        inputs.traits = Attribute(AddTags(modifier: modifier.value, traits: OptionalAttribute(inputs.traits)))
        inputs.addTraitKey(TagValueTraitKey<TagValue>.self)
        inputs.addTraitKey(TagValueTraitKey<TagValue?>.self)
        return body(_Graph(), inputs)
    }

    nonisolated public static func _viewListCount(
        inputs: _ViewListCountInputs,
        body: (_ViewListCountInputs) -> Int?
    ) -> Int? {
        body(inputs)
    }

    private struct AddTags: Rule {
        @Attribute var modifier: _TagTraitWritingModifier
        @OptionalAttribute var traits: ViewTraitCollection?

        var value: ViewTraitCollection {
            var traits = traits ?? ViewTraitCollection()
            traits[TagValueTraitKey<TagValue>.self] = .tagged(modifier.tag)
            traits[TagValueTraitKey<TagValue?>.self] = modifier.includeOptional ? .tagged(Optional(modifier.tag)) : .untagged
            return traits
        }
    }
}

@available(*, unavailable)
extension _TagTraitWritingModifier: Sendable {}
