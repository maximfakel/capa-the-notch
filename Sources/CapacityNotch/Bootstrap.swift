import AppKit
import CapacityNotchCore
import SwiftUI

@main
struct CapacityNotchApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The language chosen in Settings, read here so the menu redraws the
    /// moment it changes. Its own font stays the system's.
    @AppStorage("language") private var language = AppLanguage.system.rawValue

    var body: some Scene {
        // Three things, the ones a menu bar menu is for. Everything else it
        // used to offer is in Settings, or went (ticket 19).
        MenuBarExtra {
            Button(word("Refresh Now")) {
                appDelegate.refreshNow()
            }
            .keyboardShortcut("r")

            Divider()

            Button(word("Settings…")) {
                appDelegate.showSettings()
            }
            .keyboardShortcut(",")

            Divider()

            Button(word("Quit Capacity Notch")) {
                appDelegate.quit()
            }
            .keyboardShortcut("q")
        } label: {
            // Kapa's silhouette, drawn as a template so macOS gives it the
            // menu bar's own colour in light and dark.
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Capacity Notch")
        }
        .menuBarExtraStyle(.menu)
    }

    private func word(_ english: String) -> String {
        Localization.text(english, in: AppLanguage(rawValue: language) ?? .system)
    }
}

enum MenuBarIcon {
    /// 18 points tall, the height of a menu bar item's image.
    @MainActor static let image: NSImage = {
        // One file, drawn at 18 and 36 pixels tall, for the menu bar's two
        // resolutions.
        let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "tiff")
            ?? Bundle.module.url(forResource: "MenuBarIcon", withExtension: "tiff")
        guard let url, let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil) ?? NSImage()
        }
        let height: CGFloat = 18
        image.size = NSSize(width: height * image.size.width / image.size.height, height: height)
        image.isTemplate = true
        return image
    }()
}
