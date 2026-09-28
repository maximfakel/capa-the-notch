import CapacityNotchCore
import Foundation

private func specifiers(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "%(?:%|@|d)")
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
}

func everyTranslationKeepsItsSentencesNumbersAndNames() throws {
    for (english, russian) in Localization.russian {
        try expect(specifiers(english) == specifiers(russian), "“\(english)” and its translation must take the same arguments")
        try expect(!russian.isEmpty, "“\(english)” must not translate to nothing")
    }
}

func systemLanguageFollowsTheMacsFirstLanguage() throws {
    try expect(AppLanguage.system.resolved(preferred: ["ru-RU", "en-US"]) == .russian, "A Mac in Russian gets Russian Settings")
    try expect(AppLanguage.system.resolved(preferred: ["en-RU", "ru-RU"]) == .english, "Only the first language decides")
    try expect(AppLanguage.system.resolved(preferred: []) == .english, "No preference is English")
    try expect(AppLanguage.english.resolved(preferred: ["ru-RU"]) == .english, "A choice outranks the Mac")
}

func aSentenceWithoutATranslationIsShownAsWritten() throws {
    try expect(Localization.text("Not a sentence Settings use", in: .russian) == "Not a sentence Settings use", "A missing translation falls back to English")
    try expect(Localization.text("General", in: .russian) == "Основные", "A known sentence is translated")
    try expect(Localization.text("General", in: .english) == "General", "English is the key")
    try expect(Localization.format("%d words · %d min", 120, 3, in: .russian) == "Слов: 120 · 3 мин", "Numbers reach the translation")
    try expect(
        CapacityStatusReason.providerUnavailable(detail: "timed out").localizedGuidance.hasSuffix("timed out"),
        "A Provider's own detail is kept as it came"
    )
}

func theLanguageChoiceIsRemembered() throws {
    let suite = "localization-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try expect(Preferences(defaults: defaults).language == .system, "Settings follow the Mac until a language is chosen")
    Preferences(defaults: defaults).language = .russian
    try expect(Preferences(defaults: defaults).language == .russian, "The choice survives the next launch")
}

func dictationStatesReachTheReportWhole() throws {
    let state = DictationObservation(enabled: true, modelReady: false, microphone: .notDetermined, microphoneEntitled: false, insertionAllowed: false)
    let report = DiagnosticReport(
        applicationVersion: "0.2.1", systemVersion: "26.4", generatedAt: Date(timeIntervalSince1970: 0),
        providers: [], observations: state.observations
    ).text()
    for note in state.observations {
        try expect(report.contains("note \(note)"), "\(note) must survive Redaction, which rubs out runs of 32 characters")
    }
    try expect(state.observations.contains("dictation-mic-not-entitled"), "A build that can never ask for the microphone says so")
    let off = DictationObservation(enabled: false, modelReady: true, microphone: .authorized, microphoneEntitled: true, insertionAllowed: true)
    try expect(off.observations == ["dictation-off"], "An off Module says only that")
}

func aLogLineCarriesCodesAndNeverDescriptions() throws {
    let timeout = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://example.com/?sig=\(String(repeating: "a", count: 40))"])
    let line = DiagnosticEvent.dictationDownloadFailed(DiagnosticError(timeout)).entry(at: Date(timeIntervalSince1970: 0))
    try expect(line == "1970-01-01T00:00:00Z capacity-notch dictation download failed NSURLErrorDomain -1001", "An error is its domain and code: \(line)")
    let answered = DiagnosticEvent.microphoneAnswered(granted: false, now: .notDetermined).line
    try expect(answered == "microphone answered refused now not-determined", "A refusal without a prompt is visible: \(answered)")
}
