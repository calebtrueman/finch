// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The task modifiers `View.task` uses from macOS 26.4, to Apple's interface: a task started
// as the view appears and cancelled as it disappears (and, for the value variant, restarted
// when the value changes), named, on the preferred executor, with the action's isolation.
// They work as upstream's earlier _TaskModifier and _TaskValueModifier do.

import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly)
import SwiftUICore

@available(OpenSwiftUI_v7_0, *)
public struct _TaskModifier2: ViewModifier {
    var name: String
    var taskExecutor: (any TaskExecutor)?
    var priority: TaskPriority
    var action: @isolated(any) () async -> Void

    @usableFromInline
    nonisolated init(name: String, executorPreference taskExecutor: (any TaskExecutor)?, priority: TaskPriority,
         action: sending @escaping @isolated(any) () async -> Void) {
        self.name = name
        self.taskExecutor = taskExecutor
        self.priority = priority
        self.action = action
    }

    nonisolated public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        Child.Value._makeView(modifier: _GraphValue(Child(modifier: modifier.value)), inputs: inputs, body: body)
    }

    nonisolated public static func _makeViewList(
        modifier: _GraphValue<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        Child.Value._makeViewList(modifier: _GraphValue(Child(modifier: modifier.value)), inputs: inputs, body: body)
    }

    nonisolated public static func _viewListCount(
        inputs: _ViewListCountInputs,
        body: (_ViewListCountInputs) -> Int?
    ) -> Int? {
        Child.Value._viewListCount(inputs: inputs, body: body)
    }

    func start() -> Task<Void, Never> {
        Task(name: name, executorPreference: taskExecutor, priority: priority, operation: action)
    }

    private struct Child: Rule, AsyncAttribute {
        @Attribute var modifier: _TaskModifier2

        var value: InnerModifier { InnerModifier(base: modifier) }
    }

    private struct InnerModifier: ViewModifier {
        var base: _TaskModifier2
        @State private var task: Task<Void, Never>?

        func body(content: Content) -> some View {
            content.modifier(_AppearanceActionModifier(
                appear: {
                    guard task == nil else { return }
                    task = base.start()
                },
                disappear: {
                    task?.cancel()
                    task = nil
                }
            ))
        }
    }
}

@available(*, unavailable)
extension _TaskModifier2: Sendable {}

@available(OpenSwiftUI_v7_0, *)
public struct _TaskValueModifier2<ID>: ViewModifier where ID: Equatable {
    var id: ID
    var base: _TaskModifier2

    @usableFromInline
    nonisolated init(id: ID, name: String, executorPreference taskExecutor: (any TaskExecutor)?, priority: TaskPriority,
         action: sending @escaping @isolated(any) () async -> Void) {
        self.id = id
        self.base = _TaskModifier2(name: name, executorPreference: taskExecutor, priority: priority, action: action)
    }

    nonisolated public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        Child.Value._makeView(modifier: _GraphValue(Child(modifier: modifier.value)), inputs: inputs, body: body)
    }

    nonisolated public static func _makeViewList(
        modifier: _GraphValue<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_Graph, _ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        Child.Value._makeViewList(modifier: _GraphValue(Child(modifier: modifier.value)), inputs: inputs, body: body)
    }

    nonisolated public static func _viewListCount(
        inputs: _ViewListCountInputs,
        body: (_ViewListCountInputs) -> Int?
    ) -> Int? {
        Child.Value._viewListCount(inputs: inputs, body: body)
    }

    private struct Child: Rule, AsyncAttribute {
        @Attribute var modifier: _TaskValueModifier2<ID>

        var value: InnerModifier { InnerModifier(modifier: modifier) }
    }

    private struct InnerModifier: ViewModifier {
        var modifier: _TaskValueModifier2<ID>

        struct TaskState {
            var task: Task<Void, Never>
            var id: ID
        }

        @State private var taskState: TaskState?

        func body(content: Content) -> some View {
            content.modifier(_AppearanceActionModifier(
                appear: {
                    guard taskState == nil else { return }
                    taskState = TaskState(task: modifier.base.start(), id: modifier.id)
                },
                disappear: {
                    taskState?.task.cancel()
                    taskState = nil
                }
            ))
            .onChange(of: modifier.id) {
                guard let taskState, taskState.id != modifier.id else { return }
                taskState.task.cancel()
                self.taskState = TaskState(task: modifier.base.start(), id: modifier.id)
            }
        }
    }
}

@available(*, unavailable)
extension _TaskValueModifier2: Sendable {}

@available(OpenSwiftUI_v7_0, *)
extension View {
    nonisolated public func task(name: String? = nil, executorPreference taskExecutor: any TaskExecutor,
                                 priority: TaskPriority = .userInitiated, file: String = #fileID, line: Int = #line,
                                 @_inheritActorContext action: sending @escaping @isolated(any) () async -> Void) -> some View {
        modifier(_TaskModifier2(name: name ?? "View.task @ \(file):\(line)", executorPreference: taskExecutor,
                                priority: priority, action: action))
    }

    nonisolated public func task<T>(id: T, name: String? = nil, executorPreference taskExecutor: any TaskExecutor,
                                    priority: TaskPriority = .userInitiated, file: String = #fileID, line: Int = #line,
                                    @_inheritActorContext _ action: sending @escaping @isolated(any) () async -> Void) -> some View
        where T: Equatable {
        modifier(_TaskValueModifier2(id: id, name: name ?? "View.task @ \(file):\(line)", executorPreference: taskExecutor,
                                     priority: priority, action: action))
    }
}
