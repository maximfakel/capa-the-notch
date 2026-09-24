import AppKit
import SwiftUI

@main
struct CapacityNotchApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Three things, the ones a menu bar menu is for. Everything else it
        // used to offer is in Settings, or went (ticket 19).
        MenuBarExtra {
            Button("Refresh Now") {
                appDelegate.refreshNow()
            }
            .keyboardShortcut("r")

            Divider()

            Button("Settings…") {
                appDelegate.showSettings()
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit Capacity Notch") {
                appDelegate.quit()
            }
            .keyboardShortcut("q")
        } label: {
            // The author's portrait, drawn as a template so macOS gives it
            // the menu bar's own colour in light and dark.
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Capacity Notch")
        }
        .menuBarExtraStyle(.menu)
    }
}

enum MenuBarIcon {
    /// 18 points tall, the height of a menu bar item's image.
    @MainActor static let image: NSImage = {
        let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg")
            ?? Bundle.module.url(forResource: "MenuBarIcon", withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil) ?? NSImage()
        }
        let height: CGFloat = 18
        image.size = NSSize(width: height * image.size.width / image.size.height, height: height)
        image.isTemplate = true
        return image
    }()
}
