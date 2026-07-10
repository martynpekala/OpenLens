import Foundation

/// A bounded todo projection shared by REST and SSE updates. The server can
/// send an arbitrary-length list, while the chat chrome needs only a compact,
/// immediately renderable snapshot.
nonisolated struct TodoDisplaySnapshot: Sendable {
    let todos: [OCTodo]
    let hiddenCount: Int
}

nonisolated enum TodoDisplaySafety {
    static let maximumTodoCount = 48
    static let maximumContentBytes = 360
    static let maximumStatusBytes = 64
    static let maximumPriorityBytes = 64

    static func prepare(_ todos: [OCTodo]) -> TodoDisplaySnapshot {
        let visibleTodos = todos.prefix(maximumTodoCount)
        var result: [OCTodo] = []
        result.reserveCapacity(visibleTodos.count)

        for (index, todo) in visibleTodos.enumerated() {
            let content = StreamDisplayValue.preview(todo.content, maximumBytes: maximumContentBytes)
            let status = StreamDisplayValue.preview(todo.status, maximumBytes: maximumStatusBytes)
            let priority = StreamDisplayValue.preview(todo.priority, maximumBytes: maximumPriorityBytes)
            let stablePrefix = StreamDisplayValue.preview(todo.id, maximumBytes: 80)
            let id = "todo-\(index)-\(stablePrefix)"

            result.append(
                OCTodo(
                    id: id,
                    content: content,
                    status: status,
                    priority: priority
                )
            )
        }

        return TodoDisplaySnapshot(
            todos: result,
            hiddenCount: max(0, todos.count - result.count)
        )
    }
}
