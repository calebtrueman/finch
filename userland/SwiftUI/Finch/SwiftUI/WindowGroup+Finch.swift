// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The entry point Apple's inlinable WindowGroup initializers call (macOS 14.5 and later):
// a group whose windows build their content when they open.

@available(OpenSwiftUI_v5_0, *)
extension WindowGroup {
    @usableFromInline
    nonisolated internal init(id: String? = nil, title: Text? = nil, @ViewBuilder lazyContent: @escaping () -> Content) {
        self.title = title
        self.id = id
        self.content = .lazy(lazyContent)
    }
}
