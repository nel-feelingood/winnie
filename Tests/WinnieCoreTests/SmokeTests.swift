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
