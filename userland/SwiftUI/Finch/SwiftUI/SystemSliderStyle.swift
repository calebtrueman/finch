// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The default slider style, as Apple's on macOS: an AppKit slider, its label on the leading
// side, and the minimum and maximum value labels at its ends when the slider has them.
// Upstream's draws nothing yet; this replaces it.

import SwiftUICore

private struct SystemSliderStyle: SliderStyle {
    func body(configuration: Slider<SliderStyleLabel, SliderStyleValueLabel>) -> some View {
        HStack(spacing: 6) {
            configuration.label
            if configuration.hasCustomMinMaxValueLabels {
                configuration._minimumValueLabel
            }
            _FinchSlider(value: configuration.$value, discreteValueCount: configuration.discreteValueCount,
                         onEditingChanged: configuration.onEditingChanged)
            if configuration.hasCustomMinMaxValueLabels {
                configuration._maximumValueLabel
            }
        }
    }
}

extension AnySliderStyle {
    static let `default` = AnySliderStyle(style: SystemSliderStyle())
}
