// SPDX-License-Identifier: MIT OR Apache-2.0
// The os overlay's Swift API for os_workgroup (<os/workgroup.h>): Finch's
// implementation over libSystem's os_workgroup_* functions, with the
// declarations of Apple's os overlay (macOS 26.4 SDK).

@_exported import os.workgroup
import Darwin

@available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
extension WorkGroup {
  @available(macOS 11.0, *)
  public func copyPort() -> mach_port_t {
    var port: mach_port_t = 0
    let rc = __os_workgroup_copy_port(self, &port)
    return rc == 0 ? port : 0
  }

  @available(macOS 11.0, *)
  public convenience init?(port: mach_port_t, name: String? = nil) {
    self.init(__name: name, port: port)
  }

  public func copy(name: String? = nil) -> WorkGroup? {
    return __os_workgroup_create_with_workgroup(name, self)
  }

  /// The token of a join, handed back to leave(token:).
  public struct JoinToken {
    fileprivate let storage: UnsafeMutablePointer<__os_workgroup_join_token_opaque_s>
  }

  public func join() -> JoinToken {
    let storage = UnsafeMutablePointer<__os_workgroup_join_token_opaque_s>.allocate(capacity: 1)
    storage.initialize(to: __os_workgroup_join_token_opaque_s())
    let rc = __os_workgroup_join(self, storage)
    if rc != 0 {
      fatalError("os_workgroup_join failed: \(rc)")
    }
    return JoinToken(storage: storage)
  }

  public func leave(token: JoinToken) {
    __os_workgroup_leave(self, token.storage)
    token.storage.deinitialize(count: 1)
    token.storage.deallocate()
  }

  public func cancel() {
    __os_workgroup_cancel(self)
  }

  public var isCancelled: Bool {
    @_effects(readonly) get { __os_workgroup_testcancel(self) }
  }

  public var maxParallelThreads: Int {
    @_effects(readonly) get { Int(__os_workgroup_max_parallel_threads(self, nil)) }
  }

  public func setWorkingArena(
    arena: UnsafeMutableRawPointer?,
    max_workers: UInt32,
    destruct: @convention(c) (UnsafeMutableRawPointer?) -> Void
  ) {
    let rc = __os_workgroup_set_working_arena(self, arena, max_workers, destruct)
    if rc != 0 {
      fatalError("os_workgroup_set_working_arena failed: \(rc)")
    }
  }

  public typealias Index = UInt32

  public var workingArena: (UnsafeMutableRawPointer?, Index) {
    @_effects(readonly) get {
      var index: Index = 0
      let arena = __os_workgroup_get_working_arena(self, &index)
      return (arena, index)
    }
  }
}

extension WorkGroup: Repeatable {
  @available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
  public func start(at timestamp: UInt64, deadline: UInt64) {
    let rc = __os_workgroup_interval_start(self as! WorkGroupInterval, timestamp, deadline, nil)
    if rc != 0 {
      fatalError("os_workgroup_interval_start failed: \(rc)")
    }
  }

  @available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
  public func updateDeadline(deadline: UInt64) {
    let rc = __os_workgroup_interval_update(self as! WorkGroupInterval, deadline, nil)
    if rc != 0 {
      fatalError("os_workgroup_interval_update failed: \(rc)")
    }
  }

  @available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
  public func finish() {
    let rc = __os_workgroup_interval_finish(self as! WorkGroupInterval, nil)
    if rc != 0 {
      fatalError("os_workgroup_interval_finish failed: \(rc)")
    }
  }
}

extension WorkGroupParallel {
  @available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
  public convenience init?(name: String? = nil) {
    self.init(__name: name, attr: nil)
  }
}
