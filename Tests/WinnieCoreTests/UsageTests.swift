import Foundation
import Testing
@testable import WinnieCore

@Suite struct UsageParsingTests {
    @Test func readsCountsFromTheStream() throws {
        var turn = TurnAccumulator()
        for line in [
            #"{"type":"message_start","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":120,"cache_read_input_tokens":2400,"cache_creation_input_tokens":0,"output_tokens":1}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":900,"output_tokens":310,"server_tool_use":{"web_search_requests":2}}}"#,
        ] { _ = try turn.consume(data: line) }
        // message_delta carries the final figures, so it wins where both report a value.
        #expect(turn.usage == UsageSample(model: "claude-sonnet-5", input: 900, output: 310, cacheRead: 2400, searches: 2))
    }
}

@Suite struct PricingTests {
    @Test func pricesByModelCacheAndSearch() {
        let million = 1_000_000
        #expect(Pricing.cost(UsageSample(model: "claude-haiku-4-5", input: million, output: million)) == 6)
        #expect(Pricing.cost(UsageSample(model: "claude-opus-5", input: million)) == 5)
        // Cache reads at a tenth of the input price, writes at 1.25x; searches at a cent each.
        let cached = Pricing.cost(UsageSample(model: "claude-sonnet-5", cacheRead: million, cacheWrite: million, searches: 3))
        #expect(abs(cached - (0.2 + 2.5 + 0.03)) < 1e-9)
    }
}

@MainActor @Suite struct UsageStoreTests {
    @Test func sumsByPeriodAndPersists() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winnie-usage-\(UUID().uuidString)")
        let now = Date()
        let store = UsageStore(directory: directory)
        store.record(UsageSample(model: "claude-haiku-4-5", input: 1000, output: 200, searches: 1), at: now)
        store.record(UsageSample(model: "claude-haiku-4-5", input: 500, output: 100, cacheRead: 2000), at: now)
        store.record(UsageSample(model: "claude-opus-5", input: 4000, output: 50), at: now.addingTimeInterval(-3 * 86_400))
        store.record(UsageSample(model: "claude-opus-5", input: 9999, output: 9999), at: now.addingTimeInterval(-40 * 86_400))

        let today = UsageStore(directory: directory).totals(lastDays: 1, now: now)
        #expect(today.requests == 2 && today.input == 3500 && today.output == 300 && today.searches == 1)
        #expect(store.totals(lastDays: 7, now: now).requests == 3)
        #expect(store.totals(lastDays: 30, now: now).output == 350)
    }
}
