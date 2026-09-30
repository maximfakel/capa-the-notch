import CapacityNotchCore
import CoreGraphics
import Foundation

private func file(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/shelf-tests/\(name)")
}

func theShelfKeepsTheNewestFirstAndAtMostTwenty() throws {
    var shelf = Shelf()
    shelf.add([file("a.pdf"), file("b.png")])
    try expect(shelf.items.map(\.name) == ["b.png", "a.pdf"], "The newest first, got \(shelf.items.map(\.name))")

    shelf.add((1...25).map { file("\($0).txt") })
    try expect(shelf.items.count == Shelf.limit, "Twenty at most, got \(shelf.items.count)")
    try expect(shelf.items.first?.name == "25.txt", "The last one dropped is in front")
    try expect(!shelf.items.contains { $0.name == "a.pdf" }, "The oldest give way")
}

func aFileDroppedAgainRisesInsteadOfAppearingTwice() throws {
    var shelf = Shelf()
    shelf.add([file("a.pdf"), file("b.png"), file("c.zip")])
    shelf.add([file("a.pdf")])
    try expect(shelf.items.map(\.name) == ["a.pdf", "c.zip", "b.png"], "Risen to the front, got \(shelf.items.map(\.name))")
    try expect(shelf.items.count == 3, "Not twice")
}

func aFileIsRemovedAloneAndClearingEmptiesTheShelf() throws {
    var shelf = Shelf()
    shelf.add([file("a.pdf"), file("b.png")])
    let b = try unwrap(shelf.items.first { $0.name == "b.png" })
    shelf.remove(b.id)
    try expect(shelf.items.map(\.name) == ["a.pdf"], "Only that one goes")
    shelf.clear()
    try expect(shelf.items.isEmpty, "Clearing empties it")
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
    try expect(ShelfModule.observation(enabled: false, count: 0) == "shelf-off", "Off")
    try expect(ShelfModule.observation(enabled: true, count: 3) == "shelf-on-3-files", "On, and how many")
}

func pagesRunCapacityMusicTeleprompterShelf() throws {
    let all = SurfacePageOrder.pages(musicLoaded: true, teleprompter: true, shelf: true)
    try expect(all == [.capacity, .music, .teleprompter, .shelf], "The Shelf last, got \(all)")
    try expect(
        SurfacePageOrder.pages(musicLoaded: false, teleprompter: false, shelf: true) == [.capacity, .shelf],
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
    try expect(shelf.items.first?.name == "Снимок экрана.png", "The image lands in front")
    try expect(shelf.items.first?.url == nil, "With no file behind it")
    try expect(shelf.items.first?.kind == .image, "Drawn as an image")
    shelf.addInMemory(named: "Снимок экрана 2.png", data: png)
    try expect(shelf.items.count == 2, "The same image again rises rather than appearing twice")
    try expect(shelf.items.first?.name == "Снимок экрана 2.png", "Under its newer name")
    shelf.add((1...25).map { file("\($0).txt") })
    try expect(shelf.items.count == Shelf.limit, "Images count towards the twenty")
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
