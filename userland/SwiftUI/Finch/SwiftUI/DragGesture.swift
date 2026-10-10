// SPDX-License-Identifier: MIT OR Apache-2.0
//
// DragGesture, to Apple's interface: the pointer's moves from where it went down, in a
// coordinate space, active once it has moved the minimum distance, ended when it goes up.
// Its value carries the start and current locations, and a predicted end from the latest
// velocity (as Apple's: the velocity is four times the predicted remaining distance).

public import Foundation
import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

@available(OpenSwiftUI_v1_0, *)
public struct DragGesture: Gesture, PrimitiveGesture {
    public struct Value: Equatable, Sendable {
        public var time: Date
        public var location: CGPoint
        public var startLocation: CGPoint
        var velocityPerSecond: CGSize = .zero

        public var translation: CGSize {
            CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
        }

        public var predictedEndLocation: CGPoint {
            CGPoint(x: location.x + velocityPerSecond.width / 4, y: location.y + velocityPerSecond.height / 4)
        }

        public var predictedEndTranslation: CGSize {
            let end = predictedEndLocation
            return CGSize(width: end.x - startLocation.x, height: end.y - startLocation.y)
        }

        public static func == (a: Value, b: Value) -> Bool {
            a.time == b.time && a.location == b.location && a.startLocation == b.startLocation
                && a.velocityPerSecond == b.velocityPerSecond
        }
    }

    public var minimumDistance: CGFloat
    public var coordinateSpace: CoordinateSpace

    @_disfavoredOverload
    public init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) {
        self.minimumDistance = minimumDistance
        self.coordinateSpace = coordinateSpace
    }

    public init(minimumDistance: CGFloat = 10, coordinateSpace: some CoordinateSpaceProtocol = .local) {
        self.init(minimumDistance: minimumDistance, coordinateSpace: coordinateSpace.coordinateSpace)
    }

    /// A drag so far: where it started, the last move, and whether it has gone far enough.
    private struct DragState: GestureStateProtocol {
        var start: CGPoint?
        var last: (location: CGPoint, time: Double)?
        var velocity: CGSize = .zero
        var active = false

        init() {}

        mutating func value(for event: SpatialEvent) -> Value {
            let start = start ?? event.location
            self.start = start
            let now = event.timestamp.seconds
            if let last, now > last.time {
                velocity = CGSize(width: (event.location.x - last.location.x) / (now - last.time),
                                  height: (event.location.y - last.location.y) / (now - last.time))
            }
            last = (event.location, now)
            return Value(time: Date(), location: event.location, startLocation: start, velocityPerSecond: velocity)
        }
    }

    private struct Child: Rule {
        @Attribute var gesture: DragGesture

        var value: some Gesture<Value> {
            let minimumDistance = gesture.minimumDistance
            return DragState.gesture(content: EventListener<SpatialEvent>().coordinateSpace(gesture.coordinateSpace)) { state, phase in
                switch phase {
                case let .possible(event):
                    guard let event else { return .possible(nil) }
                    let value = state.value(for: event)
                    if minimumDistance <= 0 {
                        state.active = true
                        return .active(value)
                    }
                    return .possible(value)
                case let .active(event):
                    let value = state.value(for: event)
                    if !state.active, hypot(value.translation.width, value.translation.height) >= minimumDistance {
                        state.active = true
                    }
                    return state.active ? .active(value) : .possible(value)
                case let .ended(event):
                    let value = state.value(for: event)
                    return state.active ? .ended(value) : .failed
                case .failed:
                    return .failed
                }
            }
        }
    }

    nonisolated public static func _makeGesture(gesture: _GraphValue<DragGesture>, inputs: _GestureInputs) -> _GestureOutputs<Value> {
        let child = Attribute(Child(gesture: gesture.value))
        return Child.Value.makeDebuggableGesture(gesture: _GraphValue(child), inputs: inputs)
    }

    public typealias Body = Never
}

@available(*, unavailable) extension DragGesture: Sendable {}

// MARK: - LongPressGesture

/// A press held for a minimum time without moving more than a distance: it ends (true) as the
/// time is reached, as Apple's does, and fails if the pointer goes up first or moves too far.
@available(OpenSwiftUI_v1_0, *)
public struct LongPressGesture: Gesture, PrimitiveGesture {
    public var minimumDuration: Double
    var _maximumDistance: CGFloat

    public var maximumDistance: CGFloat {
        get { _maximumDistance }
        set { _maximumDistance = newValue }
    }

    public init(minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10) {
        self.minimumDuration = minimumDuration
        self._maximumDistance = maximumDistance
    }

    /// When the press began (the event's time: the graph's time doesn't move between events
    /// that nothing was drawn between).
    private struct PressState: GestureStateProtocol {
        var start: Double?
        init() {}
    }

    private struct Child: Rule {
        @Attribute var gesture: LongPressGesture

        var value: some Gesture<Bool> {
            let minimum = gesture.minimumDuration
            let pressed = EventListener<SpatialEvent>()
                .gated(by: DistanceGesture(maximumDistance: gesture.maximumDistance).coordinateSpace(.global))
            return PressState.gesture(content: pressed) { state, phase in
                func held(_ event: SpatialEvent) -> Bool {
                    let now = event.timestamp.seconds
                    let start = state.start ?? now
                    state.start = start
                    return now - start >= minimum
                }
                return switch phase {
                case let .possible(event):
                    event.map { _ = held($0); return .possible(false) } ?? .possible(nil)
                // held long enough: it ends there; or, if the time passed with no event, as it's let go
                case let .active(event): held(event) ? .ended(true) : .possible(false)
                case let .ended(event): held(event) ? .ended(true) : .failed
                case .failed: .failed
                }
            }
        }
    }

    nonisolated public static func _makeGesture(gesture: _GraphValue<LongPressGesture>, inputs: _GestureInputs) -> _GestureOutputs<Bool> {
        let child = Attribute(Child(gesture: gesture.value))
        return Child.Value.makeDebuggableGesture(gesture: _GraphValue(child), inputs: inputs)
    }

    public typealias Value = Bool
    public typealias Body = Never
}

@available(*, unavailable) extension LongPressGesture: Sendable {}

@available(OpenSwiftUI_v1_0, *)
extension View {
    /// (pressing isn't told yet.)
    @_disfavoredOverload
    nonisolated public func onLongPressGesture(minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10,
                                               pressing: ((Bool) -> Void)? = nil,
                                               perform action: @escaping () -> Void) -> some View {
        gesture(LongPressGesture(minimumDuration: minimumDuration, maximumDistance: maximumDistance).onEnded { _ in action() })
    }

    @_alwaysEmitIntoClient
    nonisolated public func onLongPressGesture(minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10,
                                               perform action: @escaping () -> Void,
                                               onPressingChanged: ((Bool) -> Void)? = nil) -> some View {
        onLongPressGesture(minimumDuration: minimumDuration, maximumDistance: maximumDistance,
                           pressing: onPressingChanged, perform: action)
    }
}
