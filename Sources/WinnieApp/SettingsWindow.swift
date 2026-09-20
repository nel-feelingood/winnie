import AppKit
import SwiftUI
import WinnieCore

/// Everything the settings panes can ask the rest of the app to do.
struct SettingsActions {
    var onShortcutChange: (Shortcut) -> Void
    var onNewVoiceShortcutChange: (Shortcut) -> Void
    var onVoicePreview: () -> Void
    var onScaleChange: (Double) -> Void
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case winnie, quick, api, usage, voice, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .winnie: "Винни"
        case .quick: "Быстрые действия"
        case .api: "API"
        case .usage: "Модель и расходы"
        case .voice: "Голос"
        case .shortcuts: "Шорткаты"
        }
    }

    var symbol: String {
        switch self {
        case .winnie: "pawprint"
        case .quick: "bolt"
        case .api: "link"
        case .usage: "chart.bar"
        case .voice: "waveform"
        case .shortcuts: "keyboard"
        }
    }
}

/// Lets the rest of the app open Settings on a particular pane, even when the window already exists.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane = SettingsPane.winnie
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var gmail: GmailAuth
    @ObservedObject var memory: MemoryStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var mcp: MCPAuth
    let actions: SettingsActions
    @ObservedObject var navigation: SettingsNavigation

    private var pane: SettingsPane { navigation.pane }

    /// Left empty on purpose: showing the stored key would mean reading the secret
    /// (and a macOS permission prompt) every time Settings opens.
    @State private var apiKey = ""
    private let hasStoredKey = Keychain.hasAPIKey
    @State private var saved = false
    @State private var googleClientID = ""
    @State private var googleClientSecret = ""
    private let hasGoogleClient = Keychain.has(.googleClientID)

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: Binding(get: { navigation.pane }, set: { navigation.pane = $0 ?? navigation.pane })) { item in
                Label {
                    Text(item.title)
                } icon: {
                    // Winnie's own pane wears his face, the same silhouette as in the menu bar.
                    if item == .winnie, let face = WinnieIcon.template(side: 16) {
                        Image(nsImage: face).renderingMode(.template)
                    } else {
                        Image(systemName: item.symbol)
                    }
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            Form {
                switch pane {
                case .winnie: winniePane
                case .quick: quickPane
                case .api: apiPane
                case .usage: usagePane
                case .voice: voicePane
                case .shortcuts: shortcutsPane
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 560)
        .onChange(of: settings.petScale) { _, scale in actions.onScaleChange(scale) }
        .onChange(of: settings.shortcut) { _, shortcut in actions.onShortcutChange(shortcut) }
        .onChange(of: settings.newVoiceShortcut) { _, shortcut in actions.onNewVoiceShortcutChange(shortcut) }
    }

    // MARK: - Винни

    @ViewBuilder private var winniePane: some View {
        Section("Размер") {
            HStack {
                Slider(value: $settings.petScale, in: AppSettings.petScaleRange, step: 0.05)
                Text("\(Int((settings.petScale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                Button("Сброс") { settings.petScale = 1 }.disabled(settings.petScale == 1)
            }
        }
        Section {
            TextEditor(text: $settings.masterPrompt)
                .font(.system(size: 12))
                .frame(height: 190)
                .scrollContentBackground(.hidden)
            HStack {
                Text("Правила окна чата, поиск и дата добавляются сами.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Вернуть стандартный") { settings.masterPrompt = MasterPrompt.standard }
                    .disabled(settings.masterPrompt == MasterPrompt.standard)
            }
        } header: {
            Text("Мастер-промпт")
        } footer: {
            Footnote("Характер Винни и то, как он отвечает. Написан по-английски ради экономии токенов; править и дописывать можно на любом языке. Применяется со следующего сообщения.")
        }
        Section {
            if memory.notes.isEmpty {
                Text("Пусто. Скажи Винни «запомни, что…» — и заметка появится здесь.").font(.callout).foregroundStyle(.secondary)
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
            Text("Память")
        } footer: {
            Footnote("Эти заметки Винни дописывает к промпту сам, когда ты просишь что-то запомнить. Мастер-промпт он не меняет.")
        }
    }

    // MARK: - Быстрые действия

    @ViewBuilder private var quickPane: some View {
        Section {
            ForEach(settings.quickActions.indices, id: \.self) { index in
                HStack {
                    TextField("", text: Binding(get: { settings.quickActions.indices.contains(index) ? settings.quickActions[index] : "" },
                                                set: { if settings.quickActions.indices.contains(index) { settings.quickActions[index] = $0 } }),
                              prompt: Text("Например: Переведи текст из буфера"))
                        .labelsHidden()
                    Button { settings.quickActions.remove(at: index) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Удалить")
                }
            }
            HStack {
                Button("Добавить") { settings.quickActions.append("") }
                Spacer()
                Button("Вернуть стандартные") { settings.quickActions = AppSettings.defaultQuickActions }
                    .disabled(settings.quickActions == AppSettings.defaultQuickActions)
            }
        } header: {
            Text("Кнопки в пустом чате")
        } footer: {
            Footnote("Показываются над полем ввода, пока в чате нет сообщений. Нажатие сразу отправляет текст Винни. Короткие подписи помещаются лучше.")
        }
    }

    // MARK: - API

    @ViewBuilder private var apiPane: some View {
        claudeSection
        mailSection
        appsSection
    }

    @ViewBuilder private var claudeSection: some View {
        Section {
            SecureField("Ключ", text: $apiKey, prompt: Text(hasStoredKey ? "Сохранён — вставь новый, чтобы заменить" : "sk-ant-…"))
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
        } header: {
            Text("Claude")
        } footer: {
            Footnote("Ключ Anthropic API. Хранится в Связке ключей.")
        }
    }

    // MARK: - Модель и расходы

    @ViewBuilder private var usagePane: some View {
        Section("Модель") {
            Picker("Отвечает", selection: $settings.model) {
                ForEach(ModelOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        Section {
            UsageRow(title: "Сегодня", totals: usage.totals(lastDays: 1))
            UsageRow(title: "7 дней", totals: usage.totals(lastDays: 7))
            UsageRow(title: "30 дней", totals: usage.totals(lastDays: 30))
            HStack {
                Link("Пополнить баланс", destination: URL(string: "https://console.anthropic.com/settings/billing")!)
                    .buttonStyle(.borderedProminent)
                Link("Usage в консоли", destination: URL(string: "https://console.anthropic.com/settings/usage")!)
                    .buttonStyle(.bordered)
                Spacer()
            }
        } header: {
            Text("Usage")
        } footer: {
            Footnote("Считает сам Винни по ответам API, с момента этой версии. Сумма — оценка по прайс-листу (токены, кеш, веб-поиск). Остаток на балансе API не сообщает: он виден только в консоли.")
        }
    }

    // MARK: - Голос

    @ViewBuilder private var voicePane: some View {
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
                Button("Прослушать") { actions.onVoicePreview() }
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
            Footnote("Улучшенные и премиум-голоса бесплатны: Системные настройки → Универсальный доступ → Устный контент → Системный голос → Управлять голосами → Русский.")
        }
        Section("Когда говорить") {
            Toggle("Отвечать вслух на голосовые вопросы", isOn: $settings.speaksReplies)
            Toggle("Проговаривать напоминания вслух", isOn: $settings.speaksReminders)
        }
    }

    // MARK: - Шорткаты

    @ViewBuilder private var shortcutsPane: some View {
        Section {
            ShortcutRecorder(title: "Показать / спрятать Винни", shortcut: $settings.shortcut) {
                settings.isFree($0, for: \.shortcut)
            }
            ShortcutRecorder(title: "Новый диалог голосом", shortcut: $settings.newVoiceShortcut) {
                settings.isFree($0, for: \.newVoiceShortcut)
            }
        } header: {
            Text("Глобальные")
        } footer: {
            Footnote("Работают из любого приложения. Нажми на сочетание, затем набери новое — с ⌘, ⌥ или ⌃.")
        }
        Section("В окне чата") {
            LabeledContent("Новый диалог", value: "⌘N")
            LabeledContent("Свернуть чат", value: "Esc или ⌘W")
            LabeledContent("Вставить скриншот из буфера", value: "⌘V")
            LabeledContent("Отправить", value: "↩")
            LabeledContent("Новая строка", value: "⌥↩")
        }
    }

    @ViewBuilder private var mailSection: some View {
        Section {
            if gmail.isConnected {
                HStack {
                    Label(gmail.address ?? "Gmail подключён", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
            Text("Почта · Gmail")
        } footer: {
            Footnote("Только чтение. Нужен собственный OAuth-клиент типа «Desktop app» из Google Cloud. Пока проект в статусе Testing, Google просит входить заново раз в 7 дней.")
        }
    }
}

extension SettingsView {
    @ViewBuilder var appsSection: some View {
        Section {
            ForEach($settings.connectors) { $connector in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connector.name)
                            Text(connector.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        connectorStatus(connector)
                        Toggle("", isOn: $connector.isEnabled).labelsHidden()
                        Button { settings.removeConnector(connector) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Удалить подключение и его токен")
                    }
                    if let error = mcp.errors[connector.id] { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            NewConnectorForm { name, url, token in
                let connector = AppConnector(name: name, url: url)
                settings.connectors.append(connector)
                if token.isEmpty {
                    // No token given: if the server speaks OAuth, go straight to the browser sign-in.
                    Task { if let serverURL = URL(string: url), await mcp.usesOAuth(serverURL) { mcp.signIn(connector) } }
                } else {
                    Keychain.save(token, named: connector.secretName)
                }
            }
        } header: {
            Text("MCP · приложения")
        } footer: {
            Footnote("Любое приложение с удалённым MCP-сервером (https://…). Если сервер входит через OAuth, как Bridge, оставь токен пустым — откроется вход в браузере, токены обновляются сами. Claude получает список инструментов приложения сам; перед действием, которое что-то меняет, Винни спросит подтверждение. Токены хранятся в Связке ключей и уходят только в Anthropic API вместе с запросом.")
        }
    }

    @ViewBuilder private func connectorStatus(_ connector: AppConnector) -> some View {
        // `revision` is read so the row refreshes once a sign-in finishes.
        let _ = mcp.revision
        if mcp.connecting == connector.id {
            Text("жду входа в браузере…").font(.caption).foregroundStyle(.secondary)
        } else {
            switch mcp.state(of: connector) {
            case .signedIn:
                Label("вход выполнен", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                Button("Войти заново") { mcp.signIn(connector) }.controlSize(.small)
            case .token:
                Text("токен").font(.caption).foregroundStyle(.secondary)
            case .open:
                Button("Войти") { mcp.signIn(connector) }.controlSize(.small)
            }
        }
    }
}

private struct NewConnectorForm: View {
    let onAdd: (_ name: String, _ url: String, _ token: String) -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme == "https"
    }

    var body: some View {
        TextField("Название", text: $name, prompt: Text("Bridge"))
        TextField("Адрес MCP-сервера", text: $url, prompt: Text("https://mcp.bridgeapp.ai/mcp"))
        SecureField("Токен", text: $token, prompt: Text("пусто — вход через браузер"))
        HStack {
            Button("Подключить") {
                onAdd(name.trimmingCharacters(in: .whitespaces), url.trimmingCharacters(in: .whitespaces),
                      token.trimmingCharacters(in: .whitespacesAndNewlines))
                name = ""; url = ""; token = ""
            }
            .disabled(!isValid)
            if !url.isEmpty, !isValid { Text("нужен адрес, начинающийся с https://").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Section footers read as explanations, so they align with the text they explain.
private struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageRow: View {
    let title: String
    let totals: UsageTotals

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(totals.requests) запр. · \(Self.compact(totals.input)) вх. · \(Self.compact(totals.output)) вых. · \(totals.searches) поиск.")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Text(String(format: "≈ $%.2f", totals.cost)).monospacedDigit().frame(width: 72, alignment: .trailing)
        }
    }

    static func compact(_ value: Int) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000)
            : value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : String(value)
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
    private let navigation = SettingsNavigation()
    private let makeView: (SettingsNavigation) -> SettingsView

    init(settings: AppSettings, gmail: GmailAuth, memory: MemoryStore, usage: UsageStore, mcp: MCPAuth,
         actions: SettingsActions) {
        makeView = { navigation in
            SettingsView(settings: settings, gmail: gmail, memory: memory, usage: usage, mcp: mcp, actions: actions,
                         navigation: navigation)
        }
    }

    /// With no pane given, the window reopens where it was left.
    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Настройки Винни"
            window.contentView = NSHostingView(rootView: makeView(navigation))
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 720, height: 560))
            window.center()
            self.window = window
        }
        // An accessory app has to be brought forward by hand for a regular window.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
