/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What SwiftUICore links that Finch doesn't have elsewhere:
 *   - libAccessibility's client identification (SwiftUI asks which assistive client is
 *     making a request): Finch has no assistive clients yet, so none (0);
 *   - the Swift 5.6 and concurrency compatibility libraries' force-load anchors, which
 *     the compiler adds for older deployment targets; SwiftUI targets macOS 26, which
 *     has no need of them.
 */
#include <stdint.h>

__attribute__((visibility("hidden"))) uint32_t _AXGetClientForCurrentRequestUntrusted(void) { return 0; }
__attribute__((visibility("hidden"))) void _AXSetClientIdentificationOverride(uint32_t client) { (void)client; }
__attribute__((visibility("hidden"))) char _swift_FORCE_LOAD_$_swiftCompatibility56;
__attribute__((visibility("hidden"))) char _swift_FORCE_LOAD_$_swiftCompatibilityConcurrency;
