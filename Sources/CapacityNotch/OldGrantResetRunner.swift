import CapacityNotchCore
import Foundation
import Security

/// What `OldGrantReset` needs from macOS: whether this copy is signed with a
/// certificate, and tccutil.
enum OldGrantResetRunner {
    /// A certificate in this copy's own signature. The author's builds have
    /// one (ticket 30); `swift run` and ad-hoc copies do not, and reset
    /// nothing.
    static var signedWithCertificate: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate]
        else { return false }
        return !certificates.isEmpty
    }

    /// `tccutil reset <service> <bundle identifier>`, as the person: it needs
    /// no administrator (measured in ticket 30), and with nothing granted it
    /// still succeeds. Waited on without turning the run loop — which
    /// `waitUntilExit` does, running whatever else is queued meanwhile — and
    /// for five seconds at most: one that hangs is one that failed.
    static func reset(_ service: String, _ bundleIdentifier: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard exited.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    static func runOnce(preferences: Preferences, firstRun: Bool) -> OldGrantReset.Outcome {
        OldGrantReset.runOnce(
            preferences: preferences, signedWithCertificate: signedWithCertificate, firstRun: firstRun, reset: reset
        )
    }
}
