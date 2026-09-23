import SwiftUI

@main
struct CapacityNotchApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Capacity Notch", systemImage: "gauge.with.dots.needle.67percent") {
            Button("Open Capacity Details") {
                appDelegate.openSurface()
            }
            .keyboardShortcut("o")

            Button("Show / Hide Capacity Notch") {
                appDelegate.togglePanelVisibility()
            }

            Divider()

            if let hiddenUntil = appDelegate.hiddenUntilText {
                Text("Hidden — back in \(hiddenUntil)")
            }

            Button("Hide for 1 Hour") {
                appDelegate.hideSurfaceForAnHour()
            }

            Divider()

            Button("Settings…") {
                appDelegate.showSettings()
            }
            .keyboardShortcut(",")

            Button("Check for Updates…") {
                appDelegate.checkForUpdates()
            }

            Divider()

            Button("Refresh Now") {
                appDelegate.refreshNow()
            }
            .keyboardShortcut("r")

            Divider()

            Button("Connect Codex") {
                appDelegate.connectCodex()
            }

            Button("Disconnect Codex") {
                appDelegate.disconnectCodex()
            }

            Divider()

            Button("Connect Claude Code…") {
                appDelegate.requestClaudeCodeConnection()
            }

            Button("Disconnect Claude Code") {
                appDelegate.disconnectClaudeCode()
            }

            Divider()

            Button("Quit Capacity Notch") {
                appDelegate.quit()
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
