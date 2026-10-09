//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
// SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
// Finch: UUID's bridging, from swift-foundation's UUID_Wrappers.swift
// (swift-6.3.1-RELEASE), which Finch leaves out: Apple's NSUUID there is the
// Swift subclass __NSConcreteUUID; Finch's NSUUID is Objective-C, so UUID
// bridges through the bytes.

@available(macOS 10.10, iOS 8.0, tvOS 9.0, watchOS 2.0, *)
extension UUID : ReferenceConvertible {
     public typealias ReferenceType = NSUUID

     @_semantics("convertToObjectiveC")
     public func _bridgeToObjectiveC() -> NSUUID {
         return withUnsafeBytes(of: uuid) { NSUUID(uuidBytes: $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
     }

     public static func _forceBridgeFromObjectiveC(_ x: NSUUID, result: inout UUID?) {
         if !_conditionallyBridgeFromObjectiveC(x, result: &result) {
             fatalError("Unable to bridge \(_ObjectiveCType.self) to \(self)")
         }
     }

     public static func _conditionallyBridgeFromObjectiveC(_ input: NSUUID, result: inout UUID?) -> Bool {
         var bytes = uuid_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
         withUnsafeMutableBytes(of: &bytes) { input.getBytes($0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
         result = UUID(uuid: bytes)
         return true
     }

     @_effects(readonly)
     public static func _unconditionallyBridgeFromObjectiveC(_ source: NSUUID?) -> UUID {
         var result: UUID?
         _forceBridgeFromObjectiveC(source!, result: &result)
         return result!
     }
 }

@available(macOS 10.10, iOS 8.0, tvOS 9.0, watchOS 2.0, *)
extension NSUUID : _HasCustomAnyHashableRepresentation {
    // Must be @nonobjc to avoid infinite recursion during bridging.
    @nonobjc
    public func _toCustomAnyHashable() -> AnyHashable? {
        return AnyHashable(self as UUID)
    }
}
