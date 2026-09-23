import CapacityNotchCore
import SwiftUI

/// The shortest path from launch to a number on the surface.
///
/// Two steps, and the second is only reached once a Provider has actually
/// answered — there is no point asking someone whether to be warned about
/// Capacity before they have seen any.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step {
        case providers
        case behaviour
    }

    @Published var step: Step = .providers
    @Published var alertsEnabled = false
    @Published var launchAtLogin = false

    private let preferences: Preferences
    private unowned let application: AppDelegate

    init(preferences: Preferences, application: AppDelegate) {
        self.preferences = preferences
        self.application = application
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    var providers: [ProviderChoice] {
        [
            ProviderChoice(provider: .codex, name: "Codex", note: "Read through its own App Server."),
            ProviderChoice(
                provider: .claudeCode,
                name: "Claude Code",
                note: "Experimental. Explained before anything is read."
            ),
        ]
    }

    func isConnected(_ provider: Provider) -> Bool {
        application.isProviderRunning(provider)
    }

    func connect(_ provider: Provider) {
        application.connect(provider)
    }

    var anyProviderConnected: Bool {
        providers.contains { isConnected($0.provider) }
    }

    func continueToBehaviour() {
        step = .behaviour
    }

    func finish() {
        if alertsEnabled {
            Task { [application] in _ = await application.enableAlerts() }
        } else {
            preferences.alertsEnabled = false
        }
        let settled = LaunchAtLogin.set(launchAtLogin)
        preferences.launchAtLogin = settled
        preferences.hasFinishedOnboarding = true
        application.finishOnboarding()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.step {
            case .providers:
                providers
            case .behaviour:
                behaviour
            }
        }
        .padding(28)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var providers: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect a Provider")
                    .font(.title2.weight(.semibold))
                Text("Capacity Notch shows how much of each service's allowance is left. It reads nothing until a Provider is connected.")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.providers) { provider in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).font(.headline)
                        if let note = provider.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.isConnected(provider.provider) {
                        Text("Connected").foregroundStyle(.green)
                    } else {
                        Button("Connect") { model.connect(provider.provider) }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Continue") { model.continueToBehaviour() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.anyProviderConnected)
            }
        }
    }

    private var behaviour: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Two more choices")
                    .font(.title2.weight(.semibold))
                Text("Neither is switched on for you.")
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $model.alertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Warn me when a window is about to run out")
                    Text("One warning per window, and nothing more until it recovers or resets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Launch at login", isOn: $model.launchAtLogin)

            HStack {
                Spacer()
                Button("Finish") { model.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
