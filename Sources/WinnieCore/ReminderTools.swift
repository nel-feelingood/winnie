import Foundation

public struct ToolOutcome: Sendable {
    public var content: String
    public var isError: Bool

    public init(_ content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

/// What the model is told about the reminder tools. Separate from the executor so the
/// API client can read it from any thread.
public enum ReminderToolSchema {
    public static let names: Set<String> = ["create_reminder", "list_reminders", "update_reminder", "delete_reminder"]

    private static let timeRule = """
    Local time as YYYY-MM-DDTHH:MM, computed from the current date and time given in the system prompt. \
    For vague times use: morning 09:00, afternoon 13:00, evening 19:00, night 22:00. If that time has \
    already passed today, use tomorrow. It must be in the future.
    """

    /// No `eager_input_streaming`: these inputs are a few dozen bytes, so there is nothing to
    /// gain from streaming them early, and buffered inputs arrive validated by the API.
    public static let definitions: [[String: Any]] = [
        [
            "name": "create_reminder",
            "description": "Create a reminder that fires a system notification on the user's Mac at the given time. Call this whenever the user asks to be reminded of something. After it succeeds, confirm briefly and state the exact date and time you set.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "What to remind about, as a short imperative phrase in the user's language, e.g. «Ответить Лёве по поводу поездки»."],
                    "short_title": ["type": "string", "description": "A one to three word name for this reminder in the user's language, used as the title of the chat that opens when it fires, e.g. «Ответ Лёве», «Зарядка», «Плита»."],
                    "fire_at": ["type": "string", "description": timeRule],
                    "repeat": ["type": "string", "enum": Reminder.Repeat.allCases.map(\.rawValue),
                               "description": "none = once (default). daily, weekdays (Mon–Fri), weekly (same weekday as fire_at), monthly (same day of month as fire_at)."],
                ],
                "required": ["title", "short_title", "fire_at"],
            ],
        ],
        [
            "name": "list_reminders",
            "description": "List the user's reminders with their ids. Call this before updating or deleting, to find the id, and when the user asks what is scheduled.",
            "input_schema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "update_reminder",
            "description": "Change an existing reminder. Pass only the fields that change.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The reminder's id from list_reminders."],
                    "title": ["type": "string"],
                    "short_title": ["type": "string", "description": "Update it when the title changes."],
                    "fire_at": ["type": "string", "description": timeRule],
                    "repeat": ["type": "string", "enum": Reminder.Repeat.allCases.map(\.rawValue)],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "delete_reminder",
            "description": "Delete a reminder by id. If the user's wording could match several reminders, ask which one instead of guessing.",
            "input_schema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The reminder's id from list_reminders."]],
                "required": ["id"],
            ],
        ],
    ]
}

/// Executes the reminder tools against the store.
@MainActor
public struct ReminderTools {
    private let store: ReminderStore
    private let now: () -> Date

    public init(store: ReminderStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func execute(name: String, input: Data) -> ToolOutcome {
        let arguments = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        switch name {
        case "create_reminder": return create(arguments)
        case "list_reminders": return list()
        case "update_reminder": return update(arguments)
        case "delete_reminder": return delete(arguments)
        default: return ToolOutcome("Unknown tool \(name).", isError: true)
        }
    }

    private func create(_ arguments: [String: Any]) -> ToolOutcome {
        guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return ToolOutcome("title is required.", isError: true) }
        let repeats = (arguments["repeat"] as? String).flatMap(Reminder.Repeat.init) ?? .none
        switch Self.parseTime(arguments["fire_at"], now: now()) {
        case .failure(let problem): return problem
        case .success(let date):
            let reminder = Reminder(title: title, label: arguments["short_title"] as? String, fireAt: date,
                                    repeats: repeats, createdAt: now())
            store.add(reminder)
            return ToolOutcome("Created. \(Self.describe(reminder))")
        }
    }

    private func list() -> ToolOutcome {
        let current = now()
        let lines = store.sorted(now: current).map { reminder in
            Self.describe(reminder) + (reminder.nextFire(after: current) == nil ? " (already fired)" : "")
        }
        return ToolOutcome(lines.isEmpty ? "There are no reminders." : lines.joined(separator: "\n"))
    }

    private func update(_ arguments: [String: Any]) -> ToolOutcome {
        guard let reminder = (arguments["id"] as? String).flatMap(store.reminder(matching:))
        else { return ToolOutcome("No reminder with that id. Call list_reminders to see the ids.", isError: true) }
        var newDate: Date?
        if arguments["fire_at"] != nil {
            switch Self.parseTime(arguments["fire_at"], now: now()) {
            case .failure(let problem): return problem
            case .success(let date): newDate = date
            }
        }
        store.update(reminder.id) { stored in
            if let title = arguments["title"] as? String, !title.isEmpty {
                stored.title = title
                // A stale label would name the chat after what the reminder used to be.
                stored.label = nil
            }
            if let label = arguments["short_title"] as? String, !label.isEmpty { stored.label = label }
            if let newDate { stored.fireAt = newDate }
            if let repeats = (arguments["repeat"] as? String).flatMap(Reminder.Repeat.init) { stored.repeats = repeats }
        }
        return ToolOutcome("Updated. \(store.reminder(matching: reminder.shortID).map(Self.describe) ?? "")")
    }

    private func delete(_ arguments: [String: Any]) -> ToolOutcome {
        guard let reminder = (arguments["id"] as? String).flatMap(store.reminder(matching:))
        else { return ToolOutcome("No reminder with that id. Call list_reminders to see the ids.", isError: true) }
        store.delete(reminder.id)
        return ToolOutcome("Deleted «\(reminder.title)».")
    }

    // MARK: - Time

    enum TimeResult {
        case success(Date)
        case failure(ToolOutcome)
    }

    static func parseTime(_ value: Any?, now: Date) -> TimeResult {
        guard let text = value as? String else { return .failure(ToolOutcome("fire_at is required.", isError: true)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            guard let date = formatter.date(from: text) else { continue }
            guard date > now else {
                return .failure(ToolOutcome("fire_at \(text) is in the past; now it is \(localStamp(now)). Pick a future time.", isError: true))
            }
            return .success(date)
        }
        return .failure(ToolOutcome("fire_at must look like 2026-09-20T19:00 (local time).", isError: true))
    }

    static func localStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    static func describe(_ reminder: Reminder) -> String {
        "id=\(reminder.shortID) | \(localStamp(reminder.fireAt)) | repeat=\(reminder.repeats.rawValue) | \(reminder.title)"
    }
}
