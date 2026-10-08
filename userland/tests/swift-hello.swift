// SPDX-License-Identifier: MIT OR Apache-2.0
// finch-swift-hello: a Swift program that runs against Finch's own libswiftCore
// (userland/swift), to prove the open Swift runtime works in the VM. Exercises
// the standard library's Array, Dictionary, String, closures and generics.
import Swift

let doubled = [3, 1, 2, 5, 4].sorted().map { $0 * 2 }
print("sorted*2:", doubled)
print("sum:", doubled.reduce(0, +))

var counts: [String: Int] = [:]
for word in "the cat the dog the bird".split(separator: " ") {
    counts[String(word), default: 0] += 1
}
print("counts:", counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

func describe<T>(_ xs: [T]) -> String { "\(xs.count) of \(T.self)" }
print("generic:", describe(["a", "b", "c"]), "/", describe([1.0, 2.0]))

print("finch-swift-hello: ok")
