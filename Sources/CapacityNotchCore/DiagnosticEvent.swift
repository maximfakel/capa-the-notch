import Foundation

/// A line the application writes to its own diagnostic log.
///
/// Held to the report's rule: a closed vocabulary of states, counts and
/// codes. An error is kept as its domain and code, never its description, and
/// nothing dictated — no audio, no recognised text — has a case here.
public enum DiagnosticEvent: Equatable, Sendable {
    case launched(version: String, system: String)
    case dictation(DictationObservation)
    case dictationDownloadStarted
    case dictationDownloadAnswered(status: Int, bytes: Int64)
    case dictationDownloadProgress(percent: Int)
    case dictationDownloadFailed(DiagnosticError)
    case dictationDownloadCancelled
    case dictationInstallFailed(DiagnosticError)
    case dictationModelInstalled
    case microphoneRequested(MicrophoneAuthorization)
    case microphoneAnswered(granted: Bool, now: MicrophoneAuthorization)
    case microphoneSettingsOpened(MicrophoneAuthorization)
    case microphoneStartFailed(DiagnosticError)
    case recordingStarted(AudioInput)
    case microphoneInputChanged(AudioInput?)
    case recordingStopped(samples: Int)
    case recordingRefused(reason: String)
    case recognitionFinished(samples: Int, empty: Bool)
    case recognitionFailed(DiagnosticError)
    case delivered(inserted: Bool)
    case translator(TranslatorEvent)

    public var line: String {
        switch self {
        case let .launched(version, system): "launched \(version) macOS \(system)"
        case let .dictation(state): "dictation \(state.codes.joined(separator: " "))"
        case .dictationDownloadStarted: "dictation download started"
        case let .dictationDownloadAnswered(status, bytes): "dictation download answered \(status) bytes \(bytes)"
        case let .dictationDownloadProgress(percent): "dictation download \(percent)%"
        case let .dictationDownloadFailed(error): "dictation download failed \(error.code)"
        case .dictationDownloadCancelled: "dictation download cancelled"
        case let .dictationInstallFailed(error): "dictation install failed \(error.code)"
        case .dictationModelInstalled: "dictation model installed"
        case let .microphoneRequested(status): "microphone requested from \(status.rawValue)"
        case let .microphoneAnswered(granted, now): "microphone answered \(granted ? "granted" : "refused") now \(now.rawValue)"
        case let .microphoneSettingsOpened(status): "microphone settings opened at \(status.rawValue)"
        case let .microphoneStartFailed(error): "microphone start failed \(error.code)"
        case let .recordingStarted(input): "recording started \(input.code)"
        case let .microphoneInputChanged(input): "microphone input changed \(input?.code ?? "and could not restart")"
        case let .recordingStopped(samples): "recording stopped samples \(samples)"
        case let .recordingRefused(reason): "recording refused \(reason)"
        case let .recognitionFinished(samples, empty): "recognition finished samples \(samples)\(empty ? " empty" : "")"
        case let .recognitionFailed(error): "recognition failed \(error.code)"
        case let .delivered(inserted): "delivered \(inserted ? "inserted" : "copied")"
        case let .translator(event): event.line
        }
    }

    /// One log line: the time, then the event, scrubbed like a report.
    public func entry(at date: Date, formatter: ISO8601DateFormatter = DiagnosticReport.timestamps()) -> String {
        Redaction.scrub("\(formatter.string(from: date)) capacity-notch \(line)")
    }
}

/// An error as a log may carry it: where it came from and its number.
public struct DiagnosticError: Equatable, Sendable {
    public let domain: String
    public let number: Int

    public init(domain: String, number: Int) {
        self.domain = domain
        self.number = number
    }

    public init(_ error: Error) {
        let error = error as NSError
        self.init(domain: error.domain, number: error.code)
    }

    public var code: String { "\(domain) \(number)" }
}

/// The input's shape, which tells a Bluetooth headset (16 kHz, one channel)
/// from the Mac's microphones without naming any device.
public struct AudioInput: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public init(sampleRate: Int, channels: Int) { self.sampleRate = sampleRate; self.channels = channels }
    public var code: String { "\(sampleRate)Hz \(channels)ch" }
}

public enum MicrophoneAuthorization: String, Sendable {
    case notDetermined = "not-determined"
    case restricted
    case denied
    case authorized
}

/// What a report says about the Dictation Module: whether it is on, has its
/// model, may hear and may insert — and whether the build it runs in could
/// ever be allowed the microphone.
public struct DictationObservation: Equatable, Sendable {
    public let enabled: Bool
    public let modelReady: Bool
    public let microphone: MicrophoneAuthorization
    public let microphoneEntitled: Bool
    public let insertionAllowed: Bool

    public init(enabled: Bool, modelReady: Bool, microphone: MicrophoneAuthorization, microphoneEntitled: Bool, insertionAllowed: Bool) {
        self.enabled = enabled
        self.modelReady = modelReady
        self.microphone = microphone
        self.microphoneEntitled = microphoneEntitled
        self.insertionAllowed = insertionAllowed
    }

    public var codes: [String] {
        guard enabled else { return ["off"] }
        var codes = [
            modelReady ? "model-ready" : "model-missing",
            "mic-\(microphone.rawValue)",
            insertionAllowed ? "insertion-allowed" : "insertion-not-allowed",
        ]
        if !microphoneEntitled { codes.append("mic-not-entitled") }
        return codes
    }

    /// The same codes as a report's notes, each under the 32 characters
    /// `Redaction` would rub out as an opaque secret.
    public var observations: [String] { codes.map { "dictation-\($0)" } }
}
