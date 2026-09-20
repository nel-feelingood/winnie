import AppKit
import Carbon.HIToolbox
import WinnieCore

struct Shortcut: Codable, Equatable {
    /// Same keys, whatever the display string says.
    func collides(with other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, ...).
    var modifiers: UInt32
    /// Human-readable form captured when the shortcut was recorded.
    var display: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_Space),
                                    modifiers: UInt32(controlKey | optionKey),
                                    display: "⌃⌥Space")
    static let defaultNewVoice = Shortcut(keyCode: UInt32(kVK_ANSI_E),
                                          modifiers: UInt32(cmdKey | shiftKey),
                                          display: "⇧⌘E")
}

/// A one-tap prompt offered in an empty chat.
struct QuickAction: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The short label on the button. (Named `text` in storage since before instructions existed.)
    var text: String
    /// What is actually sent: the full instruction, written to make sense on its own.
    /// Optional so buttons saved earlier still decode; empty means "send the label".
    var instruction: String?
    /// Off for prompts that need finishing, like «Переведи»: the text lands in the field instead.
    var sendsImmediately = true

    var message: String {
        let full = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return full.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : full
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var model: ModelOption {
        didSet { defaults.set(model.rawValue, forKey: "model") }
    }
    @Published var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") }
    }

    /// Pet size multiplier, applied live while the slider moves.
    @Published var petScale: Double {
        didSet { defaults.set(petScale, forKey: "petScale") }
    }
    static let petScaleRange = 0.5...2.5

    /// Only a customised prompt is stored. While the user keeps the standard text,
    /// improvements to it in later builds reach them automatically.
    @Published var masterPrompt: String {
        didSet {
            let isStandard = masterPrompt == MasterPrompt.standard
            defaults.set(isStandard ? nil : masterPrompt, forKey: "masterPrompt")
        }
    }

    /// Starts a fresh dialog with the microphone already on.
    @Published var newVoiceShortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(newVoiceShortcut), forKey: "newVoiceShortcut") }
    }
    /// Read answers aloud when the question was asked by voice.
    @Published var speaksReplies: Bool {
        didSet { defaults.set(speaksReplies, forKey: "speaksReplies") }
    }

    /// Identifier of the chosen system voice; empty means "best installed Russian voice".
    @Published var voiceIdentifier: String {
        didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }
    /// 1.0 is the voice as recorded. The cartoon's sped-up-tape effect is roughly 1.2 on a male voice.
    @Published var voicePitch: Double {
        didSet { defaults.set(voicePitch, forKey: "voicePitch") }
    }
    /// AVSpeechUtterance scale: 0.5 is normal speed.
    @Published var voiceRate: Double {
        didSet { defaults.set(voiceRate, forKey: "voiceRate") }
    }
    static let voicePitchRange = 0.6...1.6
    static let voiceRateRange = 0.35...0.65

    /// Other applications reachable through their MCP servers. Tokens are in the Keychain.
    @Published var connectors: [AppConnector] {
        didSet { defaults.set(try? JSONEncoder().encode(connectors), forKey: "connectors") }
    }

    /// Plain HTTP APIs of other applications. Keys are in the Keychain.
    @Published var customAPIs: [CustomAPI] {
        didSet { defaults.set(try? JSONEncoder().encode(customAPIs), forKey: "customAPIs") }
    }

    /// Enabled APIs with their keys, ready for one answer.
    var resolvedAPIs: [ResolvedAPI] {
        customAPIs.filter(\.isUsable).map { ResolvedAPI(api: $0, key: Keychain.load(named: $0.secretName)) }
    }

    func removeAPI(_ api: CustomAPI) {
        Keychain.save("", named: api.secretName)
        customAPIs.removeAll { $0.id == api.id }
    }

    func removeConnector(_ connector: AppConnector) {
        Keychain.save("", named: connector.secretName)
        connectors.removeAll { $0.id == connector.id }
    }

    @Published var quickActions: [QuickAction] {
        didSet { defaults.set(try? JSONEncoder().encode(quickActions), forKey: "quickActionList") }
    }
    static let defaultQuickActions = [QuickAction(text: "Проверь почту"), QuickAction(text: "Какие у меня напоминания?"),
                                      QuickAction(text: "Переведи", sendsImmediately: false)]

    /// The 16:20 smoke-break animation plays by itself every day.
    @Published var smokeBreakEnabled: Bool {
        didSet { defaults.set(smokeBreakEnabled, forKey: "smokeBreakEnabled") }
    }

    /// Emoji drift up from Winnie's head while he sleeps.
    @Published var dreamsEnabled: Bool {
        didSet { defaults.set(dreamsEnabled, forKey: "dreamsEnabled") }
    }

    /// Say a due reminder out loud. Off by default: a voice out of nowhere is a bad surprise on a call.
    @Published var speaksReminders: Bool {
        didSet { defaults.set(speaksReminders, forKey: "speaksReminders") }
    }

    /// Whether `candidate` is free to be assigned to the shortcut stored at `slot`.
    func isFree(_ candidate: Shortcut, for slot: KeyPath<AppSettings, Shortcut>) -> Bool {
        let slots: [KeyPath<AppSettings, Shortcut>] = [\.shortcut, \.newVoiceShortcut]
        return !slots.contains { $0 != slot && self[keyPath: $0].collides(with: candidate) }
    }

    init() {
        speaksReminders = defaults.bool(forKey: "speaksReminders")
        dreamsEnabled = defaults.object(forKey: "dreamsEnabled") as? Bool ?? true
        smokeBreakEnabled = defaults.object(forKey: "smokeBreakEnabled") as? Bool ?? true
        customAPIs = defaults.data(forKey: "customAPIs")
            .flatMap { try? JSONDecoder().decode([CustomAPI].self, from: $0) } ?? []
        connectors = defaults.data(forKey: "connectors")
            .flatMap { try? JSONDecoder().decode([AppConnector].self, from: $0) } ?? []
        // Falls back to the earlier plain-text list, so buttons the user already set up survive the change.
        quickActions = defaults.data(forKey: "quickActionList").flatMap { try? JSONDecoder().decode([QuickAction].self, from: $0) }
            ?? defaults.stringArray(forKey: "quickActions")?.map { QuickAction(text: $0) }
            ?? Self.defaultQuickActions
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier") ?? ""
        let pitch = defaults.double(forKey: "voicePitch"), rate = defaults.double(forKey: "voiceRate")
        // Neutral by default: an altered pitch only suits a good voice, and that is for the ear to judge.
        voicePitch = Self.voicePitchRange.contains(pitch) ? pitch : 1.0

        voiceRate = Self.voiceRateRange.contains(rate) ? rate : 0.52
        newVoiceShortcut = defaults.data(forKey: "newVoiceShortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .defaultNewVoice
        speaksReplies = defaults.object(forKey: "speaksReplies") as? Bool ?? true
        let storedScale = defaults.double(forKey: "petScale")
        petScale = Self.petScaleRange.contains(storedScale) ? storedScale : 1
        masterPrompt = defaults.string(forKey: "masterPrompt") ?? MasterPrompt.standard
        model = defaults.string(forKey: "model").flatMap(ModelOption.init) ?? .opus
        shortcut = defaults.data(forKey: "shortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        resolveShortcutCollisions()
    }

    private func resolveShortcutCollisions() {
        // Two shortcuts on one key combination: macOS registers only the first, so the other
        // would silently do nothing.
        if newVoiceShortcut.collides(with: shortcut) { newVoiceShortcut = .defaultNewVoice }
    }

    var petOrigin: NSPoint? {
        get {
            guard let values = defaults.array(forKey: "petOrigin") as? [Double], values.count == 2
            else { return nil }
            return NSPoint(x: values[0], y: values[1])
        }
        set { defaults.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: "petOrigin") }
    }

    nonisolated static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Winnie")
    }

    nonisolated static var spritesDirectory: URL {
        supportDirectory.appendingPathComponent("Sprites")
    }
}
