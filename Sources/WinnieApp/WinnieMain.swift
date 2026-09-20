import AppKit

public enum WinnieMain {
    /// Entry point of the app; the executable target is only a shell around it, so the
    /// same code can also be driven by the snapshot tool.
    public static func run() {
        // Top-level code runs on the main thread, which is what AppKit requires.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            // Menu-bar resident: no Dock icon, no app switcher entry.
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
