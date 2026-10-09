// SPDX-License-Identifier: MIT OR Apache-2.0
// OSAllocatedUnfairLock: an os_unfair_lock in a heap buffer beside the state
// it protects. Its operations are inlined into clients (they're
// @_alwaysEmitIntoClient in Apple's os overlay), so what the library holds is
// the type itself, its frozen layout (one ManagedBuffer reference) and the
// flags type. Finch's code, with Apple's declarations (macOS 26.4 SDK).

import Darwin

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
public struct OSAllocatedUnfairLockFlags: OptionSet, RawRepresentable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  /// OS_UNFAIR_LOCK_ADAPTIVE_SPIN
  public static let adaptiveSpin = OSAllocatedUnfairLockFlags(rawValue: 1 << 1)

  @usableFromInline
  internal var _translatedValue: __os_unfair_lock_flags_t {
    // OS_UNFAIR_LOCK_FLAG_ADAPTIVE_SPIN
    return __os_unfair_lock_flags_t(rawValue: contains(.adaptiveSpin) ? 0x0004_0000 : 0)
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
@frozen
public struct OSAllocatedUnfairLock<State>: @unchecked Sendable {
  @_alwaysEmitIntoClient
  internal let __lock: ManagedBuffer<State, os_unfair_lock>

  @_alwaysEmitIntoClient
  public init(uncheckedState initialState: State) {
    __lock = .create(minimumCapacity: 1) { buffer in
      buffer.withUnsafeMutablePointerToElements { lock in
        lock.initialize(to: .init())
      }
      return initialState
    }
  }

  @_alwaysEmitIntoClient
  public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
    return try __lock.withUnsafeMutablePointers { header, lock in
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      return try body(&header.pointee)
    }
  }

  @_alwaysEmitIntoClient
  public func withLock<R: Sendable>(_ body: @Sendable (inout State) throws -> R) rethrows -> R {
    return try withLockUnchecked(body)
  }

  @_alwaysEmitIntoClient
  public func withLockIfAvailableUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R? {
    return try __lock.withUnsafeMutablePointers { header, lock in
      guard os_unfair_lock_trylock(lock) else { return nil }
      defer { os_unfair_lock_unlock(lock) }
      return try body(&header.pointee)
    }
  }

  @_alwaysEmitIntoClient
  public func withLockIfAvailable<R: Sendable>(_ body: @Sendable (inout State) throws -> R) rethrows -> R? {
    return try withLockIfAvailableUnchecked(body)
  }

  @frozen
  public enum Ownership: Hashable {
    case owner
    case notOwner
  }

  @_alwaysEmitIntoClient
  internal func _preconditionTest(_ condition: Ownership) -> Bool {
    __lock.withUnsafeMutablePointerToElements { lock in
      switch condition {
      case .owner: os_unfair_lock_assert_owner(lock)
      case .notOwner: os_unfair_lock_assert_not_owner(lock)
      }
    }
    return true
  }

  @_transparent
  @_alwaysEmitIntoClient
  public func precondition(_ condition: Ownership) {
    Swift.precondition(_preconditionTest(condition), "lockPrecondition failure")
  }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension OSAllocatedUnfairLock where State == () {
  @_alwaysEmitIntoClient
  public init() { self.init(uncheckedState: ()) }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension OSAllocatedUnfairLock where State: Sendable {
  @_alwaysEmitIntoClient
  public init(initialState: State) { self.init(uncheckedState: initialState) }
}
