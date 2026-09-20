import AppKit
import Combine
import UserNotifications
import WinnieCore

/// Turns stored reminders into things that actually happen.
///
/// Two mechanisms, on purpose. System notifications are the reliable one: macOS delivers
/// them even when Winnie is not running. A single in-app timer aimed at the next due
/// reminder adds the in-character part (Winnie opens the chat and says it) while the app
/// is up; one timer costs no battery, unlike polling.
@MainActor
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    var onFire: (Reminder) -> Void = { _ in }
    var onNotificationClicked: () -> Void = {}
    var onPermissionDenied: () -> Void = {}

    private let store: ReminderStore
    private let center = UNUserNotificationCenter.current()
    private var timer: Timer?

    /// Up to when due reminders have been presented. Persisted, so a reminder that came due
    /// while Winnie was not running (quit, updated, crashed) is still shown at the next
    /// launch instead of being silently skipped.
    private var lastCheck: Date {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.lastCheckKey)
            // First launch has nothing to catch up on; never look back further than a day.
            let earliest = Date().addingTimeInterval(-Self.catchUpWindow)
            return stored == 0 ? Date() : max(Date(timeIntervalSince1970: stored), earliest)
        }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.lastCheckKey) }
    }

    private static let lastCheckKey = "remindersCheckedUntil"
    private static let catchUpWindow: TimeInterval = 24 * 60 * 60
    private var subscription: AnyCancellable?

    init(store: ReminderStore) {
        self.store = store
        super.init()
        center.delegate = self
        // Any change to the list, from the chat tools or the Events tab, lands here.
        subscription = store.$reminders
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        if UserDefaults.standard.double(forKey: Self.lastCheckKey) == 0 { lastCheck = Date() }
    }

    /// Call once the app can present: shows whatever came due while Winnie was away.
    func catchUp() { fireDue() }

    // MARK: - System notifications

    private func sync() {
        armTimer()
        let now = Date()
        let pending = store.reminders.filter { $0.nextFire(after: now) != nil }
        center.removeAllPendingNotificationRequests()
        guard !pending.isEmpty else { return }
        Task {
            guard await authorized() else { return onPermissionDenied() }
            for reminder in pending {
                for (suffix, trigger) in Self.triggers(for: reminder) {
                    let content = UNMutableNotificationContent()
                    content.title = "Винни напоминает"
                    content.body = reminder.title
                    content.sound = .default
                    let request = UNNotificationRequest(identifier: reminder.id.uuidString + suffix,
                                                        content: content, trigger: trigger)
                    try? await center.add(request)
                }
            }
        }
    }

    private func authorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    private static func triggers(for reminder: Reminder) -> [(String, UNCalendarNotificationTrigger)] {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: reminder.fireAt)
        func repeating(_ components: DateComponents) -> UNCalendarNotificationTrigger {
            UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        }
        let exact = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireAt)
        // A repeating trigger has no start date: «daily at 9, from Monday» would already fire tomorrow. Until the
        // first occurrence has passed, only that one is scheduled; `fireDue` re-syncs and the repeat takes over.
        if reminder.repeats == .none || reminder.fireAt > Date() {
            return [("", UNCalendarNotificationTrigger(dateMatching: exact, repeats: false))]
        }
        switch reminder.repeats {
        case .none:
            return []
        case .daily:
            return [("", repeating(time))]
        case .weekdays:
            // Calendar weekdays 2...6 are Monday to Friday.
            return (2...6).map { weekday in
                var components = time
                components.weekday = weekday
                return ("-\(weekday)", repeating(components))
            }
        case .weekly:
            var components = time
            components.weekday = calendar.component(.weekday, from: reminder.fireAt)
            return [("", repeating(components))]
        case .monthly:
            var components = time
            components.day = calendar.component(.day, from: reminder.fireAt)
            return [("", repeating(components))]
        }
    }

    // MARK: - In-app timer

    private func armTimer() {
        timer?.invalidate()
        let now = Date()
        guard let next = store.reminders.compactMap({ $0.nextFire(after: now) }).min() else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDue() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fireDue() {
        let now = Date()
        // Everything that came due since the last look, including while the Mac slept.
        let due = store.reminders.filter { reminder in
            guard let fire = reminder.nextFire(after: lastCheck) else { return false }
            return fire <= now
        }
        lastCheck = now
        due.forEach(onFire)
        // Not just the timer: a repeating reminder whose first occurrence just passed now gets its repeating trigger.
        sync()
    }

    @objc private func didWake() { fireDue() }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even when Winnie's chat is the active window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { onNotificationClicked() }
    }
}
