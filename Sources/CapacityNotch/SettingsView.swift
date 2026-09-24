import CapacityNotchCore
import SwiftUI

/// One place for every choice, and nothing beyond a choice.
///
/// Deliberately not a dashboard: no history, no charts, no numbers. The
/// surface shows Capacity; this decides how the surface behaves.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(model.providers) { provider in
                    Toggle(isOn: model.binding(for: provider.provider)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            if let note = provider.note {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Surface") {
                Picker("Show on", selection: $model.displayID) {
                    Text("Built-in display").tag(UInt32(0))
                    ForEach(model.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }

                Toggle("Appear in screen sharing and recordings", isOn: $model.screenSharingAllowed)
                Text("macOS can keep Capacity Notch out of the capture it controls. It cannot promise anything about a camera pointed at the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reading") {
                Picker("While the surface is closed", selection: $model.backgroundRefresh) {
                    ForEach(Preferences.refreshChoices, id: \.self) { seconds in
                        Text(model.refreshLabel(seconds)).tag(seconds)
                    }
                }
                Text("An open surface is read every minute; that is not a choice, because an open surface is being watched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Starting and updating") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Button("Check for Updates…") { model.checkForUpdates() }
                Text("Opens the latest release on GitHub. Capacity Notch does not check on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Alerts") {
                Toggle("Warn me when a window is about to run out", isOn: $model.alertsEnabled)

                ForEach(model.providers) { provider in
                    Toggle(provider.name, isOn: model.alertBinding(for: provider.provider))
                        .disabled(!model.alertsEnabled)
                        .padding(.leading, 18)
                }

                Text("One warning per window, when it first drops below a tenth left, and nothing more until it recovers or resets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Music") {
                Toggle("Show what's playing", isOn: $model.musicEnabled)
                Text("While something plays, the strip shows it under Capacity, with its controls; open, the surface has a page for it. It is read through a part of macOS that Apple does not publish, which a macOS update could close.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.musicEnabled, model.musicUnreadable {
                    Text(MusicModule.unreadableGuidance)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Diagnostics") {
                Toggle("Keep a log for bug reports", isOn: $model.keepsDiagnosticLog)

                HStack {
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                    Button("Reveal Log") { model.revealLog() }
                        .disabled(!model.keepsDiagnosticLog)
                    Spacer()
                    Button("Run Onboarding Again") { model.restartOnboarding() }
                }

                if let report = model.lastCopiedReport {
                    ScrollView {
                        Text(report)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                }

                Text("Copied text carries versions, Provider states and timings. It carries no credential, address, identifier or Provider message — those cannot reach it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
