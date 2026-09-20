import MarkdownUI
import SwiftUI
import WinnieCore

struct ChatView: View {
    @ObservedObject var controller: ChatController
    @ObservedObject var store: ChatStore
    @FocusState private var inputFocused: Bool
    enum PendingDeletion { case current, all }

    @State private var pendingDeletion: PendingDeletion?

    init(controller: ChatController, store: ChatStore, pendingDeletion: PendingDeletion? = nil) {
        self.controller = controller
        self.store = store
        _pendingDeletion = State(initialValue: pendingDeletion)
    }

    private let bottomID = "bottom"

    /// Three tabs, a labelled button and three icons do not all fit the default width; below
    /// this the «+» button drops its label instead of colliding with the tabs.
    @State private var isNarrow = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            switch controller.tab {
            case .chat:
                if let pendingDeletion { deletionConfirmation(pendingDeletion) } else { sessionPicker }
                Hairline()
                messages
                Hairline()
                input
            case .events:
                EventsView(store: controller.reminders)
            case .notes:
                NotesView(controller: controller, notes: controller.notes)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in isNarrow = width < 470 }
        })
        .overlay(alignment: .top) { toast }
        .onChange(of: controller.focusToken, initial: true) { inputFocused = true }
    }

    // MARK: - Header

    /// Top floor: new dialog on the left, tabs dead centre, minimise on the right.
    private var header: some View {
        ZStack {
            // Centred on the panel itself, not on the space the side buttons leave over.
            Picker("", selection: $controller.tab) {
                Text("Chat").tag(ChatTab.chat)
                Text("Events").tag(ChatTab.events)
                Text("Notes").tag(ChatTab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            HStack {
                // The «+» makes whatever the current tab holds: a dialog, or a note.
                Button { controller.tab == .notes ? controller.newNote() : controller.newChat() } label: {
                    Label(controller.tab == .notes ? "New note" : "New dialog", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .labelStyle(CompactLabelStyle(showsTitle: !isNarrow))
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(controller.tab == .notes ? "Новая заметка" : "Новый чат (⌘N)")

                Spacer()

                if controller.tab == .chat, !(store.current?.isEmpty ?? true) {
                    HeaderButton(symbol: "trash", help: "Удалить этот чат") { pendingDeletion = .current }
                }
                HeaderButton(symbol: "gearshape", help: "Настройки") { controller.openSettings() }
                HeaderButton(symbol: "xmark", help: "Закрыть чат (Esc)") { controller.minimize() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    /// Replaces the picker row while asking. Inline rather than an alert: a modal would take
    /// key status from the panel, which is this chat's cue to close.
    private func deletionConfirmation(_ deletion: PendingDeletion) -> some View {
        HStack(spacing: 8) {
            Text(deletion == .all ? "Удалить все чаты (\(store.sessions.filter { !$0.isEmpty }.count))?" : "Удалить этот чат?")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Отмена") { pendingDeletion = nil }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button {
                deletion == .all ? controller.deleteAllChats() : controller.deleteCurrent()
                pendingDeletion = nil
            } label: {
                Text("Удалить")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.red.opacity(0.08))
    }

    /// Second floor, Chat tab only: the whole width goes to the chat's name.
    private var sessionPicker: some View {
        Menu {
            // An inline picker, not plain buttons: macOS then draws its own checkmark next to the current chat.
            Picker("", selection: Binding(get: { store.currentID }, set: { id in id.map(controller.select) })) {
                ForEach(store.sortedSessions) { session in
                    Text(session.title ?? "Новый чат").tag(Optional(session.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Удалить этот чат", role: .destructive) { pendingDeletion = .current }
            Button(role: .destructive) { pendingDeletion = .all } label: {
                Label("Удалить все чаты…", systemImage: "trash")
            }
        } label: {
            // Icon, name and caret travel together as one centred group; a long name truncates in place.
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(store.current?.title ?? "Новый чат")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    // MARK: - Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let session = store.current, !session.isEmpty {
                        // The system's own abbreviated style, so it follows the Mac's language, region and 12/24-hour setting.
                        Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(store.current?.messages ?? []) { message in
                        MessageRow(message: message, isStreaming: controller.isStreaming)
                    }
                    if let status = controller.searchStatus {
                        Label(status, systemImage: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(12)
            }
            .onChange(of: store.current?.messages.last?.text) { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onChange(of: store.current?.messages.count) { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onChange(of: store.currentID, initial: true) { proxy.scrollTo(bottomID, anchor: .bottom) }
            .overlay {
                if store.current?.isEmpty ?? true {
                    Text("Спроси что-нибудь")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.visibleQuickActions.isEmpty { quickActions }
            if !controller.pendingImages.isEmpty { pendingStrip }
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Outline pills above the field; a tap sends the text as if it had been typed.
    /// The last one is a gear that opens the settings pane where these are edited.
    private var quickActions: some View {
        FlowLayout(spacing: 6) {
            ForEach(controller.visibleQuickActions) { action in
                Button { controller.run(action) } label: {
                    OutlinePill { Text(action.text).font(.system(size: 12)).lineLimit(1).padding(.horizontal, 11) }
                }
                .help(action.sendsImmediately ? "Отправить сразу" : "Подставить в поле ввода")
                .buttonStyle(.plain)
            }
            Button { controller.openQuickActionSettings() } label: {
                OutlinePill { Image(systemName: "gearshape").font(.system(size: 12)).frame(width: 26) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Настроить быстрые действия")
        }
        .padding(.top, 2)
    }

    private var pendingStrip: some View {
        HStack(spacing: 8) {
            ForEach(controller.pendingImages, id: \.self) { file in
                Thumbnail(file: file, height: 56)
                    .overlay(alignment: .topTrailing) {
                        Button { controller.removePending(file) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .help("Убрать скриншот")
                    }
            }
        }
        .padding(.top, 4)
    }

    private static let inputButtonSide: CGFloat = 24

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(controller.isListening ? "Слушаю…" : "Сообщение", text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { controller.send() }
                // As tall as the buttons, so one line of text centres on them; with more
                // lines the row's bottom alignment keeps the buttons by the last line.
                .frame(minHeight: Self.inputButtonSide)

            Button { controller.toggleListening() } label: {
                Image(systemName: controller.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 20))
                    .symbolEffect(.pulse, isActive: controller.isListening)
                    .frame(width: Self.inputButtonSide, height: Self.inputButtonSide)
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.isListening ? Color.red : Color.secondary)
            .disabled(controller.isStreaming)
            .help(controller.isListening ? "Закончить и отправить" : "Спросить голосом")

            Button { controller.requestCapture() } label: {
                Image(systemName: "camera.circle.fill")
                    .font(.system(size: 20))
                    .frame(width: Self.inputButtonSide, height: Self.inputButtonSide)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(controller.isStreaming || controller.isListening)
            .help("Скриншот области экрана")

            Button {
                controller.isStreaming ? controller.stop() : controller.send()
            } label: {
                Image(systemName: controller.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .frame(width: Self.inputButtonSide, height: Self.inputButtonSide)
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.canSend || controller.isStreaming ? Color.accentColor : Color.secondary.opacity(0.5))
            .disabled(!controller.canSend && !controller.isStreaming)
        }
    }

    @ViewBuilder private var toast: some View {
        if let message = controller.toast {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thickMaterial, in: Capsule())
                .padding(.top, 46)
                .transition(.opacity)
        }
    }
}

private struct OutlinePill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(height: 26)
            .fixedSize()
            // A rounded rectangle with a half-height radius: `Capsule` strokes left stray
            // arcs at both ends when rasterised.
            .background(RoundedRectangle(cornerRadius: 13, style: .circular).strokeBorder(Color.primary.opacity(0.28), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 13))
    }
}

/// Lays children out left to right and wraps to a new line when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in arrange(subviews, width: bounds.width).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}

/// A one-pixel rule: lighter than `Divider`, which reads as a border on a white panel.
/// Icon and title, or just the icon when space is short.
private struct CompactLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}

struct Hairline: View {
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1 / scale)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(message.images, id: \.self) { Thumbnail(file: $0, height: 120) }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty && isStreaming {
                    ProgressView().controlSize(.small)
                } else if message.isError {
                    Label(message.text, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    Markdown(message.text)
                        .markdownTheme(.winnie)
                        .textSelection(.enabled)
                }
                let links = message.isError ? [] : LinkExtractor.allLinks(for: message)
                if !links.isEmpty { SourceList(sources: links) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Thumbnail: View {
    let file: String
    let height: CGFloat

    var body: some View {
        if let image = ImageStore.image(for: file) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 240, maxHeight: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }
}

private struct SourceList: View {
    let sources: [Source]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sources.prefix(8).enumerated()), id: \.offset) { index, source in
                SourceRow(index: index + 1, source: source)
            }
        }
        .padding(.top, 2)
    }
}

/// A link under an answer. Hovering reveals a Copy action, so the address can be
/// taken without opening the page.
private struct SourceRow: View {
    let index: Int
    let source: Source

    @State private var isHovering = false
    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 6) {
            if let url = URL(string: source.url) {
                Link(destination: url) {
                    Text("\(index). \(source.title)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(source.url)
            }
            Spacer(minLength: 0)
            if isHovering || justCopied {
                Button(action: copy) {
                    Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Скопировать ссылку")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source.url, forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            justCopied = false
        }
    }
}

extension Theme {
    /// GitHub-style rendering scaled down for a narrow popover.
    @MainActor static let winnie = Theme.gitHub
        .text {
            FontSize(13)
            BackgroundColor(nil)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
        }
        .heading1 { configuration in
            configuration.label.markdownTextStyle { FontSize(16); FontWeight(.semibold) }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label.markdownTextStyle { FontSize(15); FontWeight(.semibold) }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label.markdownTextStyle { FontSize(14); FontWeight(.semibold) }
                .markdownMargin(top: 6, bottom: 4)
        }
}
