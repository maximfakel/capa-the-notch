import AppKit
import AVFoundation
import Carbon.HIToolbox
import SherpaOnnx
import SpikeCore

// Ticket 12's spike: GigaAM v3 (punctuated RNN-T) through sherpa-onnx, on
// this Mac, with nothing uploaded and nothing kept but what the author
// records for the corpus (Recordings/, never committed).
//
//   dictation-spike decode <file.wav>…   recognise files, with timings and memory
//   dictation-spike record-corpus        read the corpus aloud, phrase by phrase
//   dictation-spike score                recognise the corpus and score it
//   dictation-spike window <file.wav>    decode a sliding window, as ticket 20 would
//   dictation-spike ptt                  hold ⌃⌥D, speak, release: text at the cursor

let spikeFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let modelFolder = spikeFolder.appendingPathComponent("Models/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16")
let recordings = spikeFolder.appendingPathComponent("Recordings")
let sampleRate = 16_000
/// Ticket 12: a phrase is at most 25 seconds; GigaAM's own `transcribe` stops there too.
let longestPhrase: TimeInterval = 25

// MARK: - Measuring

func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

func seconds(_ body: () throws -> Void) rethrows -> Double {
    let start = Date()
    try body()
    return Date().timeIntervalSince(start)
}

// MARK: - The recogniser

final class Recognizer {
    private let recognizer: SherpaOnnxOfflineRecognizer
    let loadSeconds: Double

    init(threads: Int = Int(ProcessInfo.processInfo.environment["THREADS"] ?? "") ?? 4, hotwords: String? = ProcessInfo.processInfo.environment["HOTWORDS"]) {
        let path = { (name: String) in modelFolder.appendingPathComponent(name).path }
        guard FileManager.default.fileExists(atPath: path("encoder.int8.onnx")) else {
            fatalError("No model at \(modelFolder.path) — see README.md")
        }
        let model = sherpaOnnxOfflineModelConfig(
            tokens: path("tokens.txt"),
            transducer: sherpaOnnxOfflineTransducerModelConfig(
                encoder: path("encoder.int8.onnx"),
                decoder: path("decoder.onnx"),
                joiner: path("joiner.onnx")
            ),
            numThreads: threads,
            provider: "cpu",
            // Without it sherpa-onnx takes a NeMo transducer for another
            // kind and fails on "vocab_size" (sherpa-onnx issue #3619).
            modelType: "nemo_transducer",
            // Hotwords are cut into the model's own BPE pieces; without a
            // vocabulary sherpa-onnx cuts them into characters.
            modelingUnit: ProcessInfo.processInfo.environment["BPE_VOCAB"] == nil ? "cjkchar" : "bpe",
            bpeVocab: ProcessInfo.processInfo.environment["BPE_VOCAB"] ?? ""
        )
        // A personal vocabulary, when given: the transducer's beam search is
        // nudged towards these words (HOTWORDS=file, one phrase a line;
        // HOTWORDS_SCORE to weigh them).
        let score = Float(ProcessInfo.processInfo.environment["HOTWORDS_SCORE"] ?? "") ?? 2
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: sampleRate, featureDim: 64),
            modelConfig: model,
            decodingMethod: hotwords == nil ? "greedy_search" : "modified_beam_search",
            hotwordsFile: hotwords ?? "",
            hotwordsScore: score
        )
        var made: SherpaOnnxOfflineRecognizer?
        loadSeconds = seconds { made = SherpaOnnxOfflineRecognizer(config: &config) }
        recognizer = made!
    }

    func recognise(_ samples: [Float]) -> (text: String, seconds: Double, timestamps: [Float]) {
        var text = ""
        var timestamps: [Float] = []
        let elapsed = seconds {
            let result = recognizer.decode(samples: samples, sampleRate: sampleRate)
            text = result.text
            timestamps = result.timestamps
        }
        return (text.trimmingCharacters(in: .whitespaces), elapsed, timestamps)
    }
}

// MARK: - Audio

/// Any file AVFoundation reads, as 16 kHz mono floats.
func readAudio(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: file.processingFormat, to: target),
          let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw CocoaError(.fileReadCorruptFile) }
    try file.read(into: input)
    let ratio = Double(sampleRate) / file.processingFormat.sampleRate
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024)
    else { throw CocoaError(.fileReadCorruptFile) }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

func writeWAV(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ])
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

/// The microphone, at 16 kHz mono, into memory only — never a file unless the
/// corpus asks for one. At most 25 seconds.
final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var full = false

    static func askForAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; semaphore.signal() }
        semaphore.wait()
        return granted
    }

    func start() throws {
        lock.withLock { samples = []; full = false }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target)
        else { throw CocoaError(.featureUnsupported) }
        let ratio = Double(sampleRate) / format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self,
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64)
            else { return }
            var fed = false
            converter.convert(to: output, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            let chunk = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
            let reachedLimit = self.lock.withLock { () -> Bool in
                let room = Int(longestPhrase) * sampleRate - self.samples.count
                if room > 0 { self.samples.append(contentsOf: chunk.prefix(room)) }
                guard room <= chunk.count, !self.full else { return false }
                self.full = true
                return true
            }
            // Twenty-five seconds is the end of the phrase: the microphone
            // goes off then, not when the key is let go.
            if reachedLimit {
                DispatchQueue.main.async {
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                    print("  (25 s reached; the microphone is off)")
                }
            }
        }
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }
}

// MARK: - Commands

func decode(_ paths: [String]) throws {
    let cpuBefore = cpuSeconds()
    let recognizer = Recognizer()
    print(String(format: "cold start %.2f s, memory %.0f MB", recognizer.loadSeconds, peakMemoryMB()))
    for path in paths {
        let samples = try readAudio(URL(fileURLWithPath: path))
        let audio = Double(samples.count) / Double(sampleRate)
        let first = recognizer.recognise(samples)
        let second = recognizer.recognise(samples)
        print(String(format: "%@  %.1f s audio, decode %.2f s (warm %.2f s), RTF %.3f", (path as NSString).lastPathComponent, audio, first.seconds, second.seconds, second.seconds / audio))
        print("  → \(first.text)")
    }
    print(String(format: "peak memory %.0f MB, CPU time %.1f s", peakMemoryMB(), cpuSeconds() - cpuBefore))
}

func recordCorpus() throws {
    guard Microphone.askForAccess() else { print("Microphone access was not given."); return }
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let microphone = Microphone()
    let remaining = Corpus.phrases.filter { !FileManager.default.fileExists(atPath: recordings.appendingPathComponent("\($0.id).wav").path) }
    print("\(remaining.count) phrases to read. Return starts recording, Return again stops; type s and Return to skip, q to quit.\n")
    for (index, phrase) in remaining.enumerated() {
        print("[\(index + 1)/\(remaining.count)] \(phrase.id): \(phrase.text)")
        print("  Return to record…", terminator: "")
        let answer = readLine() ?? "q"
        if answer == "q" { return }
        if answer == "s" { continue }
        try microphone.start()
        print("  ● recording — Return to stop", terminator: "")
        _ = readLine()
        let samples = microphone.stop()
        try writeWAV(samples, to: recordings.appendingPathComponent("\(phrase.id).wav"))
        print(String(format: "  saved, %.1f s\n", Double(samples.count) / Double(sampleRate)))
    }
    print("Done. Run: dictation-spike score")
}

func score() throws {
    let recognizer = Recognizer()
    var results: [CorpusScore.Result] = []
    var lines = ["| id | length | audio s | decode s | WER | reference | recognised |", "|---|---|---|---|---|---|---|"]
    for phrase in Corpus.phrases {
        let url = recordings.appendingPathComponent("\(phrase.id).wav")
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        let samples = try readAudio(url)
        let recognised = recognizer.recognise(samples)
        let result = CorpusScore.Result(
            id: phrase.id, reference: phrase.text, hypothesis: recognised.text,
            seconds: Double(samples.count) / Double(sampleRate), decodeSeconds: recognised.seconds
        )
        results.append(result)
        let wer = ErrorRate.words(reference: phrase.text, hypothesis: recognised.text)
        print(String(format: "%@ WER %4.0f%%  %@", phrase.id, wer.rate * 100, recognised.text))
        lines.append(String(format: "| %@ | %@ | %.1f | %.2f | %.0f%% | %@ | %@ |", phrase.id, phrase.length.rawValue, result.seconds, result.decodeSeconds, wer.rate * 100, phrase.text, recognised.text))
    }
    for length in Corpus.Length.allCases {
        let group = results.filter { r in Corpus.phrases.first { $0.id == r.id }?.length == length }
        guard !group.isEmpty else { continue }
        let decode = group.map(\.decodeSeconds)
        print(String(format: "%@: %@; decode mean %.2f s, max %.2f s", length.rawValue, CorpusScore.summary(group).description, decode.reduce(0, +) / Double(decode.count), decode.max() ?? 0))
    }
    let summary = CorpusScore.summary(results)
    print("all: \(summary)")
    print(String(format: "cold start %.2f s, peak memory %.0f MB", recognizer.loadSeconds, peakMemoryMB()))
    lines += ["", "all: \(summary)", String(format: "cold start %.2f s, peak memory %.0f MB", recognizer.loadSeconds, peakMemoryMB())]
    try lines.joined(separator: "\n").write(to: recordings.appendingPathComponent("score.md"), atomically: true, encoding: .utf8)
    print("Written to Recordings/score.md")
}

/// Ticket 20 would re-decode the last few seconds every 0.2 s. For each window
/// length: how long one decode takes, and whether it keeps up.
func window(_ path: String) throws {
    let recognizer = Recognizer()
    let samples = try readAudio(URL(fileURLWithPath: path))
    let step = Int(0.2 * Double(sampleRate))
    for length in [2.0, 4.0, 6.0, 8.0] {
        let size = Int(length * Double(sampleRate))
        guard samples.count >= size else { continue }
        var times: [Double] = []
        var end = size
        while end <= samples.count {
            times.append(recognizer.recognise(Array(samples[(end - size) ..< end])).seconds)
            end += step
        }
        let timings = recognizer.recognise(Array(samples[(samples.count - size)...])).timestamps
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print(String(format: "window %.0f s: %d decodes, median %.0f ms, p95 %.0f ms — %@; %d token timings in the last window, first at %.2f s", length, times.count, median * 1000, p95 * 1000, p95 < 0.2 ? "keeps up with a 0.2 s step" : "falls behind a 0.2 s step", timings.count, timings.first ?? -1))
    }
}

// MARK: - Push to talk

/// Hold ⌃⌥D, speak, let go: the text goes where the cursor is, through the
/// clipboard and ⌘V, and the clipboard is put back as it was. Without
/// Accessibility access ⌘V cannot be sent; the text is then left on the
/// clipboard to paste by hand — the fallback ticket 12 asks for.
@MainActor
final class PushToTalk {
    private let recognizer = Recognizer()
    private let microphone = Microphone()
    private var hotKey: EventHotKeyRef?
    private var pressedAt: Date?

    func run() {
        guard Microphone.askForAccess() else { print("Microphone access was not given."); exit(1) }
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        print(trusted
            ? "Accessibility granted: text is pasted at the cursor."
            : "No Accessibility access: text will be left on the clipboard. Grant it in System Settings → Privacy & Security → Accessibility and run again to paste.")
        print(String(format: "Model loaded in %.2f s. Hold ⌃⌥D and speak; release to insert. ⌃C quits.", recognizer.loadSeconds))

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let talk = Unmanaged<PushToTalk>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { pressed ? talk.pressed() : talk.released() }
            return noErr
        }, 2, &specs, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4443_5450, id: 1), GetEventDispatcherTarget(), 0, &hotKey)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private func pressed() {
        guard pressedAt == nil else { return }
        pressedAt = Date()
        do { try microphone.start(); print("● listening") } catch { print("Microphone failed: \(error)") }
    }

    private func released() {
        guard let pressedAt else { return }
        self.pressedAt = nil
        let samples = microphone.stop()
        let held = Date().timeIntervalSince(pressedAt)
        let released = Date()
        let recognised = recognizer.recognise(samples)
        guard !recognised.text.isEmpty else { print("  (nothing heard)"); return }
        let inserted = insert(recognised.text)
        print(String(format: "  held %.1f s, recognised in %.2f s, %@ %.2f s after release: %@", held, recognised.seconds, inserted ? "pasted" : "on the clipboard", Date().timeIntervalSince(released), recognised.text))
    }

    /// Pastes at the cursor and restores the clipboard; false when it could
    /// only leave the text on the clipboard.
    private func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return false
        }
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        // The target reads the clipboard when it handles ⌘V; give it that
        // moment before putting the person's clipboard back.
        // Only if the clipboard still holds what was put there: anything the
        // person copied in the meantime is theirs and stays. Types an
        // application promises rather than writes cannot be read back, and
        // are not restored — a limit of this way of pasting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            let items = saved.map { contents -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        return true
    }
}

// MARK: -

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "decode": try decode(Array(arguments.dropFirst()))
    case "record-corpus": try recordCorpus()
    case "score": try score()
    case "window": try window(arguments.count > 1 ? arguments[1] : modelFolder.appendingPathComponent("test_wavs/example.wav").path)
    case "ptt": MainActor.assumeIsolated { PushToTalk().run() }
    default: print("usage: dictation-spike decode <wav…> | record-corpus | score | window <wav> | ptt")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
