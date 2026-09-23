import Foundation
import ServiceManagement

/// Whether macOS starts Capacity Notch when the person logs in.
///
/// The system holds the truth, not a preference: someone can turn this off in
/// System Settings without telling us, so the stored choice is only ever
/// reconciled against what the system reports.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns what the system ended up doing, which is not always what was
    /// asked — registration fails for an application that is not where macOS
    /// expects to find it.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return isEnabled
        }
        return isEnabled
    }
}
