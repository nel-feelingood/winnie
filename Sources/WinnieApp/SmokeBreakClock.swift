import AppKit

/// Fires once a day at 16:20 local time. One timer aimed at the next occurrence, re-armed
/// after it fires and after the Mac wakes; nothing runs in between.
@MainActor
final class SmokeBreakClock: NSObject {
    var onTime: () -> Void = {}
    private var timer: Timer?

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(arm), name: NSWorkspace.didWakeNotification, object: nil)
        // A time-zone or clock change moves 16:20 too.
        NotificationCenter.default.addObserver(self, selector: #selector(arm), name: .NSSystemClockDidChange, object: nil)
        arm()
    }

    @objc private func arm() {
        timer?.invalidate()
        guard let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 16, minute: 20),
                                                   matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onTime()
                self?.arm()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
