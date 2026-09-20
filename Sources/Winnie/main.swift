import AppKit

// Top-level code runs on the main thread, which is what AppKit requires.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu-bar resident: no Dock icon, no app switcher entry.
    app.setActivationPolicy(.accessory)
    app.run()
}
