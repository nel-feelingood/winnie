import Foundation

public struct Source: Codable, Hashable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: UUID
    public var role: Role
    public var text: String
    public var sources: [Source]
    /// Error bubbles are shown in the chat but never sent back to the model.
    public var isError: Bool
    public var date: Date
    /// File names of attached screenshots. Optional so chats saved before
    /// attachments existed still decode.
    public var imageFiles: [String]?

    public var images: [String] { imageFiles ?? [] }

    public init(id: UUID = UUID(), role: Role, text: String, sources: [Source] = [],
                isError: Bool = false, date: Date = Date(), imageFiles: [String]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.isError = isError
        self.date = date
        self.imageFiles = imageFiles
    }
}

public struct ChatSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]

    public init(id: UUID = UUID(), title: String? = nil, now: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = now
        self.updatedAt = now
        self.messages = []
    }

    public var isEmpty: Bool { messages.isEmpty }
}

/// Models offered in the menu. Request shape differs per model family, so the
/// differences live here rather than being scattered through the client.
public enum ModelOption: String, CaseIterable, Codable, Sendable {
    case opus = "claude-opus-5"
    case sonnet = "claude-sonnet-5"
    case haiku = "claude-haiku-4-5"

    public var displayName: String {
        switch self {
        case .opus: "Claude Opus 5"
        case .sonnet: "Claude Sonnet 5"
        case .haiku: "Claude Haiku 4.5"
        }
    }

    /// Haiku 4.5 rejects `output_config.effort`.
    var supportsEffort: Bool { self != .haiku }

    /// The dynamic-filtering search variant needs Opus/Sonnet; Haiku keeps the basic one.
    var webSearchToolType: String {
        self == .haiku ? "web_search_20250305" : "web_search_20260209"
    }

    /// Server-side refusal fallback is an Opus 5 feature.
    var usesDefaultFallback: Bool { self == .opus }
}
