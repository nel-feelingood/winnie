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

    @Test func quickActionsDefaultToSendingAndNeedText() {
        #expect(parse("add_quick_action", ["text": "  Что в календаре  "]) == .command(.addQuickAction(text: "Что в календаре", sendsImmediately: true)))
        #expect(parse("add_quick_action", ["text": "Переведи", "send_immediately": false]) == .command(.addQuickAction(text: "Переведи", sendsImmediately: false)))
        #expect(parse("add_quick_action", ["text": " "]) == .problem("text is required."))
        #expect(parse("add_quick_action", ["text": String(repeating: "я", count: 80)]) == .problem("Keep the button text under 60 characters."))
        #expect(parse("remove_quick_action", ["text": "Переведи"]) == .command(.removeQuickAction(text: "Переведи")))
    }

    @Test func readingIsNeverGuardedButChangesAre() {
        #expect(parse("get_settings") == .command(.readSettings))
        #expect(parse("delete_all_reminders") == .command(.deleteAllReminders))
        #expect(!EnvironmentToolSchema.guardedNames.contains("get_settings"))
        #expect(EnvironmentToolSchema.guardedNames.isSuperset(of: ["update_settings", "add_quick_action", "delete_all_reminders"]))
        #expect(EnvironmentToolSchema.blockedOutcome.isError)
    }

    @Test func toolsAndTheirRuleAreInEveryToolRequest() {
        let definitions = Set(EnvironmentToolSchema.definitions.compactMap { $0["name"] as? String })
        #expect(definitions == EnvironmentToolSchema.names)
        #expect(ClaudeClient.systemPrompt(master: "x").contains("add_quick_action"))
    }
}
