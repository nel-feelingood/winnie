import Foundation
import Testing
@testable import WinnieCore

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite struct ReminderScheduleTests {
    // 2026-09-20 is a Sunday.
    let sundayEvening = date(2026, 9, 20, 19, 0)

    @Test func oneOffFiresOnceThenNever() {
        let reminder = Reminder(title: "x", fireAt: sundayEvening)
        #expect(reminder.nextFire(after: date(2026, 9, 20, 12), calendar: calendar) == sundayEvening)
        #expect(reminder.nextFire(after: date(2026, 9, 20, 19, 1), calendar: calendar) == nil)
    }

    @Test func dailyMovesToTheNextDay() {
        let reminder = Reminder(title: "x", fireAt: sundayEvening, repeats: .daily)
        #expect(reminder.nextFire(after: date(2026, 9, 20, 20), calendar: calendar) == date(2026, 9, 21, 19))
    }

    @Test func weekdaysSkipTheWeekend() {
        let friday = Reminder(title: "x", fireAt: date(2026, 9, 18, 9), repeats: .weekdays)
        // After Friday 09:00 the next working morning is Monday the 21st.
        #expect(friday.nextFire(after: date(2026, 9, 18, 10), calendar: calendar) == date(2026, 9, 21, 9))
    }

    @Test func weeklyAndMonthlyKeepTheirDay() {
        let weekly = Reminder(title: "x", fireAt: sundayEvening, repeats: .weekly)
        #expect(weekly.nextFire(after: date(2026, 9, 21), calendar: calendar) == date(2026, 9, 27, 19))
        let monthly = Reminder(title: "x", fireAt: sundayEvening, repeats: .monthly)
        #expect(monthly.nextFire(after: date(2026, 9, 21), calendar: calendar) == date(2026, 10, 20, 19))
    }
}

@MainActor @Suite struct ReminderToolsTests {
    let now = date(2026, 9, 20, 17, 5)

    func makeTools() -> (ReminderTools, ReminderStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winnie-rem-\(UUID().uuidString)")
        let store = ReminderStore(directory: directory, now: now)
        return (ReminderTools(store: store, now: { [now] in now }), store)
    }

    func run(_ tools: ReminderTools, _ name: String, _ input: [String: Any]) -> ToolOutcome {
        tools.execute(name: name, input: try! JSONSerialization.data(withJSONObject: input))
    }

    @Test func createsAReminderInLocalTime() {
        let (tools, store) = makeTools()
        let outcome = run(tools, "create_reminder", ["title": "Ответить Лёве", "fire_at": "2026-09-20T19:00"])
        #expect(!outcome.isError)
        #expect(store.reminders.first?.fireAt == date(2026, 9, 20, 19))
        #expect(store.reminders.first?.repeats == Reminder.Repeat.none)
    }

    @Test func rejectsATimeThatHasAlreadyPassedAndSaysWhatTimeItIs() {
        let (tools, store) = makeTools()
        let outcome = run(tools, "create_reminder", ["title": "x", "fire_at": "2026-09-20T09:00"])
        #expect(outcome.isError)
        #expect(outcome.content.contains("2026-09-20T17:05"))
        #expect(store.reminders.isEmpty)
    }

    @Test func rejectsGarbageInsteadOfGuessing() {
        let (tools, _) = makeTools()
        #expect(run(tools, "create_reminder", ["title": "x", "fire_at": "вечером"]).isError)
        #expect(run(tools, "create_reminder", ["fire_at": "2026-09-21T09:00"]).isError)
        #expect(tools.execute(name: "create_reminder", input: Data("{broken".utf8)).isError)
    }

    @Test func listsUpdatesAndDeletesByShortID() throws {
        let (tools, store) = makeTools()
        _ = run(tools, "create_reminder", ["title": "Зарядка", "fire_at": "2026-09-21T08:00", "repeat": "weekdays"])
        let id = try #require(store.reminders.first?.shortID)
        #expect(run(tools, "list_reminders", [:]).content.contains("id=\(id)"))

        #expect(!run(tools, "update_reminder", ["id": id, "fire_at": "2026-09-21T07:30"]).isError)
        #expect(store.reminders.first?.fireAt == date(2026, 9, 21, 7, 30))
        #expect(store.reminders.first?.title == "Зарядка")

        #expect(run(tools, "delete_reminder", ["id": "deadbeef"]).isError)
        #expect(!run(tools, "delete_reminder", ["id": id]).isError)
        #expect(store.reminders.isEmpty)
    }

    @Test func storePersistsAndDropsLongFinishedOneOffs() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winnie-rem-\(UUID().uuidString)")
        let store = ReminderStore(directory: directory, now: now)
        store.add(Reminder(title: "старое", fireAt: date(2026, 9, 10, 9)))
        store.add(Reminder(title: "вчерашнее", fireAt: date(2026, 9, 20, 9)))
        store.add(Reminder(title: "ежедневное", fireAt: date(2026, 9, 1, 9), repeats: .daily))

        let reloaded = ReminderStore(directory: directory, now: now)
        #expect(Set(reloaded.reminders.map(\.title)) == ["вчерашнее", "ежедневное"])
        #expect(reloaded.sorted(now: now).first?.title == "ежедневное")
    }
}

@Suite struct ReminderPromptTests {
    @Test func promptCarriesExactLocalTimeAndWeekday() {
        let clock = ClaudeClient.clock(date(2026, 9, 20, 17, 5))
        #expect(clock.hasPrefix("2026-09-20 17:05, воскресенье"))
        #expect(ClaudeClient.systemPrompt(master: "x", now: date(2026, 9, 20, 17, 5)).contains("create_reminder"))
    }

    @Test func toolsAreOfferedOnlyWithAHandler() {
        let with = ClaudeClient.requestBody(model: .opus, clientTools: ReminderToolSchema.definitions, messages: [])
        let names = (with["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(Set(names) == ReminderToolSchema.names.union(["web_search"]))
        let without = ClaudeClient.requestBody(model: .opus, messages: [])
        #expect((without["tools"] as? [[String: Any]])?.count == 1)
    }
}
