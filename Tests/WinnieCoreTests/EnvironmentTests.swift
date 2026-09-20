import Foundation
import Testing
@testable import WinnieCore

@Suite struct EnvironmentCommandTests {
    func parse(_ name: String, _ input: [String: Any] = [:]) -> EnvironmentCommand.ParseResult {
        EnvironmentCommand.parse(name: name, input: try! JSONSerialization.data(withJSONObject: input))
    }

    @Test func settingsPatchIsValidatedAndConverted() {
        guard case .command(.update(let patch)) = parse("update_settings", ["pet_size_percent": 150, "model": "sonnet", "speak_replies": false])
        else { Issue.record("expected a patch"); return }
        #expect(patch.petScale == 1.5 && patch.model == .sonnet && patch.speaksReplies == false && patch.voicePitch == nil)
    }

    @Test func outOfRangeAndEmptyPatchesAreRefused() {
        #expect(parse("update_settings", ["pet_size_percent": 900]) == .problem("pet_size_percent must be between 50 and 250."))
        #expect(parse("update_settings", ["model": "gpt"]) == .problem("model must be one of: opus, sonnet, haiku."))
        #expect(parse("update_settings", ["voice_pitch": 3]) == .problem("voice_pitch must be between 0.6 and 1.6."))
        #expect(parse("update_settings") == .problem("Nothing to change: pass at least one setting."))
    }

    @Test func quickActionsCarryALabelAndAFullInstruction() {
        let full = "Запусти рабочий блок на 2 часа: сессии по 20 минут и перерывы по 10 минут."
        #expect(parse("add_quick_action", ["label": " Помодоро 2 ч ", "instruction": full])
            == .command(.addQuickAction(label: "Помодоро 2 ч", instruction: full, sendsImmediately: true)))
        #expect(parse("add_quick_action", ["label": "Переведи", "instruction": "Переведи", "send_immediately": false])
            == .command(.addQuickAction(label: "Переведи", instruction: "Переведи", sendsImmediately: false)))
        // A label alone is what went wrong before: «02:00 (20/10)» meant nothing when it came back.
        #expect(parse("add_quick_action", ["label": "02:00 (20/10)"])
            == .problem("instruction is required: the full request that will be sent when the button is tapped."))
        #expect(parse("add_quick_action", ["instruction": full]) == .problem("label is required."))
        #expect(parse("add_quick_action", ["label": String(repeating: "я", count: 40), "instruction": full])
            == .problem("Keep the label under 30 characters; the details belong in instruction."))
        #expect(parse("remove_quick_action", ["text": "Переведи"]) == .command(.removeQuickAction(text: "Переведи")))
    }

    @Test func buttonsCanBeMovedToAPosition() {
        #expect(parse("move_quick_action", ["text": " Помодоро ", "position": 1]) == .command(.moveQuickAction(text: "Помодоро", position: 1)))
        #expect(parse("move_quick_action", ["text": "Переведи", "position": 99.0]) == .command(.moveQuickAction(text: "Переведи", position: 99)))
        #expect(parse("move_quick_action", ["text": "Переведи", "position": 0])
            == .problem("position is required: 1 for first, 2 for second, and so on; a large number means last."))
        #expect(parse("move_quick_action", ["position": 2]) == .problem("text is required."))
        // Reordering is a lasting change, so it is guarded like the others.
        #expect(EnvironmentToolSchema.guardedNames.contains("move_quick_action"))
    }

    @Test func readingIsNeverGuardedButChangesAre() {
        #expect(parse("get_settings") == .command(.readSettings))
        #expect(parse("delete_all_reminders") == .command(.deleteAllReminders))
        #expect(!EnvironmentToolSchema.guardedNames.contains("get_settings"))
        #expect(EnvironmentToolSchema.guardedNames.isSuperset(of: ["update_settings", "add_quick_action", "delete_all_reminders"]))
        #expect(EnvironmentToolSchema.blockedOutcome.isError)
    }

    @Test func smokeBreakCanBePlayedAnytimeAndToggled() {
        #expect(parse("play_smoke_break") == .command(.playSmokeBreak))
        // A few seconds of animation is harmless, so it is not among the guarded tools.
        #expect(!EnvironmentToolSchema.guardedNames.contains("play_smoke_break"))
        guard case .command(.update(let patch)) = parse("update_settings", ["smoke_break_at_1620": false])
        else { Issue.record("expected a patch"); return }
        #expect(patch.smokeBreakAt1620 == false)
    }

    @Test func smokeBreakOutranksEveryOtherPose() {
        var mood = PetMood()
        mood.isDragging = true
        mood.activity = .error
        mood.isOnSmokeBreak = true
        #expect(mood.state == .smoke)
        mood.isOnSmokeBreak = false
        #expect(mood.state == .drag)
    }

    @Test func toolsAndTheirRuleAreInEveryToolRequest() {
        let definitions = Set(EnvironmentToolSchema.definitions.compactMap { $0["name"] as? String })
        #expect(definitions == EnvironmentToolSchema.names)
        #expect(ClaudeClient.systemPrompt(master: "x").contains("add_quick_action"))
    }
}
