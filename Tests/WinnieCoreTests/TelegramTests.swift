import Foundation
import Testing
@testable import WinnieCore

@Suite struct TelegramTests {
    @Test func readsPrivateTextMessagesAndAcknowledgesEverything() throws {
        let data = Data(#"""
        {"ok":true,"result":[
          {"update_id":10,"message":{"message_id":1,"from":{"id":5,"first_name":"Серёжа"},"chat":{"id":5,"type":"private"},"text":"проверь почту"}},
          {"update_id":11,"message":{"message_id":2,"from":{"id":7,"first_name":"Чужой"},"chat":{"id":-100123,"type":"group"},"text":"привет всем"}},
          {"update_id":12,"message":{"message_id":3,"from":{"id":5},"chat":{"id":5,"type":"private"},"photo":[{"file_id":"x"}]}},
          {"update_id":13,"edited_message":{"message_id":1,"chat":{"id":5,"type":"private"},"text":"правка"}}
        ]}
        """#.utf8)
        let parsed = try #require(TelegramAPI.parseUpdates(data))
        #expect(parsed.messages == [TelegramMessage(updateID: 10, chatID: 5, senderName: "Серёжа", text: "проверь почту")])
        // Group chatter, photos and edits are skipped but still acknowledged.
        #expect(parsed.lastUpdateID == 13)
        #expect(TelegramAPI.parseUpdates(Data(#"{"ok":false,"description":"Unauthorized"}"#.utf8)) == nil)
        #expect(TelegramAPI.errorDescription(Data(#"{"ok":false,"description":"Unauthorized"}"#.utf8)) == "Unauthorized")
    }

    @Test func tokenCheckReadsTheBotName() {
        #expect(TelegramAPI.botUsername(Data(#"{"ok":true,"result":{"id":1,"is_bot":true,"username":"winnie_pooh_bot"}}"#.utf8)) == "winnie_pooh_bot")
        #expect(TelegramAPI.botUsername(Data(#"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8)) == nil)
    }

    @Test func largeChatIdentifiersSurvive() throws {
        let data = Data(#"{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":5123456789,"type":"private"},"text":"hi"}}]}"#.utf8)
        #expect(try #require(TelegramAPI.parseUpdates(data)).messages.first?.chatID == 5_123_456_789)
    }

    @Test func pairingNeedsTheExactCode() {
        #expect(TelegramAPI.isPairingAttempt("482913", code: "482913"))
        #expect(TelegramAPI.isPairingAttempt("код 482 913", code: "482913"))
        #expect(!TelegramAPI.isPairingAttempt("482914", code: "482913"))
        #expect(!TelegramAPI.isPairingAttempt("привет", code: "482913"))
        #expect(!TelegramAPI.isPairingAttempt("", code: ""))
        #expect(TelegramAPI.makePairingCode().count == 6)
    }

    @Test func longAnswersAreSplitOnParagraphs() {
        let paragraph = String(repeating: "мёд ", count: 60).trimmingCharacters(in: .whitespaces)
        let text = Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
        let chunks = TelegramAPI.chunks(of: text, limit: 600)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 600 })
        #expect(chunks.joined(separator: "\n\n") == text)
        #expect(TelegramAPI.chunks(of: "  коротко  ") == ["коротко"])
        #expect(TelegramAPI.chunks(of: String(repeating: "я", count: 1500), limit: 600).map(\.count) == [600, 600, 300])
    }

    @Test func telegramRepliesAreAskedToBePlainText() {
        let note = ClaudeClient.volatilePrompt(spoken: false, channelNote: TelegramAPI.channelNote, now: Date())
        #expect(note.contains("no Markdown"))
        #expect(!ClaudeClient.volatilePrompt(spoken: false, now: Date()).contains("Telegram"))
    }
}
