import Combine
import Foundation

/// Winnie's own chats, kept in one JSON file. They are throwaway by design:
/// anything untouched for `retention` is dropped on launch.
@MainActor
public final class ChatStore: ObservableObject {
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    @Published public private(set) var sessions: [ChatSession] = []
    @Published public private(set) var currentID: UUID?

    private let fileURL: URL

    public init(directory: URL, now: Date = Date()) {
        fileURL = directory.appendingPathComponent("chats.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load(now: now)
    }

    public var current: ChatSession? {
        sessions.first { $0.id == currentID }
    }

    /// Every screenshot still attached to some chat; anything else on disk is an orphan.
    public var referencedImageFiles: Set<String> {
        Set(sessions.flatMap { $0.messages.flatMap(\.images) })
    }

    /// Most recently used first.
    public var sortedSessions: [ChatSession] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Sessions

    /// Opens the last used chat, creating one on first run.
    @discardableResult
    public func openLatest() -> ChatSession {
        if let latest = sortedSessions.first {
            currentID = latest.id
            return latest
        }
        return startNew()
    }

    /// Reuses the current chat if nothing was said in it, so pressing "+"
    /// repeatedly does not pile up blank chats.
    @discardableResult
    public func startNew(now: Date = Date()) -> ChatSession {
        if let current, current.isEmpty { return current }
        dropEmptySessions()
        let session = ChatSession(now: now)
        sessions.append(session)
        currentID = session.id
        save()
        return session
    }

    /// A chat that exists beside the one on screen, e.g. the Telegram conversation: created on
    /// demand and never made current, so it does not pull the open chat away from the user.
    @discardableResult
    public func detachedSession(id: UUID, title: String, now: Date = Date()) -> ChatSession {
        if let existing = sessions.first(where: { $0.id == id }) { return existing }
        let session = ChatSession(id: id, title: title, now: now)
        sessions.append(session)
        return session
    }

    public func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        currentID = id
        dropEmptySessions(keeping: id)
    }

    public func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if currentID == id { currentID = sortedSessions.first?.id }
        save()
    }

    public func deleteAll() {
        sessions = []
        currentID = nil
        save()
    }

    public func setTitle(_ title: String, for id: UUID) {
        guard !title.isEmpty else { return }
        mutate(id) { $0.title = title }
        save()
    }

    // MARK: - Messages

    public func append(_ message: ChatMessage, to id: UUID, now: Date = Date()) {
        mutate(id) {
            $0.messages.append(message)
            $0.updatedAt = now
        }
        save()
    }

    /// Streaming updates land here many times per second, so they skip the disk;
    /// call `save()` once the message is final.
    public func update(_ messageID: UUID, in id: UUID, _ change: (inout ChatMessage) -> Void) {
        mutate(id) { session in
            guard let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return }
            change(&session.messages[index])
        }
    }

    public func removeMessage(_ messageID: UUID, from id: UUID) {
        mutate(id) { $0.messages.removeAll { $0.id == messageID } }
        save()
    }

    // MARK: - Persistence

    public func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions.filter { !$0.isEmpty }) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load(now: Date) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? decoder.decode([ChatSession].self, from: data) else { return }
        sessions = stored
            .filter { now.timeIntervalSince($0.updatedAt) < Self.retention }
            .map { session in
                // A reply that was still empty when the app quit mid-answer is just a hole in the chat.
                var session = session
                session.messages.removeAll { $0.role == .assistant && $0.text.isEmpty }
                return session
            }
        if sessions != stored { save() }
    }

    private func mutate(_ id: UUID, _ change: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
    }

    private func dropEmptySessions(keeping kept: UUID? = nil) {
        sessions.removeAll { $0.isEmpty && $0.id != kept }
    }
}
