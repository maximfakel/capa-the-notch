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
}
