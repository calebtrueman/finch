// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIGallery: the common SwiftUI views and modifiers in one window, built against
// Apple's SDK as Xcode would, to see which of them Finch's SwiftUI draws.
import SwiftUI

@main
struct SwiftUIGalleryApp: App {
    var body: some Scene {
        WindowGroup("SwiftUI Gallery") {
            Gallery()
        }
    }
}

struct Gallery: View {
    @State private var on = true
    @State private var level = 0.4
    @State private var name = "Finch"
    @State private var choice = 1
    @AppStorage("galleryPresses") private var presses = 0
    @State private var taskRan = "task: waiting"
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gallery").font(.largeTitle).bold()
            HStack {
                Text("Shapes:")
                Rectangle().fill(.red).frame(width: 30, height: 20)
                RoundedRectangle(cornerRadius: 6).fill(.blue).frame(width: 30, height: 20)
                Circle().fill(.green).frame(width: 20, height: 20)
                Capsule().stroke(.orange, lineWidth: 2).frame(width: 40, height: 20)
            }
            HStack {
                Text("Styled").foregroundStyle(.purple).italic()
                Text("Mono").font(.system(.body, design: .monospaced))
                Text("Padded").padding(4).background(.yellow)
            }
            Divider()
            Toggle("Toggle", isOn: $on)
            Slider(value: $level) { Text("Slider") }
            TextField("Name", text: $name)
            Picker("Picker", selection: $choice) {
                Text("One").tag(1)
                Text("Two").tag(2)
            }
            ProgressView(value: level)
            HStack {
                Button("Button") {}
                Button("Prominent") {}.buttonStyle(.borderedProminent)
                Button("Borderless") {}.buttonStyle(.borderless)
                Button("Link") {}.buttonStyle(.link)
                Spacer()
                Text("Level \(level, specifier: "%.2f")")
            }
            HStack {
                Button("Stored \(presses)") { presses += 1 }
                Text(taskRan).task { taskRan = "task: ran" }
                Text(hovering ? "hovering" : "hover me")
                    .padding(4)
                    .background(hovering ? Color.yellow : Color.clear)
                    .onHover { hovering = $0 }
                    .help("A tooltip")
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(1...20, id: \.self) { Text("Scrolled line \($0)") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 70)
            List {
                ForEach(1...8, id: \.self) { Text("Row \($0)") }
            }
            .frame(height: 60)
        }
        .padding()
        .frame(width: 420)
    }
}
