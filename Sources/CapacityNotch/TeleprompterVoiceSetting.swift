import AppKit
import SwiftUI

/// Settings → Modules → Teleprompter: following the voice (ticket 20). The
/// switch asks macOS for the microphone when it is turned on, and only then;
/// refused, it stays off and says what to do.
struct TeleprompterVoiceSetting: View {
    @ObservedObject var teleprompter: TeleprompterController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsToggleRow(
                L("Follow my voice"),
                isOn: Binding(get: { teleprompter.followsVoice }, set: { teleprompter.setFollowsVoice($0) }),
                indent: 44
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(L("The Script moves as you read it aloud and waits when you stop. It listens only while the Script runs, on this Mac; nothing is kept."))
                    .foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let trouble = teleprompter.voiceTrouble {
                    Text(L(trouble.message))
                        .foregroundStyle(SettingsPalette.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if trouble == .microphoneDenied {
                        Button(L("Open Microphone Settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .fixedSize()
                    }
                }
            }
            .font(SettingsType.caption)
            .padding(.leading, 54)
            .padding(.trailing, 10)
            .padding(.bottom, 12)
        }
        .onAppear { teleprompter.refreshVoiceTrouble() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            teleprompter.refreshVoiceTrouble()
        }
    }
}

extension TeleprompterVoice.Trouble {
    /// English, the key to its translation.
    var message: String {
        switch self {
        case .microphoneDenied:
            "CapaTheNotch may not use the microphone. Allow it in System Settings → Privacy & Security → Microphone, then turn this on again."
        case .modelMissing:
            "Following the voice uses Dictation's speech model. Turn Dictation on and download the model, then turn this on again."
        case .failed:
            "The microphone or the speech model did not start, so the Script went back to its set speed. Turn this on again to try once more."
        }
    }
}
