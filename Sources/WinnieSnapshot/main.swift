import AppKit
import SwiftUI
@testable import WinnieApp
import WinnieCore

/// Off-screen and unfocusable: a snapshot must never take the keyboard from whatever the
/// user is typing into at that moment.
final class InertWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Renders the real ChatPanel + ChatView with sample data into a PNG, without touching
// the user's chats. Usage: swift run WinnieSnapshot <out.png> [chat|events]

let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "winnie-chat.png")
let mode = arguments.count > 2 ? arguments[2] : "chat"
let wantsEvents = mode == "events"
let mailDigest = """
### 🔴 Ждут ответа или действия
- 💼 **Марк Мартыненко** — макеты онбординга: ждёт твоих правок до среды
- ✈️ **Лёва** — поездка в Батуми: нужно подтвердить даты

### 👤 От людей
- **Аня** — прислала фото с дачи, отвечать не обязательно

### 📦 Остальное
- 📰 рассылки — 4 (Хабр, Medium, Figma)
- 🧾 чеки — 2 (Яндекс Go, Wolt)
- 🔐 вход в аккаунт Google с нового устройства — это был ты

Всего 10 непрочитанных, внимания просят два. Остальное подождёт, пока мы подкрепимся.
"""

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // `editor-test`: drives the real note editor the way the keyboard does, and prints what happened.
    if mode == "editor-test" {
        func editor(_ text: String) -> SlashTextView {
            let view = SlashTextView(usingTextLayoutManager: false)
            view.frame = NSRect(x: 0, y: 0, width: 340, height: 400)
            view.layoutManager?.delegate = view
            view.isRichText = false
            view.string = text
            view.restyle()
            return view
        }
        func check(_ name: String, _ got: String, _ expected: String) {
            print(got == expected ? "PASS" : "FAIL", name, got == expected ? "" : "— got «\(got)», expected «\(expected)»")
        }
        var view = editor("a **b** c")
        view.setSelectedRange(NSRange(location: 4, length: 0))          // just after the opening «**»
        view.deleteBackward(nil)
        check("backspace after opening ** removes both marks", view.string, "a b c")

        view = editor("a **b** c")
        view.setSelectedRange(NSRange(location: 7, length: 0))          // just after the closing «**»
        view.deleteBackward(nil)
        check("backspace after closing ** removes both marks", view.string, "a b c")

        view = editor("## Заголовок")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.deleteBackward(nil)
        check("backspace at the start of a heading makes it plain", view.string, "Заголовок")

        view = editor("обычный текст")
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.deleteBackward(nil)
        check("plain text still deletes one character", view.string, "обычны текст")

        view = editor("a **b** c")
        view.setSelectedRange(NSRange(location: 2, length: 0)); view.caretMoved()
        view.setSelectedRange(NSRange(location: 3, length: 0)); view.caretMoved()      // → lands inside «**»
        check("moving right skips the hidden mark", String(view.selectedRange().location), "4")
        view.setSelectedRange(NSRange(location: 3, length: 0)); view.caretMoved()      // ← lands inside again
        check("moving left skips it the other way", String(view.selectedRange().location), "2")
        exit(0)
    }

    let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("winnie-snapshot-\(UUID().uuidString)")
    let store = ChatStore(directory: sandbox)
    let reminders = ReminderStore(directory: sandbox)
    let session = store.startNew()
    store.setTitle("Мини-дайджест: мэрия Тбилиси и длинный хвост", for: session.id)
    if mode == "empty" { store.startNew() }
    if mode == "mail" {
        store.append(ChatMessage(role: .user, text: "Проверь почту"), to: session.id)
        store.append(ChatMessage(role: .assistant, text: mailDigest), to: session.id)
    }
    if mode != "mail", mode != "empty" { store.append(ChatMessage(role: .user, text: "Привет, как слышно?"), to: session.id) }
    if mode != "mail", mode != "empty" { store.append(ChatMessage(role: .assistant, text: "Слышно хорошо, Серёжа. Сижу тут в опилках, **урчу** потихоньку.\n\n- мёд\n- ещё мёд",
                             sources: [Source(title: "Винни-Пух — Википедия", url: "https://ru.wikipedia.org/wiki/Винни-Пух")]),
                 to: session.id) }
    reminders.add(Reminder(title: "Ответить Лёве по поводу поездки", label: "Ответ Лёве", fireAt: Date().addingTimeInterval(3 * 3600)))
    reminders.add(Reminder(title: "Зарядка", fireAt: Date().addingTimeInterval(86_400), repeats: .weekdays))

    let noteStore = NoteStore(directory: sandbox.appendingPathComponent("Notes"))
    let picture = NSImage(contentsOfFile: NSHomeDirectory() + "/Library/Application Support/Winnie/Sprites/hover.png")
        .flatMap(NoteImages.jpeg(from:)).flatMap { noteStore.addImage($0, fileExtension: "jpg") } ?? "images/none.jpg"
    noteStore.create(title: "Идеи для Винни", body: "# Заголовок первого уровня\n\n## Второго уровня\n\n**Жирный текст** и *курсивный текст*, ~~зачёркнутый~~ и `код`, см. [сайт](https://example.com).\n\n```python\ndef hello():\n    return True\n```\n\n> Цитата или выделение текста\n> может быть многострочной\n\n- Маркированный список\n- Второй пункт\n  - Вложенный пункт\n\n1. Нумерованный список\n2. Второй пункт\n\n- [x] перекур в 16:20\n- [ ] прогулка по экрану\n\n---\n\n![](\(picture))\nтекст после картинки")
    let trip = noteStore.create(title: "Поездка в Батуми", body: "Билеты на пятницу, отель у моря. Спросить Лёву про даты и про то, берём ли палатку. Забронировать машину. Проверить паспорт. Купить зарядку.")
    noteStore.update(trip.id, isPinned: true)
    noteStore.create(title: "", body: "просто мысль без заголовка")
    let controller = ChatController(store: store, reminders: reminders, memory: MemoryStore(directory: sandbox), notes: noteStore, usage: UsageStore(directory: sandbox),
                                    mcp: MCPAuth(), gmail: GmailAuth(),
                                    settings: AppSettings())
    if wantsEvents { controller.tab = .events }
    if mode == "mention" {
        let note = noteStore.sorted[0]
        store.append(ChatMessage(role: .user, text: "сделай саммари [note:\(note.shortID)] и напомни"), to: session.id)
        store.append(ChatMessage(role: .assistant, text: "Готово, записал: [note:\(note.shortID)]. А этой уже нет: [note:deadbeef]."), to: session.id)
        controller.draft = "добавь в @"
    }
    if mode == "notes" { controller.tab = .notes }
    if mode == "note" { controller.tab = .notes; controller.openNoteID = noteStore.sorted.last { !$0.title.isEmpty }?.id }
    if mode.hasPrefix("settings-"), let pane = SettingsPane(rawValue: String(mode.dropFirst(9))) {
        let usage = UsageStore(directory: sandbox)
        usage.record(UsageSample(model: "claude-haiku-4-5", input: 48_200, output: 6_100, searches: 4))
        usage.record(UsageSample(model: "claude-opus-5", input: 210_000, output: 31_000, searches: 9), at: Date().addingTimeInterval(-3 * 86_400))
        let memory = MemoryStore(directory: sandbox)
        memory.add("Лёва — брат Серёжи")
        let actions = SettingsActions(onShortcutChange: { _ in }, onNewVoiceShortcutChange: { _ in }, onVoicePreview: {})
        let navigation = SettingsNavigation()
        navigation.pane = pane
        let view = SettingsView(settings: AppSettings(), gmail: GmailAuth(), memory: memory, usage: usage, mcp: MCPAuth(), telegram: TelegramBridge(), actions: actions,
                                navigation: navigation)
        let window = InertWindow(contentRect: NSRect(x: -3000, y: -3000, width: 720, height: 560), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output)
            try? FileManager.default.removeItem(at: sandbox)
            print("wrote \(output.path)")
            exit(0)
        }
        app.run()
    }
    // A note is long: a tall window shows all of it in one picture.
    let snapshotSize = mode == "note" ? NSSize(width: 380, height: 1000) : ChatPanel.chatSize
    let panel = InertWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: snapshotSize),
                            styleMask: [.borderless], backing: .buffered, defer: false)
    panel.backgroundColor = .textBackgroundColor
    // In the app the panel paints the background; here the view has to, or a dark-mode
    // snapshot comes out as light text on nothing.
    panel.contentView = NSHostingView(rootView: ChatView(controller: controller, store: store, pendingDeletion: mode == "confirm" ? .all : nil)
        .background(Color(nsColor: .textBackgroundColor)))
    panel.orderFrontRegardless()

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output)
        try? FileManager.default.removeItem(at: sandbox)
        print("wrote \(output.path)")
        exit(0)
    }
    app.run()
}
