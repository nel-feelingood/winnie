import Foundation

public struct ClaudeClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// A search-heavy turn can hit the server's iteration cap and come back as
    /// `pause_turn`; resume it a bounded number of times.
    static let maxResumes = 3

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Request building

    /// The user's master prompt followed by the constraints that come from the app
    /// itself (popover width, search, today's date) and are not the user's to maintain.
    static func systemPrompt(master: String, now: Date = Date()) -> String {
        let date = now.formatted(.iso8601.year().month().day())
        let persona = master.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(persona.isEmpty ? MasterPrompt.standard : persona)

        ---
        Технические условия окна чата. Оно узкое, около 360 точек в ширину: пиши в Markdown, но \
        без заголовков и без широких таблиц; короткий список или пара строк кода — нормально. У \
        тебя есть веб-поиск: пользуйся им, когда вопрос зависит от актуальных или редких \
        сведений, и не трать его на то, что и так хорошо знаешь. Сегодня \(date).
        """
    }

    /// Loads the JPEG bytes of an attached screenshot by file name.
    public typealias ImageLoader = @Sendable (String) -> Data?

    /// Completed turns are replayed as plain text. Search results are large and
    /// would be re-billed as input on every later turn of a throwaway chat.
    /// Screenshots are replayed, since follow-up questions are usually about them.
    static func apiMessages(from history: [ChatMessage], imageLoader: ImageLoader = { _ in nil }) -> [[String: Any]] {
        history
            .filter { !$0.isError && !($0.text.isEmpty && $0.images.isEmpty) }
            .map { message in
                let images: [[String: Any]] = message.images.compactMap(imageLoader).map {
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
                }
                guard !images.isEmpty else { return ["role": message.role.rawValue, "content": message.text] }
                // Images go before the question, which is the order the model handles best.
                let text: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
                return ["role": message.role.rawValue, "content": images + text]
            }
    }

    static func requestBody(model: ModelOption, master: String = MasterPrompt.standard,
                            messages: [[String: Any]], now: Date = Date()) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 32000,
            "stream": true,
            "system": systemPrompt(master: master, now: now),
            "messages": messages,
            "tools": [["type": model.webSearchToolType, "name": "web_search", "max_uses": 5]],
        ]
        if model.supportsEffort {
            // Quick lookups: keep thinking shallow so the first token arrives fast.
            body["output_config"] = ["effort": "low"]
        }
        if model.usesDefaultFallback {
            body["fallbacks"] = "default"
        }
        return body
    }

    static func urlRequest(apiKey: String, body: [String: Any], betas: [String] = []) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Chat

    public func streamReply(apiKey: String, model: ModelOption, masterPrompt: String, history: [ChatMessage],
                            imageLoader: @escaping ImageLoader = { _ in nil })
        -> AsyncThrowingStream<StreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
                    var messages = Self.apiMessages(from: history, imageLoader: imageLoader)
                    for _ in 0...Self.maxResumes {
                        let turn = try await runTurn(apiKey: apiKey, model: model, master: masterPrompt, messages: messages) {
                            continuation.yield($0)
                        }
                        switch turn.stopReason {
                        case "pause_turn":
                            // No "continue" message: the API sees the trailing
                            // server_tool_use block and resumes on its own.
                            messages.append(["role": "assistant", "content": turn.contentBlocks])
                            continue
                        case "refusal":
                            throw ClaudeError.refusal
                        case "max_tokens":
                            throw ClaudeError.truncated
                        default:
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runTurn(apiKey: String, model: ModelOption, master: String, messages: [[String: Any]],
                         emit: (StreamEvent) -> Void) async throws -> TurnAccumulator
    {
        let body = Self.requestBody(model: model, master: master, messages: messages)
        let betas = model.usesDefaultFallback ? ["server-side-fallback-2026-07-01"] : []
        let request = try Self.urlRequest(apiKey: apiKey, body: body, betas: betas)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw ClaudeError.http(status: status, message: Self.errorMessage(from: raw))
        }

        var turn = TurnAccumulator()
        // Every Anthropic SSE payload is a single-line JSON object carrying its own
        // "type", so the `event:` lines and blank separators can be ignored.
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            for event in try turn.consume(data: payload) { emit(event) }
        }
        return turn
    }

    static func errorMessage(from data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        return error?["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Titles

    /// Names a chat in one to three words. Runs on the small model: it is a
    /// background nicety and must not slow down or add cost to the real answer.
    public func makeTitle(apiKey: String, firstUserMessage: String) async throws -> String {
        let body: [String: Any] = [
            "model": ModelOption.haiku.rawValue,
            "max_tokens": 40,
            "system": """
            Name the chat that starts with the user's message. Reply with the title only: \
            one to three words, in the language of the message, no quotes, no trailing punctuation.
            """,
            "messages": [["role": "user", "content": String(firstUserMessage.prefix(2000))]],
        ]
        let request = try Self.urlRequest(apiKey: apiKey, body: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClaudeError.http(status: status, message: Self.errorMessage(from: data))
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blocks = object?["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        return Self.cleanTitle(text)
    }

    static func cleanTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«».!"))
        return trimmed.split(separator: " ").prefix(3).joined(separator: " ")
    }
}
