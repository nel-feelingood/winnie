import AppKit

/// Screenshots attached to chats, stored as JPEG files next to `chats.json`.
enum ImageStore {
    /// Longest edge sent to the API. Image cost grows with pixel count, and a selected
    /// region rarely needs more; raise it (the API uses up to 1568) if small text in
    /// wide captures stops being legible to the model.
    private static let maxEdge: CGFloat = 1000

    static var directory: URL { AppSettings.supportDirectory.appendingPathComponent("Images") }

    static func url(for file: String) -> URL { directory.appendingPathComponent(file) }

    static func data(for file: String) -> Data? { try? Data(contentsOf: url(for: file)) }

    static func image(for file: String) -> NSImage? { NSImage(contentsOf: url(for: file)) }

    static func importCapture(at source: URL) -> String? {
        (try? Data(contentsOf: source)).flatMap(importImage)
    }

    /// Images on the pasteboard: copied image files first (Finder also puts the file
    /// name there as text), then raw image data such as a ⌘⇧⌃4 capture. Text-only
    /// pasteboards return nothing, so a normal paste proceeds.
    static func importFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [String] {
        let imageFiles = (pasteboard.readObjects(forClasses: [NSURL.self],
                                                 options: [.urlReadingFileURLsOnly: true,
                                                           .urlReadingContentsConformToTypes: ["public.image"]]) as? [URL]) ?? []
        if !imageFiles.isEmpty { return imageFiles.prefix(4).compactMap(importCapture) }
        // Rich text copied from a page may carry an image rendition too; text wins there.
        guard pasteboard.string(forType: .string) == nil else { return [] }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let file = importImage(data) { return [file] }
        }
        return []
    }

    /// Re-encodes an image as a size-capped JPEG and returns its file name.
    static func importImage(_ data: Data) -> String? {
        guard let original = NSBitmapImageRep(data: data), let cgImage = original.cgImage else { return nil }
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let ratio = min(1, maxEdge / max(width, height))
        let size = NSSize(width: (width * ratio).rounded(), height: (height * ratio).rounded())

        guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = scaled.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        let file = "\(UUID().uuidString).jpg"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try jpeg.write(to: url(for: file), options: .atomic) } catch { return nil }
        return file
    }

    static func delete(_ file: String) {
        try? FileManager.default.removeItem(at: url(for: file))
    }

    /// Chats expire and get deleted; their screenshots must not outlive them.
    static func removeOrphans(keeping referenced: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !referenced.contains(file) { delete(file) }
    }
}

/// Region capture through the system's own selection UI (the ⌘⇧4 crosshair), so the
/// user decides exactly what leaves the machine.
@MainActor
enum ScreenCapture {
    enum Outcome {
        case captured(String)
        case cancelled
        case needsPermission
    }

    static func captureRegion(completion: @escaping @MainActor (Outcome) -> Void) {
        // Without Screen Recording access macOS silently captures bare wallpaper.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return completion(.needsPermission)
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("winnie-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-t", "png", target.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: target) }
                // Esc leaves no file behind.
                guard FileManager.default.fileExists(atPath: target.path),
                      let file = ImageStore.importCapture(at: target) else { return completion(.cancelled) }
                completion(.captured(file))
            }
        }
        do { try process.run() } catch { completion(.cancelled) }
    }
}
