import CapacityNotchCore
import Foundation
import Translation

/// Apple's on-device translation (`docs/research/translator-engine.md`).
///
/// From macOS 26 a session can be made without a window, for languages
/// already downloaded, so the shortcut works with the surface closed; on
/// older systems the Module says it needs macOS 26 rather than half-working.
/// Apple: "All translations using the `TranslationSession` class are processed
/// on the user's device."
@MainActor
final class AppleTranslationEngine: TranslationEngine {
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// What macOS has downloaded, read for each way.
    func readiness() async -> TranslatorReadiness {
        guard #available(macOS 26, *) else { return .needsNewerMacOS }
        let availability = LanguageAvailability()
        var installed: [TranslationDirection: Bool] = [:]
        for direction in TranslationDirection.allCases {
            let status = await availability.status(
                from: Locale.Language(identifier: direction.sourceCode),
                to: Locale.Language(identifier: direction.targetCode)
            )
            installed[direction] = status == .installed
        }
        return .from(systemSupported: true, installed: installed)
    }

    func translate(_ text: String, _ direction: TranslationDirection) async throws -> String {
        guard #available(macOS 26, *) else { throw TranslatorFailure.needsNewerMacOS }
        return try await Self.translate(text, direction)
    }

    /// A session for each request: making one costs a third of a
    /// millisecond (measured), and holding none means nothing to unload.
    @available(macOS 26, *)
    private nonisolated static func translate(_ text: String, _ direction: TranslationDirection) async throws -> String {
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: direction.sourceCode),
            target: Locale.Language(identifier: direction.targetCode)
        )
        do {
            return try await session.translate(text).targetText
        } catch TranslationError.notInstalled {
            throw TranslatorFailure.languagesMissing
        } catch {
            throw TranslatorFailure.engine
        }
    }
}
