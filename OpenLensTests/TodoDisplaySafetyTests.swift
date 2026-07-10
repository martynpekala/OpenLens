import Testing
@testable import OpenLens

struct TodoDisplaySafetyTests {

    @Test func boundsTodoCountAndAllRenderedStrings() {
        let oversized = String(repeating: "untrusted todo ", count: 200)
        let todos = (0..<(TodoDisplaySafety.maximumTodoCount + 9)).map { index in
            OCTodo(
                id: "todo-\(index)-\(oversized)",
                content: oversized,
                status: oversized,
                priority: oversized
            )
        }

        let snapshot = TodoDisplaySafety.prepare(todos)

        #expect(snapshot.todos.count == TodoDisplaySafety.maximumTodoCount)
        #expect(snapshot.hiddenCount == 9)
        #expect(snapshot.todos.allSatisfy {
            $0.content.utf8.count <= TodoDisplaySafety.maximumContentBytes
                && $0.status.utf8.count <= TodoDisplaySafety.maximumStatusBytes
                && ($0.priority?.utf8.count ?? 0) <= TodoDisplaySafety.maximumPriorityBytes
        })
        #expect(Set(snapshot.todos.map(\.id)).count == snapshot.todos.count)
    }
}
