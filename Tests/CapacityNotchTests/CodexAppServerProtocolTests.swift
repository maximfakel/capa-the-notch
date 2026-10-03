import CapacityNotchCore
import Foundation

func inboundParserSeparatesResponsesFailuresAndNotifications() throws {
    let response = try JSONRPCInbound.parse(line: #"{"id":7,"result":{"ok":true}}"#)
    guard case let .response(id, result) = response else {
        throw TestFailure(description: "A result envelope should parse as a response")
    }
    try expect(id == 7, "The response should keep its request id")
    let decoded = try JSONSerialization.jsonObject(with: result) as? [String: Any]
    try expect(
        decoded?["ok"] as? Bool == true,
        "The response should carry its result payload"
    )

    let failure = try JSONRPCInbound.parse(line: FakeAppServerScript.methodNotFound(id: 9))
    guard case let .failure(failedID, error) = failure else {
        throw TestFailure(description: "An error envelope should parse as a failure")
    }
    try expect(failedID == 9, "The failure should keep its request id")
    try expect(error.code == -32601, "The failure should keep the App Server error code")

    let notification = try JSONRPCInbound.parse(
        line: FakeAppServerScript.rateLimitsUpdated(primaryUsedPercent: 12, resetsAt: 1_000)
    )
    guard case let .notification(method, _) = notification else {
        throw TestFailure(description: "An id-less envelope should parse as a notification")
    }
    try expect(
        method == "account/rateLimits/updated",
        "The rolling update should keep its method name"
    )

    let blank = try JSONRPCInbound.parse(line: "   ")
    try expect(blank == nil, "A blank line should not produce a message")
}

func outboundRequestsAreOneJSONLine() throws {
    let request = try JSONRPCOutbound.request(
        id: 3,
        method: "account/rateLimits/read",
        params: nil
    )

    try expect(
        request == #"{"id":3,"method":"account/rateLimits/read"}"#,
        "A request without params should serialize its method and id only, got \(request)"
    )
    try expect(!request.contains("\n"), "A request should occupy exactly one line")

    let notification = try JSONRPCOutbound.notification(method: "initialized")
    try expect(
        notification == #"{"method":"initialized"}"#,
        "A notification should carry no id, got \(notification)"
    )
}

func codexWindowsBecomeQuotaWindowsWithRemainingCapacity() throws {
    let payload = CodexRateLimitSnapshot(
        primary: CodexRateLimitWindow(
            usedPercent: 70,
            windowDurationMins: 300,
            resetsAt: 1_700_000_000
        ),
        secondary: CodexRateLimitWindow(
            usedPercent: 20,
            windowDurationMins: 10_080,
            resetsAt: nil
        )
    )

    let snapshot = CodexCapacityMapper.snapshot(
        from: payload,
        capturedAt: Date(timeIntervalSince1970: 1_699_999_000)
    )

    try expect(snapshot.provider == .codex, "A Codex payload should describe the Codex Provider")
    try expect(snapshot.connectionState == .fresh, "A successful read is Fresh Capacity")
    try expect(snapshot.windows.count == 2, "Both reported windows should survive the mapping")
    try expect(
        snapshot.windows[0].label == "5 hour" && snapshot.windows[1].label == "Weekly",
        "Window durations should read as their human periods"
    )
    try expect(
        snapshot.windows[0].remainingPercentage == 30,
        "70% used should leave 30% of Capacity"
    )
    try expect(
        snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_700_000_000),
        "A reported reset should become its date"
    )
    try expect(
        snapshot.windows[1].resetsAt == nil,
        "An unreported reset should stay unknown rather than become a fabricated date"
    )
}

func windowLabelsCoverTheDurationsCodexReports() throws {
    try expect(CodexCapacityMapper.label(forWindowDurationMins: 300) == "5 hour", "300 mins")
    try expect(CodexCapacityMapper.label(forWindowDurationMins: 10_080) == "Weekly", "10080 mins")
    try expect(CodexCapacityMapper.label(forWindowDurationMins: 1_440) == "Daily", "1440 mins")
    try expect(CodexCapacityMapper.label(forWindowDurationMins: 30) == "30 minute", "30 mins")
    try expect(CodexCapacityMapper.label(forWindowDurationMins: nil) == "Quota", "absent duration")
}

func rollingUpdatesKeepWindowsTheyOmit() throws {
    let previous = CodexRateLimitSnapshot(
        primary: CodexRateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: 100),
        secondary: CodexRateLimitWindow(usedPercent: 20, windowDurationMins: 10_080, resetsAt: 200)
    )
    let update = CodexRateLimitSnapshot(
        primary: CodexRateLimitWindow(usedPercent: 55, windowDurationMins: 300, resetsAt: 300),
        secondary: nil
    )

    let merged = CodexCapacityMapper.merge(update, into: previous)

    try expect(merged.primary?.usedPercent == 55, "A reported window should take the new value")
    try expect(
        merged.secondary?.usedPercent == 20,
        "A window the sparse update omits should keep its last known value"
    )
}

func disconnectedCapacityCarriesGuidanceAndNoWindows() throws {
    let snapshot = CapacitySnapshot.disconnected(
        provider: .codex,
        capturedAt: Date(timeIntervalSince1970: 1),
        reason: .providerNotAuthenticated
    )

    try expect(
        snapshot.windows.isEmpty,
        "A disconnected Provider must not present Quota Windows that would read as zero Capacity"
    )
    guard case let .disconnected(reason) = snapshot.connectionState else {
        throw TestFailure(description: "A disconnected snapshot should say so")
    }
    try expect(
        reason.guidance.contains("codex login"),
        "An unauthenticated Provider should name the action that fixes it"
    )
}

func codexBinaryIsFoundOnlyWhereItIsExecutable() throws {
    let located = CodexInstallation.locate(
        searchPaths: ["/nowhere/codex", "/opt/homebrew/bin/codex"],
        isExecutable: { $0 == "/opt/homebrew/bin/codex" }
    )
    try expect(located == "/opt/homebrew/bin/codex", "The first executable candidate should win")

    try expect(
        CodexInstallation.locate(searchPaths: ["/nowhere/codex"], isExecutable: { _ in false }) == nil,
        "A machine without Codex should report no installation"
    )
}

/// Every open page is the same height, so the surface does not jump as pages
/// turn: the strip, 152 of page and the page dots — 210 under a 38-point menu
/// bar, as drawn ("Limits — C · Gauges"). The Teleprompter reading while
/// closed stands as tall ("Compact — Teleprompter running").
func everyOpenPageIsTheSameHeight() throws {
    let drawn = NotchGeometry(menuBarHeight: 38, notchWidth: 185)
    try expect(drawn.openHeight == 210, "210 under the drawing's menu bar, got \(drawn.openHeight)")
    try expect(NotchGeometry.pageHeight == 152 && NotchGeometry.pageSwitcherHeight == 20, "152 of page, 20 of dots")
    let smaller = NotchGeometry(menuBarHeight: 32, notchWidth: 185)
    try expect(smaller.openHeight == 204, "A shorter menu bar takes its own height off, not the page's")
    try expect(
        drawn.menuBarHeight + NotchGeometry.compactTeleprompterRow == drawn.openHeight,
        "Closed, a reading Teleprompter is as tall as the open surface"
    )
}

func theCompactSurfaceTakesItsHeightFromTheMenuBar() throws {
    // The built-in display of a 16-inch MacBook Pro: a 38 point menu bar with
    // 918 points of usable strip on each side of the notch.
    let notched = NotchGeometry.measure(
        screenWidth: 2056,
        safeAreaTop: 38,
        auxiliaryTopLeftWidth: 918,
        statusBarThickness: 22
    )

    try expect(
        notched.menuBarHeight == 38,
        "A notched display's menu bar is as tall as its notch, got \(notched.menuBarHeight)"
    )
    try expect(
        notched.notchWidth == 220,
        "The notch is what the menu bar strip does not cover, got \(notched.notchWidth)"
    )
    try expect(
        notched.surfaceWidth() == 560,
        "The surface straddles the notch with room on each side, got \(notched.surfaceWidth())"
    )
    try expect(
        notched.surfaceWidth(providerWidth: 240) == 700,
        "A wider Provider column widens the surface, got \(notched.surfaceWidth(providerWidth: 240))"
    )
    try expect(
        notched.compactWidth() == 410,
        "Closed over More Space's 220-point notch, the surface is 410 wide as drawn, got \(notched.compactWidth())"
    )
    try expect(
        NotchGeometry(menuBarHeight: 32, notchWidth: 185).compactWidth() == 370,
        "Over the default scaling's 185-point notch it is 370"
    )
    try expect(
        notched.compactWidth() < notched.surfaceWidth(),
        "The closed surface is the narrower of the two, so opening widens as well as lengthens"
    )
    let vast = NotchGeometry(menuBarHeight: 38, notchWidth: 520)
    try expect(
        vast.compactWidth() == 705 && vast.compactWidth() < vast.surfaceWidth(),
        "A notch wider than either drawing still leaves a figure each side, got \(vast.compactWidth())"
    )

    let plain = NotchGeometry.measure(
        screenWidth: 1920,
        safeAreaTop: 0,
        auxiliaryTopLeftWidth: nil,
        statusBarThickness: 22
    )

    try expect(
        plain.menuBarHeight == 22,
        "A display without a notch falls back to the status bar, got \(plain.menuBarHeight)"
    )
    try expect(plain.notchWidth == 0, "A display without a notch has no notch to straddle")

    let mirrored = NotchGeometry.measure(
        screenWidth: 1440,
        safeAreaTop: 38,
        auxiliaryTopLeftWidth: 1440,
        statusBarThickness: 22
    )
    try expect(
        mirrored.notchWidth == 0,
        "A strip as wide as the screen leaves no notch, got \(mirrored.notchWidth)"
    )
}

func anUnreadSurfaceShowsNoNumbersAtAll() throws {
    let snapshots = UnreadCapacity.snapshots(capturedAt: Date(timeIntervalSince1970: 10_000))

    try expect(
        snapshots.map(\.provider) == Provider.allCases,
        "Every Provider should be present before any is read"
    )
    try expect(
        snapshots.allSatisfy(\.windows.isEmpty),
        "A Provider that has not been read must show no Quota Window, invented or otherwise"
    )
    try expect(
        snapshots.allSatisfy { snapshot in
            guard case .disconnected = snapshot.connectionState else { return false }
            return true
        },
        "An unread Provider is disconnected, not mock and not empty"
    )
    try expect(
        snapshots.compactMap(\.statusReason).allSatisfy { $0.guidance.contains("in Settings") },
        "Each unread Provider should say where to turn it on — Settings, the menu no longer connects"
    )
}

func theCodexInChatGPTIsFoundWhereNewerReleasesKeepIt() throws {
    let paths = CodexInstallation.defaultSearchPaths
    let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
    guard let newer = paths.firstIndex(of: bundled), let npm = paths.firstIndex(where: { $0.hasSuffix("/.local/bin/codex") }) else {
        throw TestFailure(description: "ChatGPT's newer Codex and an npm install are both looked for")
    }
    try expect(newer < npm, "The native Codex in ChatGPT comes before a script that needs Node")
}

func codexRunsWithThePathATerminalWouldGiveIt() throws {
    let home = URL(fileURLWithPath: "/Users/someone")
    let environment = CodexInstallation.environment(base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone"], home: home)
    let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    try expect(path.prefix(2) == ["/usr/bin", "/bin"], "What it was given comes first")
    for wanted in ["/opt/homebrew/bin", "/usr/local/bin", "/Users/someone/.local/bin"] {
        try expect(path.contains(wanted), "\(wanted) is there, where npm's Node usually is")
    }
    try expect(environment["HOME"] == "/Users/someone", "The rest is left as it was")
    let twice = CodexInstallation.environment(base: ["PATH": "/usr/local/bin:/usr/bin"], home: home)["PATH"] ?? ""
    try expect(twice.components(separatedBy: "/usr/local/bin").count == 2, "Nothing twice")
}
