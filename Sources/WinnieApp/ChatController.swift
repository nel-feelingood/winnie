import AppKit
import WinnieCore

/// Drives one chat turn: sends the history, streams the reply into the store,
/// and reports what the pet should be doing meanwhile.
enum ChatTab: Hashable { case chat, events, notes }

@MainActor
final class ChatController: ObservableObject {
    @Published var tab = ChatTab.chat
    /// The note whose page is open in the Notes tab; nil shows the list.
    @Published var openNoteID: UUID?
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var searchStatus: String?
    @Published private(set) var toast: String?
    /// Bumped whenever the input field should grab focus.
    @Published private(set) var focusToken = 0
    /// Screenshots waiting to go out with the next message.
    @Published private(set) var pendingImages: [String] = []
    @Published private(set) var isListening = false

    let store: ChatStore
    let reminders: ReminderStore
    let memory: MemoryStore
    let notes: NoteStore
    let usage: UsageStore
    let mcp: MCPAuth
    let gmail: GmailAuth
    let settings: AppSettings
    var onActivity: (ChatActivity) -> Void = { _ in }
    /// The window layer owns hiding the chat during a capture and bringing it back.
    var onCaptureRequest: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onSmokeBreak: () -> Void = {}
    var onOpenQuickActionSettings: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private let client = ClaudeClient()
    private var streamTask: Task<Void, Never>?
    private let listener = SpeechListener()
    private let speaker: Speaker

    /// MarkdownUI re-parses the whole message on every change, so deltas are
    /// flushed to the UI at most this often instead of per token.
    private static let flushInterval: Duration = .milliseconds(60)

    init(store: ChatStore, reminders: ReminderStore, memory: MemoryStore, notes: NoteStore, usage: UsageStore, mcp: MCPAuth,
         gmail: GmailAuth, settings: AppSettings) {
        self.store = store
        self.reminders = reminders
        self.memory = memory
        self.notes = notes
        self.usage = usage
        self.mcp = mcp
        self.speaker = Speaker(settings: settings)
        self.gmail = gmail
        self.settings = settings

        renameGenericReminderChats()
        listener.onTranscript = { [weak self] in self?.draft = $0 }
        listener.onFinished = { [weak self] in self?.finishListening(heard: $0) }
        listener.onFailure = { [weak self] failure in
            self?.isListening = false
            self?.onActivity(.none)
            self?.show(toast: failure.errorDescription ?? "Микрофон недоступен")
        }
        speaker.onFinished = { [weak self] in
            // The spoken answer outlasts the text stream; the pet talks until the voice stops.
            if self?.isStreaming == false { self?.onActivity(.none) }
        }
    }

    // MARK: - Mentions

    struct MentionCandidate: Identifiable {
        let target: Mentions.Target
        let title: String
        let detail: String
        var id: String { target.token }
    }

    /// Objects picked from the «@» popup for the message being written: shown by name in the field,
    /// turned into references when it is sent.
    private var draftMentions: [(display: String, target: Mentions.Target)] = []

    /// Bumped when the highlighted row of the «@» popup should move; the view owns the index.
    @Published var mentionSelection = 0

    func title(of target: Mentions.Target) -> String? {
        switch target.kind {
        case .note: notes.note(matching: target.id)?.displayTitle
        case .event: reminders.reminder(matching: target.id)?.title
        }
    }

    /// What the «@» popup offers for the query being typed; empty when no «@» is in progress.
    var mentionCandidates: [MentionCandidate] {
        guard let query = Mentions.trailingQuery(in: draft)?.lowercased() else { return [] }
        // «@Поездка в Батуми» already chosen is not a new query.
        if draftMentions.contains(where: { ("@" + query).hasPrefix($0.display.lowercased()) }) { return [] }
        let noteItems = notes.sorted.map {
            MentionCandidate(target: .init(kind: .note, id: $0.shortID), title: $0.displayTitle, detail: "заметка")
        }
        let now = Date()
        let eventItems = reminders.sorted(now: now).filter { $0.nextFire(after: now) != nil }.map {
            MentionCandidate(target: .init(kind: .event, id: $0.shortID), title: $0.title, detail: "событие · " + EventTime.describe($0, now: now))
        }
        let all = noteItems + eventItems
        return Array((query.isEmpty ? all : all.filter { $0.title.lowercased().contains(query) }).prefix(6))
    }

    func complete(_ candidate: MentionCandidate) {
        let display = Mentions.display(for: candidate.title)
        draftMentions.append((display, candidate.target))
        draft = Mentions.completing(draft, display: display)
        mentionSelection = 0
        focusInput()
    }

    /// A click on a reference anywhere in the chat.
    func open(_ target: Mentions.Target) {
        switch target.kind {
        case .note:
            guard let note = notes.note(matching: target.id) else { return show(toast: "Этой заметки уже нет") }
            openNoteID = note.id
            tab = .notes
        case .event:
            tab = .events
        }
    }

    // MARK: - Notes

    func newNote() {
        tab = .notes
        openNoteID = notes.create().id
    }

    /// A fresh chat that points at the note. The reference travels as text, so it is plain to
    /// see what was sent, and the bear fetches the note itself with read_note.
    func startChat(about note: Note) {
        newChat()
        let display = Mentions.display(for: note.displayTitle)
        draftMentions = [(display, Mentions.Target(kind: .note, id: note.shortID))]
        draft = display + " "
        focusInput()
    }

    // MARK: - Reminders

    /// Reminder chats used to share one title; name the existing ones after what they remind about.
    private func renameGenericReminderChats() {
        let prefix = "Напоминаю: **"
        for session in store.sessions where session.title == "Напоминание" {
            guard let text = session.messages.first?.text, text.hasPrefix(prefix) else { continue }
            let subject = text.dropFirst(prefix.count).replacingOccurrences(of: "**", with: "")
            store.setTitle(Reminder.shortened(subject), for: session.id)
        }
    }

    /// A due reminder, said by Winnie in a chat of its own. Written locally rather than by
    /// the model: it must work offline and cost nothing. Being an ordinary assistant
    /// message, it is context for a follow-up like «отложи на час».
    func present(_ reminder: Reminder) {
        discardPendingImages()
        let session = store.startNew()
        store.setTitle(reminder.chatTitle, for: session.id)
        store.append(ChatMessage(role: .assistant, text: "Напоминаю: **\(reminder.title)**"), to: session.id)
        tab = .chat
        onActivity(.talking)
        if settings.speaksReminders { speaker.speak("Напоминаю: \(reminder.title)") }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if !isStreaming, !speaker.isSpeaking { onActivity(.none) }
        }
    }

    // MARK: - Voice

    /// Mic button and voice shortcut: start listening, or finish early and send.
    func toggleListening() {
        if isListening { return listener.finish() }
        guard !isStreaming else { return }
        tab = .chat
        speaker.stop()
        draft = ""
        isListening = true
        onActivity(.listening)
        listener.start()
    }

    private func finishListening(heard text: String) {
        isListening = false
        guard !text.isEmpty else { return onActivity(.none) }
        draft = text
        send(spoken: true)
    }

    /// The "Прослушать" button in Settings.
    func previewVoice() {
        speaker.stop()
        speaker.speak("Привет, Серёжа! Это я, Винни. Вот так я буду с тобой разговаривать. Кажется, пора немного подкрепиться.")
    }

    /// Closing the chat is the "be quiet" gesture.
    func silence() {
        listener.cancel()
        speaker.stop()
    }

    func focusInput() { focusToken += 1 }

    /// Hides the chat; Winnie stays on screen.
    func minimize() { onMinimize() }

    var canSend: Bool {
        !isStreaming && !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty)
    }

    // MARK: - Screenshots

    func requestCapture() { onCaptureRequest() }

    func attach(_ file: String) {
        pendingImages.append(file)
        focusInput()
    }

    func removePending(_ file: String) {
        pendingImages.removeAll { $0 == file }
        ImageStore.delete(file)
    }

    func notify(_ message: String) { show(toast: message) }

    private func discardPendingImages() {
        pendingImages.forEach(ImageStore.delete)
        pendingImages = []
    }

    // MARK: - Sessions

    func newChat() {
        tab = .chat
        stop()
        discardPendingImages()
        store.startNew()
        draft = ""
        draftMentions = []
        focusInput()
    }

    func select(_ id: UUID) {
        stop()
        discardPendingImages()
        store.select(id)
        focusInput()
    }

    func deleteCurrent() {
        guard let id = store.currentID else { return }
        stop()
        store.delete(id)
        ImageStore.removeOrphans(keeping: store.referencedImageFiles.union(pendingImages))
        if store.current == nil { store.startNew() }
    }

    func deleteAllChats() {
        stop()
        discardPendingImages()
        store.deleteAll()
        ImageStore.removeOrphans(keeping: [])
        store.startNew()
        focusInput()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        speaker.stop()
    }

    func openQuickActionSettings() { onOpenQuickActionSettings() }

    func openSettings() { onOpenSettings() }

    /// Either sends the text as a message, or puts it in the field for the user to finish.
    func run(_ action: QuickAction) {
        guard !isStreaming, !isListening else { return }
        let text = action.message
        if action.sendsImmediately {
            draft = text
            send()
        } else {
            draft = text + " "
            focusInput()
        }
    }

    /// Non-empty quick actions, shown only while the current chat has no messages.
    var visibleQuickActions: [QuickAction] {
        guard store.current?.isEmpty ?? true, !isStreaming else { return [] }
        return settings.quickActions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func send(spoken: Bool = false) {
        guard canSend else { return }
        speaker.stop()
        let text = Mentions.expanding(draft, mentions: draftMentions).trimmingCharacters(in: .whitespacesAndNewlines)
        draftMentions = []
        let images = pendingImages
        let session = store.current ?? store.startNew()
        draft = ""
        pendingImages = []

        store.append(ChatMessage(role: .user, text: text, imageFiles: images.isEmpty ? nil : images),
                     to: session.id)
        let history = store.current?.messages ?? []
        let reply = ChatMessage(role: .assistant, text: "")
        store.append(reply, to: session.id)

        let apiKey = Keychain.loadAPIKey()
        // A stored key that could not be read is a different problem from a missing one.
        let keyProblem: ClaudeError? = apiKey.isEmpty && Keychain.hasAPIKey
            ? .keychainUnavailable(code: Int(Keychain.lastFailure ?? 0)) : nil
        if session.title == nil {
            if text.isEmpty {
                store.setTitle("Скриншот", for: session.id)
            } else {
                requestTitle(for: session.id, firstMessage: text, apiKey: apiKey)
            }
        }

        isStreaming = true
        onActivity(.thinking)
        streamTask = Task { [weak self] in
            await self?.stream(into: reply.id, sessionID: session.id, history: history, apiKey: apiKey,
                               spoken: spoken, keyProblem: keyProblem)
        }
    }

    private func stream(into replyID: UUID, sessionID: UUID, history: [ChatMessage], apiKey: String,
                        spoken: Bool, keyProblem: ClaudeError?) async {
        let speaks = spoken && settings.speaksReplies
        var unspoken = ""
        var pending = ""
        var lastFlush = ContinuousClock.now
        var failure: Error?

        func flush() {
            guard !pending.isEmpty else { return }
            let chunk = pending
            pending = ""
            store.update(replyID, in: sessionID) { $0.text += chunk }
            lastFlush = .now
        }

        do {
            if let keyProblem { throw keyProblem }
            for try await event in await replyEvents(apiKey: apiKey, history: history, spoken: speaks) {
                switch event {
                case .textDelta(let piece):
                    if searchStatus != nil { searchStatus = nil }
                    onActivity(.talking)
                    pending += piece
                    if speaks {
                        // Speak sentence by sentence, so the voice starts before the answer ends.
                        unspoken += piece
                        SpeechText.popSentences(from: &unspoken).forEach(speaker.speak)
                    }
                    if ContinuousClock.now - lastFlush >= Self.flushInterval { flush() }
                case .searching(let query):
                    searchStatus = query.map { "Ищу: \($0)" } ?? "Ищу в интернете…"
                    onActivity(.thinking)
                case .toolUse(let name):
                    searchStatus = Self.status(forTool: name)
                    onActivity(.thinking)
                case .usage(let sample):
                    usage.record(sample)
                case .sources(let sources):
                    store.update(replyID, in: sessionID) { $0.sources = sources }
                }
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            failure = error
        }
        flush()
        let tail = SpeechText.clean(unspoken)
        if speaks, failure == nil, !tail.isEmpty { speaker.speak(tail) }

        searchStatus = nil
        isStreaming = false
        streamTask = nil

        let isEmpty = store.sessions.first { $0.id == sessionID }?
            .messages.first { $0.id == replyID }?.text.isEmpty ?? true
        if let failure {
            if isEmpty { store.removeMessage(replyID, from: sessionID) }
            let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
            store.append(ChatMessage(role: .assistant, text: message, isError: true), to: sessionID)
            onActivity(.error)
            try? await Task.sleep(for: .seconds(4))
            if !isStreaming { onActivity(.none) }
        } else {
            if isEmpty { store.removeMessage(replyID, from: sessionID) }
            store.save()
            if !speaker.isSpeaking { onActivity(.none) }
        }
    }

    /// One answer from the model with every tool Winnie has. The chat and the Telegram bridge
    /// both go through here, so they cannot drift apart in what Winnie is able to do.
    private func replyEvents(apiKey: String, history: [ChatMessage], spoken: Bool, channelNote: String = "")
        async -> AsyncThrowingStream<StreamEvent, Error>
    {
        // Resolved per answer: an expired OAuth token is refreshed here, before the request needs it.
        let apps = await mcp.servers(for: settings.connectors)
        let apis = settings.resolvedAPIs
        return client.streamReply(
            apiKey: apiKey, model: settings.model, masterPrompt: settings.masterPrompt, history: history, spoken: spoken,
            imageLoader: { ImageStore.data(for: $0) },
            toolHandler: { [reminders, memory, notes, settings, smokeBreak = onSmokeBreak, mail = MailTools(client: gmail.client),
                            custom = CustomAPITools(apis: apis)] name, input in
                if name == CustomAPIToolSchema.name { return await custom.execute(input: input) }
                if MailToolSchema.names.contains(name) { return await mail.execute(name: name, input: input) }
                if EnvironmentToolSchema.names.contains(name) {
                    return await MainActor.run {
                        EnvironmentTools(settings: settings, reminders: reminders, onSmokeBreak: smokeBreak).execute(name: name, input: input)
                    }
                }
                if MemoryToolSchema.names.contains(name) {
                    return await MainActor.run { MemoryTools(store: memory).execute(name: name, input: input) }
                }
                if NoteToolSchema.names.contains(name) {
                    return await MainActor.run { NoteTools(store: notes).execute(name: name, input: input) }
                }
                return await MainActor.run { ReminderTools(store: reminders).execute(name: name, input: input) }
            },
            offersMail: gmail.isConnected, memory: memory.notes, apps: apps, apis: apis.map(\.api), channelNote: channelNote)
    }

    // MARK: - Telegram

    /// Stable id of the chat that mirrors the Telegram conversation.
    private static let telegramSessionID = UUID(uuidString: "7E1E6A00-0000-4000-8000-00000000B0B0")!
    /// Older turns are dropped from what is sent: a phone conversation can run for weeks.
    private static let telegramHistoryLimit = 24

    /// Answers a message that arrived through the bot. It lives in its own chat, beside
    /// whatever is open on screen, and never touches the UI state of the visible chat.
    func answerTelegram(_ text: String) async -> String {
        let sessionID = Self.telegramSessionID
        store.detachedSession(id: sessionID, title: "Telegram")
        store.append(ChatMessage(role: .user, text: text), to: sessionID)
        let history = Array((store.sessions.first { $0.id == sessionID }?.messages ?? []).suffix(Self.telegramHistoryLimit))

        let apiKey = Keychain.loadAPIKey()
        var answer = ""
        var sources: [Source] = []
        do {
            if apiKey.isEmpty { throw Keychain.hasAPIKey ? ClaudeError.keychainUnavailable(code: Int(Keychain.lastFailure ?? 0)) : ClaudeError.missingAPIKey }
            for try await event in await replyEvents(apiKey: apiKey, history: history, spoken: false, channelNote: TelegramAPI.channelNote) {
                switch event {
                case .textDelta(let piece): answer += piece
                case .usage(let sample): usage.record(sample)
                case .sources(let found): sources = found
                case .searching, .toolUse: break
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            store.append(ChatMessage(role: .assistant, text: message, isError: true), to: sessionID)
            return message
        }
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return "…" }
        store.append(ChatMessage(role: .assistant, text: answer, sources: sources), to: sessionID)
        // Telegram shows no source list of its own, so the links travel with the text.
        let links = sources.prefix(3).map(\.url).joined(separator: "\n")
        return links.isEmpty ? answer : answer + "\n\n" + links
    }

    /// Wipes the Telegram conversation's context («/new» in the bot).
    func resetTelegramChat() {
        store.delete(Self.telegramSessionID)
    }

    private static func status(forTool name: String) -> String {
        if name.hasPrefix("app:") { return "Спрашиваю \(name.dropFirst(4))…" }
        switch name {
        case "call_api": return "Обращаюсь к API…"
        case "list_notes", "read_note": return "Смотрю заметки…"
        case "create_note", "update_note", "delete_note": return "Правлю заметки…"
        case "get_settings": return "Смотрю настройки…"
        case "update_settings", "add_quick_action", "remove_quick_action", "move_quick_action": return "Меняю настройки…"
        case "delete_all_reminders": return "Удаляю события…"
        case "play_smoke_break": return "16:20…"
        case "list_emails": return "Смотрю почту…"
        case "read_email": return "Читаю письмо…"
        case "list_reminders": return "Смотрю напоминания…"
        case "remember": return "Запоминаю…"
        case "forget": return "Забываю…"
        default: return "Записываю напоминание…"
        }
    }

    private func requestTitle(for sessionID: UUID, firstMessage: String, apiKey: String) {
        guard !apiKey.isEmpty else { return }
        Task { [client, weak store, weak usage] in
            guard let result = try? await client.makeTitle(apiKey: apiKey, firstUserMessage: firstMessage)
            else { return }
            store?.setTitle(result.title, for: sessionID)
            usage?.record(result.usage)
        }
    }

    // MARK: - Toast

    private func show(toast message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == message { toast = nil }
        }
    }
}
