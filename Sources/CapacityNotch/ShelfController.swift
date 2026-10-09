import AppKit
import CapacityNotchCore
import os
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The Shelf Module: files dropped on the notch, held as references, and
/// images with no file, held in memory — all dragged out again — and, on a
/// switch of their own, copied texts as Clippings (ADR 0005). Off, it holds
/// nothing; switching it off empties it.
@MainActor
final class ShelfController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var shelf = Shelf()
    /// The Shelf Tab shown, and the one the Shelf opens on next: remembered
    /// for the session, never written down.
    @Published var tab: ShelfTab = .files
    /// Files moved or deleted since they were set down.
    @Published private(set) var missing: Set<ShelfItem.ID> = []
    /// Thumbnails of the images on the Shelf, drawn once each.
    @Published private(set) var thumbnails: [ShelfItem.ID: NSImage] = [:]
    /// A file is being carried over the surface: it has opened on the Shelf,
    /// and the Shelf shows where to drop it.
    @Published var isDropTargeted = false
    /// The file has come near the drop area: its words go, and Kapa grows to
    /// the dashes to take it (ADR 0006).
    @Published var isDropNear = false
    /// A file was just dropped and Kapa is eating it: the drop area stays the
    /// length of the gulp, then gives way to what the Shelf holds.
    @Published private(set) var isSwallowing = false
    /// When it was dropped, which starts the gulp.
    @Published private(set) var swallowedAt: Date?

    /// The Shelf shows its drop area: a file carried over it, or one being
    /// eaten.
    var showsDropArea: Bool { isDropTargeted || isSwallowing }

    /// Holds the drop area while Kapa eats what was dropped on it — only
    /// where Kapa is shown, since without it there is nothing to watch.
    func swallow() {
        guard UserDefaults.standard.object(forKey: KapaPreference.key) as? Bool ?? KapaPreference.defaultValue,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let at = Date()
        swallowedAt = at
        isSwallowing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(KapaMotion.gulpLength + 0.15))
            guard let self, self.swallowedAt == at else { return }
            self.isSwallowing = false
        }
    }
    /// Images copied to the clipboard — screenshots among them — land on the
    /// Shelf by themselves.
    @Published private(set) var takesClipboardImages: Bool
    /// Text copied lands under the Clipboard tab as Clippings.
    @Published private(set) var keepsText: Bool
    @Published private(set) var clippings = Clippings()
    @Published private(set) var clippingLimit: ClippingLimit
    @Published private(set) var clippingsExpire: Bool
    /// Applications nothing is taken from while they are in front.
    @Published private(set) var excludedApplications: [String]
    /// The Clipping just put on the clipboard, which says "Copied" a moment.
    @Published private(set) var justCopied: Clipping.ID?
    /// macOS would not let the Shelf read the clipboard.
    @Published private(set) var clipboardRefused = false
    /// macOS would not let the Shelf read the folder screenshots are saved
    /// to. Screenshots copied to the clipboard still arrive.
    @Published private(set) var screenshotFolderRefused = false

    private let preferences: Preferences
    private var clipboardTimer: Timer?
    private var clipboardCount = 0
    private var copiedFade: Task<Void, Never>?
    private var folderTimer: Timer?
    /// When the folder began to be watched: only screenshots saved since.
    private var folderSince = Date()
    private var folderTaken: Set<URL> = []
    private var folderScanning = false
    /// Counts each start of watching, so a look begun before the switch went
    /// off — and perhaps on again — is not taken as one of this watch's.
    private var folderWatch = 0
    private static let logger = Logger(subsystem: "app.capacitynotch.CapacityNotch", category: "Shelf")

    init(preferences: Preferences) {
        self.preferences = preferences
        isEnabled = preferences.shelfEnabled
        takesClipboardImages = preferences.shelfTakesClipboardImages
        keepsText = preferences.shelfKeepsText
        clippingLimit = preferences.clippingLimit
        clippingsExpire = preferences.clippingsExpire
        excludedApplications = preferences.clipboardExcludedApplications
        watchIfAsked()
    }

    func items(in tab: ShelfTab) -> [ShelfItem] { shelf.items(in: tab) }

    func setEnabled(_ enabled: Bool) {
        preferences.shelfEnabled = enabled
        isEnabled = enabled
        if !enabled { clearAll() }
        watchIfAsked()
    }

    /// Its own switch, off by default: what a person copies is the most
    /// sensitive thing CapaTheNotch could keep (ADR 0005). Off, the
    /// Clippings go at once.
    func setKeepsText(_ keeps: Bool) {
        preferences.shelfKeepsText = keeps
        keepsText = keeps
        if !keeps { clippings.clear() }
        watchIfAsked()
    }

    func setClippingLimit(_ limit: ClippingLimit) {
        preferences.clippingLimit = limit
        clippingLimit = limit
        if clippings.items.count > limit.rawValue { clippings.trim(to: limit) }
    }

    func setClippingsExpire(_ expire: Bool) {
        preferences.clippingsExpire = expire
        clippingsExpire = expire
        forgetOldClippings()
    }

    func setExcludedApplications(_ identifiers: [String]) {
        preferences.clipboardExcludedApplications = identifiers
        excludedApplications = identifiers
    }

    /// Choosing a Clipping puts it on the clipboard and nothing more:
    /// pasting is the person's own ⌘V, so no Accessibility access is needed.
    func copy(_ clipping: Clipping) {
        OwnClipboard.copy(clipping.text)
        justCopied = clipping.id
        Sounds.shared.play(.clippingCopied)
        copiedFade?.cancel()
        copiedFade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.justCopied = nil
        }
    }

    /// A text read off the clipboard, kept as the rules say.
    func keepClipping(_ text: String, at date: Date = Date()) {
        guard isEnabled, keepsText else { return }
        clippings.keep(text, at: date, limit: clippingLimit)
    }

    func removeClipping(_ id: Clipping.ID) {
        clippings.remove(id)
    }

    /// Asked for on its own switch: it means watching the clipboard, which
    /// is the person's to decide (ADR 0003, 0005).
    func setTakesClipboardImages(_ takes: Bool) {
        preferences.shelfTakesClipboardImages = takes
        takesClipboardImages = takes
        clipboardRefused = false
        screenshotFolderRefused = false
        watchIfAsked()
    }

    func add(_ urls: [URL], to tab: ShelfTab = .files) {
        guard isEnabled else { return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        shelf.add(files, to: tab)
        forgetGone()
        refreshAvailability()
        for item in shelf.items(in: tab) where thumbnails[item.id] == nil && item.kind == .image {
            if let url = item.url { drawThumbnail(of: item, at: url) }
        }
    }

    /// Something with no file behind it, held in memory.
    func addInMemory(named name: String, data: Data, to tab: ShelfTab = .files) {
        guard isEnabled else { return }
        shelf.addInMemory(named: name, data: data, to: tab)
        forgetGone()
        if let item = shelf.items(in: tab).first, let image = NSImage(data: data) {
            thumbnails[item.id] = image
        }
    }

    func remove(_ id: ShelfItem.ID) {
        shelf.remove(id)
        forgetGone()
    }

    /// Clear on the page: the tab shown, and no other.
    func clear() {
        if tab == .clipboard { clippings.clear() }
        shelf.clear(tab)
        forgetGone()
    }

    private func clearAll() {
        shelf.clearAll()
        clippings.clear()
        forgetGone()
    }

    private func forgetOldClippings() {
        var kept = clippings
        kept.forgetOld(at: Date(), expiring: clippingsExpire)
        if kept != clippings { clippings = kept }
    }

    /// Asked whenever the page is shown: a file moved in Finder since then
    /// is shown as moved, not offered to be dragged from nowhere. An image
    /// held in memory cannot go missing.
    func refreshAvailability() {
        let gone = Set(shelf.allItems.filter { item in
            guard let url = item.url else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        }.map(\.id))
        if gone != missing { missing = gone }
    }

    private func forgetGone() {
        let ids = Set(shelf.allItems.map(\.id))
        ShelfDragFiles.keep(only: ids)
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
                guard let self, self.shelf.allItems.contains(where: { $0.id == item.id }) else { return }
                self.thumbnails[item.id] = image
            }
        }
    }

    // MARK: - From the clipboard

    /// The clipboard and the screenshot folder, on the one switch (ADR 0005,
    /// amended 2026-10-02).
    private var watchesOutside: Bool { isEnabled && takesClipboardImages }

    private func watchIfAsked() {
        watchClipboard()
        watchScreenshotFolder()
    }

    /// Only what is copied after it was switched on: what is on the clipboard
    /// already is left alone. Until something is worth taking, only the kinds
    /// of thing on the clipboard are read (`ClipboardTake`).
    private func watchClipboard() {
        // The clipboard is read for images, for text, or for both.
        let wanted = watchesOutside || (isEnabled && keepsText)
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
        // A day old, a Clipping goes whether or not anything is copied.
        forgetOldClippings()
        guard board.changeCount != clipboardCount else { return }
        clipboardCount = board.changeCount
        // The translator's own coming and going (ticket 28).
        guard !OwnClipboard.isLatestChangeBorrowed else { return }
        // Apple's password apps mark nothing; nothing is read while one is in front.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !ClipboardTake.isExcludedApplication(front) else { return }
        let items = (board.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        let text = keepsText && ClipboardText.isKept(
            types: items, frontmost: front, excluded: Set(excludedApplications), ownApplication: Bundle.main.bundleIdentifier
        )
        let fromFinder = front == "com.apple.finder"
        // Copying in Finder is left alone, so its files are not even read.
        let fileURL = items.joined().contains("public.file-url") && !fromFinder
            ? (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
            : nil
        let values = try? fileURL?.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let choice = takesClipboardImages ? ClipboardTake.choose(
            items, fileURL: fileURL, fileSize: values?.fileSize,
            isDirectory: values?.isDirectory ?? false, fromFinder: fromFinder
        ) : .nothing
        guard choice != .nothing || text else { return }
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny {
            clipboardRefused = true
            return
        }
        if text {
            if let copied = board.string(forType: .string) {
                clipboardRefused = false
                keepClipping(copied)
            } else {
                Self.logger.error("Text was on the clipboard and could not be read")
                clipboardRefused = true
            }
        }
        switch choice {
        case .nothing:
            return
        case .screenshot:
            guard let data = read(board, .png) else { return }
            addInMemory(named: ScreenshotClipboard.name(at: Date()), data: data, to: .screenshots)
        case let .data(type):
            guard var data = read(board, NSPasteboard.PasteboardType(type)) else { return }
            var ext = UTType(type)?.preferredFilenameExtension ?? "png"
            // TIFF is the clipboard's converted copy, and large; kept as PNG.
            if type == "public.tiff", let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                data = png
                ext = "png"
            }
            let stamp = ScreenshotClipboard.name(at: Date()).drop { !$0.isNumber }.dropLast(4)
            addInMemory(named: L("Image %@", String(stamp)) + ".\(ext)", data: data, to: .screenshots)
        case .fileIntoMemory:
            guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
                Self.logger.error("A copied file could not be read")
                return
            }
            addInMemory(named: fileURL.lastPathComponent, data: data, to: ShelfTab.forCopied(fileURL.lastPathComponent))
        case .fileReference:
            if let fileURL { add([fileURL], to: ShelfTab.forCopied(fileURL.lastPathComponent)) }
        }
    }

    // MARK: - From the screenshot folder

    /// Looked at every two seconds while the switch is on and macOS saves
    /// screenshots to a file. The first look — as the switch is turned on, or
    /// as macOS is told to save to a file — is what has macOS ask for the
    /// folder when it is one it guards: the Desktop, Documents, Downloads.
    private func watchScreenshotFolder() {
        let wanted = watchesOutside
        guard wanted != (folderTimer != nil) else { return }
        folderWatch += 1
        folderScanning = false
        folderTaken = []
        guard wanted else {
            folderTimer?.invalidate()
            folderTimer = nil
            screenshotFolderRefused = false
            return
        }
        folderSince = Date()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readScreenshotFolder() }
        }
        RunLoop.main.add(timer, forMode: .common)
        folderTimer = timer
        readScreenshotFolder()
    }

    private func readScreenshotFolder() {
        guard !folderScanning else { return }
        folderScanning = true
        // Read each time, so a folder chosen since is followed. The domain is
        // macOS's own and undocumented; should it say nothing, screenshots
        // are looked for on the Desktop, where macOS saves them by default.
        // Only its own keys: a suite's dictionary would mix in the global
        // domain and this application's.
        let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture") ?? [:]
        // While screenshots go to the clipboard, the folder gets none, and
        // macOS is not asked for one it would get nothing from.
        guard ScreenshotFolder.savesToFolder(domain: domain) else {
            folderScanning = false
            return
        }
        let folder = ScreenshotFolder.location(domain: domain, home: FileManager.default.homeDirectoryForCurrentUser)
        let settings = ScreenshotFolder.Settings(domain: domain)
        let watch = folderWatch
        Task.detached(priority: .utility) { [weak self] in
            let listing = Self.list(folder)
            await self?.apply(listing, settings: settings, watch: watch)
        }
    }

    private func apply(_ listing: FolderListing, settings: ScreenshotFolder.Settings, watch: Int) {
        guard watch == folderWatch, folderTimer != nil else { return }
        folderScanning = false
        switch listing {
        case .refused:
            if !screenshotFolderRefused { Self.logger.error("The screenshot folder could not be read") }
            screenshotFolderRefused = true
        case let .entries(entries):
            screenshotFolderRefused = false
            let new = ScreenshotFolder.newScreenshots(in: entries, since: folderSince, alreadyTaken: folderTaken, settings: settings)
            guard !new.isEmpty else { return }
            folderTaken.formUnion(new)
            add(new, to: .screenshots)
        }
    }

    private enum FolderListing: Sendable {
        case entries([ScreenshotFolder.Entry])
        /// macOS said no; a folder that is not there is only empty.
        case refused
    }

    private nonisolated static func list(_ folder: URL) -> FolderListing {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
            return .entries(urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return ScreenshotFolder.Entry(
                    url: url.standardizedFileURL,
                    created: values.creationDate ?? .distantPast,
                    isRegularFile: values.isRegularFile ?? false
                )
            })
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .refused
        } catch {
            return .entries([])
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

/// The files written for dragging out what the Shelf holds only in memory
/// (ADR 0005, amended 2026-10-02): one folder of the Shelf's own, a file per
/// item written as its drag starts, removed when the item leaves the Shelf
/// and all of them at launch and at quit. Not removed when the drag ends —
/// an application that took it may still be reading it.
enum ShelfDragFiles {
    static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("capacity-notch-shelf-drag", isDirectory: true)

    /// The item's file, written if it is not there yet; nil for a file the
    /// Shelf only refers to, or if it could not be written.
    static func file(for item: ShelfItem) -> URL? {
        guard case let .inMemory(name, data) = item.content else { return nil }
        let directory = folder.appendingPathComponent(item.id.uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Removes the files of items no longer on the Shelf.
    static func keep(only ids: Set<ShelfItem.ID>) {
        let held = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for directory in held where UUID(uuidString: directory.lastPathComponent).map({ !ids.contains($0) }) ?? true {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
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
    /// The Shelf's row of files, in the same coordinates, while there are
    /// more than it can show. A swipe that starts over it scrolls the files
    /// rather than turning the page. Not published: only the panel reads it,
    /// when a swipe begins.
    var scrollableRow: CGRect?
    /// The Shelf's drop area, in the same coordinates, while it shows: the
    /// panel reads it to tell when a carried file has come near. Kept here,
    /// not on the Shelf, because the column is also built off screen to be
    /// measured, and that copy would report a place nobody sees.
    var dropArea: CGRect?

    static let space = "surface"
}
