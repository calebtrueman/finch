// SPDX-License-Identifier: MIT OR Apache-2.0
// SwiftUINavigation: a split view whose sidebar links show their values in the detail column,
// a stack there that pushes further pages by value and by view, and navigation titles,
// built against Apple's SDK as Xcode would.
import SwiftUI

struct Fruit: Hashable, Identifiable {
    var name: String
    var colour: String
    var id: String { name }
}

let fruits = [Fruit(name: "Apple", colour: "red"), Fruit(name: "Banana", colour: "yellow"),
              Fruit(name: "Cherry", colour: "dark red")]

struct FruitDetail: View {
    var fruit: Fruit
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(fruit.name).font(.title)
            Text("Colour: \(fruit.colour)")
            NavigationLink("Nutrition", value: fruit.name.count)
            NavigationLink("About \(fruit.name)") {
                Text("All about \(fruit.name)").padding().navigationTitle("About")
            }
        }
        .padding()
        .navigationTitle(fruit.name)
    }
}

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List(fruits) { fruit in
                NavigationLink(fruit.name, value: fruit)
            }
            .navigationSplitViewColumnWidth(160)
            .navigationDestination(for: Fruit.self) { fruit in
                NavigationStack {
                    FruitDetail(fruit: fruit)
                        .navigationDestination(for: Int.self) { letters in
                            Text("\(letters) letters").padding().navigationTitle("Nutrition")
                        }
                }
            }
        } detail: {
            Text("Pick a fruit").foregroundStyle(.secondary)
                .navigationTitle("Fruits")
        }
        .frame(width: 560, height: 320)
    }
}

@main struct NavigationApp: App { var body: some Scene { WindowGroup("Navigation") { ContentView() } } }
