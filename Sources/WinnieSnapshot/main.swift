import AppKit
import SwiftUI
@testable import WinnieApp
import WinnieCore

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

    let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("winnie-snapshot-\(UUID().uuidString)")
    let store = ChatStore(directory: sandbox)
    let reminders = ReminderStore(directory: sandbox)
    let session = store.startNew()
    store.setTitle("Мини-дайджест: мэрия Тбилиси и длинный хвост", for: session.id)
    if mode == "mail" {
        store.append(ChatMessage(role: .user, text: "Проверь почту"), to: session.id)
        store.append(ChatMessage(role: .assistant, text: mailDigest), to: session.id)
    }
    if mode != "mail" { store.append(ChatMessage(role: .user, text: "Привет, как слышно?"), to: session.id) }
    if mode != "mail" { store.append(ChatMessage(role: .assistant, text: "Слышно хорошо, Серёжа. Сижу тут в опилках, **урчу** потихоньку.\n\n- мёд\n- ещё мёд",
                             sources: [Source(title: "Винни-Пух — Википедия", url: "https://ru.wikipedia.org/wiki/Винни-Пух")]),
                 to: session.id) }
    reminders.add(Reminder(title: "Ответить Лёве по поводу поездки", label: "Ответ Лёве", fireAt: Date().addingTimeInterval(3 * 3600)))
    reminders.add(Reminder(title: "Зарядка", fireAt: Date().addingTimeInterval(86_400), repeats: .weekdays))

    let controller = ChatController(store: store, reminders: reminders, memory: MemoryStore(directory: sandbox), gmail: GmailAuth(),
                                    settings: AppSettings())
    if wantsEvents { controller.tab = .events }
    let panel = ChatPanel(content: ChatView(controller: controller, store: store))
    panel.setFrame(NSRect(origin: NSPoint(x: -2000, y: -2000), size: ChatPanel.chatSize), display: true)
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
