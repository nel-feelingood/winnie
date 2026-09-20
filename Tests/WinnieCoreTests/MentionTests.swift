import Foundation
import Testing
@testable import WinnieCore

@Suite struct MentionTests {
    @Test func referencesBecomeTitledLinks() {
        let text = "Записал: [note:1A2B3C4D]. Напомню: [event:9f8e7d6c]. А это [не ссылка]."
        let linked = Mentions.linkified(text) { target in
            target == Mentions.Target(kind: .note, id: "1a2b3c4d") ? "Поездка [в] Батуми" : nil
        }
        // Brackets in a title would break the Markdown link; a missing object stays visible as such.
        #expect(linked == "Записал: [📝 Поездка (в) Батуми](winnie://note/1a2b3c4d). Напомню: ~~🔔 удалено~~. А это [не ссылка].")
    }

    @Test func linksResolveBackToTheirObject() {
        let target = Mentions.Target(kind: .event, id: "9f8e7d6c")
        #expect(Mentions.target(of: target.url) == target)
        #expect(Mentions.target(of: URL(string: "https://example.com/note/1")!) == nil)
        #expect(Mentions.target(of: URL(string: "winnie://chat/1")!) == nil)
    }

    @Test func atSignStartsAQueryOnlyWhereItShould() {
        #expect(Mentions.trailingQuery(in: "сделай саммари @") == "")
        #expect(Mentions.trailingQuery(in: "сделай саммари @Бат") == "Бат")
        #expect(Mentions.trailingQuery(in: "@поездка в") == "поездка в")
        #expect(Mentions.trailingQuery(in: "напиши на lev@example.com") == nil)      // an address, not a mention
        #expect(Mentions.trailingQuery(in: "без собачки") == nil)
        #expect(Mentions.trailingQuery(in: "@раз\nдва") == nil)
    }

    @Test func choosingAnObjectReplacesTheQuery() {
        let target = Mentions.Target(kind: .note, id: "1a2b3c4d")
        #expect(Mentions.completing("сделай саммари @Бат", with: target) == "сделай саммари [note:1a2b3c4d] ")
        #expect(Mentions.completing("без собачки", with: target) == "без собачки")
    }

    @MainActor @Test func remindersAcceptAWrappedReference() {
        let store = ReminderStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("winnie-m-\(UUID().uuidString)"))
        for _ in 0..<60 {
            let reminder = Reminder(title: "x", fireAt: Date().addingTimeInterval(3600))
            store.add(reminder)
            #expect(store.reminder(matching: "[event:\(reminder.shortID)]")?.id == reminder.id)
            #expect(store.reminder(matching: reminder.shortID)?.id == reminder.id)
        }
    }
}
