import Combine
import Foundation

public struct Reminder: Codable, Identifiable, Equatable, Sendable {
    public enum Repeat: String, Codable, CaseIterable, Sendable {
        case none, daily, weekdays, weekly, monthly
    }

    public var id: UUID
    public var title: String
    /// For a repeating reminder this is the first occurrence; its time of day
    /// (and weekday or day of month) defines the rest.
    public var fireAt: Date
    public var repeats: Repeat
    public var createdAt: Date
    /// One to three words naming the reminder, written by the model. Optional so
    /// reminders saved before labels existed still decode.
    public var label: String?

    public init(id: UUID = UUID(), title: String, label: String? = nil, fireAt: Date, repeats: Repeat = .none,
                createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.title = title
        self.fireAt = fireAt
        self.repeats = repeats
        self.createdAt = createdAt
    }

    /// Name for the chat Winnie opens when this reminder fires.
    public var chatTitle: String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        return Self.shortened(title)
    }

    /// First three words, minus a dangling preposition: «Ответить Лёве по поводу поездки» → «Ответить Лёве».
    public static func shortened(_ title: String) -> String {
        let dangling: Set<String> = ["в", "во", "на", "по", "к", "ко", "с", "со", "о", "об", "у", "за", "из", "от", "до",
                                     "для", "про", "и", "а", "не", "что", "чтобы"]
        var words = title.split(whereSeparator: \.isWhitespace).prefix(3).map(String.init)
        while let last = words.last, words.count > 1, dangling.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?«»\"*"))
    }

    /// Short handle the model uses to refer to a reminder.
    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    /// The next time this reminder fires after `now`; nil for a one-off that has passed.
    public func nextFire(after now: Date, calendar: Calendar = .current) -> Date? {
        if fireAt > now { return fireAt }
        let time = calendar.dateComponents([.hour, .minute], from: fireAt)
        func next(_ components: DateComponents, after date: Date = now) -> Date? {
            calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
        }
        switch repeats {
        case .none:
            return nil
        case .daily:
            return next(time)
        case .weekdays:
            var date = now
            for _ in 0..<8 {
                guard let candidate = next(time, after: date) else { return nil }
                if !calendar.isDateInWeekend(candidate) { return candidate }
                date = candidate
            }
            return nil
        case .weekly:
            var components = time
            components.weekday = calendar.component(.weekday, from: fireAt)
            return next(components)
        case .monthly:
            var components = time
            components.day = calendar.component(.day, from: fireAt)
            return next(components)
        }
    }
}

/// Winnie's reminders, kept in one JSON file next to the chats.
@MainActor
public final class ReminderStore: ObservableObject {
    /// A finished one-off stays visible this long, so "did it fire?" can be answered by looking.
    public static let keepFinished: TimeInterval = 24 * 60 * 60

    @Published public private(set) var reminders: [Reminder] = []

    private let fileURL: URL

    public init(directory: URL, now: Date = Date()) {
        fileURL = directory.appendingPathComponent("events.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load(now: now)
    }

    /// Upcoming first, by next occurrence; finished one-offs at the end.
    public func sorted(now: Date = Date()) -> [Reminder] {
        reminders.sorted { lhs, rhs in
            switch (lhs.nextFire(after: now), rhs.nextFire(after: now)) {
            case let (left?, right?): left < right
            case (nil, nil): lhs.fireAt > rhs.fireAt
            case (let left, _): left != nil
            }
        }
    }

    public func reminder(matching handle: String) -> Reminder? {
        // A bare id or a whole «[event:ID]» reference.
        var handle = handle.lowercased().trimmingCharacters(in: .whitespaces)
        if handle.hasPrefix("[") { handle.removeFirst() }
        if handle.hasSuffix("]") { handle.removeLast() }
        if handle.hasPrefix("event:") { handle.removeFirst(6) }
        return reminders.first { $0.shortID == handle || $0.id.uuidString.lowercased() == handle }
    }

    public func add(_ reminder: Reminder) {
        reminders.append(reminder)
        save()
    }

    public func update(_ id: UUID, _ change: (inout Reminder) -> Void) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        change(&reminders[index])
        save()
    }

    public func delete(_ id: UUID) {
        reminders.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(reminders) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load(now: Date) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? decoder.decode([Reminder].self, from: data) else { return }
        reminders = stored.filter { $0.nextFire(after: now) != nil || now.timeIntervalSince($0.fireAt) < Self.keepFinished }
        if reminders.count != stored.count { save() }
    }
}
