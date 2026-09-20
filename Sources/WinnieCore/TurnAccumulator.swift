import Foundation

public enum StreamEvent: Equatable, Sendable {
    case textDelta(String)
    /// The model started a web search; the query is known once the block closes.
    case searching(query: String?)
    case sources([Source])
}

public enum ClaudeError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case stream(message: String)
    case refusal
    case truncated

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Не задан API-ключ. Добавь его в меню Винни → «Настройки…»."
        case .http(401, _):
            "API-ключ не подошёл. Проверь его в меню Винни → «Настройки…»."
        case .http(429, _):
            "Слишком много запросов. Подожди немного и повтори."
        case .http(529, _), .http(503, _):
            "Серверы Claude перегружены. Попробуй ещё раз через минуту."
        case .http(let status, let message):
            "Ошибка API (\(status)): \(message)"
        case .stream(let message):
            "Ошибка во время ответа: \(message)"
        case .refusal:
            "Модель отказалась отвечать на этот запрос."
        case .truncated:
            "Ответ оборвался: достигнут лимит длины."
        }
    }
}

/// Rebuilds one assistant turn from SSE `data:` payloads.
///
/// Raw HTTP streaming has no `finalMessage()` helper, and resuming a
/// `pause_turn` requires echoing the assistant content blocks back verbatim,
/// so the blocks are reassembled here from their deltas.
public struct TurnAccumulator {
    public private(set) var stopReason: String?
    public private(set) var text = ""
    public private(set) var sources: [Source] = []

    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]

    public init() {}

    /// Content blocks in order, ready to be sent back as an assistant message.
    public var contentBlocks: [[String: Any]] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }

    public mutating func consume(data: String) throws -> [StreamEvent] {
        guard let raw = data.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let type = event["type"] as? String
        else { return [] }

        switch type {
        case "content_block_start":
            guard let index = event["index"] as? Int,
                  let block = event["content_block"] as? [String: Any] else { return [] }
            blocks[index] = block
            if block["type"] as? String == "server_tool_use",
               block["name"] as? String == "web_search" {
                return [.searching(query: nil)]
            }
            return []

        case "content_block_delta":
            guard let index = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return [] }
            return applyDelta(deltaType, delta, at: index)

        case "content_block_stop":
            guard let index = event["index"] as? Int else { return [] }
            return closeBlock(at: index)

        case "message_delta":
            if let delta = event["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            return []

        case "error":
            let error = event["error"] as? [String: Any]
            throw ClaudeError.stream(message: error?["message"] as? String ?? "unknown")

        default:
            return []
        }
    }

    private mutating func applyDelta(_ type: String, _ delta: [String: Any], at index: Int) -> [StreamEvent] {
        switch type {
        case "text_delta":
            let piece = delta["text"] as? String ?? ""
            append(piece, to: "text", at: index)
            text += piece
            return piece.isEmpty ? [] : [.textDelta(piece)]

        case "thinking_delta":
            append(delta["thinking"] as? String ?? "", to: "thinking", at: index)
            return []

        case "signature_delta":
            blocks[index]?["signature"] = delta["signature"]
            return []

        case "input_json_delta":
            partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            return []

        case "citations_delta":
            guard let citation = delta["citation"] as? [String: Any] else { return [] }
            var citations = blocks[index]?["citations"] as? [[String: Any]] ?? []
            citations.append(citation)
            blocks[index]?["citations"] = citations
            guard let url = citation["url"] as? String,
                  !sources.contains(where: { $0.url == url }) else { return [] }
            sources.append(Source(title: citation["title"] as? String ?? url, url: url))
            return [.sources(sources)]

        default:
            return []
        }
    }

    private mutating func closeBlock(at index: Int) -> [StreamEvent] {
        // An empty `citations` array is what the stream opens with, but the API
        // does not accept it on the way back in.
        if let citations = blocks[index]?["citations"] as? [Any], citations.isEmpty {
            blocks[index]?.removeValue(forKey: "citations")
        }
        guard let json = partialJSON.removeValue(forKey: index) else { return [] }
        let input = (json.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        blocks[index]?["input"] = input
        if blocks[index]?["name"] as? String == "web_search", let query = input["query"] as? String {
            return [.searching(query: query)]
        }
        return []
    }

    private mutating func append(_ piece: String, to key: String, at index: Int) {
        let current = blocks[index]?[key] as? String ?? ""
        blocks[index]?[key] = current + piece
    }
}
