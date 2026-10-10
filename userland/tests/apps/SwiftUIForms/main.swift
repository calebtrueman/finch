// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUIForms: forms (grouped, with sections, headers and footers) and a sectioned list,
// sheets, alerts, a confirmation dialog and a popover, built against Apple's SDK as Xcode would.
import SwiftUI
struct FormsView: View {
    @State private var on = true
    @State private var name = "Finch"
    @State private var pick: String? = "b"
    @State private var lastAction = "none"
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var showDialog = false
    @State private var showPopover = false
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
        HStack {
            Button("Sheet") { showSheet = true }
                .sheet(isPresented: $showSheet, onDismiss: { lastAction += " (sheet closed)" }) {
                    SheetView(name: $name)
                }
            Button("Alert") { showAlert = true }
                .alert("Delete \(name)?", isPresented: $showAlert) {
                    Button("Delete", role: .destructive) { lastAction = "deleted" }
                    Button("Cancel", role: .cancel) { lastAction = "kept" }
                } message: {
                    Text("This can't be undone.")
                }
            Button("Dialog") { showDialog = true }
                .confirmationDialog("Share", isPresented: $showDialog) {
                    Button("Mail") { lastAction = "mail" }
                    Button("Messages") { lastAction = "messages" }
                }
            Button("Popover") { showPopover = true }
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    Text("Hello from a popover").padding()
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
struct SheetView: View {
    @Binding var name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Edit name").font(.headline)
            TextField("Name", text: $name).frame(width: 200)
            Button("Done") { dismiss() }
        }
        .padding(20)
    }
}
@main struct FormsApp: App { var body: some Scene { WindowGroup("Forms") { FormsView() } } }
