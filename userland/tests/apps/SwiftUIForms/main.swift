// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIForms: forms (grouped, with sections, headers and footers) and a sectioned list,
// built against Apple's SDK as Xcode would.
import SwiftUI
struct FormsView: View {
    @State private var on = true
    @State private var name = "Finch"
    @State private var pick: String? = "b"
    var body: some View {
        HStack(alignment: .top) {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                    Toggle("Notifications", isOn: $on)
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
        .padding()
    }
}
@main struct FormsApp: App { var body: some Scene { WindowGroup("Forms") { FormsView() } } }
