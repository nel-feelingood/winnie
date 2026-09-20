import Foundation

/// A validated request from the model to change Winnie's own environment. Parsing and
/// range checks live here, away from AppKit, so they can be tested; the app applies them.
public enum EnvironmentCommand: Equatable, Sendable {
    public struct SettingsPatch: Equatable, Sendable {
        public var petScale: Double?
        public var model: ModelOption?
        public var speaksReplies: Bool?
        public var speaksReminders: Bool?
        public var voicePitch: Double?
        public var voiceRate: Double?

        public var isEmpty: Bool {
            petScale == nil && model == nil && speaksReplies == nil && speaksReminders == nil && voicePitch == nil && voiceRate == nil
        }
    }

    case readSettings
    case update(SettingsPatch)
    case addQuickAction(text: String, sendsImmediately: Bool)
    case removeQuickAction(text: String)
    case deleteAllReminders

    public static let petScaleRange = 0.5...2.5
    public static let voicePitchRange = 0.6...1.6
    public static let voiceRateRange = 0.35...0.65

    public enum ParseResult: Equatable {
        case command(EnvironmentCommand)
        case problem(String)
    }

    public static func parse(name: String, input: Data) -> ParseResult {
        let arguments = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        switch name {
        case "get_settings":
            return .command(.readSettings)
        case "delete_all_reminders":
            return .command(.deleteAllReminders)
        case "add_quick_action":
            guard let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return .problem("text is required.") }
            guard text.count <= 60 else { return .problem("Keep the button text under 60 characters.") }
            return .command(.addQuickAction(text: text, sendsImmediately: arguments["send_immediately"] as? Bool ?? true))
        case "remove_quick_action":
            guard let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return .problem("text is required.") }
            return .command(.removeQuickAction(text: text))
        case "update_settings":
            return parsePatch(arguments)
        default:
            return .problem("Unknown tool \(name).")
        }
    }

    private static func parsePatch(_ arguments: [String: Any]) -> ParseResult {
        func number(_ key: String) -> Double? { (arguments[key] as? Double) ?? (arguments[key] as? Int).map(Double.init) }
        var patch = SettingsPatch()

        if let percent = number("pet_size_percent") {
            let scale = percent / 100
            guard petScaleRange.contains(scale) else { return .problem("pet_size_percent must be between 50 and 250.") }
            patch.petScale = scale
        }
        if let raw = arguments["model"] as? String {
            guard let model = ModelOption.allCases.first(where: { $0.rawValue.contains(raw.lowercased()) })
            else { return .problem("model must be one of: opus, sonnet, haiku.") }
            patch.model = model
        }
        if let pitch = number("voice_pitch") {
            guard voicePitchRange.contains(pitch) else { return .problem("voice_pitch must be between 0.6 and 1.6.") }
            patch.voicePitch = pitch
        }
        if let rate = number("voice_rate") {
            guard voiceRateRange.contains(rate) else { return .problem("voice_rate must be between 0.35 and 0.65.") }
            patch.voiceRate = rate
        }
        patch.speaksReplies = arguments["speak_replies"] as? Bool
        patch.speaksReminders = arguments["speak_reminders"] as? Bool
        return patch.isEmpty ? .problem("Nothing to change: pass at least one setting.") : .command(.update(patch))
    }
}

public enum EnvironmentToolSchema {
    public static let names: Set<String> = ["get_settings", "update_settings", "add_quick_action", "remove_quick_action",
                                            "delete_all_reminders"]

    public static let definitions: [[String: Any]] = [
        [
            "name": "get_settings",
            "description": "Read Winnie's own current settings: size, model, voice options, quick action buttons and how many reminders exist. Call it when you need the current values, e.g. to make Winnie «a bit bigger» or to find a button's exact text.",
            "input_schema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "update_settings",
            "description": "Change Winnie's own settings when the user asks (bigger or smaller, another model, speak or stay silent, voice pitch and pace). Pass only what changes.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "pet_size_percent": ["type": "number", "description": "Winnie's size on screen, 50–250. 100 is normal."],
                    "model": ["type": "string", "enum": ["opus", "sonnet", "haiku"], "description": "Which Claude model answers. Takes effect from the next message."],
                    "speak_replies": ["type": "boolean", "description": "Read answers aloud when the question was asked by voice."],
                    "speak_reminders": ["type": "boolean", "description": "Say due reminders out loud."],
                    "voice_pitch": ["type": "number", "description": "0.6–1.6; 1.0 is the voice as recorded."],
                    "voice_rate": ["type": "number", "description": "0.35–0.65; 0.5 is normal speed."],
                ],
            ],
        ],
        [
            "name": "add_quick_action",
            "description": "Add a quick action button shown in an empty chat. Use it when the user asks for a quick command or button, e.g. «добавь быструю команду „Что в календаре“».",
            "input_schema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The button's text, short, in the user's language; it is also what gets sent."],
                    "send_immediately": ["type": "boolean", "description": "true (default): a tap sends the text. false: the text goes into the input field to be finished, right for prompts like «Переведи»."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "remove_quick_action",
            "description": "Remove a quick action button by its text (case-insensitive). Get the exact texts from get_settings if unsure.",
            "input_schema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
        ],
        [
            "name": "delete_all_reminders",
            "description": "Delete every reminder (the user calls them events, «события»). Only when the user clearly asks to remove all of them; for one reminder use delete_reminder.",
            "input_schema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    /// Tools that change lasting state. Like memory, they are refused once mail, web or app
    /// content has entered the same answer.
    public static let guardedNames = names.subtracting(["get_settings"])

    public static let blockedOutcome = ToolOutcome("""
        Not changed. This answer has already read mail, web or app content, and Winnie's settings cannot be changed in \
        the same answer, so that nothing written by a stranger can alter them. Tell the user this, and that they can \
        repeat the request in a separate message.
        """, isError: true)
}
