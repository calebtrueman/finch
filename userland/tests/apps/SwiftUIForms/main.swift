// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIForms: forms (grouped, with sections, headers and footers) and a sectioned list,
// built against Apple's SDK as Xcode would.
import SwiftUI
struct FormsView: View {
    @State private var on = true
    @State private var name = "Finch"
    @State private var pick: String? = "b"
    @State private var lastAction = "none"
    var body: some View {
        VStack(alignment: .leading) {
        HStack {
            Menu("Actions") {
                Button("Rename") { lastAction = "rename" }
                Divider()
                Toggle("Notifications", isOn: $on)
                Menu("More") {
                    Button("Archive") { lastAction = "archive" }
                }
            }
            Text("Last: \(lastAction)")
                .padding(4)
                .contextMenu {
                    Button("Copy") { lastAction = "copy" }
                }
        }
        HStack(alignment: .top) {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                    Toggle("Notifications", isOn: $on)
                }
                Section("Fields") {
                    TextField("Rounded", text: $name).textFieldStyle(.roundedBorder)
                    TextField("Plain", text: $name).textFieldStyle(.plain)
                }
                Section {
                    Text("Version 1.0")
                } header: {
                    Text("About")
                } footer: {
                    Text("Built for Finch")
                }
            }
            .formStyle(.grouped)
            .frame(width: 300)
            List(selection: $pick) {
                Section("Letters") {
                    Text("A").tag("a")
                    Text("B").tag("b")
                }
                Section("Numbers") {
                    Text("1").tag("1")
                }
            }
            .frame(width: 180, height: 220)
        }
        }
        .padding()
    }
}
@main struct FormsApp: App { var body: some Scene { WindowGroup("Forms") { FormsView() } } }
