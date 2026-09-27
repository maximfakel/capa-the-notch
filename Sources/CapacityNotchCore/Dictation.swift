import Foundation

/// A held key owns one recording. The generation remains valid only until
/// cancellation or completion; inference may finish after either.
public struct DictationSession: Sendable {
    public static let maximumDuration: TimeInterval = 60
    public enum Phase: Equatable, Sendable { case idle, recording(UUID), recognizing(UUID) }
    public private(set) var phase: Phase = .idle
    public init() {}
    public mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        let id = UUID(); phase = .recording(id); return id
    }
    public mutating func stop() -> UUID? {
        guard case .recording(let id) = phase else { return nil }
        phase = .recognizing(id); return id
    }
    public mutating func cancel() { phase = .idle }
    public mutating func complete(_ id: UUID) -> Bool {
        guard phase == .recognizing(id) else { return false }
        phase = .idle; return true
    }
}

public struct DictationReplacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var heard: String
    public var replacement: String
    public var enabled: Bool
    public init(heard: String, replacement: String, enabled: Bool = true) {
        id = UUID(); self.heard = heard; self.replacement = replacement; self.enabled = enabled
    }
    public static let defaults: [Self] = [
        .init(heard: "пул реквест", replacement: "pull request"),
        .init(heard: "коммит", replacement: "commit"),
        .init(heard: "диплой", replacement: "deploy"),
        .init(heard: "гитхаб", replacement: "GitHub"),
        .init(heard: "тайпскрипт", replacement: "TypeScript"),
        .init(heard: "докер", replacement: "Docker"),
        .init(heard: "кубернетес", replacement: "Kubernetes"),
        .init(heard: "фронтенд", replacement: "frontend"),
        .init(heard: "бэкенд", replacement: "backend"),
        // Also ordinary words or names, so off until the person turns them on.
        .init(heard: "джейсон", replacement: "JSON", enabled: false),
        .init(heard: "реакт", replacement: "React", enabled: false),
    ]
    /// Match the original once, choosing the longest phrase at a position.
    /// Replacements are literal, never regex templates or input to another rule.
    public static func apply(_ rules: [Self], to text: String) -> String {
        let rules = rules.filter { $0.enabled && !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
        var matches: [(NSRange, String)] = []
        for rule in rules {
            let phrase = rule.heard.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])(?:\(phrase))(?![\\p{L}\\p{N}_])", options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if !matches.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
                    matches.append((match.range, rule.replacement))
                }
            }
        }
        let output = NSMutableString(string: text)
        for (range, replacement) in matches.sorted(by: { $0.0.location > $1.0.location }) {
            output.replaceCharacters(in: range, with: replacement)
        }
        return output as String
    }
}

public struct DictationHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let text: String
    }
    public private(set) var entries: [Entry] = []
    public init() {}
    public mutating func append(_ text: String, enabled: Bool, date: Date = Date()) {
        guard enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(Entry(id: UUID(), date: date, text: text), at: 0)
        entries = Array(entries.prefix(50))
    }
    public mutating func delete(_ id: UUID) { entries.removeAll { $0.id == id } }
    public mutating func clear() { entries.removeAll() }
}
