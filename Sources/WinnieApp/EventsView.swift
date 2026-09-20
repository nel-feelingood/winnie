import SwiftUI
import WinnieCore

/// The Events tab: what Winnie has been asked to remind about.
struct EventsView: View {
    @ObservedObject var store: ReminderStore

    var body: some View {
        // Re-evaluated every minute so "сегодня" and finished states stay truthful.
        TimelineView(.everyMinute) { context in
            let reminders = store.sorted(now: context.date)
            if reminders.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("Пока пусто").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Скажи Винни: «напомни вечером ответить Лёве»")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(reminders) { reminder in
                            EventRow(reminder: reminder, now: context.date) { store.delete(reminder.id) }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

private struct EventRow: View {
    let reminder: Reminder
    let now: Date
    let onDelete: () -> Void

    @State private var isHovering = false

    private var isFinished: Bool { reminder.nextFire(after: now) == nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isFinished ? "checkmark.circle" : (reminder.repeats == .none ? "bell" : "repeat"))
                .font(.system(size: 13))
                .foregroundStyle(isFinished ? Color.secondary : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.system(size: 13))
                    .strikethrough(isFinished)
                    .foregroundStyle(isFinished ? .secondary : .primary)
                    .lineLimit(2)
                Text(EventTime.describe(reminder, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 12)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Удалить")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

enum EventTime {
    static func describe(_ reminder: Reminder, now: Date) -> String {
        let time = formatted(reminder.fireAt, "HH:mm")
        switch reminder.repeats {
        case .none:
            let day = DateFormatter()
            day.locale = Locale(identifier: "ru_RU")
            day.dateStyle = .medium
            day.timeStyle = .none
            day.doesRelativeDateFormatting = true
            let text = "\(day.string(from: reminder.fireAt)), \(time)"
            return reminder.fireAt <= now ? "Сработало: \(text)" : text.prefix(1).uppercased() + text.dropFirst()
        case .daily: return "Каждый день в \(time)"
        case .weekdays: return "По будням в \(time)"
        case .weekly: return "Каждую неделю: \(formatted(reminder.fireAt, "EEEE")), \(time)"
        case .monthly: return "Каждый месяц: \(formatted(reminder.fireAt, "d"))-го в \(time)"
        }
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
