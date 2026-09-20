import Foundation
import Testing
@testable import WinnieCore

@Suite struct TaskListTests {
    let body = """
    ## План
    вступление

    - [x] перекур в 16:20
    - [ ] прогулка **по экрану**
      - [ ] вложенная
    1. [ ] нумерованная

    ```
    - [ ] это код, не чекбокс
    ```
    - обычный пункт
    """

    @Test func splitsTasksFromTheRestAndSkipsCode() {
        let segments = TaskList.segments(of: body)
        #expect(segments == [
            .markdown(id: 0, text: "## План\nвступление\n"),
            .task(line: 3, indent: 0, isDone: true, text: "перекур в 16:20"),
            .task(line: 4, indent: 0, isDone: false, text: "прогулка **по экрану**"),
            .task(line: 5, indent: 1, isDone: false, text: "вложенная"),
            .task(line: 6, indent: 0, isDone: false, text: "нумерованная"),
            .markdown(id: 7, text: "\n```\n- [ ] это код, не чекбокс\n```\n- обычный пункт"),
        ])
    }

    @Test func togglesExactlyOneLine() {
        let once = TaskList.toggling(line: 4, in: body)
        #expect(once.components(separatedBy: "\n")[4] == "- [x] прогулка **по экрану**")
        // Everything else is byte-for-byte the same, and toggling back restores the original.
        #expect(once.components(separatedBy: "\n").enumerated().allSatisfy { $0.offset == 4 || $0.element == body.components(separatedBy: "\n")[$0.offset] })
        #expect(TaskList.toggling(line: 4, in: once) == body)
        #expect(TaskList.toggling(line: 3, in: body).contains("- [ ] перекур"))
    }

    @Test func refusesLinesThatAreNotTasks() {
        #expect(TaskList.toggling(line: 0, in: body) == body)      // a heading
        #expect(TaskList.toggling(line: 9, in: body) == body)      // inside the code block: same text, but untouched
        #expect(TaskList.toggling(line: 99, in: body) == body)
        #expect(TaskList.segments(of: "").isEmpty)
    }
}
