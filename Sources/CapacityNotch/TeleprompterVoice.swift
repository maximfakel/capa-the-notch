import AudioToolbox
import AVFoundation
import CapacityNotchCore
import CoreAudio
import Foundation

/// Ticket 20: the Teleprompter hears the Script being read. Every fifth of a
/// second the last few seconds are recognised again, on this Mac, with the
/// model the Dictation Module downloads; what was heard goes to the
/// controller's `ScriptFollower` and is then dropped. No audio and no text is
/// kept, written or logged (ADR 0003). Measured in
/// `docs/research/teleprompter-voice-follow.md`.
@MainActor
final class TeleprompterVoice {
    enum Trouble: Equatable {
        /// Microphone access was refused, or never asked and now refused.
        case microphoneDenied
        /// Dictation's speech model is not on this Mac.
        case modelMissing
        /// The microphone or the model would not start.
        case failed
    }

    /// The window heard again each step, and the step. Chosen by the
    /// measurement: 2 s holds enough words to place the voice (3 and 4 s lit
    /// no sooner and cost more); 2 threads decode it in about 70 ms, at under
    /// one core while the voice is heard.
    nonisolated static let window = 2.0
    nonisolated static let step = 0.2
    nonisolated static let threads: Int32 = 2

    /// What the recogniser made of the last few seconds; the caller matches
    /// it to the Script and lets it go.
    var heard: (String) -> Void = { _ in }
    var trouble: (Trouble) -> Void = { _ in }

    private let microphone = RollingMicrophone(seconds: TeleprompterVoice.window)
    private let engine = TeleprompterVoiceEngine()
    private var timer: Timer?
    private var busy = false
    /// Changes on every start and stop, so a decode finishing after a stop is dropped.
    private var generation = 0
    private var quietSteps = 0
    private var unload: Task<Void, Never>?

    var isListening: Bool { timer != nil }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks macOS once, when following is turned on; true when it may listen.
    static func askForMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() {
        guard timer == nil else { return }
        guard Self.microphoneStatus == .authorized else { trouble(.microphoneDenied); return }
        guard DictationModelFiles.exists() else { trouble(.modelMissing); return }
        unload?.cancel()
        unload = nil
        generation += 1
        quietSteps = 0
        do { try microphone.start() } catch { trouble(.failed); return }
        let generation = generation
        Task { [engine] in
            do { try await engine.load(DictationModelFiles.directory) } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.stop()
                    self.trouble(.failed)
                }
            }
        }
        let timer = Timer(timeInterval: Self.step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The microphone off at once; the model let go a minute later, so a
    /// pause and resume does not load it again.
    func stop() {
        guard timer != nil else { return }
        generation += 1
        timer?.invalidate()
        timer = nil
        busy = false
        microphone.stop()
        unload?.cancel()
        unload = Task { [engine] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await engine.unload()
        }
    }

    private func tick() {
        guard !busy else { return }
        let samples = microphone.window()
        guard samples.count >= Int(0.3 * 16_000) else { return }
        // A reader who has stopped costs nothing: once the newest moment has
        // been quiet for two steps, the window is not heard again until a
        // voice comes back. The first quiet step is still heard, for the
        // last word before it.
        if RollingMicrophone.isQuiet(samples.suffix(Int(0.6 * 16_000))) {
            quietSteps += 1
            if quietSteps > 1 { return }
        } else {
            quietSteps = 0
        }
        busy = true
        let generation = generation
        Task { [engine, weak self] in
            let text = try? await engine.hear(samples)
            guard let self, self.generation == generation else { return }
            self.busy = false
            if let text { self.heard(text) }
        }
    }
}

/// The model, loaded on this actor's executor and decoded there.
actor TeleprompterVoiceEngine {
    private var recognizer: DictationEngine.Recognizer?

    func load(_ folder: URL) throws {
        guard recognizer == nil else { return }
        recognizer = try DictationEngine.Recognizer(folder: folder, threads: TeleprompterVoice.threads)
    }

    func hear(_ samples: [Float]) throws -> String {
        guard let recognizer else { return "" }
        return try recognizer.decode(samples)
    }

    func unload() { recognizer = nil }
}

/// The microphone at 16 kHz mono, keeping only the last few seconds in
/// memory — never a file. An input-only AudioQueue, as Dictation's: it asks
/// for 16 kHz itself and never opens an output (see `DictationMicrophone`).
final class RollingMicrophone: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var samples: [Float] = []
    private var queue: AudioQueueRef?
    private let callbacks = DispatchQueue(label: "CapacityNotch.TeleprompterVoice")

    init(seconds: Double) { capacity = Int(seconds * 16_000) }

    /// About -48 dBFS: a room, not a voice. Unverified on other microphones.
    static func isQuiet(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return true }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return power < 0.004 * 0.004
    }

    @MainActor func start() throws {
        stop()
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var made: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&made, &format, 0, callbacks) { [weak self] queue, buffer, _, _, _ in
            self?.received(buffer, from: queue)
        }
        guard status == noErr, let made else { throw DictationFailure("The microphone could not start.") }
        for _ in 0 ..< 3 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(made, 1_600 * 4, &buffer) == noErr, let buffer { AudioQueueEnqueueBuffer(made, buffer, 0, nil) }
        }
        lock.withLock { samples = []; queue = made }
        guard AudioQueueStart(made, nil) == noErr else {
            stop()
            throw DictationFailure("The microphone could not start.")
        }
    }

    private func received(_ buffer: AudioQueueBufferRef, from queue: AudioQueueRef) {
        lock.withLock {
            guard self.queue == queue else { return }
            defer { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
            let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count))
            if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        }
    }

    /// The last few seconds, as they are now.
    func window() -> [Float] { lock.withLock { samples } }

    @MainActor func stop() {
        let queue = lock.withLock { () -> AudioQueueRef? in
            defer { self.queue = nil; samples = [] }
            return self.queue
        }
        if let queue { AudioQueueStop(queue, true); AudioQueueDispose(queue, true) }
    }
}
