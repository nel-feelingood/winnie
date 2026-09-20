import MarkdownUI
import SwiftUI
import WinnieCore

struct ChatView: View {
    @ObservedObject var controller: ChatController
    @ObservedObject var store: ChatStore
    @FocusState private var inputFocused: Bool

    private let bottomID = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            switch controller.tab {
            case .chat:
                sessionPicker
                Hairline()
                messages
                Hairline()
                input
            case .events:
                EventsView(store: controller.reminders)
            }
        }
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
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack {
                Button { controller.newChat() } label: {
                    Label("New dialog", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Новый чат (⌘N)")

                Spacer()

                HeaderButton(symbol: "minus", help: "Свернуть чат (Esc)") { controller.minimize() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    /// Second floor, Chat tab only: the whole width goes to the chat's name.
    private var sessionPicker: some View {
        Menu {
            ForEach(store.sortedSessions) { session in
                Button {
                    controller.select(session.id)
                } label: {
                    let title = session.title ?? "Новый чат"
                    session.id == store.currentID ? Label(title, systemImage: "checkmark") : Label(title, systemImage: "")
                }
            }
            Divider()
            Button("Удалить этот чат", role: .destructive) { controller.deleteCurrent() }
        } label: {
            HStack(spacing: 8) {
                Text(store.current?.title ?? "Новый чат")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
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
            if !controller.pendingImages.isEmpty { pendingStrip }
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

/// A one-pixel rule: lighter than `Divider`, which reads as a border on a white panel.
private struct Hairline: View {
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
