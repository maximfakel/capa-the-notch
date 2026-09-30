import AppKit
import CapacityNotchCore
import os
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The Shelf Module: files dropped on the notch, held as references, and
/// images with no file, held in memory — all dragged out again (ADR 0005).
/// Off, it holds nothing; switching it off empties it.
@MainActor
final class ShelfController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var shelf = Shelf()
    /// Files moved or deleted since they were set down.
    @Published private(set) var missing: Set<ShelfItem.ID> = []
    /// Thumbnails of the images on the Shelf, drawn once each.
    @Published private(set) var thumbnails: [ShelfItem.ID: NSImage] = [:]
    /// A file is being held over the closed notch, so the drop tab shows.
    @Published var isDropTargeted = false
    /// Images copied to the clipboard — screenshots among them — land on the
    /// Shelf by themselves.
    @Published private(set) var takesClipboardImages: Bool
    /// macOS would not let the Shelf read the clipboard.
    @Published private(set) var clipboardRefused = false

    private let preferences: Preferences
    private var clipboardTimer: Timer?
    private var clipboardCount = 0
    private static let logger = Logger(subsystem: "app.capacitynotch.CapacityNotch", category: "Shelf")

    init(preferences: Preferences) {
        self.preferences = preferences
        isEnabled = preferences.shelfEnabled
        takesClipboardImages = preferences.shelfTakesClipboardImages
        watchClipboardIfAsked()
    }

    var items: [ShelfItem] { shelf.items }

    func setEnabled(_ enabled: Bool) {
        preferences.shelfEnabled = enabled
        isEnabled = enabled
        if !enabled { clear() }
        watchClipboardIfAsked()
    }

    /// Asked for on its own switch: it means watching the clipboard, which
    /// is the person's to decide (ADR 0003, 0005).
    func setTakesClipboardImages(_ takes: Bool) {
        preferences.shelfTakesClipboardImages = takes
        takesClipboardImages = takes
        clipboardRefused = false
        watchClipboardIfAsked()
    }

    func add(_ urls: [URL]) {
        guard isEnabled else { return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        shelf.add(files)
        forgetGone()
        refreshAvailability()
        for item in shelf.items where thumbnails[item.id] == nil && item.kind == .image {
            if let url = item.url { drawThumbnail(of: item, at: url) }
        }
    }

    /// Something with no file behind it, held in memory.
    func addInMemory(named name: String, data: Data) {
        guard isEnabled else { return }
        shelf.addInMemory(named: name, data: data)
        forgetGone()
        if let item = shelf.items.first, let image = NSImage(data: data) {
            thumbnails[item.id] = image
        }
    }

    func remove(_ id: ShelfItem.ID) {
        shelf.remove(id)
        forgetGone()
    }

    func clear() {
        shelf.clear()
        forgetGone()
    }

    /// Asked whenever the page is shown: a file moved in Finder since then
    /// is shown as moved, not offered to be dragged from nowhere. An image
    /// held in memory cannot go missing.
    func refreshAvailability() {
        let gone = Set(shelf.items.filter { item in
            guard let url = item.url else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        }.map(\.id))
        if gone != missing { missing = gone }
    }

    private func forgetGone() {
        let ids = Set(shelf.items.map(\.id))
        missing.formIntersection(ids)
        thumbnails = thumbnails.filter { ids.contains($0.key) }
    }

    private func drawThumbnail(of item: ShelfItem, at url: URL) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 112, height: 76),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            Task { @MainActor in
                guard let self, self.shelf.items.contains(where: { $0.id == item.id }) else { return }
                self.thumbnails[item.id] = image
            }
        }
    }

    // MARK: - From the clipboard

    /// Only what is copied after it was switched on: what is on the clipboard
    /// already is left alone. Until something is worth taking, only the kinds
    /// of thing on the clipboard are read (`ClipboardTake`).
    private func watchClipboardIfAsked() {
        let wanted = isEnabled && takesClipboardImages
        guard wanted != (clipboardTimer != nil) else { return }
        guard wanted else {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
            return
        }
        clipboardCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readClipboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    private func readClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != clipboardCount else { return }
        clipboardCount = board.changeCount
        // Apple's password apps mark nothing; nothing is read while one is in front.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !ClipboardTake.isExcludedApplication(front) else { return }
        let items = (board.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        let fromFinder = front == "com.apple.finder"
        // Copying in Finder is left alone, so its files are not even read.
        let fileURL = items.joined().contains("public.file-url") && !fromFinder
            ? (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
            : nil
        let values = try? fileURL?.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let choice = ClipboardTake.choose(
            items, fileURL: fileURL, fileSize: values?.fileSize,
            isDirectory: values?.isDirectory ?? false, fromFinder: fromFinder
        )
        guard choice != .nothing else { return }
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny {
            clipboardRefused = true
            return
        }
        switch choice {
        case .nothing:
            return
        case .screenshot:
            guard let data = read(board, .png) else { return }
            addInMemory(named: ScreenshotClipboard.name(at: Date()), data: data)
        case let .data(type):
            guard var data = read(board, NSPasteboard.PasteboardType(type)) else { return }
            var ext = UTType(type)?.preferredFilenameExtension ?? "png"
            // TIFF is the clipboard's converted copy, and large; kept as PNG.
            if type == "public.tiff", let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                data = png
                ext = "png"
            }
            let stamp = ScreenshotClipboard.name(at: Date()).drop { !$0.isNumber }.dropLast(4)
            addInMemory(named: L("Image %@", String(stamp)) + ".\(ext)", data: data)
        case .fileIntoMemory:
            guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
                Self.logger.error("A copied file could not be read")
                return
            }
            addInMemory(named: fileURL.lastPathComponent, data: data)
        case .fileReference:
            if let fileURL { add([fileURL]) }
        }
    }

    private func read(_ board: NSPasteboard, _ type: NSPasteboard.PasteboardType) -> Data? {
        guard let data = board.data(forType: type) else {
            Self.logger.error("An image was on the clipboard and could not be read")
            clipboardRefused = true
            return nil
        }
        clipboardRefused = false
        return data
    }
}

/// Where the pointer is over the surface's window, in the window's own
/// coordinates, top left at zero — the one the panel already reads ten times
/// a second. The surface is never the active window, so hover is taken from
/// here rather than from SwiftUI's own, which a panel that never activates
/// does not reliably hear.
@MainActor
final class SurfacePointer: ObservableObject {
    @Published var location: CGPoint?

    static let space = "surface"
}
