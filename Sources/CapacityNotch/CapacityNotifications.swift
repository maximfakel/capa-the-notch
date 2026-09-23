import CapacityNotchCore
import Foundation
import UserNotifications

/// Puts a Capacity Alert in front of the person, and brings them back to the
/// window it was about.
///
/// Permission is asked for at the moment someone switches alerts on, and never
/// before: a permission prompt at launch is a question nobody asked for.
@MainActor
final class CapacityNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let providerKey = "provider"
    nonisolated static let windowKey = "window"

    private let centre = UNUserNotificationCenter.current()
    private let opened: (Provider, String) -> Void

    /// Nothing here works outside an application bundle: asking macOS for the
    /// notification centre from a bare executable raises rather than failing,
    /// which took the whole process down when the surface was run straight out
    /// of the build directory to be measured.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    init(opened: @escaping (Provider, String) -> Void) {
        self.opened = opened
        super.init()
        centre.delegate = self
    }

    /// Asks, once, when alerts are switched on. Returns what the system
    /// decided, which is not always what was asked.
    func requestPermission() async -> Bool {
        (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func send(_ alert: CapacityAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.userInfo = [
            Self.providerKey: alert.provider.rawValue,
            Self.windowKey: alert.windowID,
        ]

        // One notification per window, replaced rather than stacked, so a
        // Provider cannot fill the notification centre.
        let request = UNNotificationRequest(
            identifier: "\(alert.provider.rawValue).\(alert.windowID)",
            content: content,
            trigger: nil
        )
        centre.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard
            let raw = info[Self.providerKey] as? String,
            let provider = Provider(rawValue: raw),
            let window = info[Self.windowKey] as? String
        else { return }

        await MainActor.run { self.opened(provider, window) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
