@preconcurrency import ApplicationServices
import AppKit
import AVFoundation
import CapacityNotchCore
import Combine

@MainActor
final class DictationController: ObservableObject {
    enum Presentation: Equatable { case hidden, recording, recognizing, inserted, copied, error }
    @Published private(set) var isEnabled: Bool
    @Published private(set) var presentation: Presentation = .hidden
    let audioLevel = CurrentValueSubject<Float, Never>(0)
    var level: Float { audioLevel.value }
    @Published private(set) var remaining = 60
    @Published private(set) var error: String?
    @Published private(set) var deliveryMessage: String?
    @Published private(set) var modelReady: Bool
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var insertionAllowed = AXIsProcessTrusted()
    @Published private(set) var shortcutUnavailable = false
    @Published var keepsHistory: Bool { didSet { preferences.dictationKeepsHistory = keepsHistory } }
    @Published var replacements: [DictationReplacement] { didSet { preferences.dictationReplacements = replacements } }
    @Published private(set) var history: DictationHistory
    @Published private(set) var shortcut: KeyShortcut
    var openSettings: () -> Void = {}
    private let preferences: Preferences
    private let engine = DictationEngine()
    private let microphone = DictationMicrophone()
    private var hotKey: DictationHotKey?
    private var session = DictationSession()
    private var shortcutSuspended = false
    private var keyHeld = false
    private var sessionReplacements: [DictationReplacement] = []
    private var target: DictationDelivery?
    private var clock: Task<Void, Never>?
    private var recognition: Task<Void, Never>?
    private var download: Task<Void, Never>?
    /// The log hears a download a quarter at a time, so one that stalls shows where.
    private var loggedQuarter = 0
    private var dismiss: Task<Void, Never>?
    private var observing: AnyCancellable?
    private var systemObservers: Set<AnyCancellable> = []
    private let registersShortcuts: Bool

    init(preferences: Preferences, registersShortcuts: Bool = true) {
        self.preferences = preferences; self.registersShortcuts = registersShortcuts
        isEnabled = preferences.dictationEnabled; keepsHistory = preferences.dictationKeepsHistory
        replacements = preferences.dictationReplacements; history = preferences.dictationHistory
        shortcut = preferences.dictationShortcut; modelReady = DictationModelFiles.exists()
        if registersShortcuts {
            observing = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.keyHeld = false; self?.cancel() } }.store(in: &systemObservers)
            // A headset connecting or leaving mid-recording: capture goes on
            // with the new input, keeping what was already heard.
            microphone.inputChanged = { [weak self] input in
                guard let self, presentation == .recording else { return }
                DiagnosticLog.record(.microphoneInputChanged(input.map { .init(sampleRate: $0.sampleRate, channels: $0.channels) }))
                guard input == nil else { return }
                cancel(); fail("The microphone changed. Select your input device and try again.")
            }
            register()
        }
    }
    /// Only the screenshot fixture can set a display state without recording.
    func preview(_ state: Presentation) {
        guard !registersShortcuts else { return }
        modelReady = true; microphoneAllowed = true; insertionAllowed = true
        presentation = state; audioLevel.send(0.35); remaining = 8
    }
    func previewLevel(_ value: Float) {
        guard !registersShortcuts else { return }
        audioLevel.send(value)
    }
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled; preferences.dictationEnabled = enabled
        if !enabled { keyHeld = false; cancel(); cancelDownload(); Task { await engine.unload() } }
        register()
    }
    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        insertionAllowed = AXIsProcessTrusted()
    }
    /// What a bug report and the log say about Dictation.
    var observation: DictationObservation {
        DictationObservation(
            enabled: isEnabled, modelReady: modelReady, microphone: Self.microphoneStatus,
            microphoneEntitled: DiagnosticLog.microphoneEntitled, insertionAllowed: AXIsProcessTrusted()
        )
    }
    private static var microphoneStatus: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    func requestMicrophone() {
        guard isEnabled, modelReady else { return }
        if Self.microphoneStatus == .notDetermined {
            Task { await askForMicrophone() }
        } else {
            openMicrophoneSettings()
        }
    }
    /// macOS's own question, which it asks only once; onboarding asks it
    /// before Dictation is on, with the rest of what Capacity Notch needs.
    func askForMicrophone() async {
        DiagnosticLog.record(.microphoneRequested(Self.microphoneStatus))
        microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        DiagnosticLog.record(.microphoneAnswered(granted: microphoneAllowed, now: Self.microphoneStatus))
    }
    func openMicrophoneSettings() {
        DiagnosticLog.record(.microphoneSettingsOpened(Self.microphoneStatus))
        openPrivacy("Microphone")
    }
    func requestInsertion() {
        guard isEnabled else { return }
        askForInsertion()
    }
    func askForInsertion() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        refreshPermissions()
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(url) }
    }
    func startDownload() {
        guard isEnabled, download == nil else { return }
        error = nil; downloadProgress = 0
        download = Task { [weak self] in
            guard let self else { return }
            defer { download = nil; downloadProgress = nil }
            DiagnosticLog.record(.dictationDownloadStarted)
            var installing = false
            do {
                loggedQuarter = 0
                let (archive, response) = try await DictationDownloader.download(DictationModelFiles.source) { [weak self] fraction in
                    Task { @MainActor in self?.downloaded(fraction) }
                }
                defer { try? FileManager.default.removeItem(at: archive) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let bytes = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                DiagnosticLog.record(.dictationDownloadAnswered(status: status, bytes: bytes))
                guard status == 200 else { throw DictationFailure("Download failed. Check your connection and try again.") }
                try Task.checkCancellation()
                installing = true
                // Installation and hashing do not block the main actor.
                let worker = Task.detached { try DictationModelFiles.install(archive) }
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                modelReady = true
                DiagnosticLog.record(.dictationModelInstalled)
            } catch is CancellationError {
                DiagnosticLog.record(.dictationDownloadCancelled)
            } catch {
                DiagnosticLog.record(installing ? .dictationInstallFailed(DiagnosticError(error)) : .dictationDownloadFailed(DiagnosticError(error)))
                if !Task.isCancelled { self.error = "Download failed. Check your connection and free disk space, then try again." }
            }
        }
    }
    private func downloaded(_ fraction: Double) {
        guard download != nil else { return }
        downloadProgress = fraction
        let quarter = Int(fraction * 4) * 25
        if quarter > loggedQuarter, quarter < 100 { loggedQuarter = quarter; DiagnosticLog.record(.dictationDownloadProgress(percent: quarter)) }
    }
    func cancelDownload() { download?.cancel() }
    func setShortcut(_ shortcut: KeyShortcut) {
        self.shortcut = shortcut; preferences.dictationShortcut = shortcut; register()
    }
    func suspendShortcut(_ suspend: Bool) {
        shortcutSuspended = suspend
        if suspend { _ = hotKey?.register(nil) } else { register() }
    }
    private func register() {
        guard registersShortcuts else { return }
        guard isEnabled, !shortcutSuspended else { _ = hotKey?.register(nil); return }
        if hotKey == nil {
            let key = DictationHotKey()
            key.pressed = { [weak self] in
                guard let self, !keyHeld else { return }
                keyHeld = true; begin()
            }
            key.released = { [weak self] in self?.keyHeld = false; self?.finishRecording() }
            key.cancelled = { [weak self] in self?.cancel() }
            hotKey = key
        }
        shortcutUnavailable = !(hotKey?.register(shortcut) ?? false)
    }
    func begin() {
        guard isEnabled, session.phase == .idle else { return }
        refreshPermissions()
        guard modelReady else { DiagnosticLog.record(.recordingRefused(reason: "model-missing")); fail("Download the speech model in Dictation settings before recording."); return }
        guard microphoneAllowed else { DiagnosticLog.record(.recordingRefused(reason: "mic-\(Self.microphoneStatus.rawValue)")); fail("Microphone access is required. Allow Capacity Notch in System Settings → Privacy & Security → Microphone."); return }
        guard let id = session.begin() else { return }
        sessionReplacements = replacements
        dismiss?.cancel(); target = DictationDelivery.capture(); error = nil; deliveryMessage = nil; remaining = 60
        do {
            let input = try microphone.start(level: { [weak self] value in
                Task { @MainActor in
                    guard self?.session.phase == .recording(id) else { return }
                    self?.audioLevel.send(value)
                }
            }, limit: { [weak self] in Task { @MainActor in
                guard self?.session.phase == .recording(id) else { return }
                self?.finishRecording()
            } })
            presentation = .recording; hotKey?.captureEscape(true)
            DiagnosticLog.record(.recordingStarted(.init(sampleRate: input.sampleRate, channels: input.channels)))
            clock = Task { [weak self] in
                let start = ContinuousClock.now
                for _ in 0..<60 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, session.phase == .recording(id) else { return }
                    let elapsed = Int(start.duration(to: .now).components.seconds)
                    remaining = max(0, 60 - elapsed)
                    if remaining == 0 { finishRecording(); return }
                }
            }
        } catch {
            DiagnosticLog.record(.microphoneStartFailed(DiagnosticError(error)))
            session.cancel(); fail("The microphone could not start. Check microphone access and your input device in System Settings.") }
    }
    func finishRecording() {
        guard let id = session.stop() else { return }
        clock?.cancel(); clock = nil
        let samples = microphone.stop()
        DiagnosticLog.record(.recordingStopped(samples: samples.count))
        presentation = .recognizing; audioLevel.send(0)
        recognition = Task { [weak self, engine] in
            do {
                let raw = try await engine.recognize(samples, folder: DictationModelFiles.directory)
                guard let self, !Task.isCancelled, session.complete(id) else { return }
                let result = DictationReplacement.apply(sessionReplacements, to: raw)
                DiagnosticLog.record(.recognitionFinished(samples: samples.count, empty: result.isEmpty))
                // Nothing to fix, only to try again, so it does not wait for Escape.
                guard !result.isEmpty else { fail("No speech was recognised. Check your microphone and try again.", hidesAfter: .seconds(2.5)); return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string)
                let delivery = target; target = nil
                deliveryMessage = await delivery?.insert(result) ?? DictationDelivery.lastCaptureFailure ?? "No external application was captured when recording began."
                presentation = deliveryMessage == nil ? .inserted : .copied
                DiagnosticLog.record(.delivered(inserted: deliveryMessage == nil))
                hotKey?.captureEscape(false)
                history.append(result, enabled: keepsHistory); preferences.dictationHistory = history
                let dismissDelay: Duration = .seconds(1.4)
                dismiss = Task { [weak self] in
                    do { try await Task.sleep(for: dismissDelay) } catch { return }
                    self?.presentation = .hidden
                }
            } catch {
                guard let self, !Task.isCancelled, session.complete(id) else { return }
                DiagnosticLog.record(.recognitionFailed(DiagnosticError(error)))
                // Dictation's own failures are sentences with translations;
                // anything else is macOS's wording, which the log keeps.
                fail((error as? DictationFailure)?.message ?? "Recognition failed. Try again.")
            }
        }
    }
    func cancel() {
        session.cancel(); clock?.cancel(); clock = nil; recognition?.cancel(); recognition = nil
        dismiss?.cancel(); _ = microphone.stop(); target = nil; presentation = .hidden; audioLevel.send(0)
        hotKey?.captureEscape(false)
    }
    private func fail(_ message: String, hidesAfter delay: Duration? = nil) {
        // An earlier error's timer would hide this one early.
        dismiss?.cancel(); dismiss = nil
        target = nil; error = message; presentation = .error; hotKey?.captureEscape(true)
        guard let delay else { return }
        dismiss = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, presentation == .error else { return }
            presentation = .hidden; hotKey?.captureEscape(false)
        }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func delete(_ id: UUID) { history.delete(id); preferences.dictationHistory = history }
    func clearHistory() { history.clear(); preferences.dictationHistory = history }
}
