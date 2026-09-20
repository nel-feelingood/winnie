import Foundation
import Testing
@testable import WinnieCore

@Suite struct TurnAccumulatorTests {
    @Test func rebuildsTextSearchAndCitations() throws {
        var turn = TurnAccumulator()
        var events: [StreamEvent] = []
        let stream = [
            #"{"type":"message_start","message":{"id":"msg_1"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"swift "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"6.1\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[]}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":"","citations":[]}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://swift.org","title":"Swift"}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Swift "}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"6.1"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":"","citations":[]}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"."}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
            #"{"type":"message_stop"}"#,
        ]
        for line in stream { events += try turn.consume(data: line) }

        #expect(turn.text == "Swift 6.1.")
        #expect(turn.stopReason == "end_turn")
        #expect(turn.sources == [Source(title: "Swift", url: "https://swift.org")])
        #expect(events.contains(.searching(query: "swift 6.1")))
        #expect(events.contains(.textDelta("Swift ")))

        let blocks = turn.contentBlocks
        #expect(blocks.count == 4)
        #expect((blocks[0]["input"] as? [String: Any])?["query"] as? String == "swift 6.1")
        #expect((blocks[2]["citations"] as? [Any])?.count == 1)
        // Empty citation arrays must not be echoed back to the API.
        #expect(blocks[3]["citations"] == nil)
    }

    @Test func errorEventThrows() {
        var turn = TurnAccumulator()
        #expect(throws: ClaudeError.stream(message: "Overloaded")) {
            try turn.consume(data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func ignoresGarbage() throws {
        var turn = TurnAccumulator()
        #expect(try turn.consume(data: "[DONE]").isEmpty)
        #expect(try turn.consume(data: #"{"type":"ping"}"#).isEmpty)
    }
}

@Suite struct RequestTests {
    @Test func opusBodyUsesEffortFallbackAndNewSearch() {
        let body = ClaudeClient.requestBody(model: .opus, messages: [])
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["thinking"] == nil)
        let tool = (body["tools"] as? [[String: Any]])?.first
        #expect(tool?["type"] as? String == "web_search_20260209")
    }

    @Test func systemPromptCarriesMasterTextAndAppConstraints() {
        let custom = ClaudeClient.systemPrompt(master: "Будь краток.")
        #expect(custom.hasPrefix("Будь краток."))
        #expect(custom.contains("360 точек"))
        // A blank prompt must not leave the model without any persona.
        #expect(ClaudeClient.systemPrompt(master: "  \n").hasPrefix(MasterPrompt.standard))
    }

    @Test func haikuBodyOmitsUnsupportedFields() {
        let body = ClaudeClient.requestBody(model: .haiku, messages: [])
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
        let tool = (body["tools"] as? [[String: Any]])?.first
        #expect(tool?["type"] as? String == "web_search_20250305")
    }

    @Test func historySkipsErrorsAndEmptyMessages() {
        let history = [
            ChatMessage(role: .user, text: "hi"),
            ChatMessage(role: .assistant, text: "boom", isError: true),
            ChatMessage(role: .assistant, text: ""),
            ChatMessage(role: .assistant, text: "hello"),
        ]
        let messages = ClaudeClient.apiMessages(from: history)
        #expect(messages.map { $0["content"] as? String } == ["hi", "hello"])
    }

    @Test func screenshotsBecomeImageBlocksBeforeTheText() {
        let history = [
            ChatMessage(role: .user, text: "что это?", imageFiles: ["a.jpg"]),
            ChatMessage(role: .user, text: "", imageFiles: ["b.jpg"]),
            ChatMessage(role: .user, text: "файл пропал", imageFiles: ["missing.jpg"]),
        ]
        let messages = ClaudeClient.apiMessages(from: history) { $0 == "missing.jpg" ? nil : Data([1, 2, 3]) }

        let first = messages[0]["content"] as? [[String: Any]]
        #expect(first?.map { $0["type"] as? String } == ["image", "text"])
        #expect((first?[0]["source"] as? [String: String])?["data"] == "AQID")
        // An image with no caption is still a valid message.
        #expect((messages[1]["content"] as? [[String: Any]])?.count == 1)
        // A lost file degrades to plain text instead of breaking the request.
        #expect(messages[2]["content"] as? String == "файл пропал")
    }

    @Test func oldChatsWithoutAttachmentsStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","text":"hi","sources":[],"isError":false,"date":"2026-09-20T10:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let messages = try decoder.decode([ChatMessage].self, from: Data(json.utf8))
        #expect(messages.first?.images.isEmpty == true)
    }

    @Test func titlesAreTrimmedToThreeWords() {
        #expect(ClaudeClient.cleanTitle("«Перевод слова на английский».\n") == "Перевод слова на")
        #expect(ClaudeClient.cleanTitle("Weather") == "Weather")
    }

    @Test func apiErrorMessageIsExtracted() {
        let data = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        #expect(ClaudeClient.errorMessage(from: data) == "invalid x-api-key")
    }
}

@MainActor @Suite struct ChatStoreTests {
    func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("winnie-tests-\(UUID().uuidString)")
    }

    @Test func newChatIsReusedWhileEmpty() {
        let store = ChatStore(directory: tempDirectory())
        let first = store.startNew()
        let second = store.startNew()
        #expect(first.id == second.id)
        #expect(store.sessions.count == 1)
    }

    @Test func persistsAndReopensLatest() {
        let directory = tempDirectory()
        let store = ChatStore(directory: directory)
        let old = store.startNew(now: Date(timeIntervalSinceNow: -3600))
        store.append(ChatMessage(role: .user, text: "old"), to: old.id, now: Date(timeIntervalSinceNow: -3600))
        let recent = store.startNew()
        store.append(ChatMessage(role: .user, text: "recent"), to: recent.id)

        let reloaded = ChatStore(directory: directory)
        #expect(reloaded.sessions.count == 2)
        #expect(reloaded.openLatest().id == recent.id)
    }

    @Test func expiredChatsArePruned() {
        let directory = tempDirectory()
        let longAgo = Date(timeIntervalSinceNow: -ChatStore.retention - 60)
        let store = ChatStore(directory: directory)
        let stale = store.startNew(now: longAgo)
        store.append(ChatMessage(role: .user, text: "stale"), to: stale.id, now: longAgo)

        #expect(ChatStore(directory: directory).sessions.isEmpty)
    }

    @Test func unfinishedRepliesAreDroppedOnLoad() {
        let directory = tempDirectory()
        let store = ChatStore(directory: directory)
        let session = store.startNew()
        store.append(ChatMessage(role: .user, text: "hi"), to: session.id)
        store.append(ChatMessage(role: .assistant, text: ""), to: session.id)

        #expect(ChatStore(directory: directory).sessions.first?.messages.map(\.text) == ["hi"])
    }

    @Test func emptyChatsAreNotSaved() {
        let directory = tempDirectory()
        ChatStore(directory: directory).startNew()
        #expect(ChatStore(directory: directory).sessions.isEmpty)
    }

    @Test func deletingCurrentFallsBackToLatest() {
        let store = ChatStore(directory: tempDirectory())
        let a = store.startNew()
        store.append(ChatMessage(role: .user, text: "a"), to: a.id)
        let b = store.startNew()
        store.append(ChatMessage(role: .user, text: "b"), to: b.id)
        store.delete(b.id)
        #expect(store.currentID == a.id)
    }
}

@Suite struct PetMoodTests {
    @Test func priorityOrder() {
        var mood = PetMood()
        #expect(mood.state == .idle)
        mood.isAsleep = true
        #expect(mood.state == .sleep)
        mood.isHovering = true
        #expect(mood.state == .hover)
        mood.activity = .thinking
        #expect(mood.state == .thinking)
        mood.activity = .error
        #expect(mood.state == .error)
        mood.isDragging = true
        #expect(mood.state == .drag)
    }
}

@Suite struct LinkExtractorTests {
    @Test func findsMarkdownAndBareLinksInOrderWithoutDuplicates() {
        let text = """
        Смотри [документацию](https://swift.org/docs) и https://www.example.com/a/b.
        Ещё раз: https://swift.org/docs, а также (https://apple.com).
        """
        #expect(LinkExtractor.links(in: text) == [
            Source(title: "документацию", url: "https://swift.org/docs"),
            Source(title: "example.com/a/b", url: "https://www.example.com/a/b"),
            Source(title: "apple.com", url: "https://apple.com"),
        ])
    }

    @Test func ignoresTextWithoutLinksAndHalfStreamedOnes() {
        #expect(LinkExtractor.links(in: "Просто текст, http без схемы и [скобки](").isEmpty)
    }

    @Test func citedSourcesComeFirstAndAreNotRepeated() {
        let message = ChatMessage(role: .assistant, text: "См. https://a.com и https://b.com",
                                  sources: [Source(title: "B", url: "https://b.com")])
        #expect(LinkExtractor.allLinks(for: message).map(\.url) == ["https://b.com", "https://a.com"])
    }
}
