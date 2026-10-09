// SPDX-License-Identifier: MIT OR Apache-2.0
// The QuartzCore overlay: CAFrameRateRange's Swift initializer and
// equality, and CATransform3D's bridging to NSValue, with the declarations
// of Apple's overlay (macOS 26.4 SDK). Finch's code.

@_exported import QuartzCore
import Foundation

@available(macOS 12.0, iOS 15.0, tvOS 15.0, visionOS 1.0, *)
extension CAFrameRateRange {
  /// A preferred rate of zero means none.
  public init(minimum: Float, maximum: Float, preferred: Float? = nil) {
    self.init()
    self.minimum = minimum
    self.maximum = maximum
    self.__preferred = preferred ?? 0
  }

  public var preferred: Float? {
    get { __preferred == 0 ? nil : __preferred }
    set(rate) { __preferred = rate ?? 0 }
  }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, visionOS 1.0, *)
extension CAFrameRateRange: Equatable {
  public static func == (lhs: CAFrameRateRange, rhs: CAFrameRateRange) -> Bool {
    return lhs.minimum == rhs.minimum && lhs.maximum == rhs.maximum
      && lhs.__preferred == rhs.__preferred
  }
}

@available(macOS 10.9, iOS 7.0, tvOS 9.0, visionOS 1.0, *)
extension CATransform3D: _ObjectiveCBridgeable {
  public func _bridgeToObjectiveC() -> NSValue {
    return NSValue(caTransform3D: self)
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSValue, result: inout CATransform3D?) {
    result = source.caTransform3DValue
  }

  public static func _conditionallyBridgeFromObjectiveC(
    _ source: NSValue, result: inout CATransform3D?
  ) -> Bool {
    _forceBridgeFromObjectiveC(source, result: &result)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSValue?) -> CATransform3D {
    var result: CATransform3D?
    _forceBridgeFromObjectiveC(source!, result: &result)
    return result!
  }
}
