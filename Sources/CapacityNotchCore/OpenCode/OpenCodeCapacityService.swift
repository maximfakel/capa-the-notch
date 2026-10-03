import Foundation

/// Where OpenCode keeps its sign-in, and the one thing Capacity Notch takes
/// from it: the Go plan's key, read at each request and kept nowhere
/// (ADR 0001, amended 2026-10-02).
public enum OpenCodeAuth {
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    /// The Go plan's key in OpenCode's file, and nothing else: the ADR lets
    /// Capacity Notch take that one key, not another of OpenCode's entries.
    public static func key(in file: Data) -> String? {
        guard
            let entries = try? JSONSerialization.jsonObject(with: file) as? [String: Any],
            let entry = entries["opencode-go"] as? [String: Any],
            let key = entry["key"] as? String, !key.isEmpty
        else { return nil }
        return key
    }

    /// Reads the file now; nil when there is none or no key in it. The whole
    /// file is in memory for that moment — it holds other sign-ins too —
    /// and only the Go key leaves this function.
    public static func readKey(from fileURL: URL = defaultFileURL) -> String? {
        (try? Data(contentsOf: fileURL)).flatMap(key(in:))
    }
}

/// The only address the key is ever sent to. Undocumented: OpenCode's own
/// console reads it (anomalyco/opencode PR 16513).
public enum OpenCodeUsageEndpoint {
    public static let url = URL(string: "https://opencode.ai/zen/go/v1/usage")!
}

/// Asks the usage endpoint once. Separate so tests answer without a network.
public protocol OpenCodeUsageClient: Sendable {
    func usage(key: String) async throws -> (status: Int, body: Data)
}

public struct OpenCodeHTTPClient: OpenCodeUsageClient {
    /// One session for the application's life, ephemeral: nothing it hears
    /// is cached or kept on disk.
    private static let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func usage(key: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: OpenCodeUsageEndpoint.url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Nothing of the answer is cached: it carries the person's plan.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (body, response) = try await Self.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
}

/// What the endpoint answers, as Quota Windows: `rolling` is the five hours,
/// `weekly` the week; a window it marks rate-limited has nothing left, since
/// that is what OpenCode lets a person do. `monthly` is no window — only
/// whether it is used up, and until when.
public struct OpenCodeUsageReading: Equatable, Sendable {
    public enum Month: Equatable, Sendable {
        case available
        case usedUp(until: Date?)
    }

    public let windows: [QuotaWindow]
    public let month: Month

    public static func parse(_ body: Data) -> OpenCodeUsageReading? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let usage = object["usage"] as? [String: Any],
            let rolling = Window(usage["rolling"]),
            let weekly = Window(usage["weekly"])
        else { return nil }

        let month = Window(usage["monthly"])
        return OpenCodeUsageReading(
            windows: [
                rolling.quotaWindow(id: "opencode-five-hour", label: "5 hour", minutes: 300),
                weekly.quotaWindow(id: "opencode-weekly", label: "Weekly", minutes: 10_080),
            ],
            month: month.map { $0.isUsedUp ? .usedUp(until: $0.resetsAt) : .available } ?? .available
        )
    }

    private struct Window {
        let usedFraction: Double
        let isRateLimited: Bool
        let resetsAt: Date?

        init?(_ value: Any?) {
            guard
                let window = value as? [String: Any],
                let status = window["status"] as? String,
                let percent = (window["percent"] as? NSNumber)?.doubleValue
            else { return nil }
            isRateLimited = status == "rate-limited"
            usedFraction = isRateLimited ? 1 : min(max(percent / 100, 0), 1)
            resetsAt = (window["resetsAt"] as? String).flatMap { Self.dates.date(from: $0) }
        }

        nonisolated(unsafe) private static let dates = ISO8601DateFormatter()

        var isUsedUp: Bool { usedFraction >= 1 }

        func quotaWindow(id: String, label: String, minutes: Int) -> QuotaWindow {
            QuotaWindow(id: id, label: label, durationMinutes: minutes, usedFraction: usedFraction, resetsAt: resetsAt)
        }
    }
}

/// Reads OpenCode Go's Capacity: the key from OpenCode's file at each
/// request, the endpoint no more often than every five minutes unless a
/// person asks. Like the other services, a failure after a reading keeps it
/// as Stale Capacity, and nothing read is never drawn as zero.
public actor OpenCodeCapacityService {
    public static let minimumInterval: TimeInterval = 5 * 60

    private let now: @Sendable () -> Date
    private let readKey: @Sendable () -> String?
    private let client: any OpenCodeUsageClient
    private var isConnected = false
    private var lastAsked: Date?
    private var lastSuccessfulSnapshot: CapacitySnapshot?

    public nonisolated let snapshots: AsyncStream<CapacitySnapshot>
    private nonisolated let snapshotContinuation: AsyncStream<CapacitySnapshot>.Continuation

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        readKey: @escaping @Sendable () -> String? = { OpenCodeAuth.readKey() },
        client: any OpenCodeUsageClient = OpenCodeHTTPClient()
    ) {
        self.now = now
        self.readKey = readKey
        self.client = client
        var capturedContinuation: AsyncStream<CapacitySnapshot>.Continuation!
        snapshots = AsyncStream { capturedContinuation = $0 }
        snapshotContinuation = capturedContinuation
    }

    public func connect() async {
        guard !isConnected else { return }
        isConnected = true
        await refresh(force: true)
    }

    /// Asks the endpoint unless it was asked less than five minutes ago;
    /// `force` is a person asking, which is answered at once.
    public func refresh(force: Bool = false) async {
        guard isConnected else { return }
        if !force, let lastAsked, now().timeIntervalSince(lastAsked) < Self.minimumInterval { return }

        guard let key = readKey() else {
            lastAsked = now()
            holdLastCapacityOrDisconnect(.openCodeNotSignedIn)
            return
        }
        lastAsked = now()

        let answer: (status: Int, body: Data)
        do {
            answer = try await client.usage(key: key)
        } catch {
            // Disconnected while asking: the switched-off card stands, not
            // an "unreachable" that arrived after it.
            guard isConnected else { return }
            holdLastCapacityOrDisconnect(.openCodeUnreachable)
            return
        }
        guard isConnected else { return }

        switch answer.status {
        case 200:
            guard let reading = OpenCodeUsageReading.parse(answer.body) else {
                holdLastCapacityOrDisconnect(.openCodeAnswerNotUnderstood)
                return
            }
            let snapshot = CapacitySnapshot(
                provider: .openCode,
                capturedAt: now(),
                windows: reading.windows,
                connectionState: .fresh,
                statusReason: {
                    guard case let .usedUp(until) = reading.month else { return nil }
                    return .openCodeMonthlyLimitReached(until: until)
                }()
            )
            lastSuccessfulSnapshot = snapshot
            snapshotContinuation.yield(snapshot)
        case 401, 403:
            holdLastCapacityOrDisconnect(.openCodeKeyRefused)
        default:
            holdLastCapacityOrDisconnect(.openCodeUnreachable)
        }
    }

    public func disconnect() {
        isConnected = false
        lastSuccessfulSnapshot = nil
        lastAsked = nil
        snapshotContinuation.yield(.disconnected(provider: .openCode, capturedAt: now(), reason: .openCodeDisconnected))
    }

    private func holdLastCapacityOrDisconnect(_ reason: CapacityStatusReason) {
        guard let lastSuccessfulSnapshot else {
            snapshotContinuation.yield(.disconnected(provider: .openCode, capturedAt: now(), reason: reason))
            return
        }
        snapshotContinuation.yield(
            CapacitySnapshot(
                provider: .openCode,
                capturedAt: lastSuccessfulSnapshot.capturedAt,
                windows: lastSuccessfulSnapshot.windows,
                connectionState: .stale,
                statusReason: reason
            )
        )
    }
}
