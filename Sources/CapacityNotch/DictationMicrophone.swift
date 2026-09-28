import AudioToolbox
import CoreAudio
import Foundation

/// The lock owns the bounded sample buffer and which queue is live.
/// Start/stop run only on MainActor. Raw audio never reaches disk.
///
/// An input-only AudioQueue, not AVAudioEngine. The engine always opens an
/// output beside its input, and a Bluetooth headset such as the WH-1000XM4
/// is two devices at two rates — a 16 kHz headset microphone, a 44.1 kHz
/// stereo output. The engine kept reconfiguring between them with coreaudiod,
/// holding the main thread until Capacity Notch stopped responding. A queue
/// asks for 16 kHz mono itself and never touches the output.
final class DictationMicrophone: @unchecked Sendable {
    /// What the input was when capture (re)started, for the diagnostic log.
    struct Input: Equatable, Sendable {
        let sampleRate: Int
        let channels: Int
    }

    private static let sampleRate = 16_000.0
    private static let limitSamples = 960_000
    private let callbacks = DispatchQueue(label: "CapacityNotch.DictationMicrophone")
    private let lock = NSLock()
    private var samples: [Float] = []
    private var accepting = false
    /// The queue whose buffers are still wanted; any other's are dropped.
    private var live: AudioQueueRef?
    // Touched only from the MainActor methods below.
    private var queue: AudioQueueRef?
    private var listener: AudioObjectPropertyListenerBlock?
    private var level: (@Sendable (Float) -> Void)?
    private var limit: (@Sendable () -> Void)?
    /// Told when the input changed during a recording: the new input, or
    /// nil when capture could not start again on it.
    var inputChanged: (@MainActor (Input?) -> Void)?

    @MainActor func start(level: @escaping @Sendable (Float) -> Void, limit: @escaping @Sendable () -> Void) throws -> Input {
        lock.withLock { samples = []; accepting = true }
        self.level = level; self.limit = limit
        do {
            let input = try capture()
            listenForInputChanges()
            return input
        } catch { _ = stop(); throw error }
    }

    /// A fresh queue on whatever the default input is now. Samples already taken stay.
    @MainActor private func capture() throws -> Input {
        tearDownQueue()
        guard let input = Self.defaultInput(), let level, let limit else {
            throw DictationFailure("No microphone is available. Connect one and try again.")
        }
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var made: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&made, &format, 0, callbacks) { [weak self] queue, buffer, _, _, _ in
            self?.received(buffer, from: queue, level: level, limit: limit)
        }
        guard status == noErr, let made else { throw DictationFailure("The microphone could not start. Check microphone access and your input device in System Settings.") }
        // A tenth of a second a buffer, three in turn.
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(made, 1_600 * 4, &buffer) == noErr, let buffer { AudioQueueEnqueueBuffer(made, buffer, 0, nil) }
        }
        lock.withLock { live = made }
        queue = made
        guard AudioQueueStart(made, nil) == noErr else {
            tearDownQueue()
            throw DictationFailure("The microphone could not start. Check microphone access and your input device in System Settings.")
        }
        return input
    }

    /// On the callback queue. Held under the lock throughout, so a queue being
    /// torn down never has its buffer read after it is gone.
    private func received(_ buffer: AudioQueueBufferRef, from queue: AudioQueueRef, level: @escaping @Sendable (Float) -> Void, limit: @escaping @Sendable () -> Void) {
        var measured: Float?
        var full = false
        lock.withLock {
            guard live == queue else { return }
            defer { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
            let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
            guard accepting, count > 0 else { return }
            let chunk = UnsafeBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count)
            let room = Self.limitSamples - samples.count
            samples.append(contentsOf: chunk.prefix(max(0, room)))
            if count >= room { accepting = false; full = true }
            let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(count))
            let decibels = 20 * log10(max(rms, 0.000_01))
            measured = min(1, max(0, (decibels + 55) / 35))
        }
        if let measured { DispatchQueue.main.async { level(measured) } }
        if full { DispatchQueue.main.async(execute: limit) }
    }

    /// A headset connecting or leaving moves the default input; follow it.
    @MainActor private func listenForInputChanges() {
        var address = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
    }

    @MainActor private func changed() {
        guard lock.withLock({ accepting }) else { return }
        do { inputChanged?(try capture()) } catch { tearDownQueue(); inputChanged?(nil) }
    }

    @MainActor private func tearDownQueue() {
        lock.withLock { live = nil }
        if let queue { AudioQueueStop(queue, true); AudioQueueDispose(queue, true) }
        queue = nil
    }

    @MainActor func stop() -> [Float] {
        lock.withLock { accepting = false }
        if let listener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        listener = nil
        tearDownQueue()
        level = nil; limit = nil
        return lock.withLock { let result = samples; samples = []; return result }
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// The default input's own rate and channels, or nil when there is none.
    private static func defaultInput() -> Input? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var channels = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 {
            let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { list.deallocate() }
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr {
                channels = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
            }
        }
        guard channels > 0 else { return nil }
        return Input(sampleRate: Int(rate), channels: channels)
    }
}
