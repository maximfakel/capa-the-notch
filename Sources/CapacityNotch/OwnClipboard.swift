import AppKit
import CapacityNotchCore

/// Everything CapaTheNotch puts on the clipboard goes through here, with a
/// mark of its own, so the Shelf never keeps it as a Clipping: Dictation's
/// text, a copied diagnostics report, a Clipping chosen again (ADR 0005).
enum OwnClipboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardText.ownMarker))
        board.writeObjects([item])
    }

    /// The translator borrows the clipboard — to copy a selection it cannot
    /// read otherwise, to paste a translation — and puts back what was there.
    /// Nothing that passes through it meanwhile, nor what is put back, is a
    /// new copy the Shelf should keep (ADR 0005).
    @MainActor private(set) static var isBorrowed = false
    /// Every change up to this one was the translator's.
    @MainActor private(set) static var borrowedThrough = 0

    @MainActor static func setBorrowed(_ borrowed: Bool) {
        isBorrowed = borrowed
        // Only as it is given back: a copy made just before the borrowing
        // began, not yet seen by the Shelf, is still the person's.
        if !borrowed { borrowedThrough = NSPasteboard.general.changeCount }
    }

    /// Whether the Shelf should pass over the clipboard's latest change.
    @MainActor static var isLatestChangeBorrowed: Bool {
        isBorrowed || NSPasteboard.general.changeCount <= borrowedThrough
    }
}
