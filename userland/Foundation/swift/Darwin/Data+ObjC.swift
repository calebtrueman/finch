//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// Finch: Data's Objective-C half: what swift-foundation's Data.swift leaves to
// Foundation.framework (FOUNDATION_FRAMEWORK). Taken from Swift's historical
// overlay stdlib/public/Darwin/Foundation/Data.swift (swift-5.4-RELEASE),
// arranged as extensions with the declarations of Apple's current
// Foundation (the SDK's Foundation.swiftinterface).

@_implementationOnly import _SwiftFoundationOverlayShims

extension __DataStorage {
    static func allocate(_ size: Int, _ clear: Bool) -> UnsafeMutableRawPointer? {
        if clear {
            return calloc(1, size)
        } else {
            return malloc(size)
        }
    }

    static func reallocate(_ ptr: UnsafeMutableRawPointer, _ newSize: Int) -> UnsafeMutableRawPointer? {
        return realloc(ptr, newSize)
    }

    /// The NSRange form, which clients' inlined code calls on systems before
    /// macOS 14.
    @usableFromInline
    func replaceBytes(in range_: NSRange, with replacementBytes: UnsafeRawPointer?, length replacementLength: Int) {
        replaceBytes(in: range_.location ..< range_.location + range_.length,
                     with: replacementBytes, length: replacementLength)
    }

    @usableFromInline
    convenience init(immutableReference: NSData, offset: Int) {
        self.init(bytes: UnsafeMutableRawPointer(mutating: immutableReference.bytes),
                  length: immutableReference.length, copy: false,
                  deallocator: { _, _ in _fixLifetime(immutableReference) }, offset: offset)
    }

    @usableFromInline
    convenience init(mutableReference: NSMutableData, offset: Int) {
        self.init(bytes: mutableReference.mutableBytes, length: mutableReference.length, copy: false,
                  deallocator: { _, _ in _fixLifetime(mutableReference) }, offset: offset)
    }

    @usableFromInline
    convenience init(customReference: NSData, offset: Int) {
        self.init(bytes: UnsafeMutableRawPointer(mutating: customReference.bytes),
                  length: customReference.length, copy: false,
                  deallocator: { _, _ in _fixLifetime(customReference) }, offset: offset)
    }

    @usableFromInline
    convenience init(customMutableReference: NSMutableData, offset: Int) {
        self.init(bytes: customMutableReference.mutableBytes, length: customMutableReference.length, copy: false,
                  deallocator: { _, _ in _fixLifetime(customMutableReference) }, offset: offset)
    }

    func withInteriorPointerReference<T>(_ range: Range<Int>, _ work: (NSData) throws -> T) rethrows -> T {
        if range.isEmpty {
            return try work(NSData()) // zero length data can be optimized as a singleton
        }
        return try work(NSData(bytesNoCopy: _bytes!.advanced(by: range.lowerBound - _offset),
                               length: range.upperBound - range.lowerBound, freeWhenDone: false))
    }

    @inline(never) // Not @inlinable, to keep the private `__NSSwiftData` class name out of clients.
    @usableFromInline
    func bridgedReference(_ range: Range<Int>) -> NSData {
        if range.isEmpty {
            return NSData() // zero length data can be optimized as a singleton
        }
        return __NSSwiftData(backing: self, range: range)
    }
}

// NOTE: older overlays called this _NSSwiftData. The two must
// coexist, so it was renamed. The old name must not be used in the new
// runtime.
internal class __NSSwiftData : NSData {
    var _backing: __DataStorage!
    var _range: Range<Data.Index>!

    convenience init(backing: __DataStorage, range: Range<Data.Index>) {
        self.init()
        _backing = backing
        _range = range
    }
    @objc override var length: Int {
        return _range.upperBound - _range.lowerBound
    }

    @objc override var bytes: UnsafeRawPointer {
        // NSData's byte pointer methods are not annotated for nullability
        // correctly; an empty NSData's bytes are never dereferenced.
        guard let bytes = _backing.bytes else {
            return UnsafeRawPointer(bitPattern: 0xBAD0)!
        }
        return bytes.advanced(by: _range.lowerBound)
    }

    @objc override func copy(with zone: NSZone? = nil) -> Any {
        return self
    }

    @objc override func mutableCopy(with zone: NSZone? = nil) -> Any {
        return NSMutableData(bytes: bytes, length: length)
    }

    @objc override func _isCompact() -> Bool {
        return true
    }

    @objc(_providesConcreteBacking)
    func _providesConcreteBacking() -> Bool {
        return true
    }
}

extension Data.InlineSlice {
    @inlinable
    internal func bridgedReference() -> NSData {
        return storage.bridgedReference(self.range)
    }
}

extension Data.LargeSlice {
    @inlinable
    internal func bridgedReference() -> NSData {
        return storage.bridgedReference(self.range)
    }
}

extension Data._Representation {
    @inlinable
    internal func bridgedReference() -> NSData {
        switch self {
        case .empty: return NSData()
        case .inline(let inline):
            return inline.withUnsafeBytes {
                return NSData(bytes: $0.baseAddress, length: $0.count)
            }
        case .slice(let slice):
            return slice.bridgedReference()
        case .large(let slice):
            return slice.bridgedReference()
        }
    }

    func withInteriorPointerReference<T>(_ work: (NSData) throws -> T) rethrows -> T {
        switch self {
        case .empty:
            return try work(NSData())
        case .inline(let inline):
            return try inline.withUnsafeBytes {
                return try work(NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 0xBAD0)!), length: $0.count, freeWhenDone: false))
            }
        case .slice(let slice):
            return try slice.storage.withInteriorPointerReference(slice.range, work)
        case .large(let slice):
            return try slice.storage.withInteriorPointerReference(slice.range, work)
        }
    }
}

extension Data : ReferenceConvertible {
    public typealias ReferenceType = NSData

    @_semantics("convertToObjectiveC")
    public func _bridgeToObjectiveC() -> NSData {
        return _representation.bridgedReference()
    }

    public static func _forceBridgeFromObjectiveC(_ input: NSData, result: inout Data?) {
        // We must copy the input because it might be mutable; just like storing a value type in ObjC
        result = Data(referencing: input)
    }

    public static func _conditionallyBridgeFromObjectiveC(_ input: NSData, result: inout Data?) -> Bool {
        // We must copy the input because it might be mutable; just like storing a value type in ObjC
        result = Data(referencing: input)
        return true
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSData?) -> Data {
        guard let src = source else { return Data() }
        return Data(referencing: src)
    }
}

extension NSData : _HasCustomAnyHashableRepresentation {
    // Must be @nonobjc to avoid infinite recursion during bridging.
    @nonobjc
    public func _toCustomAnyHashable() -> AnyHashable? {
        return AnyHashable(Data._unconditionallyBridgeFromObjectiveC(self))
    }
}

extension Data {
    /// Initialize a `Data` by adopting a reference type.
    ///
    /// `struct Data` will use the `class NSData` for all operations; mutating
    /// the result copies the contents (through `mutableCopy()`).
    public init(referencing reference: __shared NSData) {
        let length = reference.length
        if length == 0 {
            self.init()
        } else {
            let providesConcreteBacking = (reference as AnyObject)._providesConcreteBacking?() ?? false
            if providesConcreteBacking {
                self.init(representation: _Representation(__DataStorage(immutableReference: reference.copy() as! NSData, offset: 0), count: length))
            } else {
                self.init(representation: _Representation(__DataStorage(customReference: reference.copy() as! NSData, offset: 0), count: length))
            }
        }
    }
}

// The selector _providesConcreteBacking, for the dynamic lookup above.
@objc private protocol _NSDataConcreteBacking {
    @objc optional func _providesConcreteBacking() -> Bool
}
