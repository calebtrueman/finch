// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIGallery: the common SwiftUI views and modifiers in one window, built against
// Apple's SDK as Xcode would, to see which of them Finch's SwiftUI draws.
import SwiftUI
import Observation

@Observable
final class GalleryModel {
    var taps = 0
}

@main
struct SwiftUIGalleryApp: App {
    var body: some Scene {
        WindowGroup("SwiftUI Gallery") {
            Gallery()
        }
    }
}

struct Gallery: View {
    @State private var drag = CGSize.zero
    @State private var on = true
    @State private var level = 0.4
    @State private var name = "Finch"
    @State private var choice = 1
    @AppStorage("galleryPresses") private var presses = 0
    @State private var taskRan = "task: waiting"
    @State private var hovering = false
    @State private var model = GalleryModel()

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
                Text("Gradients:")
                Rectangle().fill(LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom))
                    .frame(width: 30, height: 20)
                Circle().fill(RadialGradient(colors: [.yellow, .orange], center: .center, startRadius: 0, endRadius: 10))
                    .frame(width: 20, height: 20)
                Circle().fill(AngularGradient(colors: [.red, .green, .blue, .red], center: .center))
                    .frame(width: 20, height: 20)
                RoundedRectangle(cornerRadius: 6).fill(EllipticalGradient(colors: [.white, .purple]))
                    .frame(width: 40, height: 20)
                Capsule().stroke(LinearGradient(colors: [.green, .blue], startPoint: .leading, endPoint: .trailing),
                                 lineWidth: 3)
                    .frame(width: 40, height: 20)
                LinearGradient(colors: [.black, .gray], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 40, height: 20)
                Rectangle().fill(.blue).frame(width: 20, height: 20).mask { Circle() }
                LinearGradient(colors: [.red, .blue], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 60, height: 20)
                    .mask { Text("Mask").bold() }
            }
            HStack(alignment: .top) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 24))], spacing: 4) {
                    ForEach(0 ..< 9) { index in
                        RoundedRectangle(cornerRadius: 4).fill(Color(hue: Double(index) / 9, saturation: 0.6, brightness: 0.9))
                            .frame(height: 16)
                    }
                }
                .frame(width: 120)
                LazyHStack(spacing: 6) {
                    ForEach(["Lazy", "stack", "of", "words"], id: \.self) { Text($0) }
                }
                Circle().fill(.pink).frame(width: 20, height: 20)
                    .offset(drag)
                    .gesture(DragGesture().onChanged { drag = $0.translation })
                Text("drag \(Int(drag.width)),\(Int(drag.height))")
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
            HStack(alignment: .top) {
                Picker("Segmented", selection: $choice) {
                    Text("One").tag(1)
                    Text("Two").tag(2)
                }
                .pickerStyle(.segmented)
                Picker("Radio", selection: $choice) {
                    Text("One").tag(1)
                    Text("Two").tag(2)
                }
                .pickerStyle(.radioGroup)
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
                Button("Observed \(model.taps)") { model.taps += 1 }
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
            .listStyle(.bordered)
            .frame(height: 60)
        }
        .padding()
        .frame(width: 420)
    }
}
