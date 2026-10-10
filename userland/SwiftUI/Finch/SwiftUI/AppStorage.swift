// SPDX-License-Identifier: MIT OR Apache-2.0
//
// AppStorage, to Apple's interface: a value in UserDefaults, read and written through the
// property, and the view updated when the default changes (from the property, or from any
// other writer: the store's change notification). Its one stored property is a reference
// to a UserDefaultLocation, as Apple's is: apps lay AppStorage out inline.

public import Foundation
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

@available(OpenSwiftUI_v2_0, *)
@usableFromInline
class UserDefaultLocation<Value>: @unchecked Sendable {
    @usableFromInline
    var wasRead = false

    let key: String
    let store: UserDefaults
    let defaultValue: Value
    private let read: (UserDefaults, String) -> Value?
    private let write: (UserDefaults, String, Value) -> Void
    private var observer: NSObjectProtocol?
    /// What to do when the value may have changed: invalidate the views reading it.
    private var invalidations: [ObjectIdentifier: () -> Void] = [:]

    init(key: String, store: UserDefaults?, defaultValue: Value, read: @escaping (UserDefaults, String) -> Value?,
         write: @escaping (UserDefaults, String, Value) -> Void) {
        self.key = key
        self.store = store ?? .standard
        self.defaultValue = defaultValue
        self.read = read
        self.write = write
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: self.store,
                                                          queue: .main) { [weak self] _ in
            self?.changed()
        }
    }

    @usableFromInline
    func get() -> Value {
        wasRead = true
        return read(store, key) ?? defaultValue
    }

    @usableFromInline
    func set(_ value: Value, transaction: Transaction) {
        write(store, key, value)
        changed()
    }

    @usableFromInline
    func update() -> (Value, Bool) {
        (get(), false)
    }

    @usableFromInline
    static func == (lhs: UserDefaultLocation<Value>, rhs: UserDefaultLocation<Value>) -> Bool {
        lhs === rhs
    }

    func observe(_ owner: AnyObject, _ invalidate: @escaping () -> Void) {
        invalidations[ObjectIdentifier(owner)] = invalidate
    }

    func stopObserving(_ owner: AnyObject) {
        invalidations[ObjectIdentifier(owner)] = nil
    }

    private func changed() {
        for invalidate in invalidations.values {
            invalidate()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@available(OpenSwiftUI_v2_0, *)
@frozen
@propertyWrapper
public struct AppStorage<Value>: DynamicProperty {
    @usableFromInline
    var location: UserDefaultLocation<Value>

    init(location: UserDefaultLocation<Value>) {
        self.location = location
    }

    public var wrappedValue: Value {
        get { location.get() }
        nonmutating set { location.set(newValue, transaction: Transaction()) }
    }

    public var projectedValue: Binding<Value> {
        let location = location
        return Binding(get: { location.get() }, set: { location.set($0, transaction: $1) })
    }

    public static func _makeProperty<V>(in buffer: inout _DynamicPropertyBuffer, container: _GraphValue<V>, fieldOffset: Int,
                                        inputs: inout _GraphInputs) {
        let attribute = Attribute(value: ())
        buffer.append(AppStorageBox<Value>(host: .currentHost, invalidation: WeakAttribute(attribute)), fieldOffset: fieldOffset)
    }
}

@available(OpenSwiftUI_v2_0, *)
extension AppStorage: Sendable where Value: Sendable {}

/// Invalidates the view when its default changes.
private final class AppStorageObserver {
    weak var host: GraphHost?
    let attribute: WeakAttribute<()>

    init(host: GraphHost, attribute: WeakAttribute<()>) {
        self.host = host
        self.attribute = attribute
    }

    func invalidate() {
        let attribute = attribute
        Update.perform {
            guard let host = self.host else { return }
            host.asyncTransaction(.current, invalidating: attribute, style: Update.threadIsUpdating ? .deferred : .immediate)
        }
    }
}

private struct AppStorageBox<Value>: DynamicPropertyBox {
    let observer: AppStorageObserver
    var location: UserDefaultLocation<Value>?

    init(host: GraphHost, invalidation: WeakAttribute<()>) {
        observer = AppStorageObserver(host: host, attribute: invalidation)
    }

    typealias Property = AppStorage<Value>

    mutating func update(property: inout Property, phase: ViewPhase) -> Bool {
        if location !== property.location {
            location?.stopObserving(observer)
            let observer = observer
            property.location.observe(observer) { observer.invalidate() }
            location = property.location
        }
        return observer.attribute.changedValue()?.changed ?? false
    }
}

// MARK: - Values

private func object<T>(_ store: UserDefaults, _ key: String) -> T? {
    store.object(forKey: key) as? T
}

private func setObject<T>(_ store: UserDefaults, _ key: String, _ value: T?) {
    if let value {
        store.set(value, forKey: key)
    } else {
        store.removeObject(forKey: key)
    }
}

@available(OpenSwiftUI_v2_0, *)
extension AppStorage {
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Bool {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) }))
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Int {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) }))
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Double {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) }))
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == String {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) }))
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == URL {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue,
                                                read: { $0.url(forKey: $1) }, write: { $0.set($2, forKey: $1) }))
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Date {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) }))
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Data {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue, read: object, write: { $0.set($2, forKey: $1) }))
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil)
        where Value: RawRepresentable, Value.RawValue == Int {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue,
                                                read: { (object($0, $1) as Int?).flatMap(Value.init(rawValue:)) },
                                                write: { $0.set($2.rawValue, forKey: $1) }))
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil)
        where Value: RawRepresentable, Value.RawValue == String {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: wrappedValue,
                                                read: { (object($0, $1) as String?).flatMap(Value.init(rawValue:)) },
                                                write: { $0.set($2.rawValue, forKey: $1) }))
    }
}

@available(OpenSwiftUI_v2_0, *)
extension AppStorage where Value: ExpressibleByNilLiteral {
    public init(_ key: String, store: UserDefaults? = nil) where Value == Bool? {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject))
    }

    public init(_ key: String, store: UserDefaults? = nil) where Value == Int? {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject))
    }

    public init(_ key: String, store: UserDefaults? = nil) where Value == Double? {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject))
    }

    public init(_ key: String, store: UserDefaults? = nil) where Value == String? {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject))
    }

    public init(_ key: String, store: UserDefaults? = nil) where Value == URL? {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil, read: { .some($0.url(forKey: $1)) },
                                                write: { store, key, url in
                                                    if let url { store.set(url, forKey: key) } else { store.removeObject(forKey: key) }
                                                }))
    }

    public init(_ key: String, store: UserDefaults? = nil) where Value == Date? {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject))
    }

    public init(_ key: String, store: UserDefaults? = nil) where Value == Data? {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil, read: { .some(object($0, $1)) }, write: setObject))
    }
}

@available(OpenSwiftUI_v3_0, *)
extension AppStorage {
    public init<R>(_ key: String, store: UserDefaults? = nil) where Value == R?, R: RawRepresentable, R.RawValue == String {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil,
                                                read: { .some((object($0, $1) as String?).flatMap(R.init(rawValue:))) },
                                                write: { setObject($0, $1, $2?.rawValue) }))
    }

    public init<R>(_ key: String, store: UserDefaults? = nil) where Value == R?, R: RawRepresentable, R.RawValue == Int {
        self.init(location: UserDefaultLocation(key: key, store: store, defaultValue: nil,
                                                read: { .some((object($0, $1) as Int?).flatMap(R.init(rawValue:))) },
                                                write: { setObject($0, $1, $2?.rawValue) }))
    }
}
