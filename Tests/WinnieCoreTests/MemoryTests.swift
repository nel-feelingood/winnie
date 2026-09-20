import Foundation
import Testing
@testable import WinnieCore

@MainActor @Suite struct MemoryTests {
    func makeStore() -> (MemoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winnie-mem-\(UUID().uuidString)")
        return (MemoryStore(directory: directory), directory)
    }

    func run(_ tools: MemoryTools, _ name: String, _ input: [String: Any]) -> ToolOutcome {
        tools.execute(name: name, input: try! JSONSerialization.data(withJSONObject: input))
    }

    @Test func remembersPersistsAndForgets() throws {
        let (store, directory) = makeStore()
        let tools = MemoryTools(store: store)
        #expect(!run(tools, "remember", ["text": "  Лёва — брат Серёжи  "]).isError)
        #expect(MemoryStore(directory: directory).notes.map(\.text) == ["Лёва — брат Серёжи"])

        let id = try #require(store.notes.first?.shortID)
        #expect(run(tools, "forget", ["id": "zzzzzz"]).isError)
        #expect(!run(tools, "forget", ["id": id]).isError)
        #expect(MemoryStore(directory: directory).notes.isEmpty)
    }

    @Test func refusesEmptyNotesAndStopsWhenFull() {
        let (store, _) = makeStore()
        let tools = MemoryTools(store: store)
        #expect(run(tools, "remember", ["text": "   "]).isError)
        for index in 0..<MemoryStore.maxNotes { store.add("заметка \(index)") }
        #expect(run(tools, "remember", ["text": "лишняя"]).isError)
        #expect(store.notes.count == MemoryStore.maxNotes)
    }

    @Test func overlongNotesAreCut() {
        let (store, _) = makeStore()
        store.add(String(repeating: "я", count: 1000))
        #expect(store.notes.first?.text.count == MemoryStore.maxLength)
    }

    @Test func notesAppearInThePromptWithTheirIDs() {
        let note = MemoryNote(text: "Отвечать без смайликов")
        let prompt = ClaudeClient.systemPrompt(master: "Мой промпт.", memory: [note])
        #expect(prompt.contains("- [\(note.shortID)] Отвечать без смайликов"))
        // The user's own text stays first and untouched.
        #expect(prompt.hasPrefix("Мой промпт."))
        #expect(ClaudeClient.systemPrompt(master: "x").contains("Пока ничего."))
    }

    @Test func memoryToolsAreOfferedAlongsideReminders() {
        let names = Set(ReminderToolSchema.definitions.compactMap { $0["name"] as? String })
            .union(MemoryToolSchema.definitions.compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: ["remember", "forget", "create_reminder"]))
    }

    @Test func webAndMailActivityCountsAsUntrusted() {
        #expect(ClaudeClient.isUntrustedSource(["type": "server_tool_use", "name": "web_search"]))
        #expect(ClaudeClient.isUntrustedSource(["type": "web_search_tool_result"]))
        #expect(!ClaudeClient.isUntrustedSource(["type": "text", "text": "привет"]))
        #expect(!ClaudeClient.isUntrustedSource(["type": "tool_use", "name": "remember"]))
        #expect(MemoryToolSchema.blockedOutcome.isError)
    }
}
