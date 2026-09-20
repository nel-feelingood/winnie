import Foundation
import WinnieCore

/// Applies the model's requests to change Winnie's own environment.
@MainActor
struct EnvironmentTools {
    let settings: AppSettings
    let reminders: ReminderStore

    func execute(name: String, input: Data) -> ToolOutcome {
        switch EnvironmentCommand.parse(name: name, input: input) {
        case .problem(let message):
            return ToolOutcome(message, isError: true)
        case .command(let command):
            return apply(command)
        }
    }

    private func apply(_ command: EnvironmentCommand) -> ToolOutcome {
        switch command {
        case .readSettings:
            return ToolOutcome(summary)

        case .update(let patch):
            // Assigning to the published settings is all it takes: the pet, the voice and the
            // next request read them from there.
            if let scale = patch.petScale { settings.petScale = scale }
            if let model = patch.model { settings.model = model }
            if let speaks = patch.speaksReplies { settings.speaksReplies = speaks }
            if let speaks = patch.speaksReminders { settings.speaksReminders = speaks }
            if let pitch = patch.voicePitch { settings.voicePitch = pitch }
            if let rate = patch.voiceRate { settings.voiceRate = rate }
            return ToolOutcome("Changed. Now:\n\(summary)")

        case .addQuickAction(let text, let sendsImmediately):
            guard !settings.quickActions.contains(where: { Self.same($0.text, text) })
            else { return ToolOutcome("A button «\(text)» already exists.", isError: true) }
            guard settings.quickActions.count < 12 else { return ToolOutcome("There are already 12 buttons; remove one first.", isError: true) }
            settings.quickActions.append(QuickAction(text: text, sendsImmediately: sendsImmediately))
            return ToolOutcome("Added the button «\(text)» (\(sendsImmediately ? "sends at once" : "fills the input field")).")

        case .removeQuickAction(let text):
            guard settings.quickActions.contains(where: { Self.same($0.text, text) }) else {
                let existing = settings.quickActions.map { "«\($0.text)»" }.joined(separator: ", ")
                return ToolOutcome("No button «\(text)». Existing: \(existing.isEmpty ? "none" : existing).", isError: true)
            }
            settings.quickActions.removeAll { Self.same($0.text, text) }
            return ToolOutcome("Removed the button «\(text)».")

        case .deleteAllReminders:
            let count = reminders.reminders.count
            reminders.reminders.map(\.id).forEach(reminders.delete)
            return ToolOutcome(count == 0 ? "There were no reminders." : "Deleted all \(count) reminders.")
        }
    }

    private var summary: String {
        let buttons = settings.quickActions.map { "«\($0.text)»\($0.sendsImmediately ? "" : " (fills the field)")" }.joined(separator: ", ")
        return """
        pet_size_percent: \(Int((settings.petScale * 100).rounded()))
        model: \(settings.model.displayName)
        speak_replies: \(settings.speaksReplies)
        speak_reminders: \(settings.speaksReminders)
        voice_pitch: \(String(format: "%.2f", settings.voicePitch))
        voice_rate: \(String(format: "%.2f", settings.voiceRate))
        quick action buttons: \(buttons.isEmpty ? "none" : buttons)
        reminders: \(reminders.reminders.count)
        """
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
