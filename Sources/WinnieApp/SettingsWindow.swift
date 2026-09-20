import AppKit
import SwiftUI
import WinnieCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var gmail: GmailAuth
    @ObservedObject var memory: MemoryStore
    var onShortcutChange: (Shortcut) -> Void
    var onVoiceShortcutChange: (Shortcut) -> Void
    var onNewVoiceShortcutChange: (Shortcut) -> Void
    var onVoicePreview: () -> Void
    var onScaleChange: (Double) -> Void

    /// Left empty on purpose: showing the stored key would mean reading the secret
    /// (and a macOS permission prompt) every time Settings opens.
    @State private var apiKey = ""
    private let hasStoredKey = Keychain.hasAPIKey
    @State private var saved = false
    @State private var googleClientID = ""
    @State private var googleClientSecret = ""
    private let hasGoogleClient = Keychain.has(.googleClientID)

    var body: some View {
        Form {
            Section("Claude API") {
                SecureField("API-ключ", text: $apiKey,
                            prompt: Text(hasStoredKey ? "Ключ сохранён — вставь новый, чтобы заменить" : "sk-ant-…"))
                HStack {
                    Button("Сохранить") {
                        Keychain.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        saved = true
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if saved { Text("Сохранено в Связке ключей").foregroundStyle(.secondary) }
                    Spacer()
                    Link("Получить ключ", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
            }
            Section {
                if gmail.isConnected {
                    HStack {
                        Label(gmail.address ?? "Gmail подключён", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Отключить") { gmail.disconnect() }
                    }
                } else {
                    TextField("Client ID", text: $googleClientID,
                              prompt: Text(hasGoogleClient ? "Сохранён — вставь новый, чтобы заменить" : "…apps.googleusercontent.com"))
                    SecureField("Client secret", text: $googleClientSecret, prompt: Text(hasGoogleClient ? "Сохранён" : "GOCSPX-…"))
                    HStack {
                        Button(gmail.isConnecting ? "Жду ответа в браузере…" : "Подключить Gmail") {
                            gmail.connect(clientID: googleClientID.isEmpty ? Keychain.load(.googleClientID) : googleClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                          clientSecret: googleClientSecret.isEmpty ? Keychain.load(.googleClientSecret) : googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .disabled(gmail.isConnecting)
                        if let error = gmail.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            } header: {
                Text("Почта (Gmail)")
            } footer: {
                Text("Только чтение. Нужен собственный OAuth-клиент типа «Desktop app» из Google Cloud.")
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
            Section {
                TextEditor(text: $settings.masterPrompt)
                    .font(.system(size: 12))
                    .frame(height: 190)
                    .scrollContentBackground(.hidden)
                HStack {
                    Text("Правила окна чата, поиск и дата добавляются сами.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Вернуть стандартный") { settings.masterPrompt = MasterPrompt.standard }
                        .disabled(settings.masterPrompt == MasterPrompt.standard)
                }
            } header: {
                Text("Мастер-промпт")
            } footer: {
                Text("Характер Винни и то, как он отвечает. Применяется со следующего сообщения.")
            }
            Section {
                if memory.notes.isEmpty {
                    Text("Пусто. Скажи Винни «запомни, что…» — и заметка появится здесь.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(memory.notes) { note in
                    HStack(alignment: .firstTextBaseline) {
                        Text(note.text).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { memory.delete(note.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Забыть")
                    }
                }
            } header: {
                Text("Память Винни")
            } footer: {
                Text("Эти заметки Винни дописывает к промпту сам, когда ты просишь что-то запомнить. Твой мастер-промпт он не меняет.")
            }
            Section {
                Picker("Голос", selection: $settings.voiceIdentifier) {
                    Text("Авто — лучший установленный").tag("")
                    ForEach(Speaker.russianVoices(), id: \.identifier) { voice in
                        Text(Speaker.label(for: voice)).tag(voice.identifier)
                    }
                }
                HStack {
                    Text("Тон")
                    Slider(value: $settings.voicePitch, in: AppSettings.voicePitchRange, step: 0.02)
                    Text(String(format: "%.2f", settings.voicePitch)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Темп")
                    Slider(value: $settings.voiceRate, in: AppSettings.voiceRateRange, step: 0.01)
                    Text(String(format: "%.2f", settings.voiceRate)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Button("Прослушать") { onVoicePreview() }
                    Button("Как в мультике") { settings.voicePitch = 1.22; settings.voiceRate = 0.56 }
                    Button("Обычный") { settings.voicePitch = 1.0; settings.voiceRate = 0.52 }
                    Spacer()
                    Button("Скачать голоса…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
                    }
                }
            } header: {
                Text("Звучание")
            } footer: {
                Text("Улучшенные и премиум-голоса бесплатны: Системные настройки → Универсальный доступ → Устный контент → Системный голос → Управлять голосами → Русский.")
            }
            Section("Голос") {
                Toggle("Отвечать вслух на голосовые вопросы", isOn: $settings.speaksReplies)
                Toggle("Проговаривать напоминания вслух", isOn: $settings.speaksReminders)
                ShortcutRecorder(title: "Спросить голосом", shortcut: $settings.voiceShortcut) {
                    settings.isFree($0, for: \.voiceShortcut)
                }
                ShortcutRecorder(title: "Новый диалог голосом", shortcut: $settings.newVoiceShortcut) {
                    settings.isFree($0, for: \.newVoiceShortcut)
                }
            }
            Section("Шорткат") {
                ShortcutRecorder(title: "Показать / спрятать Винни", shortcut: $settings.shortcut) {
                    settings.isFree($0, for: \.shortcut)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        .onChange(of: settings.shortcut) { _, shortcut in onShortcutChange(shortcut) }
        .onChange(of: settings.voiceShortcut) { _, shortcut in onVoiceShortcutChange(shortcut) }
        .onChange(of: settings.newVoiceShortcut) { _, shortcut in onNewVoiceShortcutChange(shortcut) }
        .onChange(of: settings.petScale) { _, scale in onScaleChange(scale) }
    }
}

/// A button that captures the next modifier+key press as a shortcut.
private struct ShortcutRecorder: View {
    let title: String
    @Binding var shortcut: Shortcut
    /// False for a combination another Winnie shortcut already uses.
    let isFree: (Shortcut) -> Bool

    @State private var isRecording = false
    @State private var isTaken = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if isTaken { Text("уже занято другим шорткатом").font(.caption).foregroundStyle(.red) }
            Button(isRecording ? "Нажми сочетание…" : shortcut.display) {
                isRecording ? stopRecording() : startRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        isTaken = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let recorded = Shortcut(event: event) {
                isTaken = !isFree(recorded)
                if !isTaken { shortcut = recorded }
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
    private let gmail: GmailAuth
    private let memory: MemoryStore
    private let onShortcutChange: (Shortcut) -> Void
    private let onVoiceShortcutChange: (Shortcut) -> Void
    private let onNewVoiceShortcutChange: (Shortcut) -> Void
    private let onVoicePreview: () -> Void
    private let onScaleChange: (Double) -> Void

    init(settings: AppSettings, gmail: GmailAuth, memory: MemoryStore, onShortcutChange: @escaping (Shortcut) -> Void,
         onVoiceShortcutChange: @escaping (Shortcut) -> Void,
         onNewVoiceShortcutChange: @escaping (Shortcut) -> Void,
         onVoicePreview: @escaping () -> Void,
         onScaleChange: @escaping (Double) -> Void) {
        self.settings = settings
        self.gmail = gmail
        self.memory = memory
        self.onShortcutChange = onShortcutChange
        self.onVoiceShortcutChange = onVoiceShortcutChange
        self.onNewVoiceShortcutChange = onNewVoiceShortcutChange
        self.onVoicePreview = onVoicePreview
        self.onScaleChange = onScaleChange
    }

    func show() {
        if window == nil {
            let view = SettingsView(settings: settings, gmail: gmail, memory: memory, onShortcutChange: onShortcutChange,
                                    onVoiceShortcutChange: onVoiceShortcutChange,
                                    onNewVoiceShortcutChange: onNewVoiceShortcutChange,
                                    onVoicePreview: onVoicePreview,
                                    onScaleChange: onScaleChange)
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Настройки Винни"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 760))
            window.center()
            self.window = window
        }
        // An accessory app has to be brought forward by hand for a regular window.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
