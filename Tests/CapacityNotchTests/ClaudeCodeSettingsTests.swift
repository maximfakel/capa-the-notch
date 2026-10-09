import CapacityNotchCore
import Foundation

// Settings ▸ Providers ▸ Claude Code's rows (Paper "Settings — Providers —
// Claude mod working", "— not added", "— Claude Code too old for the mod";
// the author's decisions of 2026-10-08). Everything on disk happens in a
// temporary home: the real ~/.claude is never touched.

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let modSource = repository.appendingPathComponent("Packaging/ClaudeMod/capathenotch", isDirectory: true)
private let modBridge = "/Applications/CapaTheNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    return home
}

private func inLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
    let before = Localization.current
    defer { Localization.current = before }
    Localization.current = language
    return try body()
}

func theClaudeCardShowsOneRowSetForEachStateOfTheMod() throws {
    let old = ClaudeCodeVersion("2.1.250")!
    let new = ClaudeCodeVersion("2.1.290")!

    let working = ClaudeCodeSettings.of(installed: true, support: .supported, newestVersion: new, canInstallHere: true)
    try expect(working.mod == .working && working.action == .remove, "In place and run: Работает, and Удалить")
    try expect(working.isWorking && working.reason == nil, "with the green dot and no reason line")
    try expect(!working.showsTerminal, "and no terminal row: nothing needs it")

    let notAdded = ClaudeCodeSettings.of(installed: false, support: .supported, newestVersion: new, canInstallHere: true)
    try expect(notAdded.mod == .notAdded && notAdded.action == .add, "Not in place: Не добавлен, and Добавить")
    try expect(notAdded.reason == .withoutMod && notAdded.showsTerminal && !notAdded.isWorking, "with the reason and the terminal")

    let elsewhere = ClaudeCodeSettings.of(installed: false, support: .supported, newestVersion: new, canInstallHere: false)
    try expect(elsewhere.mod == .notAddedHere && elsewhere.action == nil, "A copy outside Applications offers no Add that would do nothing")
    try expect(elsewhere.showsTerminal, "but the terminal still works")

    let tooOld = ClaudeCodeSettings.of(installed: false, support: .tooOld, newestVersion: old, canInstallHere: true)
    try expect(tooOld.mod == .needsNewer && tooOld.action == nil, "Too old: Нужен Claude Code 2.1.287 или новее, no button")
    try expect(tooOld.reason == .tooOld(old) && tooOld.showsTerminal, "naming the version found, with the terminal")

    let none = ClaudeCodeSettings.of(installed: false, support: .unknown, newestVersion: nil, canInstallHere: true)
    try expect(none.mod == .needsNewer && none.action == nil && none.reason == .notFound && none.showsTerminal, "None found: the same row, its own reason")

    let leftBehind = ClaudeCodeSettings.of(installed: true, support: .tooOld, newestVersion: old, canInstallHere: true)
    try expect(leftBehind.mod == .installedButNeedsNewer && leftBehind.action == .remove, "In place but no longer run: not called working, and still removable")
    try expect(!leftBehind.isWorking && leftBehind.showsTerminal, "and the terminal is offered")
}

func theClaudeCardSaysWhatTheMockupsSay() throws {
    let old = ClaudeCodeVersion("2.1.250")!
    try inLanguage(.russian) {
        let working = ClaudeCodeSettings(mod: .working, reason: nil)
        try expect(working.status == "Работает" && working.reasonText == nil, "Работает, got \(working.status)")
        let notAdded = ClaudeCodeSettings(mod: .notAdded, reason: .withoutMod)
        try expect(notAdded.status == "Не добавлен", "Не добавлен, got \(notAdded.status)")
        try expect(notAdded.reasonText == "Без мода лимиты Claude обновляются только из терминала.", "the reason as drawn, got \(notAdded.reasonText ?? "nothing")")
        let tooOld = ClaudeCodeSettings(mod: .needsNewer, reason: .tooOld(old))
        try expect(tooOld.status == "Нужен Claude Code 2.1.287 или новее", "the requirement as drawn, got \(tooOld.status)")
        try expect(
            tooOld.reasonText == "Установлен Claude Code 2.1.250, а моды появились в 2.1.287. Пока лимиты обновляются только из терминала.",
            "the real version in the reason, got \(tooOld.reasonText ?? "nothing")"
        )
        let note = SettingsNote.mod
        try expect(note.title == "Что такое мод", "The note's title")
        try expect(note.body == "Небольшое дополнение для Claude Code. После каждого ответа Claude — в приложении Claude, VS Code или терминале — он передаёт сюда только проценты и время сброса лимитов. Ни переписки, ни токенов.", "and body, as drawn")
        try expect(note.footer == "Лежит в ~/.claude/skills/capathenotch. «Удалить» убирает его целиком.", "and where it lives")
        try expect(SettingsNote.terminal.title == "Обновление из терминала", "The terminal's note is Russian too")
        try expect(Localization.text("About %@") != "About %@", "VoiceOver's label for “?” too")
    }
    try inLanguage(.english) {
        try expect(ClaudeCodeSettings(mod: .working, reason: nil).status == "Working", "English: Working")
        try expect(ClaudeCodeSettings(mod: .needsNewer, reason: nil).status == "Needs Claude Code 2.1.287 or later", "English: the requirement")
        try expect(
            ClaudeCodeSettings(mod: .needsNewer, reason: .tooOld(old)).reasonText?.hasPrefix("Claude Code 2.1.250 is installed") == true,
            "English: the version found"
        )
    }
}

/// Добавить and Удалить show at once: the card is read from the folder
/// itself, so the moment it is there or gone, the row says so.
func addingAndRemovingTheModShowsAtOnce() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    func card() -> ClaudeCodeSettings {
        .of(installed: ClaudeModSetup.isInstalled(atHome: home), support: .supported, newestVersion: ClaudeModSupport.terminalMinimum, canInstallHere: true)
    }
    try expect(card().action == .add, "Before: Добавить")
    try ClaudeModSetup.install(from: modSource, atHome: home, bridge: modBridge)
    try expect(card().mod == .working && card().action == .remove, "Added: Работает, Удалить")
    try ClaudeModSetup.uninstall(atHome: home)
    try expect(card().mod == .notAdded, "Removed: Не добавлен again")
    try expect(!FileManager.default.fileExists(atPath: ClaudeModSetup.folder(home: home).path), "and the folder is gone")
}

/// The version the too-old line names: the newest Claude Code found, in the
/// terminal or the desktop app.
func theNewestClaudeCodeFoundIsTheOneNamed() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try expect(ClaudeModSupport.newestVersion(home: home, commands: []) == nil, "Nothing installed, nothing named")
    let desktop = home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
    for version in ["2.1.240", "2.1.250", "not-a-version"] {
        try FileManager.default.createDirectory(at: desktop.appendingPathComponent(version), withIntermediateDirectories: true)
    }
    try expect(ClaudeModSupport.newestVersion(home: home, commands: [])?.description == "2.1.250", "The newest of the desktop app's")
    let native = home.appendingPathComponent(".local/share/claude/versions/2.1.260")
    try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: native)
    let command = home.appendingPathComponent(".local/bin/claude")
    try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: command, withDestinationURL: native)
    try expect(ClaudeModSupport.newestVersion(home: home, commands: [command])?.description == "2.1.260", "A newer one in the terminal wins")
}

/// "Открыть Терминал" runs a `.command` file: `claude` with no arguments,
/// from the shell's PATH or where it is usually installed, and a plain line
/// when there is none. The script is run here with `sh`, never Terminal,
/// and a stand-in `claude`.
func theTerminalButtonStartsClaudeWithNothingSent() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let written = try ClaudeTerminal.write(home: home, notFound: "Claude Code was not found.")
    try expect(written.path.hasSuffix("Library/Application Support/CapacityNotch/Claude Code.command"), "In CapaTheNotch's own folder, got \(written.path)")
    let mode = (try FileManager.default.attributesOfItem(atPath: written.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    try expect(mode & 0o111 != 0, "and executable, as Terminal needs")
    try expect((try? String(contentsOf: written, encoding: .utf8))?.contains("exec claude\n") == true, "It runs claude with nothing after it")

    // Run here with the usual places inside the temporary home only, so no
    // Claude Code installed on this Mac is ever started.
    let local = home.appendingPathComponent(".local/bin/claude")
    let file = home.appendingPathComponent("test.command")
    try Data(ClaudeTerminal.script(usualCommands: [local], notFound: "Claude Code was not found.").utf8).write(to: file)

    let bin = home.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    func standIn(at url: URL, saying word: String) throws {
        try Data("#!/bin/sh\necho \"\(word) $# $PWD\"\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func run(_ script: URL, path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["PATH": path, "HOME": home.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // On the PATH: run as it is, no arguments, from home.
    try standIn(at: bin.appendingPathComponent("claude"), saying: "path")
    let fromPath = try run(file, path: "\(bin.path):/usr/bin:/bin")
    try expect(fromPath == "path 0 \(home.path)", "claude from PATH, no arguments, in the home folder, got \(fromPath)")

    // Not on the PATH: the usual place, such as ~/.local/bin.
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try standIn(at: local, saying: "local")
    let fromLocal = try run(file, path: "/usr/bin:/bin")
    try expect(fromLocal == "local 0 \(home.path)", "claude from ~/.local/bin, got \(fromLocal)")

    // Nowhere: said, and nothing else run.
    try FileManager.default.removeItem(at: local)
    let fromNowhere = try run(file, path: "/usr/bin:/bin")
    try expect(fromNowhere == "Claude Code was not found.", "None found is said, got \(fromNowhere)")

    // A quote in a path or the message cannot break out of the script.
    let quoted = ClaudeTerminal.script(usualCommands: [URL(fileURLWithPath: "/tmp/it's/claude")], notFound: "it's gone; rm -rf x")
    try expect(quoted.contains("'/tmp/it'\\''s/claude'") && quoted.contains("echo 'it'\\''s gone; rm -rf x'"), "Quotes are escaped, got \(quoted)")
}
