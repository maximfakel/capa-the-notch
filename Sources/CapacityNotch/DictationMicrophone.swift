import AVFoundation
import Foundation

/// The tap owns the converter; the lock owns the bounded sample buffer.
/// Engine start/stop run only on MainActor. Raw audio never reaches disk.
final class DictationMicrophone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var accepting = false
    @MainActor private var hasTap = false

    @MainActor func start(level: @escaping @Sendable (Float) -> Void, limit: @escaping @Sendable () -> Void) throws {
        lock.withLock { samples = []; accepting = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw DictationFailure("No microphone is available. Connect one and try again.") }
        installTap(on: input, format: format, target: target, converter: converter, level: level, limit: limit)
        hasTap = true
        do { try engine.start() } catch { _ = stop(); throw error }
    }
    /// Form the real-time callback outside MainActor so AVFoundation can invoke it
    /// from its audio queue without a Swift executor assertion.
    private nonisolated func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        target: AVAudioFormat,
        converter: AVAudioConverter,
        level: @escaping @Sendable (Float) -> Void,
        limit: @escaping @Sendable () -> Void
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / format.sampleRate) + 64) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let data = output.floatChannelData else { return }
            let chunk = UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))
            let full = self.lock.withLock { () -> Bool in
                guard self.accepting else { return false }
                let room = 960_000 - self.samples.count
                self.samples.append(contentsOf: chunk.prefix(max(0, room)))
                if chunk.count >= room { self.accepting = false; return true }
                return false
            }
            if !chunk.isEmpty {
                let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
                let decibels = 20 * log10(max(rms, 0.000_01))
                let measuredLevel = min(1, max(0, (decibels + 55) / 35))
                DispatchQueue.main.async { level(measuredLevel) }
            }
            if full { DispatchQueue.main.async(execute: limit) }
        }
    }

    @MainActor func stop() -> [Float] {
        lock.withLock { accepting = false }
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        engine.stop()
        return lock.withLock { let result = samples; samples = []; return result }
    }
}
