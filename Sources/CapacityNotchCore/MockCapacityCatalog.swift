import Foundation

public enum MockCapacityCatalog {
    public static func snapshots(capturedAt: Date = .now) -> [CapacitySnapshot] {
        [
            CapacitySnapshot(
                provider: .codex,
                capturedAt: capturedAt,
                windows: [
                    QuotaWindow(
                        id: "codex-five-hour",
                        label: "5 hour",
                        durationMinutes: 300,
                        usedFraction: 0.70,
                        resetsAt: capturedAt.addingTimeInterval(2 * 60 * 60)
                    ),
                ],
                connectionState: .mock
            ),
            CapacitySnapshot(
                provider: .claudeCode,
                capturedAt: capturedAt,
                windows: [
                    QuotaWindow(
                        id: "claude-five-hour",
                        label: "5 hour",
                        durationMinutes: 300,
                        usedFraction: 0.45,
                        resetsAt: capturedAt.addingTimeInterval(3 * 60 * 60)
                    ),
                ],
                connectionState: .mock
            ),
        ]
    }
}
