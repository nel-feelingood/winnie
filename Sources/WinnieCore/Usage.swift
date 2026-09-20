import Combine
import Foundation

/// Token counts of one API response, as reported in its `usage` object.
public struct UsageSample: Codable, Equatable, Sendable {
    public var model: String
    /// Uncached input. Cached tokens are reported, and billed, separately.
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var searches = 0

    public init(model: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, searches: Int = 0) {
        self.model = model
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.searches = searches
    }

    public static func + (lhs: UsageSample, rhs: UsageSample) -> UsageSample {
        UsageSample(model: lhs.model, input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                    searches: lhs.searches + rhs.searches)
    }

    public var totalInput: Int { input + cacheRead + cacheWrite }
}

/// List prices in USD, for an estimate only: the authoritative figure is the Console's.
public enum Pricing {
    /// (input, output) per million tokens.
    static func rates(for model: String) -> (input: Double, output: Double) {
        if model.contains("opus") { return (5, 25) }
        if model.contains("sonnet") { return (2, 10) }
        return (1, 5) // Haiku 4.5
    }

    static let cacheReadFactor = 0.1
    static let cacheWriteFactor = 1.25
    static let perSearch = 0.01

    public static func cost(_ sample: UsageSample) -> Double {
        let rate = rates(for: sample.model)
        let input = Double(sample.input) + Double(sample.cacheRead) * cacheReadFactor + Double(sample.cacheWrite) * cacheWriteFactor
        return (input * rate.input + Double(sample.output) * rate.output) / 1_000_000 + Double(sample.searches) * perSearch
    }
}

public struct UsageTotals: Equatable, Sendable {
    public var requests = 0
    public var input = 0
    public var output = 0
    public var searches = 0
    public var cost = 0.0
}

/// What Winnie has spent, counted locally from API responses and kept per day and model.
@MainActor
public final class UsageStore: ObservableObject {
    struct Day: Codable, Equatable {
        var requests = 0
        var models: [String: UsageSample] = [:]
    }

    static let retentionDays = 120

    @Published private(set) var days: [String: Day] = [:]

    private let fileURL: URL
    private let calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.calendar = calendar
        fileURL = directory.appendingPathComponent("usage.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = stored
        }
    }

    public func record(_ sample: UsageSample, at date: Date = Date()) {
        var day = days[key(date)] ?? Day()
        day.requests += 1
        day.models[sample.model] = day.models[sample.model].map { $0 + sample } ?? sample
        days[key(date)] = day
        if let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: date) {
            days = days.filter { $0.key >= key(cutoff) }
        }
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Totals for the last `dayCount` calendar days, today included.
    public func totals(lastDays dayCount: Int, now: Date = Date()) -> UsageTotals {
        guard let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: now) else { return UsageTotals() }
        var totals = UsageTotals()
        for (day, entry) in days where day >= key(start) && day <= key(now) {
            totals.requests += entry.requests
            for sample in entry.models.values {
                totals.input += sample.totalInput
                totals.output += sample.output
                totals.searches += sample.searches
                totals.cost += Pricing.cost(sample)
            }
        }
        return totals
    }

    private func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
