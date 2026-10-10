// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUITable: a table of people, sorted by clicking a column's title (again to reverse), a row
// selected by clicking it, and a column shown or hidden by a toggle, built against Apple's SDK
// as Xcode would.
import SwiftUI

struct Person: Identifiable {
    var id: Int
    var name: String
    var city: String
    var age: Int
}

let people = [Person(id: 1, name: "Ada", city: "London", age: 36), Person(id: 2, name: "Grace", city: "New York", age: 85),
              Person(id: 3, name: "Linus", city: "Helsinki", age: 55), Person(id: 4, name: "Margaret", city: "Boston", age: 88)]

struct ContentView: View {
    @State private var sortOrder = [KeyPathComparator(\Person.name)]
    @State private var selection: Person.ID?
    @State private var showsCity = true
    var sorted: [Person] { people.sorted(using: sortOrder) }
    var body: some View {
        VStack(alignment: .leading) {
            Table(sorted, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name)
                if showsCity {
                    TableColumn("City", value: \.city)
                }
                TableColumn("Age", value: \.age) { Text("\($0.age)") }.width(60)
            }
            HStack {
                Text("Selected: \(selection.flatMap { id in people.first { $0.id == id }?.name } ?? "none")")
                Spacer()
                Toggle("City", isOn: $showsCity)
            }
        }
        .padding()
        .frame(width: 480, height: 260)
    }
}

@main struct TableApp: App { var body: some Scene { WindowGroup("Table") { ContentView() } } }
