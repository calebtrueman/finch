// SPDX-License-Identifier: MIT OR Apache-2.0
// The block-observer registration swift-foundation's NotificationCenter
// messages use in Foundation.framework (Apple's private
// -_addObserver:object:usingBlock: and its token class). Finch's sits on
// the public block API.

extension NotificationCenter {
    /// An observer registration (the object -addObserverForName:… returns).
    internal typealias _NSNotificationObserverToken = NSObject

    internal func _addObserver(_ name: Notification.Name, object: Any?,
                               using block: @escaping @Sendable (Notification) -> Void) -> _NSNotificationObserverToken {
        addObserver(forName: name, object: object, queue: nil, using: block) as! NSObject
    }

    internal func _removeObserver(_ token: _NSNotificationObserverToken) {
        removeObserver(token)
    }

    /// The center's queue for async message observers, made on first use
    /// (Apple's NSNotificationCenter keeps it in an ivar).
    internal func _getActorQueueManager() -> AnyObject {
        _finchActorQueueManagerLock.lock()
        defer { _finchActorQueueManagerLock.unlock() }
        if let manager = objc_getAssociatedObject(self, &_finchActorQueueManagerKey) {
            return manager as AnyObject
        }
        let manager = _NotificationCenterActorQueueManager()
        objc_setAssociatedObject(self, &_finchActorQueueManagerKey, manager, .OBJC_ASSOCIATION_RETAIN)
        return manager
    }
}

nonisolated(unsafe) private var _finchActorQueueManagerKey: UInt8 = 0
private let _finchActorQueueManagerLock = NSLock()
