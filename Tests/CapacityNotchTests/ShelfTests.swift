import CapacityNotchCore
import CoreGraphics
import Foundation

private func file(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/shelf-tests/\(name)")
}

func theShelfKeepsTheNewestFirstAndAtMostTwenty() throws {
    var shelf = Shelf()
    shelf.add([file("a.pdf"), file("b.png")])
    let files = { shelf.items(in: .files) }
    try expect(files().map(\.name) == ["b.png", "a.pdf"], "The newest first, got \(files().map(\.name))")

    shelf.add((1...25).map { file("\($0).txt") })
    try expect(files().count == ShelfTab.files.limit, "Twenty at most, got \(files().count)")
    try expect(files().first?.name == "25.txt", "The last one dropped is in front")
    try expect(!files().contains { $0.name == "a.pdf" }, "The oldest give way")
}

func aFileDroppedAgainRisesInsteadOfAppearingTwice() throws {
    var shelf = Shelf()
    shelf.add([file("a.pdf"), file("b.png"), file("c.zip")])
    shelf.add([file("a.pdf")])
    let names = shelf.items(in: .files).map(\.name)
    try expect(names == ["a.pdf", "c.zip", "b.png"], "Risen to the front, got \(names)")
}

func aFileIsRemovedAloneAndClearingEmptiesItsTab() throws {
    var shelf = Shelf()
    shelf.add([file("a.pdf"), file("b.png")])
    let b = try unwrap(shelf.items(in: .files).first { $0.name == "b.png" })
    shelf.remove(b.id)
    try expect(shelf.items(in: .files).map(\.name) == ["a.pdf"], "Only that one goes")
    shelf.clear(.files)
    try expect(shelf.items(in: .files).isEmpty, "Clearing empties it")
}

func aFileIsDrawnByWhatKindItIs() throws {
    try expect(ShelfFileKind(url: file("Отчёт.PDF")) == .pdf, "PDF, whatever the case")
    try expect(ShelfFileKind(url: file("Снимок.png")) == .image, "An image shows itself")
    try expect(ShelfFileKind(url: file("build.zip")) == .archive, "An archive")
    try expect(ShelfFileKind(url: file("Демо.key")) == .presentation, "A presentation")
    try expect(ShelfFileKind(url: file("Договор.docx")) == .document, "A document")
    try expect(ShelfFileKind(url: file("Бюджет.xlsx")) == .spreadsheet, "A spreadsheet")
    try expect(ShelfFileKind(url: file("notes")) == .other, "No extension, no guess")
    try expect(ShelfFileKind.pdf.badge(for: file("a.pdf")) == "PDF", "The badge is the extension")
    try expect(ShelfFileKind.other.badge(for: file("a.markdown")) == "MARK", "Four letters at most")
    try expect(ShelfFileKind.other.badge(for: file("notes")) == nil, "Nothing to show, no badge")
}

func theShelfTellsDiagnosticsHowManyNeverWhich() throws {
    var shelf = Shelf()
    try expect(ShelfModule.observation(enabled: false, shelf: shelf) == "shelf-off", "Off")
    shelf.add([file("a.pdf"), file("b.zip"), file("c.key")])
    shelf.addInMemory(named: "shot.png", data: Data([1]), to: .screenshots)
    shelf.addInMemory(named: "shot 2.png", data: Data([2]), to: .screenshots)
    let said = ShelfModule.observation(enabled: true, shelf: shelf)
    try expect(said == "shelf-on-3-files-2-screenshots", "On, and how many in each tab, got \(said)")
}

func pagesRunCapacityMusicTeleprompterShelf() throws {
    let all = SurfacePageOrder.pages(music: true, teleprompter: true, shelf: true)
    try expect(all == [.capacity, .music, .teleprompter, .shelf], "The Shelf last, got \(all)")
    try expect(
        SurfacePageOrder.pages(music: false, teleprompter: false, shelf: true) == [.capacity, .shelf],
        "Empty or not, the Shelf has its page while it is on"
    )
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TestFailure(description: "Expected a value") }
    return value
}

// MARK: - The outline with a drop tab

func theDropTabIsPartOfTheSurfacesOwnOutline() throws {
    let rect = CGRect(x: 0, y: 0, width: 600, height: 300)
    let strip = CGSize(width: 410, height: 38)
    let tab = CGSize(width: 184, height: 110)
    let outline = SurfaceOutline.path(in: rect, size: strip, radius: 22, tab: tab)
    // y runs down, as SwiftUI draws.
    try expect(outline.contains(CGPoint(x: 300, y: 20)), "The strip is inside")
    try expect(outline.contains(CGPoint(x: 300, y: 38 + 100)), "The tab is inside, in the same path")
    try expect(!outline.contains(CGPoint(x: 300 - 92 - 30, y: 38 + 40)), "Beside the tab, under the strip, is outside")
    // The inverse corner: the outline curves out from the tab into the strip,
    // so just outside the tab's side, just under the strip, is filled.
    try expect(outline.contains(CGPoint(x: 300 - 92 - 3, y: 38 + 1.5)), "The inverse corner fills the angle")
    try expect(!outline.contains(CGPoint(x: 300 - 92 - 11, y: 38 + 11)), "And is a curve, not a square")
    try expect(!outline.contains(CGPoint(x: 300 - 92 + 2, y: 38 + 108)), "The tab's own corner is rounded")

    let none = SurfaceOutline.path(in: rect, size: strip, radius: 22, tab: .zero)
    try expect(!none.contains(CGPoint(x: 300, y: 38 + 20)), "No tab, nothing under the strip")
    try expect(none.contains(CGPoint(x: 300 - 205 - 2, y: 1)), "The shoulders stay either way")
}

func theShelfCountsItsFilesAsEachLanguageDoes() throws {
    try expect(Localization.fileCount(1, in: .english) == "1 file", "One file")
    try expect(Localization.fileCount(5, in: .english) == "5 files", "Files")
    try expect(Localization.fileCount(1, in: .russian) == "1 файл", "Один файл")
    try expect(Localization.fileCount(3, in: .russian) == "3 файла", "Три файла")
    try expect(Localization.fileCount(5, in: .russian) == "5 файлов", "Пять файлов")
    try expect(Localization.fileCount(11, in: .russian) == "11 файлов", "Одиннадцать — файлов, не файл")
    try expect(Localization.fileCount(22, in: .russian) == "22 файла", "Двадцать два файла")
}

func anImageWithoutAFileIsHeldInMemory() throws {
    var shelf = Shelf()
    shelf.add([file("a.pdf")])
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    shelf.addInMemory(named: "Снимок экрана.png", data: png)
    let files = { shelf.items(in: .files) }
    try expect(files().first?.name == "Снимок экрана.png", "An image dropped with no file lands in front")
    try expect(files().first?.url == nil, "With no file behind it")
    try expect(files().first?.kind == .image, "Drawn as an image")
    shelf.addInMemory(named: "Снимок экрана 2.png", data: png)
    try expect(files().count == 2, "The same image again rises rather than appearing twice")
    try expect(files().first?.name == "Снимок экрана 2.png", "Under its newer name")
    shelf.add((1...25).map { file("\($0).txt") })
    try expect(files().count == ShelfTab.files.limit, "Images dropped count towards the twenty files")
}

func aScreenshotOnTheClipboardIsOnePNGAndNothingElse() throws {
    try expect(ScreenshotClipboard.isScreenshot([["public.png"]]), "One item, only PNG: a screenshot")
    try expect(!ScreenshotClipboard.isScreenshot([["public.png", "public.tiff", "public.url"]]), "An image copied from a page brings more")
    try expect(!ScreenshotClipboard.isScreenshot([["public.utf8-plain-text"]]), "Text is not")
    try expect(!ScreenshotClipboard.isScreenshot([["public.png"], ["public.png"]]), "Two items are not one screenshot")
    try expect(!ScreenshotClipboard.isScreenshot([]), "Nothing is nothing")
}

func aScreenshotIsNamedAsMacOSNamesOne() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 1, minute: 2, second: 3))!
    let utc = TimeZone(identifier: "UTC")!
    try expect(
        ScreenshotClipboard.name(at: date, timeZone: utc, in: .russian) == "Снимок экрана 2026-10-01 в 01.02.03.png",
        "In Russian, as Finder shows them"
    )
    try expect(
        ScreenshotClipboard.name(at: date, timeZone: utc, in: .english) == "Screenshot 2026-10-01 at 01.02.03.png",
        "And in English"
    )
}

func whatIsCopiedLandsOnTheShelfExceptFromFinder() throws {
    let photo = URL(fileURLWithPath: "/tmp/cache/photo.JPG")
    let contract = URL(fileURLWithPath: "/tmp/cache/Договор.docx")
    let mb = 1024 * 1024
    func take(_ items: [[String]], _ url: URL? = nil, size: Int? = nil, folder: Bool = false, finder: Bool = false) -> ClipboardTake.Choice {
        ClipboardTake.choose(items, fileURL: url, fileSize: size, isDirectory: folder, fromFinder: finder)
    }
    try expect(take([["public.png"]]) == .screenshot, "A lone PNG is a screenshot")
    try expect(take([["public.html", "public.tiff", "public.png", "public.url"]]) == .data("public.png"), "An image from a page: its PNG, over the TIFF")
    try expect(take([["org.webmproject.webp", "public.url"]]) == .data("org.webmproject.webp"), "WebP too")
    try expect(take([["public.tiff"]]) == .data("public.tiff"), "TIFF when nothing else")
    try expect(take([["public.file-url"]], photo, size: 2 * mb) == .fileIntoMemory, "An image file copied as Telegram copies media")
    try expect(take([["public.file-url"]], contract, size: 3 * mb) == .fileIntoMemory, "A document from a messenger, held in memory")
    try expect(take([["public.file-url"]], contract, size: 200 * mb) == .fileReference, "Past fifty megabytes, a reference")
    try expect(take([["public.file-url"]], contract, size: 3 * mb, finder: true) == .nothing, "Copying in Finder is a file operation, left alone")
    try expect(take([["public.file-url"]], photo, size: 2 * mb, finder: true) == .nothing, "Images included")
    try expect(take([["public.file-url"]], URL(fileURLWithPath: "/tmp/Папка"), folder: true) == .nothing, "Not a folder")
    try expect(take([["public.utf8-plain-text"]]) == .nothing, "Text never")
    try expect(take([["public.png", "org.nspasteboard.ConcealedType"]]) == .nothing, "Nothing a password manager marks as secret")
    try expect(take([["public.png", "org.nspasteboard.TransientType"]]) == .nothing, "Nor anything marked as passing through")
    try expect(ClipboardTake.isExcludedApplication("com.apple.Passwords"), "Passwords is never read from")
    try expect(ClipboardTake.isExcludedApplication("com.apple.keychainaccess"), "Nor Keychain Access")
    try expect(!ClipboardTake.isExcludedApplication("ru.keepcoder.Telegram"), "Telegram is")
}

// MARK: - Shelf Tabs

func theShelfHasThreeTabsInOrder() throws {
    try expect(ShelfTab.allCases == [.files, .screenshots, .clipboard], "Files, Screenshots, Clipboard, got \(ShelfTab.allCases)")
    try expect(ShelfTab.files.limit == 20 && ShelfTab.screenshots.limit == 20, "Twenty files and twenty screenshots")
}

func whatIsCopiedLandsInTheTabForItsKind() throws {
    var shelf = Shelf()
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    shelf.addInMemory(named: "Снимок экрана 2026-10-01 в 01.02.03.png", data: png, to: ShelfTab.forCopied("Снимок экрана 2026-10-01 в 01.02.03.png"))
    shelf.addInMemory(named: "Договор.docx", data: Data([1, 2, 3]), to: ShelfTab.forCopied("Договор.docx"))
    shelf.add([file("photo.JPG")], to: ShelfTab.forCopied("photo.JPG"))
    shelf.add([file("Отчёт.pdf")])

    try expect(
        shelf.items(in: .screenshots).map(\.name) == ["photo.JPG", "Снимок экрана 2026-10-01 в 01.02.03.png"],
        "Screenshots and copied images under Screenshots, got \(shelf.items(in: .screenshots).map(\.name))"
    )
    try expect(
        shelf.items(in: .files).map(\.name) == ["Отчёт.pdf", "Договор.docx"],
        "A dropped file and a copied document under Files, got \(shelf.items(in: .files).map(\.name))"
    )
    try expect(shelf.items(in: .clipboard).isEmpty, "Nothing under Clipboard until text intake")
    try expect(shelf.count == 4, "Four held in all, got \(shelf.count)")
}

func eachTabKeepsItsOwnLimit() throws {
    var shelf = Shelf()
    shelf.add((1...20).map { file("\($0).txt") })
    for index in 1...25 {
        shelf.addInMemory(named: "\(index).png", data: Data([UInt8(index)]), to: .screenshots)
    }
    try expect(shelf.items(in: .screenshots).count == 20, "Twenty screenshots, got \(shelf.items(in: .screenshots).count)")
    try expect(shelf.items(in: .screenshots).first?.name == "25.png", "The newest in front")
    try expect(!shelf.items(in: .screenshots).contains { $0.name == "1.png" }, "The oldest screenshot gives way")
    try expect(shelf.items(in: .files).count == 20, "and the twenty files are all still there")
}

func clearEmptiesOnlyTheTabItIsAskedFor() throws {
    var shelf = Shelf()
    shelf.add([file("a.pdf"), file("b.zip")])
    shelf.addInMemory(named: "shot.png", data: Data([9]), to: .screenshots)
    shelf.clear(.screenshots)
    try expect(shelf.items(in: .screenshots).isEmpty, "Screenshots cleared")
    try expect(shelf.items(in: .files).count == 2, "Files kept, got \(shelf.items(in: .files).count)")
    let a = try unwrap(shelf.items(in: .files).first { $0.name == "a.pdf" })
    shelf.remove(a.id)
    try expect(shelf.items(in: .files).map(\.name) == ["b.zip"], "Removing finds the item in whichever tab holds it")
    shelf.clearAll()
    try expect(shelf.count == 0, "Switching off or quitting empties every tab")
}

func theShelfCountsScreenshotsAsEachLanguageDoes() throws {
    try expect(Localization.screenshotCount(1, in: .english) == "1 screenshot", "One")
    try expect(Localization.screenshotCount(5, in: .english) == "5 screenshots", "Many")
    try expect(Localization.screenshotCount(1, in: .russian) == "1 скрин", "Один скрин")
    try expect(Localization.screenshotCount(3, in: .russian) == "3 скрина", "Три скрина")
    try expect(Localization.screenshotCount(11, in: .russian) == "11 скринов", "Одиннадцать скринов")
}

// MARK: - The screenshot folder

func theScreenshotFolderIsWhereMacOSSavesScreenshots() throws {
    let home = URL(fileURLWithPath: "/Users/someone")
    try expect(
        ScreenshotFolder.location(setting: nil, home: home).path == "/Users/someone/Desktop",
        "The Desktop unless another place was chosen"
    )
    try expect(
        ScreenshotFolder.location(setting: "~/Pictures/Снимки", home: home).path == "/Users/someone/Pictures/Снимки",
        "A folder of one's own, with ~ for home"
    )
    try expect(
        ScreenshotFolder.location(setting: "/Volumes/Work/Shots/", home: home).path == "/Volumes/Work/Shots",
        "Or anywhere at all"
    )
    try expect(ScreenshotFolder.location(setting: "  ", home: home).path == "/Users/someone/Desktop", "A blank setting is no setting")
}

func onlyScreenshotsSavedAfterTheSwitchWasTurnedOnAreTaken() throws {
    let folder = URL(fileURLWithPath: "/Users/someone/Desktop")
    let on = Date(timeIntervalSince1970: 1_000_000)
    func entry(_ name: String, after seconds: TimeInterval, regular: Bool = true) -> ScreenshotFolder.Entry {
        ScreenshotFolder.Entry(url: folder.appendingPathComponent(name), created: on.addingTimeInterval(seconds), isRegularFile: regular)
    }
    let entries = [
        entry("Снимок экрана 2026-10-02 в 10.00.02.png", after: 2),
        entry("Screenshot 2026-10-02 at 10.00.01.png", after: 1),
        entry("Снимок экрана 2026-10-02 в 09.59.00.png", after: -60),
        entry(".Снимок экрана 2026-10-02 в 10.00.03.png", after: 3),
        entry("kcl.png", after: 4),
        entry("Отчёт.pdf", after: 5),
        entry("Bildschirmfoto 2026-10-02 um 10.00.06.png", after: 6),
        entry("Screenshot 2026-10-02 at 1.00.07 PM.png", after: 7),
        entry("Screenshot 2026-10-02 at 10.00.08.png", after: 8, regular: false),
    ]
    let taken = ScreenshotFolder.newScreenshots(in: entries, since: on, alreadyTaken: [], settings: .init())
    try expect(
        taken.map(\.lastPathComponent) == [
            "Screenshot 2026-10-02 at 10.00.01.png",
            "Снимок экрана 2026-10-02 в 10.00.02.png",
            "Bildschirmfoto 2026-10-02 um 10.00.06.png",
            "Screenshot 2026-10-02 at 1.00.07 PM.png",
        ],
        """
        New screenshots, oldest first so the newest lands in front — whatever language names them — \
        never one from before, one still being written, another image, a document or a folder; \
        got \\(taken.map(\\.lastPathComponent))
        """
    )

    let again = ScreenshotFolder.newScreenshots(in: entries, since: on, alreadyTaken: Set(taken), settings: .init())
    try expect(again.isEmpty, "A screenshot already taken is not taken again, got \\(again.map(\\.lastPathComponent))")
}

func aScreenshotIsKnownByTheNameAndTypeMacOSWasToldToUse() throws {
    func taken(_ name: String, _ settings: ScreenshotFolder.Settings) -> Bool {
        ScreenshotFolder.isScreenshot(name: name, settings: settings)
    }
    try expect(taken("Screenshot.png", .init()), "Without the date, by its name")
    try expect(taken("Снимок экрана 2.png", .init()), "or a numbered one")
    try expect(!taken("Screenshot 2026-10-02 at 10.00.01.jpg", .init()), "PNG unless told otherwise")
    try expect(taken("Screenshot 2026-10-02 at 10.00.01.jpg", .init(type: "jpg")), "JPEG when macOS was told JPEG")
    try expect(taken("Экран.png", .init(name: "Экран")), "A name of one's own")
    try expect(taken("Экран 2026-10-02 в 10.00.01.png", .init(name: "Экран")), "with the date after it")
    try expect(!taken("Экраны и окна.png", .init(name: "Экран")), "but not any word that starts with it")
    try expect(!taken("Screenshot of the bug.png", .init()), "nor a name that only begins like a screenshot's")
    try expect(taken("Screenshot 2026-10-02 at 10.00.01 (2).png", .init()), "Two in one second")
    try expect(taken("Снимок экрана — 2026-10-02 в 18.03.21.png", .init()), "macOS 27 puts a dash between the name and the day")
    try expect(
        taken("Снимок экрана\u{00A0}— 2026-10-02 в\u{00A0}18.03.21.png", .init()),
        "with no-break spaces where macOS 27 puts them, as on this Mac"
    )
    try expect(taken("Screenshot 2026-10-02 at 1.00.07\u{202F}PM.png", .init()), "and the narrow one before PM")
    try expect(taken("Screenshot — 2026-10-02 at 18.03.21.png", .init()), "in English too")
    try expect(taken("Экран — 2026-10-02 в 18.03.21.png", .init(name: "Экран")), "and after a name of one's own")
    try expect(
        !taken("Bildschirmfoto 2026-10-02 um 10.00.06.png", .init(name: "Экран")),
        "With a name of one's own, only that name"
    )
}

func theScreenshotSettingsAreReadFromMacOSsOwnKeys() throws {
    let home = URL(fileURLWithPath: "/Users/someone")
    let chosen: [String: Any] = ["location": "~/Pictures", "name": "Экран", "type": "JPG", "location-last": "~/Elsewhere"]
    try expect(ScreenshotFolder.location(domain: chosen, home: home).path == "/Users/someone/Pictures", "`location`, not the last one offered")
    try expect(ScreenshotFolder.Settings(domain: chosen) == .init(name: "Экран", type: "jpg"), "`name` and `type`, the type in lower case")
    try expect(ScreenshotFolder.location(domain: [:], home: home).path == "/Users/someone/Desktop", "Nothing said, the Desktop")
    try expect(ScreenshotFolder.Settings(domain: ["name": "", "type": 3]) == .init(), "Nothing usable, nothing set")
}

func theFolderIsLookedAtOnlyWhileMacOSSavesScreenshotsToOne() throws {
    try expect(ScreenshotFolder.savesToFolder(domain: [:]), "To a file, unless told otherwise")
    try expect(ScreenshotFolder.savesToFolder(domain: ["target": "file"]), "To a file")
    try expect(!ScreenshotFolder.savesToFolder(domain: ["target": "clipboard"]), "Not while screenshots go to the clipboard")
    try expect(!ScreenshotFolder.savesToFolder(domain: ["target": "preview"]), "nor to Preview")
    try expect(
        ScreenshotFolder.savesToFolder(domain: ["target": "clipboard", "target-screenshot": "file"]),
        "The screenshots' own target over the shared one"
    )
}
