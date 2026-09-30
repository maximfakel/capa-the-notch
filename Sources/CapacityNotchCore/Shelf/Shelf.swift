import Foundation

/// One thing set down on the Shelf: a file, held as a reference and never
/// copied, or something held in memory — an image with no file anywhere, a
/// file copied out of another application's cache — until it is dragged
/// out, when it becomes a file wherever it is dropped (ADR 0005).
public struct ShelfItem: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case file(URL)
        case inMemory(name: String, data: Data)
    }

    public let id: UUID
    public let content: Content

    public init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    public init(id: UUID = UUID(), url: URL) {
        self.init(id: id, content: .file(url))
    }

    public var name: String {
        switch content {
        case let .file(url): url.lastPathComponent
        case let .inMemory(name, _): name
        }
    }

    /// The file behind it; nil for an image held in memory.
    public var url: URL? {
        if case let .file(url) = content { return url }
        return nil
    }

    public var kind: ShelfFileKind { ShelfFileKind(name: name) }
}

/// What the Shelf Module holds: newest first, up to twenty. It lives in
/// memory only; nothing here is written anywhere (ADR 0005).
public struct Shelf: Equatable, Sendable {
    public static let limit = 20

    public private(set) var items: [ShelfItem] = []

    public init() {}

    /// Files dropped together keep their order, and the last of them lands
    /// in front. A file already here rises rather than appearing twice, and
    /// past twenty the oldest give way.
    public mutating func add(_ urls: [URL]) {
        for url in urls {
            let standard = url.standardizedFileURL
            let existing = items.firstIndex { $0.url?.standardizedFileURL == standard }
            let item = existing.map { items.remove(at: $0) } ?? ShelfItem(url: standard)
            items.insert(item, at: 0)
        }
        trim()
    }

    /// Something with no file behind it, held in memory. The same bytes
    /// again rise, under the name they came with this time.
    public mutating func addInMemory(named name: String, data: Data) {
        if let existing = items.firstIndex(where: {
            if case let .inMemory(_, held) = $0.content { return held == data }
            return false
        }) {
            items.remove(at: existing)
        }
        items.insert(ShelfItem(content: .inMemory(name: name, data: data)), at: 0)
        trim()
    }

    public mutating func remove(_ id: ShelfItem.ID) {
        items.removeAll { $0.id == id }
    }

    public mutating func clear() {
        items.removeAll()
    }

    private mutating func trim() {
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }
}

/// How a file is drawn on the Shelf: a thumbnail for an image, otherwise a
/// page with its extension on a badge coloured by what kind it is.
public enum ShelfFileKind: Equatable, Sendable {
    case image
    case pdf
    case archive
    case presentation
    case document
    case spreadsheet
    case other

    public init(url: URL) {
        self.init(name: url.lastPathComponent)
    }

    public init(name: String) {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp":
            self = .image
        case "pdf":
            self = .pdf
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg":
            self = .archive
        case "key", "ppt", "pptx", "odp":
            self = .presentation
        case "doc", "docx", "pages", "rtf", "txt", "md", "odt":
            self = .document
        case "xls", "xlsx", "numbers", "csv", "ods":
            self = .spreadsheet
        default:
            self = .other
        }
    }

    /// The extension, four letters at most, or nothing when there is none.
    public func badge(for url: URL) -> String? {
        badge(forName: url.lastPathComponent)
    }

    public func badge(forName name: String) -> String? {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? nil : String(ext.prefix(4))
    }
}

/// What the Shelf Module says in Copy Diagnostics: on or off, and how many
/// files — never a name or a path (ADR 0005).
public enum ShelfModule {
    public static func observation(enabled: Bool, count: Int) -> String {
        enabled ? "shelf-on-\(count)-files" : "shelf-off"
    }
}

/// A screenshot taken to the clipboard, which the Shelf takes in when asked
/// to (ADR 0005, amended). macOS puts a screenshot there as one item holding
/// PNG and nothing else; an image copied from a page or an application comes
/// with more — TIFF, a link, an archive of the page.
public enum ScreenshotClipboard {
    /// - Parameter items: each pasteboard item's type identifiers.
    public static func isScreenshot(_ items: [[String]]) -> Bool {
        items.count == 1 && items[0] == ["public.png"]
    }

    /// As macOS names a screenshot saved to a file: "Снимок экрана
    /// 2026-10-01 в 01.02.03.png".
    public static func name(at date: Date, timeZone: TimeZone = .current, in language: AppLanguage = Localization.current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd"
        let day = format.string(from: date)
        format.dateFormat = "HH.mm.ss"
        let time = format.string(from: date)
        switch language.resolved() {
        case .russian: return "Снимок экрана \(day) в \(time).png"
        case .english, .system: return "Screenshot \(day) at \(time).png"
        }
    }
}

/// What the Shelf takes from the clipboard when asked to (ADR 0005,
/// amended): a screenshot, an image copied from a page or an application,
/// or a file copied in another application — media or a document from a
/// messenger, an attachment from mail. Never text, never anything a password
/// manager marks as secret, and nothing copied in Finder, where copying a
/// file is a file operation and not a thing to keep at hand.
public enum ClipboardTake {
    public enum Choice: Equatable, Sendable {
        case nothing
        /// A lone PNG: a screenshot, named as macOS names one.
        case screenshot
        /// An image copied as data, in this type.
        case data(String)
        /// A copied file, read into memory: it may sit in another
        /// application's cache, which can be emptied.
        case fileIntoMemory
        /// A copied file too large to hold in memory, kept as a reference.
        case fileReference
    }

    /// Up to this size a copied file is read into memory.
    public static let memoryLimit = 50 * 1024 * 1024

    /// The nspasteboard.org markers, and the older ones listed there, for
    /// what must not be kept.
    public static let secretMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType",
        "com.agilebits.onepassword",
        "Pasteboard generator type",
        "com.typeit4me.clipping",
    ]

    /// Image types, in the order they are preferred: the ones that keep the
    /// image as it was, TIFF — a converted copy — last.
    public static let imageTypes = ["public.png", "public.jpeg", "org.webmproject.webp", "public.heic", "com.compuserve.gif", "public.tiff"]

    /// - Parameters:
    ///   - items: each pasteboard item's type identifiers.
    ///   - fileURL: the file the clipboard points at, when it holds one.
    ///   - fromFinder: Finder was in front when it was copied.
    public static func choose(_ items: [[String]], fileURL: URL?, fileSize: Int?, isDirectory: Bool, fromFinder: Bool) -> Choice {
        let types = Set(items.flatMap { $0 })
        guard !types.isEmpty, types.isDisjoint(with: secretMarkers) else { return .nothing }
        if types.contains("public.file-url") {
            guard fileURL != nil, !fromFinder, !isDirectory else { return .nothing }
            return (fileSize ?? 0) <= memoryLimit ? .fileIntoMemory : .fileReference
        }
        if ScreenshotClipboard.isScreenshot(items) { return .screenshot }
        if let type = imageTypes.first(where: types.contains) { return .data(type) }
        return .nothing
    }

    /// Apple's own password apps mark nothing they copy, so nothing is read
    /// while one of them is in front.
    public static func isExcludedApplication(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return ["com.apple.Passwords", "com.apple.keychainaccess"].contains(bundleIdentifier)
    }
}
