import SwiftUI

@main
struct CapacityNotchApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Three things, the ones a menu bar menu is for. Everything else it
        // used to offer is in Settings, or went (ticket 19).
        MenuBarExtra("Capacity Notch", systemImage: "gauge.with.dots.needle.67percent") {
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
        }
        .menuBarExtraStyle(.menu)
    }
}
