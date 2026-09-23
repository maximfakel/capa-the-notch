import CapacityNotchCore
import Foundation

private let reportedAt = Date(timeIntervalSince1970: 1_700_000_000)

/// Errors shaped like the ones these Providers really produce, each carrying
/// something that must never leave the machine.
private let secretBearingErrors = [
    "error sending request: Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
    "failed to read sk-ant-oat01-7Qv3mK9xR2wL5nB8tY4cE6uH1sJ0aD",
    "no credential at /Users/jordanlee/.claude/.credentials.json",
    "account jordan.lee@example.com is not authorised",
    "organization 3f9d1bdc-5671-44be-bc29-0825e2fb372e has no access",
    "token=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEf",
]

private func reportCarrying(_ detail: String) -> String {
    DiagnosticReport(
        applicationVersion: "0.1.0",
        systemVersion: "26.6.2",
        generatedAt: reportedAt,
        providers: [
            ProviderDiagnostic(
                snapshot: CapacitySnapshot.disconnected(
                    provider: .codex,
                    capturedAt: reportedAt,
                    // The one place a Provider's own words reach the domain.
                    reason: .providerUnavailable(detail: detail)
                ),
                consecutiveTransientFailures: 3
            ),
        ]
    ).text()
}

func aProvidersOwnWordsNeverReachTheReport() throws {
    for error in secretBearingErrors {
        let report = reportCarrying(error)

        for fragment in error.split(separator: " ") where fragment.count >= 8 {
            try expect(
                !report.contains(fragment),
                "\"\(fragment)\" reached the report:\n\(report)"
            )
        }

        try expect(
            report.contains("reason provider-unavailable"),
            "The report still says what went wrong, in a word:\n\(report)"
        )
    }
}

func scrubbingCatchesWhatGetsInFromOutside() throws {
    let cases = [
        ("Bearer eyJhbGciOiJIUzI1NiJ9.eyJhIjoxfQ.sig", "eyJ"),
        ("key sk-ant-oat01-7Qv3mK9xR2wL5nB8tY4cE6uH1sJ0aD", "sk-ant"),
        ("/Users/jordanlee/Library", "jordanlee"),
        ("jordan.lee@example.com", "@example.com"),
        ("3f9d1bdc-5671-44be-bc29-0825e2fb372e", "3f9d1bdc"),
        ("AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", "AbCdEfGh"),
    ]

    for (input, forbidden) in cases {
        let scrubbed = Redaction.scrub(input)
        try expect(
            !scrubbed.contains(forbidden),
            "\"\(forbidden)\" survived scrubbing: \(scrubbed)"
        )
    }

    try expect(
        Redaction.scrub("/Users/someone/Library") == "~/Library",
        "A home directory becomes a tilde rather than a name, got \(Redaction.scrub("/Users/someone/Library"))"
    )
}

func theReportStaysUsefulForEveryFailureWorthReporting() throws {
    let failures: [(CapacityStatusReason, String)] = [
        (.providerNotInstalled, "provider-not-installed"),
        (.providerIncompatible(detail: "too old"), "provider-incompatible"),
        (.providerNotAuthenticated, "provider-not-authenticated"),
        (.providerUnavailable(detail: "closed"), "provider-unavailable"),
        (.providerAnswerNotUnderstood, "provider-answer-not-understood"),
        (.providerCouldNotRead(detail: "error sending request"), "provider-could-not-read"),
        (.claudeStatusLineStale, "claude-status-line-stale"),
        (.claudeStatusLineUnavailable, "claude-status-line-unavailable"),
        (.claudeCodeNotInstalled, "claude-code-not-installed"),
        (.claudeUsageFailed, "claude-usage-failed"),
        (.claudeUsageNotUnderstood, "claude-usage-not-understood"),
        (.staleFromArchive, "stale-from-archive"),
    ]

    for (reason, code) in failures {
        let report = DiagnosticReport(
            applicationVersion: "0.1.0",
            systemVersion: "26.6.2",
            generatedAt: reportedAt,
            providers: [
                ProviderDiagnostic(
                    snapshot: CapacitySnapshot.disconnected(
                        provider: .claudeCode, capturedAt: reportedAt, reason: reason
                    )
                ),
            ]
        ).text()

        try expect(report.contains("reason \(code)"), "\(code) should be reportable:\n\(report)")
    }
}

func aBugReportCanTellWhyTheBridgeFileCannotBeRead() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("capacity-notch-bridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    func observation(of contents: String?) throws -> String? {
        let file = directory.appendingPathComponent("\(UUID().uuidString).json")
        if let contents { try contents.write(to: file, atomically: true, encoding: .utf8) }
        return ClaudeStatusLineBridge.observation(of: file)
    }

    let cases: [(String?, String?, String)] = [
        (nil, "claude-bridge-snapshot-missing", "no file"),
        ("not json at all", "claude-bridge-unreadable", "a file that is not the bridge's JSON"),
        (#"{"schema_version":2,"captured_at":1,"windows":[]}"#, "claude-bridge-schema-unknown", "another schema version"),
        (#"{"schema_version":1,"captured_at":1,"windows":[{"id":"fortnight","used_percentage":5,"resets_at":2}]}"#,
         "claude-bridge-no-windows", "no window this build knows"),
        (#"{"schema_version":1,"captured_at":1,"windows":[{"id":"five_hour","used_percentage":5,"resets_at":2}]}"#,
         nil, "a file that reads"),
    ]
    for (contents, expected, what) in cases {
        let said = try observation(of: contents)
        try expect(said == expected, "\(what) should note \(expected ?? "nothing"), got \(said ?? "nothing")")
        if let said {
            try expect(Redaction.scrub(said) == said, "\(said) must survive the report's scrubbing")
        }
    }
}

func theReportSaysWhatAMaintainerNeedsToKnow() throws {
    let report = DiagnosticReport(
        applicationVersion: "0.1.0",
        systemVersion: "26.6.2",
        generatedAt: reportedAt,
        providers: [
            ProviderDiagnostic(
                snapshot: CapacitySnapshot(
                    provider: .codex,
                    capturedAt: reportedAt,
                    windows: [
                        QuotaWindow(id: "a", label: "5 hour", durationMinutes: 300,
                                    usedFraction: 0.5, resetsAt: nil),
                    ],
                    connectionState: .fresh
                ),
                consecutiveTransientFailures: 2
            ),
        ],
        observations: ["claude-bridge-snapshot-missing"]
    ).text()

    for expected in [
        "Capacity Notch 0.1.0", "macOS 26.6.2", "generated 2023-11-14",
        "codex:", "state fresh", "windows 1", "retries 2",
        "note claude-bridge-snapshot-missing",
    ] {
        try expect(report.contains(expected), "It should carry \"\(expected)\":\n\(report)")
    }
}
