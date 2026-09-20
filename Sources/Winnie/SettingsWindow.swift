import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onShortcutChange: (Shortcut) -> Void
    var onScaleChange: (Double) -> Void

    @State private var apiKey = Keychain.loadAPIKey()
    @State private var saved = false
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("Claude API") {
                SecureField("API-ключ", text: $apiKey, prompt: Text("sk-ant-…"))
                HStack {
                    Button("Сохранить") {
                        Keychain.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        saved = true
                    }
                    if saved { Text("Сохранено в Связке ключей").foregroundStyle(.secondary) }
                    Spacer()
                    Link("Получить ключ", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
            }
            Section("Винни") {
                HStack {
                    Text("Размер")
                    Slider(value: $settings.petScale, in: AppSettings.petScaleRange, step: 0.05)
                    Text("\(Int((settings.petScale * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                    Button("Сброс") { settings.petScale = 1 }
                        .disabled(settings.petScale == 1)
                }
            }
            Section("Шорткат") {
                HStack {
                    Text("Показать / спрятать Винни")
                    Spacer()
                    Button(isRecording ? "Нажми сочетание…" : settings.shortcut.display) {
                        isRecording ? stopRecording() : startRecording()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 330)
        .onChange(of: settings.petScale) { _, scale in onScaleChange(scale) }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let shortcut = Shortcut(event: event) {
                settings.shortcut = shortcut
                onShortcutChange(shortcut)
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let onShortcutChange: (Shortcut) -> Void
    private let onScaleChange: (Double) -> Void

    init(settings: AppSettings, onShortcutChange: @escaping (Shortcut) -> Void,
         onScaleChange: @escaping (Double) -> Void) {
        self.settings = settings
        self.onShortcutChange = onShortcutChange
        self.onScaleChange = onScaleChange
    }

    func show() {
        if window == nil {
            let view = SettingsView(settings: settings, onShortcutChange: onShortcutChange,
                                    onScaleChange: onScaleChange)
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Настройки Винни"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 440, height: 330))
            window.center()
            self.window = window
        }
        // An accessory app has to be brought forward by hand for a regular window.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
