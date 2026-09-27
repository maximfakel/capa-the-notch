import Foundation
import CapacityNotchCore

func dictationStopsOnceAndRejectsCancelledResults() throws {
    var session = DictationSession()
    let id = session.begin()!
    try expect(session.begin() == nil, "A repeated key down must not start another recording")
    try expect(session.stop() == id, "The limit stops the current recording")
    try expect(session.stop() == nil, "Key release after the limit must not decode twice")
    session.cancel()
    try expect(!session.complete(id), "A cancelled decode must never deliver")
    let next = session.begin()!
    _ = session.stop()
    try expect(!session.complete(id), "An old result cannot complete a new recording")
    try expect(session.complete(next), "The current result can complete once")
    try expect(!session.complete(next), "A duplicate completion cannot deliver twice")
}

func dictationReplacesPhrasesWithoutSubstringsOrCascades() throws {
    let rules = [DictationReplacement(heard: "пул реквест", replacement: "pull request"),
                 DictationReplacement(heard: "коммит", replacement: "commit"),
                 DictationReplacement(heard: "commit", replacement: "WRONG")]
    try expect(DictationReplacement.apply(rules, to: "ПУЛ РЕКВЕСТ, коммит. Коммиты!") == "pull request, commit. Коммиты!", "Whole phrases, preserved spelling, no cascading")
    try expect(DictationReplacement.apply(DictationReplacement.defaults, to: "Джейсон читает реакт, докеров и фронтендеров.") == "Джейсон читает реакт, докеров и фронтендеров.", "Ambiguous and substring matches stay untouched")
}

func dictationHistoryIsOptInBoundedAndPersistent() throws {
    let name = "dictation-test-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = Preferences(defaults: defaults)
    try expect(!preferences.dictationEnabled && !preferences.dictationKeepsHistory, "Quiet defaults")
    var history = DictationHistory()
    history.append("private", enabled: false)
    try expect(history.entries.isEmpty, "No implicit retention")
    for i in 0..<55 { history.append("Result \(i)", enabled: true) }
    try expect(history.entries.count == 50 && history.entries.first?.text == "Result 54", "Newest fifty")
    preferences.dictationHistory = history
    let restored = Preferences(defaults: defaults).dictationHistory
    try expect(restored == history, "History survives reopening")
    history.append("not saved", enabled: false)
    try expect(history == restored, "Opting out preserves old records")
    history.delete(history.entries[0].id)
    try expect(history.entries.count == 49, "Individual deletion")
    history.clear()
    try expect(history.entries.isEmpty, "Clear all")
}
