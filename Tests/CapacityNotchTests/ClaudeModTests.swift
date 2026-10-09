import CapacityNotchCore
import Foundation

// CapaTheNotch's Claude Code mod (ticket 31, ADR 0001 amended 2026-10-08).
// Every install and removal here happens in a temporary home: the real
// ~/.claude is never touched.

private let modBridge = "/Applications/CapaTheNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The mod as it is kept in the repository and copied into the bundle.
private let modSource = repository.appendingPathComponent("Packaging/ClaudeMod/capathenotch", isDirectory: true)

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-mod-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    return home
}

private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

func theModIsCopiedIntoTheSkillsFolderAndSettingsAreNotTouched() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let settings = home.appendingPathComponent(".claude/settings.json")
    let written = "{\n  \"env\": { \"SECRET\": \"a/b\" },\n  \"model\": \"opus\"\n}\n"
    try Data(written.utf8).write(to: settings)

    try expect(!ClaudeModSetup.isInstalled(atHome: home), "Nothing is there before")
    let first = try ClaudeModSetup.install(from: modSource, atHome: home, bridge: modBridge)
    try expect(first, "The first install writes")
    let folder = ClaudeModSetup.folder(home: home)
    try expect(folder.path.hasSuffix("/.claude/skills/capathenotch"), "It lives where Claude Code loads skills-directory plugins, got \(folder.path)")
    for path in ClaudeModSetup.shipped {
        try expect(
            (try? Data(contentsOf: folder.appendingPathComponent(path))) == (try? Data(contentsOf: modSource.appendingPathComponent(path))),
            "\(path) is copied as shipped"
        )
    }
    try expect(
        text(folder.appendingPathComponent("hooks/bridge.ts")) == "export const bridge = \"\(modBridge)\"\n",
        "The bridge's path is written as a TypeScript string, got \(text(folder.appendingPathComponent("hooks/bridge.ts")) ?? "nothing")"
    )
    try expect(ClaudeModSetup.isInstalled(atHome: home), "and it is seen as installed")
    try expect(ClaudeModSetup.isCurrent(atHome: home, from: modSource, bridge: modBridge), "and current")
    try expect(text(settings) == written, "settings.json is left byte for byte")
    let again = try ClaudeModSetup.install(from: modSource, atHome: home, bridge: modBridge)
    try expect(!again, "Installing again changes nothing")
}

func anInstalledModFollowsTheBridgeAndKeepsClaudeCodesTypes() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try ClaudeModSetup.install(from: modSource, atHome: home, bridge: modBridge)
    let folder = ClaudeModSetup.folder(home: home)
    // Claude Code lays its type files into a folder it loads.
    let types = folder.appendingPathComponent(".claude-plugin/types/claude-code/index.d.ts")
    try FileManager.default.createDirectory(at: types.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// types".utf8).write(to: types)

    let moved = "/Users/someone/Applications/CapaTheNotch Beta.app/Contents/MacOS/CapacityNotchClaudeBridge"
    try expect(!ClaudeModSetup.isCurrent(atHome: home, from: modSource, bridge: moved), "A copy elsewhere is not current")
    let updated = try ClaudeModSetup.install(from: modSource, atHome: home, bridge: moved)
    try expect(updated, "and is brought up to date")
    try expect(text(folder.appendingPathComponent("hooks/bridge.ts"))?.contains(moved) == true, "to the new bridge")
    try expect(text(types) == "// types", "Claude Code's own files stay")
}

func aFolderCapaTheNotchDidNotMakeIsNeverTouched() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = ClaudeModSetup.folder(home: home)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let theirs = folder.appendingPathComponent("SKILL.md")
    try Data("mine".utf8).write(to: theirs)

    do {
        try ClaudeModSetup.install(from: modSource, atHome: home, bridge: modBridge)
        throw TestFailure(description: "Someone else's folder must be refused")
    } catch ClaudeModSetup.SetupError.notOurs {}
    let removedTheirs = try ClaudeModSetup.uninstall(atHome: home)
    try expect(!removedTheirs, "and never removed")
    try expect(text(theirs) == "mine", "Their file stays")
    try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("hooks").path), "and nothing was added")

    // A link by that name is someone's arrangement too.
    try FileManager.default.removeItem(at: folder)
    let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
    try ClaudeModSetup.install(from: modSource, atHome: elsewhere, bridge: modBridge)
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: ClaudeModSetup.folder(home: elsewhere))
    try expect(!ClaudeModSetup.isInstalled(atHome: home), "A linked folder is not called ours")
    let removedLink = try ClaudeModSetup.uninstall(atHome: home)
    try expect(!removedLink, "nor removed")
    try expect(ClaudeModSetup.isInstalled(atHome: elsewhere), "and what it points at stays")
}

func turningOffRemovesTheModAndNothingElse() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let skills = home.appendingPathComponent(".claude/skills", isDirectory: true)
    let other = skills.appendingPathComponent("someone-elses/SKILL.md")
    try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("theirs".utf8).write(to: other)
    let settings = home.appendingPathComponent(".claude/settings.json")
    try Data("{\"model\":\"opus\"}".utf8).write(to: settings)

    try ClaudeModSetup.install(from: modSource, atHome: home, bridge: modBridge)
    let removed = try ClaudeModSetup.uninstall(atHome: home)
    try expect(removed, "Turn Off removes the mod")
    try expect(!FileManager.default.fileExists(atPath: ClaudeModSetup.folder(home: home).path), "the whole folder")
    try expect(text(other) == "theirs", "and no other skill")
    try expect(text(settings) == "{\"model\":\"opus\"}", "and settings.json as it was")
    let removedTwice = try ClaudeModSetup.uninstall(atHome: home)
    try expect(!removedTwice, "Twice is nothing")
}

func aBundleMissingAFileInstallsNothing() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let broken = home.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createDirectory(at: broken.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: modSource.appendingPathComponent(".claude-plugin/plugin.json"),
        to: broken.appendingPathComponent(".claude-plugin/plugin.json")
    )
    do {
        try ClaudeModSetup.install(from: broken, atHome: home, bridge: modBridge)
        throw TestFailure(description: "An incomplete mod must not be installed")
    } catch ClaudeModSetup.SetupError.incomplete {}
    try expect(!FileManager.default.fileExists(atPath: ClaudeModSetup.folder(home: home).path), "Nothing was written")
}

func modsAreUsedOnlyWhereClaudeCodeRunsThem() throws {
    let v = { ClaudeCodeVersion($0)! }
    try expect(ClaudeModSupport.verdict(terminal: v("2.1.287"), desktop: nil) == .supported, "2.1.287 in a terminal runs mods")
    try expect(ClaudeModSupport.verdict(terminal: v("2.1.286"), desktop: nil) == .tooOld, "2.1.286 in a terminal does not")
    try expect(ClaudeModSupport.verdict(terminal: nil, desktop: v("2.1.286")) == .supported, "the desktop app's 2.1.286 does")
    try expect(ClaudeModSupport.verdict(terminal: v("2.1.200"), desktop: v("2.1.285")) == .tooOld, "older everywhere is too old")
    try expect(ClaudeModSupport.verdict(terminal: nil, desktop: nil) == .unknown, "none found is unknown, not supported")
    try expect(v("2.1.293") > v("2.1.287") && v("2.10.0") > v("2.9.99"), "versions compare by number")
    try expect(ClaudeCodeVersion("2.1") == nil && ClaudeCodeVersion("latest") == nil && ClaudeCodeVersion("2.1.x") == nil, "a name that is no version is none")

    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let manager = FileManager.default
    // The desktop app keeps a folder per release.
    let desktop = home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
    for name in ["2.1.288", "2.1.293", ".DS_Store", "tmp"] {
        try manager.createDirectory(at: desktop.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try expect(ClaudeModSupport.desktopVersion(home: home) == v("2.1.293"), "The desktop app's newest release is read from its folders")

    // The native installer links `claude` to versions/<release>.
    let native = home.appendingPathComponent(".local/share/claude/versions/2.1.290")
    try manager.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: native)
    let nativeCommand = home.appendingPathComponent(".local/bin/claude")
    try manager.createDirectory(at: nativeCommand.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: nativeCommand, withDestinationURL: native)
    try expect(ClaudeModSupport.terminalVersion(home: home, commands: [nativeCommand]) == v("2.1.290"), "The native install's release is its file's name")

    // npm links `claude` into its package.
    let package = home.appendingPathComponent("npm/lib/node_modules/@anthropic-ai/claude-code", isDirectory: true)
    try manager.createDirectory(at: package.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try Data(#"{"name":"@anthropic-ai/claude-code","version":"2.1.250"}"#.utf8).write(to: package.appendingPathComponent("package.json"))
    try Data().write(to: package.appendingPathComponent("bin/claude.exe"))
    let npmCommand = home.appendingPathComponent("npm/bin/claude")
    try manager.createDirectory(at: npmCommand.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: npmCommand, withDestinationURL: package.appendingPathComponent("bin/claude.exe"))
    try expect(ClaudeModSupport.terminalVersion(home: home, commands: [npmCommand]) == v("2.1.250"), "an npm install's from its package.json")
    try expect(ClaudeModSupport.terminalVersion(home: home, commands: [npmCommand, nativeCommand]) == v("2.1.290"), "The newest command found counts")
    try expect(ClaudeModSupport.terminalVersion(home: home, commands: [home.appendingPathComponent("nowhere")]) == nil, "No command is no version")
    try expect(ClaudeModSupport.onThisMac(home: home, commands: [npmCommand]) == .supported, "An old terminal beside a new desktop app still runs the mod there")
}

func copyDiagnosticsSaysTheModsStateInOneWord() throws {
    try expect(ClaudeModState.of(installed: true, asked: true, agreed: true, support: .supported).diagnosticCode == "claude-mod-installed", "installed")
    try expect(ClaudeModState.of(installed: false, asked: false, agreed: false, support: .supported) == .notInstalled, "not installed before anyone asked")
    try expect(ClaudeModState.of(installed: false, asked: false, agreed: false, support: .unknown) == .notInstalled, "nor where no Claude Code is found")
    try expect(ClaudeModState.of(installed: false, asked: true, agreed: true, support: .tooOld) == .tooOld, "too old")
    try expect(ClaudeModState.of(installed: false, asked: true, agreed: false, support: .supported).diagnosticCode == "claude-mod-refused", "refused")
}

/// The mod and the status line write the same file through the same bridge,
/// each as its own session; whichever saw the limits change last is shown.
func theModAndTheStatusLineShareOneFileAndTheNewestWins() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("claude-capacity.json")
    let start = Date(timeIntervalSince1970: 1_791_450_000)
    var clock: TimeInterval = 0
    func write(_ json: String) throws {
        clock += 60
        try ClaudeStatusLineBridge.publish(statusLineJSON: Data(json.utf8), capturedAt: start.addingTimeInterval(clock), to: destination)
    }
    func used() throws -> [Double] {
        let at = start.addingTimeInterval(clock)
        return try ClaudeFileCapacitySource(fileURL: destination, now: { at }).read().windows.map { ($0.usedFraction * 100).rounded() }
    }
    // A terminal's status line, a day old, repeating itself.
    let statusLine = #"{"session_id":"terminal","model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1791463800},"seven_day":{"used_percentage":16,"resets_at":1791730800}}}"#
    try write(statusLine)
    // The mod, after a reply in the desktop app: exactly what it pipes.
    try write(#"{"session_id":"6f1c2a7e-0b7e-4b55-9a8f-1d2e3f405162","rate_limits":{"five_hour":{"used_percentage":27,"resets_at":1791463800},"seven_day":{"used_percentage":34,"resets_at":1791730800}}}"#)
    let afterMod = try used()
    try expect(afterMod == [27, 34], "The mod's newer reading is shown, got \(afterMod)")
    try write(statusLine)
    let afterRepeat = try used()
    try expect(afterRepeat == [27, 34], "and a status line repeating an old one does not undo it, got \(afterRepeat)")
}

/// Runs the mod's own argv — read from its source — with a stand-in for the
/// bridge that reports which variables it was given, while this process
/// holds a sign-in token, keys and account ids. Only the names are compared;
/// no value is printed.
func theBridgeIsRunWithNoneOfClaudeCodesCredentials() throws {
    let source = try String(contentsOf: modSource.appendingPathComponent("hooks/register.ts"), encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: #"export const argv: readonly string\[\] = \[([^\]]*)\]"#)
    guard let match = pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          let range = Range(match.range(at: 1), in: source) else {
        throw TestFailure(description: "The mod names its argv in one place")
    }
    // The stand-in: /usr/bin/env alone prints the environment it got.
    let argv = source[range].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.map { item -> String in
        item == "bridge" ? "/usr/bin/env" : item.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
    try expect(argv.first == "/usr/bin/env" && argv.dropFirst().first == "-i", "The bridge is started with an empty environment, got \(argv)")

    let secrets = [
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USER_EMAIL", "CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_ORGANIZATION_UUID",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY",
    ]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    for name in secrets { environment[name] = "test-only-\(UUID().uuidString)" }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try expect(process.terminationStatus == 0, "The stand-in ran")
    let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map { String($0.prefix { $0 != "=" }) }
    let leaked = names.filter { name in
        secrets.contains(name) || name.hasPrefix("ANTHROPIC_") || name.hasPrefix("CLAUDE") || name.hasSuffix("_TOKEN") || name.hasSuffix("_KEY")
    }
    try expect(leaked.isEmpty, "No credential reaches the bridge; it saw \(leaked)")
    try expect(names.isEmpty, "Nothing at all does, got the names \(names)")
}

/// `claude plugin validate --json` reads the mod the way Claude Code will and
/// lists what it hooks and calls: exactly `session.measure` and
/// `$.process.run`. The mod's own tests run too (`claude plugin test`).
/// Without `claude` on this Mac it says so loudly rather than pass.
func theModHooksAndCallsNothingButItsOwnTwo() throws {
    guard let claude = ([ProcessInfo.processInfo.environment["PATH"] ?? ""]
        .flatMap { $0.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") } }
        + ClaudeModSupport.usualCommands(home: FileManager.default.homeDirectoryForCurrentUser))
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        print("  SKIPPED — NOT CHECKED: `claude` is not installed here, so the mod's hooks and calls were not validated")
        return
    }

    // Claude Code runs in a home of its own, so nothing of the person's is
    // read or written, and with nothing of this process's environment.
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try ClaudeModSetup.install(from: modSource, atHome: home, bridge: modBridge)
    func run(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        process.environment = [
            "HOME": home.path,
            "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + claude.deletingLastPathComponent().path,
        ]
        process.currentDirectoryURL = home
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    let expected: Set<String> = ["./register.ts hooks: session.measure", "./register.ts calls: $.process.run"]
    // The copy Claude Code will load, and the one in the repository.
    for folder in [ClaudeModSetup.folder(home: home), modSource] {
        let (status, data) = try run(["plugin", "validate", "--json", folder.path])
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(description: "`claude plugin validate --json` answered no JSON: \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
        let parts = [report["manifest"] as? [String: Any]].compactMap { $0 } + ((report["contents"] as? [[String: Any]]) ?? [])
        let errors = parts.flatMap { ($0["errors"] as? [Any]) ?? [] }
        let notes = Set(parts.flatMap { ($0["notes"] as? [String]) ?? [] })
        let gating = parts.flatMap { ($0["gatingHooks"] as? [Any]) ?? [] }
        try expect(status == 0 && report["success"] as? Bool == true && errors.isEmpty, "The mod validates, got \(errors)")
        try expect(notes == expected, "The mod hooks session.measure and calls $.process.run, and nothing else; got \(notes.sorted())")
        try expect(gating.isEmpty, "and refuses nothing of Claude Code's")
    }

    let (status, data) = try run(["plugin", "test", modSource.path])
    try expect(status == 0, "The mod's own tests pass:\n\(String(decoding: data.suffix(1500), as: UTF8.self))")
}

/// The bundle carries exactly the files the install copies: no tests, no
/// stand-in bridge path.
func theBuildBundlesExactlyWhatIsInstalled() throws {
    for script in ["Scripts/build-app.sh", "Scripts/build-release.sh"] {
        let text = try String(contentsOf: repository.appendingPathComponent(script), encoding: .utf8)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("for mod_file in ") }) else {
            throw TestFailure(description: "\(script) bundles the mod")
        }
        let files = line.dropFirst("for mod_file in ".count).replacingOccurrences(of: "; do", with: "").split(separator: " ").map(String.init)
        try expect(files == ClaudeModSetup.shipped, "\(script) bundles \(files), the install copies \(ClaudeModSetup.shipped)")
    }
}
