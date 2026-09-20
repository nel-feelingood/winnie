import AppKit
import Carbon.HIToolbox
import WinnieCore

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, ...).
    var modifiers: UInt32
    /// Human-readable form captured when the shortcut was recorded.
    var display: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_Space),
                                    modifiers: UInt32(controlKey | optionKey),
                                    display: "⌃⌥Space")
    static let defaultVoice = Shortcut(keyCode: UInt32(kVK_ANSI_V),
                                       modifiers: UInt32(controlKey | optionKey),
                                       display: "⌃⌥V")
    static let defaultNewVoice = Shortcut(keyCode: UInt32(kVK_ANSI_E),
                                          modifiers: UInt32(cmdKey | shiftKey),
                                          display: "⇧⌘E")
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

    /// Opens the chat with the microphone already on.
    @Published var voiceShortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(voiceShortcut), forKey: "voiceShortcut") }
    }
    /// Starts a fresh dialog with the microphone already on.
    @Published var newVoiceShortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(newVoiceShortcut), forKey: "newVoiceShortcut") }
    }
    /// Read answers aloud when the question was asked by voice.
    @Published var speaksReplies: Bool {
        didSet { defaults.set(speaksReplies, forKey: "speaksReplies") }
    }

    /// Say a due reminder out loud. Off by default: a voice out of nowhere is a bad surprise on a call.
    @Published var speaksReminders: Bool {
        didSet { defaults.set(speaksReminders, forKey: "speaksReminders") }
    }

    init() {
        speaksReminders = defaults.bool(forKey: "speaksReminders")
        voiceShortcut = defaults.data(forKey: "voiceShortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .defaultVoice
        newVoiceShortcut = defaults.data(forKey: "newVoiceShortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .defaultNewVoice
        speaksReplies = defaults.object(forKey: "speaksReplies") as? Bool ?? true
        let storedScale = defaults.double(forKey: "petScale")
        petScale = Self.petScaleRange.contains(storedScale) ? storedScale : 1
        masterPrompt = defaults.string(forKey: "masterPrompt") ?? MasterPrompt.standard
        model = defaults.string(forKey: "model").flatMap(ModelOption.init) ?? .opus
        shortcut = defaults.data(forKey: "shortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
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
