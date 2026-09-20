import AppKit
import WinnieCore

/// Lets the owner talk to Winnie through a Telegram bot.
///
/// Long polling from the Mac: no server and no webhook, but also no answers while Winnie
/// is not running. Anyone can find a bot by name, and this one can read the owner's mail,
/// so it serves exactly one chat: the one that sent the pairing code shown in Settings.
@MainActor
final class TelegramBridge: ObservableObject {
    enum Status: Equatable {
        case off, connecting, waitingForCode, connected(String), failed(String)
    }

    @Published private(set) var status = Status.off
    @Published private(set) var pairingCode = ""

    /// Produces Winnie's answer to a message from the owner.
    var answer: (String) async -> String = { _ in "" }
    var resetConversation: () -> Void = {}

    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(TelegramAPI.pollTimeout + 15)
        return URLSession(configuration: configuration)
    }()

    var hasToken: Bool { Keychain.has(.telegramBotToken) }

    private var ownerChatID: Int64? {
        get { (defaults.object(forKey: "telegramOwnerChat") as? NSNumber)?.int64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "telegramOwnerChat") }
    }

    private var ownerName: String {
        get { defaults.string(forKey: "telegramOwnerName") ?? "" }
        set { defaults.set(newValue, forKey: "telegramOwnerName") }
    }

    var forwardsReminders: Bool {
        get { defaults.object(forKey: "telegramForwardsReminders") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "telegramForwardsReminders"); objectWillChange.send() }
    }

    // MARK: - Lifecycle

    /// Starts polling if a token is stored. Safe to call again after a token change.
    func start() {
        loop?.cancel()
        guard hasToken else { return status = .off }
        if ownerChatID == nil, pairingCode.isEmpty { pairingCode = TelegramAPI.makePairingCode() }
        status = .connecting
        loop = Task { [weak self] in await self?.poll() }
    }

    func saveToken(_ token: String) {
        Keychain.save(token, for: .telegramBotToken)
        unpair()
    }

    /// Forgets the owner, so the bot has to be claimed again with a fresh code.
    func unpair() {
        ownerChatID = nil
        ownerName = ""
        pairingCode = ""
        start()
    }

    func disconnect() {
        loop?.cancel()
        Keychain.save("", for: .telegramBotToken)
        ownerChatID = nil
        ownerName = ""
        pairingCode = ""
        status = .off
    }

    /// A due reminder, sent to the owner's phone as well.
    func forward(reminder title: String) {
        guard forwardsReminders, let chat = ownerChatID else { return }
        Task { await send("🔔 Напоминаю: \(title)", to: chat) }
    }

    // MARK: - Polling

    private func poll() async {
        let token = Keychain.load(.telegramBotToken)
        guard !token.isEmpty else { return status = .off }
        var offset = defaults.integer(forKey: "telegramOffset")
        var backoff: UInt64 = 2

        while !Task.isCancelled {
            guard var components = TelegramAPI.url(token: token, method: "getUpdates").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            else { return status = .failed("Неверный токен.") }
            components.queryItems = [URLQueryItem(name: "timeout", value: String(TelegramAPI.pollTimeout)),
                                     URLQueryItem(name: "offset", value: String(offset)),
                                     URLQueryItem(name: "allowed_updates", value: #"["message"]"#)]
            do {
                let (data, _) = try await session.data(from: components.url!)
                guard let parsed = TelegramAPI.parseUpdates(data) else {
                    // A rejected token will not fix itself; anything else is worth retrying.
                    let reason = TelegramAPI.errorDescription(data) ?? "неожиданный ответ"
                    status = .failed("Telegram: \(reason)")
                    if reason.lowercased().contains("unauthorized") { return }
                    try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    continue
                }
                backoff = 2
                if case .failed = status { status = .connecting }
                if status == .connecting { status = ownerChatID == nil ? .waitingForCode : .connected(ownerName) }
                if let last = parsed.lastUpdateID {
                    offset = last + 1
                    defaults.set(offset, forKey: "telegramOffset")
                }
                for message in parsed.messages { await handle(message) }
            } catch is CancellationError {
                return
            } catch {
                // Offline, asleep, or a dropped connection: wait a little longer each time, up to a minute.
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func handle(_ message: TelegramMessage) async {
        guard let owner = ownerChatID else {
            if TelegramAPI.isPairingAttempt(message.text, code: pairingCode) {
                ownerChatID = message.chatID
                ownerName = message.senderName
                pairingCode = ""
                status = .connected(message.senderName)
                await send("Готово, теперь я отвечаю только тебе. Пиши как в обычный чат; /new начинает разговор заново.", to: message.chatID)
            } else {
                await send("Я ещё ни к кому не привязан. Пришли код из настроек Winnie на маке (раздел API → Telegram).", to: message.chatID)
            }
            return
        }
        // Strangers get silence: no hint that anything lives here.
        guard message.chatID == owner else { return }

        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "/start" { return await send("Я тут. Спрашивай.", to: owner) }
        if text == "/new" {
            resetConversation()
            return await send("Начали заново.", to: owner)
        }
        await call("sendChatAction", ["chat_id": owner, "action": "typing"])
        let reply = await answer(text)
        await send(reply, to: owner)
    }

    // MARK: - Sending

    private func send(_ text: String, to chat: Int64) async {
        for chunk in TelegramAPI.chunks(of: text) {
            // Plain text, no parse_mode: Telegram rejects a whole message over one unbalanced Markdown character.
            await call("sendMessage", ["chat_id": chat, "text": chunk, "disable_web_page_preview": true])
        }
    }

    private func call(_ method: String, _ body: [String: Any]) async {
        let token = Keychain.load(.telegramBotToken)
        guard let url = TelegramAPI.url(token: token, method: method) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }
}
