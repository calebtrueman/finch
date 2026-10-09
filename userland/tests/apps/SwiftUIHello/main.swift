// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIHello: the smallest SwiftUI app, a window with text and a counting button,
// built against Apple's SDK as Xcode would, for running unmodified on Finch's SwiftUI.
import SwiftUI

@main
struct SwiftUIHelloApp: App {
    var body: some Scene {
        WindowGroup("SwiftUI Hello") {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Hello from SwiftUI")
                .font(.title)
            Text("Pressed \(count) times")
            Button("Press") { count += 1 }
        }
        .padding(40)
    }
}
