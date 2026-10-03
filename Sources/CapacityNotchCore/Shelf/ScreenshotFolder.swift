import Foundation

/// The folder macOS saves screenshots to, which the Shelf watches while it
/// takes from the clipboard (ADR 0005, amended 2026-10-02): each new
/// screenshot there goes under Screenshots, as a reference to its file.
///
/// macOS marks a screenshot nowhere a program can read — no attribute,
/// nothing Spotlight is sure to have yet — so one is known as macOS names
/// it: the name it was told to use, or its own in the Mac's language, and the
/// type it was told to save.
public enum ScreenshotFolder {
    /// What `com.apple.screencapture` says, where it says anything.
    public struct Settings: Equatable, Sendable {
        /// The name given in place of "Screenshot", if any (`name`).
        public var name: String?
        /// The file type, "png" unless told otherwise (`type`).
        public var type: String?

        public init(name: String? = nil, type: String? = nil) {
            self.name = name
            self.type = type.map(ScreenshotFolder.normalised)
        }

        /// From the `com.apple.screencapture` domain; anything unusable is
        /// as if unsaid.
        public init(domain: [String: Any]) {
            func text(_ key: String) -> String? {
                (domain[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            }
            self.init(name: text("name"), type: text("type"))
        }
    }

    /// One thing in the folder, as the file system describes it.
    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var created: Date
        public var isRegularFile: Bool

        public init(url: URL, created: Date, isRegularFile: Bool) {
            self.url = url
            self.created = created
            self.isRegularFile = isRegularFile
        }
    }

    /// Whether macOS saves screenshots to a file at all, rather than to the
    /// clipboard, Preview, Mail or Messages. Newer macOS keeps a target for
    /// screenshots apart from screen recordings; older keeps one for both.
    public static func savesToFolder(domain: [String: Any]) -> Bool {
        let target = (domain["target-screenshot"] as? String) ?? (domain["target"] as? String) ?? "file"
        return target == "file"
    }

    /// Where macOS saves screenshots, from the `com.apple.screencapture`
    /// domain. `location-last` is only the last folder the menu offers, not
    /// where screenshots go.
    public static func location(domain: [String: Any], home: URL) -> URL {
        location(setting: domain["location"] as? String, home: home)
    }

    /// Where macOS saves screenshots: the folder chosen (`location`), with ~
    /// for home, or the Desktop.
    public static func location(setting: String?, home: URL) -> URL {
        guard let setting = setting?.trimmingCharacters(in: .whitespaces), !setting.isEmpty else {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        let path = setting.hasPrefix("~")
            ? home.path + setting.dropFirst()
            : setting
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// The screenshots saved since `since` and not taken yet, oldest first,
    /// so that the newest lands in front of the Shelf.
    public static func newScreenshots(in entries: [Entry], since: Date, alreadyTaken: Set<URL>, settings: Settings) -> [URL] {
        entries
            .filter { entry in
                entry.isRegularFile
                    && entry.created >= since
                    && !alreadyTaken.contains(entry.url)
                    && isScreenshot(name: entry.url.lastPathComponent, settings: settings)
            }
            .sorted { $0.created < $1.created }
            .map(\.url)
    }

    /// macOS writes a screenshot as a hidden file first and names it once it
    /// is whole, so a hidden file is one still being written.
    ///
    /// After its name macOS writes nothing, a number, or the day and time:
    /// "Screenshot", "Screenshot 2", "Screenshot 2026-10-02 at 10.00.01 (2)".
    /// Without a name of one's own, any name before the day and time will do,
    /// for the languages other than these — at the cost of taking a file
    /// someone else named the same way.
    public static func isScreenshot(name: String, settings: Settings) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let file = name as NSString
        guard normalised(file.pathExtension) == (settings.type ?? "png") else { return false }
        // macOS 27 writes no-break spaces round its dash and before the
        // time, and a narrow one before AM or PM; any space is a space here.
        let base = file.deletingPathExtension.replacingOccurrences(of: #"\s"#, with: " ", options: .regularExpression)
        let names = settings.name.map { [$0] } ?? ownNames
        let named = names.contains { own in
            base.hasPrefix(own) && base.dropFirst(own.count).range(of: afterName, options: .regularExpression) != nil
        }
        return named || (settings.name == nil && base.range(of: anyNameDated, options: .regularExpression) != nil)
    }

    /// The names macOS gives in English, before and since Mojave, and in
    /// Russian.
    private static let ownNames = ["Screenshot", "Screen Shot", "Снимок экрана"]

    /// "2026-10-02 at 10.00.01", "2026-10-02 um 1.00.07 PM", and "(2)" or
    /// "2" when there were two in one second: a day, a word, and a time, as
    /// every language macOS speaks writes them.
    private static let dated = #"\d{4}-\d{2}-\d{2} \S+ \d{1,2}[.:]\d{2}[.:]\d{2}( [AP]M)?( \(\d+\)| \d+)?"#
    /// Since macOS 27 a dash stands between the name and the day:
    /// "Снимок экрана — 2026-10-02 в 18.03.21".
    private static let afterName = #"^( \d+| (— )?"# + dated + ")?$"
    private static let anyNameDated = "^.+ " + dated + "$"

    fileprivate static func normalised(_ type: String) -> String {
        let type = type.lowercased()
        return type == "jpeg" ? "jpg" : type
    }
}
