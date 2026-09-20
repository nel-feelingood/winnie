import AppKit
import SwiftUI
import WinnieCore

/// Everything the settings panes can ask the rest of the app to do.
struct SettingsActions {
    var onShortcutChange: (Shortcut) -> Void
    var onNewVoiceShortcutChange: (Shortcut) -> Void
    var onVoicePreview: () -> Void
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case winnie, behaviour, quick, api, mcp, usage, voice, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .winnie: "Винни"
        case .behaviour: "Поведение"
        case .quick: "Быстрые действия"
        case .api: "API"
        case .mcp: "MCP"
        case .usage: "Модель и расходы"
        case .voice: "Голос"
        case .shortcuts: "Шорткаты"
        }
    }

    var symbol: String {
        switch self {
        case .winnie: "pawprint"
        case .behaviour: "theatermasks"
        case .quick: "bolt"
        case .api: "link"
        case .mcp: "point.3.connected.trianglepath.dotted"
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
    @ObservedObject var telegram: TelegramBridge
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
                case .behaviour: behaviourPane
                case .quick: quickPane
                case .api: apiPane
                case .mcp: appsSection
                case .usage: usagePane
                case .voice: voicePane
                case .shortcuts: shortcutsPane
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: .infinity, minHeight: 440, idealHeight: 560, maxHeight: .infinity)
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

    // MARK: - Поведение

    /// One row per behaviour, each with its own explanation. New behaviours are added here.
    @ViewBuilder private var behaviourPane: some View {
        Section {
            BehaviourToggle(title: "16:20", isOn: $settings.smokeBreakEnabled,
                            description: "Каждый день в 16:20 Винни устраивает перекур. По просьбе в чате («16:20», «перекур») анимация играет в любое время, даже если тумблер выключен.")
            BehaviourToggle(title: "Сны", isOn: $settings.dreamsEnabled,
                            description: "Пока Винни спит, над ним раз в 10 секунд всплывает эмодзи: чаще то, что ему снится (мёд, женщины, трава, тачки, работа), иногда любой случайный.")
        }
    }

    // MARK: - Быстрые действия

    @ViewBuilder private var quickPane: some View {
        Section {
            ForEach($settings.quickActions) { $action in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("", text: $action.text, prompt: Text("Подпись на кнопке"))
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        // The caption is a separate Text: a labelled Toggle in a Form claims the whole row.
                        Text("сразу").font(.caption).foregroundStyle(.secondary)
                        Toggle("", isOn: $action.sendsImmediately)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("Включено — нажатие сразу отправляет инструкцию. Выключено — она подставляется в поле, и её можно дописать.")
                        // Arrows rather than drag and drop: reordering by drag is unreliable inside a macOS Form.
                        Button { moveQuickAction(action, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(settings.quickActions.first?.id == action.id)
                            .help("Выше")
                        Button { moveQuickAction(action, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(settings.quickActions.last?.id == action.id)
                            .help("Ниже")
                        Button { settings.quickActions.removeAll { $0.id == action.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Удалить")
                    }
                    TextField("", text: Binding(get: { action.instruction ?? "" }, set: { action.instruction = $0 }),
                              prompt: Text("Инструкция для Винни. Пусто — отправляется сама подпись"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...5)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button("Добавить") { settings.quickActions.append(QuickAction(text: "")) }
                Spacer()
                Button("Вернуть стандартные") { settings.quickActions = AppSettings.defaultQuickActions }
                    .disabled(settings.quickActions == AppSettings.defaultQuickActions)
            }
        } header: {
            Text("Кнопки в пустом чате")
        } footer: {
            Footnote("Показываются над полем ввода, пока в чате нет сообщений. У кнопки короткая подпись и полная инструкция: на кнопке видна подпись, Винни получает инструкцию. Пиши её так, чтобы она была понятна без контекста. Тумблер «сразу»: включён — нажатие отправляет; выключен — текст подставляется в поле, чтобы его дописать.")
        }
    }

    private func moveQuickAction(_ action: QuickAction, by offset: Int) {
        guard let index = settings.quickActions.firstIndex(where: { $0.id == action.id }) else { return }
        let target = index + offset
        guard settings.quickActions.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { settings.quickActions.swapAt(index, target) }
    }

    // MARK: - API

    @ViewBuilder private var apiPane: some View {
        claudeSection
        mailSection
        TelegramSection(telegram: telegram)
        customAPISection
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
            ShortcutRecorder(title: "Диктовка: включить / выключить", shortcut: $settings.newVoiceShortcut) {
                settings.isFree($0, for: \.newVoiceShortcut)
            }
        } header: {
            Text("Глобальные")
        } footer: {
            Footnote("Работают из любого приложения. «Диктовка» включает и выключает микрофон в текущем чате; закрытый чат сначала открывается. Новый диалог шорткат не создаёт. Нажми на сочетание, затем набери новое — с ⌘, ⌥ или ⌃.")
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
            Text("Приложения по MCP")
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

extension SettingsView {
    @ViewBuilder var customAPISection: some View {
        Section {
            ForEach($settings.customAPIs) { $api in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(api.name)
                            Text(api.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Toggle("", isOn: $api.isEnabled).labelsHidden()
                        Button { settings.removeAPI(api) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Удалить API и его ключ")
                    }
                    TextField("Заметки для Винни", text: $api.notes, prompt: Text("GET /tasks — мои задачи; GET /tasks/{id} — одна задача"), axis: .vertical)
                        .lineLimit(1...4)
                        .font(.callout)
                        .labelsHidden()
                    Toggle("Разрешить запросы, которые что-то меняют (POST, PUT, PATCH, DELETE)", isOn: $api.allowsWrites)
                        .font(.callout)
                }
                .padding(.vertical, 2)
            }
            NewAPIForm { api, key in
                Keychain.save(key, named: api.secretName)
                settings.customAPIs.append(api)
            }
        } header: {
            Text("Свои API")
        } footer: {
            Footnote("Обычный HTTP-API другого приложения. Винни ходит только на указанный адрес и по умолчанию только читает (GET). В заметках опиши, какие эндпоинты есть: он пользуется ими, а не угадывает. Ключ хранится в Связке ключей и добавляется к запросам самим приложением — модель его не видит.")
        }
    }
}

private struct TelegramSection: View {
    @ObservedObject var telegram: TelegramBridge
    @State private var token = ""

    var body: some View {
        Section {
            switch telegram.status {
            case .off:
                SecureField("Токен бота", text: $token, prompt: Text("123456:ABC… от @BotFather"))
                Button("Подключить бота") {
                    telegram.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                    token = ""
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .connecting:
                Label("Подключаюсь к Telegram…", systemImage: "ellipsis.circle").foregroundStyle(.secondary)
                Button("Отключить") { telegram.disconnect() }
            case .waitingForCode:
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Отправь этот код своему боту в Telegram")
                        Text("Кто первым пришлёт код, тому бот и будет отвечать.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(telegram.pairingCode).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                }
                Button("Отключить") { telegram.disconnect() }
            case .connected(let name):
                HStack {
                    Label(name.isEmpty ? "Бот привязан" : "Бот отвечает: \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Отвязать") { telegram.unpair() }
                    Button("Отключить") { telegram.disconnect() }
                }
                Toggle("Присылать напоминания в Telegram", isOn: Binding(get: { telegram.forwardsReminders }, set: { telegram.forwardsReminders = $0 }))
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Отключить") { telegram.disconnect() }
            }
        } header: {
            Text("Telegram")
        } footer: {
            Footnote("Свой бот от @BotFather: пиши ему с телефона — отвечает Винни с этого мака, со всеми своими инструментами. Работает, пока Winnie запущен. Бот отвечает только одному чату — тому, что прислал код; остальным молчит. Токен хранится в Связке ключей.")
        }
    }
}

private struct NewAPIForm: View {
    let onAdd: (CustomAPI, _ key: String) -> Void

    @State private var name = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var header = "Authorization"
    @State private var scheme = "Bearer"

    private var isValid: Bool {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces))
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && url?.scheme == "https" && url?.host != nil
    }

    var body: some View {
        TextField("Название", text: $name, prompt: Text("Bridge API"))
        TextField("Базовый адрес", text: $baseURL, prompt: Text("https://api.example.com/v1"))
        SecureField("Ключ", text: $key, prompt: Text("если API его требует"))
        HStack {
            TextField("Заголовок", text: $header, prompt: Text("Authorization"))
            TextField("Схема", text: $scheme, prompt: Text("Bearer или пусто"))
        }
        HStack {
            Button("Добавить API") {
                onAdd(CustomAPI(name: name.trimmingCharacters(in: .whitespaces), baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                                authHeader: header.trimmingCharacters(in: .whitespaces), authScheme: scheme.trimmingCharacters(in: .whitespaces)),
                      key.trimmingCharacters(in: .whitespacesAndNewlines))
                name = ""; baseURL = ""; key = ""; header = "Authorization"; scheme = "Bearer"
            }
            .disabled(!isValid)
            if !baseURL.isEmpty, !isValid { Text("нужен адрес, начинающийся с https://").font(.caption).foregroundStyle(.secondary) }
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

/// A behaviour switch with its explanation right under its name.
private struct BehaviourToggle: View {
    let title: String
    @Binding var isOn: Bool
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 4)
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
         telegram: TelegramBridge, actions: SettingsActions) {
        makeView = { navigation in
            SettingsView(settings: settings, gmail: gmail, memory: memory, usage: usage, mcp: mcp, telegram: telegram,
                         actions: actions,
                         navigation: navigation)
        }
    }

    /// With no pane given, the window reopens where it was left.
    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Настройки Винни"
            window.contentView = NSHostingView(rootView: makeView(navigation))
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 720, height: 560))
            window.contentMinSize = NSSize(width: 640, height: 440)
            window.center()
            // Remembers the size and place the user gave it.
            window.setFrameAutosaveName("WinnieSettings")
            self.window = window
        }
        // An accessory app has to be brought forward by hand for a regular window.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
