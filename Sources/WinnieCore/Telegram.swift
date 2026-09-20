import Foundation

/// One text message received by the bot.
public struct TelegramMessage: Equatable, Sendable {
    public var updateID: Int
    public var chatID: Int64
    public var senderName: String
    public var text: String
}

public enum TelegramAPI {
    /// Telegram rejects messages over 4096 characters.
    public static let messageLimit = 4000
    /// Long polling: the request simply hangs until a message arrives, so waiting costs nothing.
    public static let pollTimeout = 50

    public static func url(token: String, method: String) -> URL? {
        URL(string: "https://api.telegram.org/bot\(token)/\(method)")
    }

    /// Text messages of a `getUpdates` response, plus the highest update id seen, which
    /// covers non-text updates too, so they are acknowledged rather than re-delivered forever.
    public static func parseUpdates(_ data: Data) -> (messages: [TelegramMessage], lastUpdateID: Int?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true,
              let updates = object["result"] as? [[String: Any]] else { return nil }
        var messages: [TelegramMessage] = []
        var last: Int?
        for update in updates {
            guard let id = update["update_id"] as? Int else { continue }
            last = max(last ?? id, id)
            guard let message = update["message"] as? [String: Any], let text = message["text"] as? String,
                  let chat = message["chat"] as? [String: Any], let chatID = (chat["id"] as? NSNumber)?.int64Value,
                  // Only a private chat with a person: a bot added to a group would otherwise answer everyone in it.
                  chat["type"] as? String == "private" else { continue }
            let sender = message["from"] as? [String: Any]
            let name = (sender?["first_name"] as? String) ?? (sender?["username"] as? String) ?? ""
            messages.append(TelegramMessage(updateID: id, chatID: chatID, senderName: name, text: text))
        }
        return (messages, last)
    }

    /// The bot's @username from a `getMe` response; nil when the token was rejected.
    public static func botUsername(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true,
              let bot = object["result"] as? [String: Any] else { return nil }
        return bot["username"] as? String ?? ""
    }

    public static func errorDescription(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == false else { return nil }
        return object["description"] as? String
    }

    /// Splits a long answer on paragraph, then line, then hard boundaries.
    public static func chunks(of text: String, limit: Int = messageLimit) -> [String] {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var chunks: [String] = []
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.range(of: "\n\n", options: .backwards)?.lowerBound
                ?? window.lastIndex(of: "\n") ?? window.lastIndex(of: " ") ?? window.endIndex
            let end = cut == window.startIndex ? window.endIndex : cut
            chunks.append(String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[end...].drop(while: \.isWhitespace)
        }
        if !rest.isEmpty { chunks.append(String(rest)) }
        return chunks
    }

    /// Six digits the owner sends to the bot to claim it. Anyone can find a bot by its name,
    /// so without this step anyone could talk to an assistant that reads the owner's mail.
    public static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    public static func isPairingAttempt(_ text: String, code: String) -> Bool {
        let digits = text.filter(\.isNumber)
        return !code.isEmpty && digits == code
    }

    /// Added to the prompt for answers that go out through Telegram.
    public static let channelNote = """
        This message came from Серёжа through the Telegram bot, probably from his phone, and your reply is sent \
        there as plain text: no Markdown at all (no **, no #, no tables, no code fences), short paragraphs, \
        plain «- » for lists. Links as bare URLs.
        """
}
