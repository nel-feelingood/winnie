import Foundation
import Testing
@testable import WinnieCore

@Suite struct NoteFileTests {
    @Test func roundTripsThroughTheFileFormat() {
        let created = Date(timeIntervalSince1970: 1_790_000_000), edited = created.addingTimeInterval(3600)
        let note = Note(title: "Поездка: Батуми", body: "# План\n- билеты\n---\nне шапка", isPinned: true, createdAt: created, updatedAt: edited)
        let parsed = NoteFile.parse(NoteFile.serialize(note), id: note.id)
        // A colon in the title and a `---` rule inside the body must both survive.
        #expect(parsed == note)
    }

    @Test func aFileWithoutAHeaderIsStillANote() {
        let id = UUID()
        let parsed = NoteFile.parse("просто текст\nвторая строка", id: id)
        #expect(parsed.body == "просто текст\nвторая строка" && parsed.title.isEmpty && !parsed.isPinned)
        #expect(parsed.displayTitle == "Без названия")
    }

    @Test func previewDropsMarkdownAndFindsPictures() {
        let note = Note(title: "t", body: "## Итог\n**Мёд** ![шот](images/a1.jpg) и [ссылка](https://x.y)\n![](images/b2.png)")
        #expect(note.preview == "Итог\nМёд 🖼 и ссылка\n🖼")
        #expect(note.imagePaths == ["images/a1.jpg", "images/b2.png"])
        #expect(Note(title: "t", body: "раз\n\n\nдва\n\nтри").preview == "раз\nдва\nтри")
    }
}

@MainActor @Suite struct NoteStoreTests {
    func makeStore() -> NoteStore {
        NoteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("winnie-notes-\(UUID().uuidString)"))
    }

    @Test func persistsAsOneMarkdownFilePerNote() throws {
        let store = makeStore()
        let note = store.create(title: "Идеи", body: "первая")
        let file = store.directory.appendingPathComponent("\(note.id.uuidString.lowercased()).md")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("title: Идеи"))
        #expect(NoteStore(directory: store.directory).notes.map(\.title) == ["Идеи"])
    }

    @Test func pinnedComeFirstThenMostRecentlyEdited() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let old = store.create(title: "старая", now: t0)
        let fresh = store.create(title: "свежая", now: t0.addingTimeInterval(100))
        #expect(store.sorted.map(\.id) == [fresh.id, old.id])
        store.update(old.id, isPinned: true, now: t0.addingTimeInterval(200))
        #expect(store.sorted.map(\.id) == [old.id, fresh.id])
        // Pinning is not an edit.
        #expect(store.notes.first { $0.id == old.id }?.updatedAt == t0)
        store.update(old.id, body: "правка", now: t0.addingTimeInterval(300))
        #expect(store.notes.first { $0.id == old.id }?.updatedAt == t0.addingTimeInterval(300))
    }

    @Test func picturesGoWithTheirNoteButNotIfSharedOrStillUsed() throws {
        let store = makeStore()
        let shared = try #require(store.addImage(Data([1]), fileExtension: "jpg"))
        let own = try #require(store.addImage(Data([2]), fileExtension: "jpg"))
        let first = store.create(title: "a", body: "![](\(shared)) ![](\(own))")
        _ = store.create(title: "b", body: "![](\(shared))")
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(path).path) }

        store.update(first.id, body: "![](\(shared))")      // `own` was removed from the text
        #expect(!exists(own) && exists(shared))
        store.delete(first.id)                              // the other note still shows `shared`
        #expect(exists(shared))
    }
}

@MainActor @Suite struct NoteToolsTests {
    func run(_ tools: NoteTools, _ name: String, _ input: [String: Any]) -> ToolOutcome {
        tools.execute(name: name, input: try! JSONSerialization.data(withJSONObject: input))
    }

    @Test func theBearCanManageNotes() throws {
        let store = NoteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("winnie-notes-\(UUID().uuidString)"))
        let tools = NoteTools(store: store)
        #expect(!run(tools, "create_note", ["title": "Покупки", "body": "- мёд", "pinned": true]).isError)
        let id = try #require(store.notes.first?.shortID)
        #expect(store.notes.first?.isPinned == true)
        #expect(run(tools, "list_notes", [:]).content.contains("id=\(id) | pinned"))

        #expect(!run(tools, "update_note", ["id": "[note:\(id)]", "append": "- шарик"]).isError)
        #expect(store.notes.first?.body == "- мёд\n\n- шарик")
        #expect(run(tools, "read_note", ["id": id]).content.contains("<note_body>\n- мёд"))

        #expect(run(tools, "delete_note", ["id": "deadbeef"]).isError)
        #expect(!run(tools, "delete_note", ["id": id]).isError)
        #expect(store.notes.isEmpty)
        #expect(run(tools, "create_note", ["title": " ", "body": ""]).isError)
    }

    @Test func overwritingAndDeletingAreGuardedButCreatingIsNot() {
        #expect(NoteToolSchema.guardedNames == ["update_note", "delete_note"])
        #expect(Set(NoteToolSchema.definitions.compactMap { $0["name"] as? String }) == NoteToolSchema.names)
        #expect(ClaudeClient.systemPrompt(master: "x").contains("create_note"))
    }
}
