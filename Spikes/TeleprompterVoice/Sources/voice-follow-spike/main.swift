import AVFoundation
import Foundation
import FollowCore
import SherpaOnnxC

// Ticket 20's measurement: a voice reads a Script; every `step` seconds the
// recogniser hears the last `window` seconds again, the app's own
// ScriptFollower finds the word being said, and we time how long after the
// word was spoken it was lit. Run in real time, as the app would run it, so
// the CPU, memory and heat are what a person reading would cost.
//
//   voice-follow-spike synth                         make the scenarios with `say -v Milena`
//   voice-follow-spike follow [scenario…]            GigaAM sliding window (WINDOW, THREADS, STEP)
//   voice-follow-spike follow-tone [scenario…]       T-One, streaming (THREADS)
//
// Nothing is uploaded; the synthesised audio stays in Audio/ (never committed).

let spike = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let audioFolder = spike.appendingPathComponent("Audio")
let environment = ProcessInfo.processInfo.environment
let gigaamFolder = URL(fileURLWithPath: environment["GIGAAM_MODEL"] ?? FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("CapacityNotch/Dictation/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16").path)
let toneFolder = URL(fileURLWithPath: environment["TONE_MODEL"] ?? spike.appendingPathComponent("Models/sherpa-onnx-streaming-t-one-russian-2025-09-08").path)
let sampleRate = 16_000

// MARK: - The Script and the scenarios

/// A Script of our own (not the author's), about two minutes read aloud.
let paragraphs = [
    "Добрый день. Сегодня я расскажу, как устроена наша новая система уведомлений и почему мы решили переписать её с нуля, вместо того чтобы чинить старую.",
    "Старая система отправляла письма пачками раз в час. Пользователи узнавали о проблеме слишком поздно, а служба поддержки получала одинаковые вопросы по десять раз подряд.",
    "Новая система работает иначе. Каждое событие попадает в очередь, проходит проверку и уходит к человеку за несколько секунд. Если адресат не в сети, сообщение ждёт его и не теряется.",
    "Осталось рассказать о сроках. Первую версию мы покажем в конце месяца, а полностью перейдём на неё к лету. Спасибо за внимание, я с удовольствием отвечу на ваши вопросы.",
]

/// Lines about as long as the Teleprompter Row holds at the medium size.
func wrap(_ paragraph: String, width: Int = 56) -> [String] {
    var lines: [String] = []
    var line = ""
    for word in paragraph.split(separator: " ") {
        if !line.isEmpty, line.count + 1 + word.count > width { lines.append(line); line = "" }
        line += line.isEmpty ? String(word) : " " + word
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

/// The row's lines, a blank line between paragraphs, as TeleprompterScript.lines keeps them.
let paragraphLines = paragraphs.map { wrap($0) }
let scriptLines: [String] = paragraphLines.enumerated().flatMap { index, lines in index == 0 ? lines : [""] + lines }
/// Which row lines each paragraph has.
let paragraphRanges: [Range<Int>] = {
    var ranges: [Range<Int>] = []
    var start = 0
    for (index, lines) in paragraphLines.enumerated() {
        if index > 0 { start += 1 }
        ranges.append(start ..< start + lines.count)
        start += lines.count
    }
    return ranges
}()

enum Segment {
    /// Script lines read aloud.
    case script(Range<Int>)
    /// Something said that is not the Script.
    case offScript(String)
    case silence(Double)
}

let scenarios: [String: [Segment]] = [
    "straight": paragraphRanges.flatMap { [.script($0), .silence(0.5)] },
    // The voice stops twice, for five seconds: the Script must wait.
    "pauses": [.script(paragraphRanges[0]), .silence(5), .script(paragraphRanges[1]), .silence(5), .script(paragraphRanges[2]), .silence(0.5), .script(paragraphRanges[3])],
    // The reader skips the second line of the third paragraph.
    "skip": [.script(paragraphRanges[0]), .silence(0.5), .script(paragraphRanges[1]), .silence(0.5),
             .script(paragraphRanges[2].lowerBound ..< paragraphRanges[2].lowerBound + 1),
             .script(paragraphRanges[2].lowerBound + 2 ..< paragraphRanges[2].upperBound), .silence(0.5), .script(paragraphRanges[3])],
    // Talk off the Script, then back to it.
    "offscript": [.script(paragraphRanges[0]), .silence(0.5),
                  .offScript("Так, секунду, я сейчас налью себе воды. Простите, коллеги, у меня тут кот на клавиатуре."),
                  .silence(0.5), .script(paragraphRanges[1]), .silence(0.5), .script(paragraphRanges[2]), .silence(0.5), .script(paragraphRanges[3])],
    // A phrase said twice, as a reader repeats one after a slip.
    "repeat": [.script(paragraphRanges[0]), .silence(0.5), .script(paragraphRanges[1].lowerBound ..< paragraphRanges[1].lowerBound + 1),
               .offScript(String(scriptLines[paragraphRanges[1].lowerBound].split(separator: " ").suffix(4).joined(separator: " "))),
               .script(paragraphRanges[1].lowerBound + 1 ..< paragraphRanges[1].upperBound), .silence(0.5),
               .script(paragraphRanges[2]), .silence(0.5), .script(paragraphRanges[3])],
]

let follower = ScriptFollower(lines: scriptLines)

// MARK: - Audio

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

let rate = environment["RATE"] ?? "150"

func say(_ text: String, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", "Milena", "-r", rate, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}

/// One scenario's audio, and what was said when: each Script word's index in
/// the follower and its start and end, from a full-context decode of its
/// segment (the best timing the model gives); off-script and silent spans.
struct Truth: Codable {
    struct Word: Codable { let index: Int; let start: Double; let end: Double }
    var words: [Word] = []
    /// Spans where nothing of the Script is said: the Script must wait.
    var holds: [ClosedRange<Double>] = []
    var duration: Double = 0
    /// How far the model's first-word start sits after the first sound, by energy, per segment.
    var onsetBias: [Double] = []
}

func segmentText(_ lines: Range<Int>) -> String { scriptLines[lines].filter { !$0.isEmpty }.joined(separator: " ") }

/// The follower's word indices for a range of lines.
func wordIndices(_ lines: Range<Int>) -> [Int] {
    follower.words.indices.filter { lines.contains(follower.words[$0].line) }
}

func synth() throws {
    try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
    let reference = try OfflineRecognizer(folder: gigaamFolder, threads: 4)
    for (name, segments) in scenarios.sorted(by: { $0.key < $1.key }) {
        var audio: [Float] = []
        var truth = Truth()
        for (number, segment) in segments.enumerated() {
            let start = Double(audio.count) / Double(sampleRate)
            switch segment {
            case let .silence(seconds):
                audio += [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
                truth.holds.append(start ... start + seconds)
            case let .offScript(text):
                let url = audioFolder.appendingPathComponent("\(name)-\(number).wav")
                try say(text, to: url)
                audio += try readAudio(url)
                truth.holds.append(start ... Double(audio.count) / Double(sampleRate))
            case let .script(lines):
                let url = audioFolder.appendingPathComponent("\(name)-\(number).wav")
                try say(segmentText(lines), to: url)
                let samples = try readAudio(url)
                let indices = wordIndices(lines)
                let heard = reference.decode(samples).words
                let timed = align(expected: indices.map { follower.words[$0].text }, heard: heard, duration: Double(samples.count) / Double(sampleRate))
                for (index, time) in zip(indices, timed) {
                    truth.words.append(.init(index: index, start: start + time.start, end: start + time.end))
                }
                if let onset = samples.firstIndex(where: { abs($0) > 0.02 }), let first = heard.first {
                    truth.onsetBias.append(first.start - Double(onset) / Double(sampleRate))
                }
                audio += samples
            }
            try? FileManager.default.removeItem(at: audioFolder.appendingPathComponent("\(name)-\(number).wav"))
        }
        truth.duration = Double(audio.count) / Double(sampleRate)
        try writeWAV(audio, to: audioFolder.appendingPathComponent("\(name).wav"))
        try JSONEncoder().encode(truth).write(to: audioFolder.appendingPathComponent("\(name).json"))
        let bias = truth.onsetBias.sorted()
        print(String(format: "%@: %.1f s, %d Script words timed, model's first word %.0f ms after the first sound (median)", name, truth.duration, truth.words.count, (bias.isEmpty ? 0 : bias[bias.count / 2]) * 1000))
    }
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

/// Times for the expected words from the words heard: matched by a longest
/// common subsequence of folded words, the rest spread between neighbours.
func align(expected: [String], heard: [HeardWord], duration: Double) -> [(start: Double, end: Double)] {
    let n = expected.count, m = heard.count
    var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            table[i][j] = expected[i] == heard[j].text ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
        }
    }
    var times = [(start: Double, end: Double)?](repeating: nil, count: n)
    var i = 0, j = 0
    while i < n, j < m {
        if expected[i] == heard[j].text { times[i] = (heard[j].start, heard[j].end); i += 1; j += 1 }
        else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
    }
    // Unmatched words: evenly between the matched ones around them.
    var result: [(start: Double, end: Double)] = []
    var k = 0
    while k < n {
        if let time = times[k] { result.append(time); k += 1; continue }
        var end = k
        while end < n, times[end] == nil { end += 1 }
        let from = k > 0 ? result[k - 1].end : 0
        let to = end < n ? times[end]!.start : duration
        let slice = (to - from) / Double(end - k)
        for g in 0 ..< (end - k) { result.append((from + Double(g) * slice, from + Double(g + 1) * slice)) }
        k = end
    }
    return result
}

// MARK: - Recognisers

struct HeardWord { let text: String; let start: Double; let end: Double }

/// GigaAM v3 punctuated RNN-T, offline, as the Dictation Module loads it.
final class OfflineRecognizer {
    let handle: OpaquePointer
    let loadSeconds: Double

    init(folder: URL, threads: Int) throws {
        var strings: [UnsafeMutablePointer<CChar>] = []
        func c(_ value: String) -> UnsafePointer<CChar> { let p = strdup(value)!; strings.append(p); return UnsafePointer(p) }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(sampleRate)
        config.feat_config.feature_dim = 64
        config.model_config.transducer.encoder = c(folder.appendingPathComponent("encoder.int8.onnx").path)
        config.model_config.transducer.decoder = c(folder.appendingPathComponent("decoder.onnx").path)
        config.model_config.transducer.joiner = c(folder.appendingPathComponent("joiner.onnx").path)
        config.model_config.tokens = c(folder.appendingPathComponent("tokens.txt").path)
        config.model_config.num_threads = Int32(threads)
        config.model_config.provider = c("cpu")
        config.model_config.model_type = c("nemo_transducer")
        config.model_config.modeling_unit = c("cjkchar")
        config.decoding_method = c("greedy_search")
        config.max_active_paths = 4
        let started = Date()
        guard let handle = SherpaOnnxCreateOfflineRecognizer(&config) else { throw CocoaError(.fileReadNoSuchFile) }
        loadSeconds = Date().timeIntervalSince(started)
        self.handle = handle
    }

    func decode(_ samples: [Float]) -> (text: String, words: [HeardWord]) {
        let stream = SherpaOnnxCreateOfflineStream(handle)!
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count)) }
        SherpaOnnxDecodeOfflineStream(handle, stream)
        let result = SherpaOnnxGetOfflineStreamResult(stream)!
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let text = String(cString: result.pointee.text)
        var words: [HeardWord] = []
        let count = Int(result.pointee.count)
        if count > 0, let stamps = result.pointee.timestamps, let tokens = result.pointee.tokens_arr {
            var piece = "", first = 0.0, last = 0.0
            func close() {
                let folded = ScriptWords.fold(piece)
                if !folded.isEmpty { words.append(HeardWord(text: folded, start: first, end: last + 0.12)) }
                piece = ""
            }
            for t in 0 ..< count {
                let token = String(cString: tokens[t]!)
                let time = Double(stamps[t])
                if token.hasPrefix("▁") { close(); first = time }
                if piece.isEmpty, !token.hasPrefix("▁") { first = time }
                piece += token.replacingOccurrences(of: "▁", with: "")
                last = time
            }
            close()
        }
        return (text, words)
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(handle) }
}

/// T-One, sherpa-onnx's streaming Russian CTC model.
final class StreamingRecognizer {
    let handle: OpaquePointer
    var stream: OpaquePointer
    let loadSeconds: Double

    init(folder: URL, threads: Int) throws {
        var strings: [UnsafeMutablePointer<CChar>] = []
        func c(_ value: String) -> UnsafePointer<CChar> { let p = strdup(value)!; strings.append(p); return UnsafePointer(p) }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 8_000
        config.feat_config.feature_dim = 80
        config.model_config.t_one_ctc.model = c(folder.appendingPathComponent("model.onnx").path)
        config.model_config.tokens = c(folder.appendingPathComponent("tokens.txt").path)
        config.model_config.num_threads = Int32(threads)
        config.model_config.provider = c("cpu")
        config.decoding_method = c("greedy_search")
        let started = Date()
        guard let handle = SherpaOnnxCreateOnlineRecognizer(&config) else { throw CocoaError(.fileReadNoSuchFile) }
        loadSeconds = Date().timeIntervalSince(started)
        self.handle = handle
        stream = SherpaOnnxCreateOnlineStream(handle)
    }

    func accept(_ samples: ArraySlice<Float>) -> String {
        samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count)) }
        while SherpaOnnxIsOnlineStreamReady(handle, stream) == 1 { SherpaOnnxDecodeOnlineStream(handle, stream) }
        let result = SherpaOnnxGetOnlineStreamResult(handle, stream)!
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        return String(cString: result.pointee.text)
    }

    deinit { SherpaOnnxDestroyOnlineStream(stream); SherpaOnnxDestroyOnlineRecognizer(handle) }
}

// MARK: - Measuring

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func thermal() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
}

struct Record { let loop: Int; let time: Double; let current: Int? }

enum Engine {
    case gigaam(OfflineRecognizer, window: Double)
    case tone(StreamingRecognizer)
}

/// Plays the scenario in real time — the microphone hands over a tenth of a
/// second at a time — and every `step` hears what the engine makes of it.
func run(_ name: String, engine: Engine, step: Double, loops: Int = 1) throws -> String {
    let once = try readAudio(audioFolder.appendingPathComponent("\(name).wav"))
    let truthOnce = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: audioFolder.appendingPathComponent("\(name).json")))
    let audio = Array([[Float]](repeating: once, count: loops).joined())
    let duration = Double(audio.count) / Double(sampleRate)

    var follower = follower
    var records: [Record] = []
    var decodes: [Double] = []
    var timingErrors: [Double] = []
    var newestTimingErrors: [Double] = []
    var fed = 0
    let thermalBefore = thermal()
    let cpuBefore = cpuSeconds()
    let started = DispatchTime.now()
    func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9 }
    var next = step
    var loop = 0

    while true {
        let now = elapsed()
        if now < next { usleep(useconds_t((next - now) * 1e6)); continue }
        if now > duration + 1.5 { break }
        let available = min(Int((now / 0.1).rounded(.down) * 0.1 * Double(sampleRate)), audio.count)
        // A loop of the same audio starts the Script over, as Stop and Start would.
        let thisLoop = min(available / once.count, loops - 1)
        if thisLoop != loop { loop = thisLoop; follower.reset() }
        let begun = elapsed()
        switch engine {
        case let .gigaam(recognizer, window):
            let from = max(available - Int(window * Double(sampleRate)), loop * once.count)
            if available - from >= Int(0.3 * Double(sampleRate)) {
                let heard = recognizer.decode(Array(audio[from ..< available]))
                follower.hear(ScriptWords.heard(heard.text))
                // How the window's word timings compare with the full-context ones.
                let offset = Double(from - loop * once.count) / Double(sampleRate)
                for (position, word) in heard.words.enumerated() {
                    let start = offset + word.start
                    if let reference = truthOnce.words.filter({ follower.words[$0.index].text == word.text && abs($0.start - start) < 0.6 }).min(by: { abs($0.start - start) < abs($1.start - start) }) {
                        timingErrors.append(abs(reference.start - start))
                        if position == heard.words.count - 1 { newestTimingErrors.append(abs(reference.start - start)) }
                    }
                }
            }
        case let .tone(recognizer):
            if available > fed {
                let text = recognizer.accept(audio[fed ..< available])
                fed = available
                follower.hear(ScriptWords.heard(text))
            }
        }
        let done = elapsed()
        decodes.append(done - begun)
        records.append(Record(loop: loop, time: done - Double(loop * once.count) / Double(sampleRate), current: follower.current))
        next = ((done / step).rounded(.down) + 1) * step
    }
    let wall = elapsed()
    let cores = (cpuSeconds() - cpuBefore) / wall

    // Score only the last loop: its records, against the truth.
    let lastRecords = records.filter { $0.loop == loops - 1 }
    var latencies: [Double] = [], fromStart: [Double] = [], longWords: [Double] = [], missed = 0
    var slowest: [(Double, String)] = []
    for word in truthOnce.words {
        guard let lit = lastRecords.first(where: { ($0.current ?? -1) >= word.index }) else { missed += 1; continue }
        latencies.append(lit.time - word.end)
        fromStart.append(lit.time - word.start)
        let text = follower.words[word.index].text
        if text.count >= 4 { longWords.append(lit.time - word.end) }
        slowest.append((lit.time - word.end, text))
    }
    if environment["TRACE"] != nil {
        var shown: Int?
        for record in lastRecords where record.current != shown {
            let spoken = truthOnce.words.filter { $0.start <= record.time }.map(\.index).max() ?? -1
            print(String(format: "  %6.2f s  lit %3d %@   (spoken %3d %@)", record.time, record.current ?? -1, record.current.map { follower.words[$0].text } ?? "-", spoken, spoken >= 0 ? follower.words[spoken].text : "-"))
            shown = record.current
        }
    }
    if environment["DETAIL"] != nil {
        // The Script is this harness's own synthetic text, so its words may be printed.
        print("  slowest: " + slowest.sorted { $0.0 > $1.0 }.prefix(12).map { String(format: "%@ %.2f", $0.1, $0.0) }.joined(separator: ", "))
        print(String(format: "  words of 4+ letters: lit after end p50 %.2f / p90 %.2f s (%d words)", percentile(longWords, 0.5), percentile(longWords, 0.9), longWords.count))
    }
    // Lit a word not yet begun.
    var ahead = 0, aheadWorst = 0
    for record in lastRecords {
        guard let current = record.current else { continue }
        let spoken = truthOnce.words.filter { $0.start <= record.time }.map(\.index).max() ?? -1
        if current > spoken + 1 { ahead += 1; aheadWorst = max(aheadWorst, current - spoken) }
    }
    // Moved while nothing of the Script was said (a second into the span, so
    // the last words before it can still land).
    var movedWhileWaiting = 0
    var backwards = 0
    var previous: Int?
    for record in lastRecords {
        if let previous, let current = record.current, current < previous { backwards += 1 }
        if record.current != previous, truthOnce.holds.contains(where: { $0.upperBound - $0.lowerBound > 1.5 && record.time > $0.lowerBound + 1.0 && record.time < $0.upperBound }) {
            movedWhileWaiting += 1
        }
        previous = record.current
    }
    let litLate = latencies.filter { $0 > 1.0 }.count

    var line = String(format: "%@  decode p50 %.0f / p95 %.0f / max %.0f ms; lit after word end p50 %.2f / p90 %.2f / p95 %.2f s (after start p50 %.2f s); %d/%d words lit, %d later than 1 s, %d never; ahead %d (worst %d words); moved while waiting %d; went back %d; CPU %.2f cores over %.0f s; peak memory %.0f MB; thermal %@ → %@",
        name, percentile(decodes, 0.5) * 1000, percentile(decodes, 0.95) * 1000, (decodes.max() ?? 0) * 1000,
        percentile(latencies, 0.5), percentile(latencies, 0.9), percentile(latencies, 0.95), percentile(fromStart, 0.5),
        latencies.count, truthOnce.words.count, litLate, missed, ahead, aheadWorst, movedWhileWaiting, backwards, cores, wall, peakMemoryMB(), thermalBefore, thermal())
    if !timingErrors.isEmpty {
        line += String(format: "; window word starts vs full context p50 %.0f / p90 %.0f ms (newest word p50 %.0f / p90 %.0f ms)",
                       percentile(timingErrors, 0.5) * 1000, percentile(timingErrors, 0.9) * 1000,
                       percentile(newestTimingErrors, 0.5) * 1000, percentile(newestTimingErrors, 0.9) * 1000)
    }
    return line
}


// MARK: -

let arguments = Array(CommandLine.arguments.dropFirst())
let chosen = arguments.dropFirst().isEmpty ? ["straight", "pauses", "skip", "offscript", "repeat"] : Array(arguments.dropFirst())
let threads = Int(environment["THREADS"] ?? "") ?? 2
let step = Double(environment["STEP"] ?? "") ?? 0.2
let loops = Int(environment["LOOPS"] ?? "") ?? 1
do {
    switch arguments.first {
    case "synth":
        try synth()
    case "follow":
        let window = Double(environment["WINDOW"] ?? "") ?? 3
        let recognizer = try OfflineRecognizer(folder: gigaamFolder, threads: threads)
        print(String(format: "GigaAM: window %.1f s, step %.1f s, %d threads; model loaded in %.2f s", window, step, threads, recognizer.loadSeconds))
        for name in chosen { print(try run(name, engine: .gigaam(recognizer, window: window), step: step, loops: loops)) }
    case "follow-tone":
        for name in chosen {
            let recognizer = try StreamingRecognizer(folder: toneFolder, threads: threads)
            print(String(format: "T-One: step %.1f s, %d threads; model loaded in %.2f s", step, threads, recognizer.loadSeconds))
            print(try run(name, engine: .tone(recognizer), step: step, loops: loops))
        }
    default:
        print("usage: voice-follow-spike synth | follow [scenario…] | follow-tone [scenario…]")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
