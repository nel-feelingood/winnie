import MarkdownUI
import SwiftUI
import WinnieCore

/// The Notes tab: the list, or one note's page.
struct NotesView: View {
    @ObservedObject var controller: ChatController
    @ObservedObject var notes: NoteStore

    var body: some View {
        if let id = controller.openNoteID, let note = notes.notes.first(where: { $0.id == id }) {
            NotePage(note: note, controller: controller, notes: notes).id(id)
        } else {
            list
        }
    }

    private var list: some View {
        Group {
            if notes.notes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "note.text").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("Заметок пока нет").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Нажми «+ New note» или скажи Винни: «запиши…»")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(notes.sorted) { note in
                            NoteRow(note: note,
                                    onOpen: { controller.openNoteID = note.id },
                                    onPin: { notes.update(note.id, isPinned: !note.isPinned) })
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let onOpen: () -> Void
    let onPin: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                }
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Always visible on a pinned note; otherwise offered on hover.
            if note.isPinned || isHovering {
                Button(action: onPin) {
                    Image(systemName: note.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(note.isPinned ? Color.accentColor : Color.secondary)
                .help(note.isPinned ? "Открепить" : "Закрепить")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
    }
}

private struct NotePage: View {
    let note: Note
    @ObservedObject var controller: ChatController
    @ObservedObject var notes: NoteStore

    @State private var title: String
    @State private var text: String
    @State private var isEditing: Bool
    @State private var confirmsDelete = false
    @State private var justCopied = false
    @State private var saveTask: Task<Void, Never>?

    init(note: Note, controller: ChatController, notes: NoteStore) {
        self.note = note
        self.controller = controller
        self.notes = notes
        _title = State(initialValue: note.title)
        _text = State(initialValue: note.body)
        // A brand-new note is for writing; an existing one opens rendered, for reading.
        _isEditing = State(initialValue: note.title.isEmpty && note.body.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            if confirmsDelete { deleteConfirmation } else { toolbar }
            Hairline()
            TextField("Заголовок", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            content
            Text("Last edit: \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .onChange(of: title) { scheduleSave() }
        .onChange(of: text) { scheduleSave() }
        // The bear may edit the open note from the chat; take his text unless the user is mid-edit.
        .onChange(of: note.body) { _, body in if !isEditing { text = body } }
        .onChange(of: note.title) { _, newTitle in if !isEditing { title = newTitle } }
        .onDisappear { save() }
    }

    @ViewBuilder private var content: some View {
        if isEditing {
            MarkdownEditor(text: $text) { image in
                guard let data = NoteImages.jpeg(from: image), let path = notes.addImage(data, fileExtension: "jpg") else { return nil }
                return "![](\(path))\n"
            }
            .padding(.horizontal, 4)
        } else {
            ScrollView {
                Group {
                    if text.isEmpty {
                        Text("Пусто. Дважды кликни, чтобы писать.").font(.system(size: 13)).foregroundStyle(.tertiary)
                    } else {
                        // Task lines are drawn as real controls, each tied to its line of the text;
                        // everything between them is ordinary rendered Markdown.
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(TaskList.segments(of: text)) { segment in
                                switch segment {
                                case .markdown(_, let chunk):
                                    Markdown(chunk, imageBaseURL: notes.directory)
                                        .markdownTheme(.winnie)
                                        .markdownImageProvider(LocalImageProvider())
                                        .textSelection(.enabled)
                                case .task(let line, let indent, let isDone, let label):
                                    TaskRow(isDone: isDone, label: label, indent: indent) {
                                        text = TaskList.toggling(line: line, in: text)
                                        save()
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { isEditing = true }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                save()
                controller.openNoteID = nil
            } label: {
                Label("Notes", systemImage: "chevron.left").font(.system(size: 12, weight: .medium)).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("К списку заметок")

            Spacer()

            NoteBarButton(symbol: isEditing ? "eye" : "pencil", help: isEditing ? "Просмотр" : "Править (или двойной клик по тексту)") {
                save()
                isEditing.toggle()
            }
            NoteBarButton(symbol: note.isPinned ? "pin.fill" : "pin", help: note.isPinned ? "Открепить" : "Закрепить", isActive: note.isPinned) {
                notes.update(note.id, isPinned: !note.isPinned)
            }
            NoteBarButton(symbol: justCopied ? "checkmark" : "doc.on.doc", help: "Скопировать текст") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(title.isEmpty ? text : "# \(title)\n\n\(text)", forType: .string)
                justCopied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); justCopied = false }
            }
            NoteBarButton(symbol: "bubble.left.and.text.bubble.right", help: "Обсудить заметку в новом чате") {
                save()
                controller.startChat(about: note)
            }
            NoteBarButton(symbol: "trash", help: "Удалить заметку") { confirmsDelete = true }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var deleteConfirmation: some View {
        HStack(spacing: 8) {
            Text("Удалить заметку?").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button("Отмена") { confirmsDelete = false }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            Button {
                saveTask?.cancel()
                controller.openNoteID = nil
                notes.delete(note.id)
            } label: {
                Text("Удалить").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 22).background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.red.opacity(0.08))
    }

    /// A file write per keystroke would be wasteful; wait for a pause in typing.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { save() }
        }
    }

    private func save() {
        saveTask?.cancel()
        guard notes.notes.contains(where: { $0.id == note.id }) else { return }
        // An untouched blank note is not worth keeping.
        if title.isEmpty, text.isEmpty, note.title.isEmpty, note.body.isEmpty { return }
        notes.update(note.id, title: title, body: text)
    }
}

/// One «- [ ]» line in the rendered note. The box toggles; the label is still Markdown.
private struct TaskRow: View {
    let isDone: Bool
    let label: String
    let indent: Int
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDone ? "Снять отметку" : "Отметить")
            Markdown(label)
                .markdownTheme(.winnie)
                .opacity(isDone ? 0.55 : 1)
                .strikethrough(isDone)
        }
        .padding(.leading, CGFloat(indent) * 18 + 4)
    }
}

private struct NoteBarButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .help(help)
    }
}

/// Shows pictures stored beside the notes; MarkdownUI's default provider only fetches over the network.
private struct LocalImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        if let url, url.isFileURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: min(image.size.width, 520))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Label("картинка недоступна", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum NoteImages {
    /// Long edge capped: a Retina screenshot is far larger than a note needs.
    private static let maxEdge: CGFloat = 1600

    static func jpeg(from image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let ratio = min(1, maxEdge / max(width, height))
        let size = NSSize(width: (width * ratio).rounded(), height: (height * ratio).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()                     // JPEG has no alpha; transparent areas would turn black
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
