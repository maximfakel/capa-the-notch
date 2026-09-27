import Foundation
import CryptoKit
import SherpaOnnxC

struct DictationFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// All C handles and inference remain on this actor's executor. Nothing here
/// touches a microphone, pasteboard, UI, or a recognised-text log.
actor DictationEngine {
    private var model: Recognizer?
    private var unloadTask: Task<Void, Never>?
    func recognize(_ samples: [Float], folder: URL) throws -> String {
        try Task.checkCancellation()
        unloadTask?.cancel()
        defer {
            unloadTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await self?.unload()
            }
        }
        guard !samples.isEmpty else { throw DictationFailure("No speech was recorded. Hold the shortcut while speaking.") }
        if model == nil { model = try Recognizer(folder: folder) }
        try Task.checkCancellation()
        return try model!.decode(samples)
    }
    func unload() { unloadTask?.cancel(); unloadTask = nil; model = nil }

    private final class Recognizer {
        let handle: OpaquePointer
        init(folder: URL) throws {
            try DictationModelFiles.validate(folder)
            var strings: [UnsafeMutablePointer<CChar>] = []
            func c(_ value: String) -> UnsafePointer<CChar> {
                let pointer = strdup(value)!
                strings.append(pointer); return UnsafePointer(pointer)
            }
            defer { strings.forEach { free($0) } }
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = 16_000
            config.feat_config.feature_dim = 64
            config.model_config.transducer.encoder = c(folder.appendingPathComponent("encoder.int8.onnx").path)
            config.model_config.transducer.decoder = c(folder.appendingPathComponent("decoder.onnx").path)
            config.model_config.transducer.joiner = c(folder.appendingPathComponent("joiner.onnx").path)
            config.model_config.tokens = c(folder.appendingPathComponent("tokens.txt").path)
            config.model_config.num_threads = 4
            config.model_config.provider = c("cpu")
            config.model_config.model_type = c("nemo_transducer")
            config.model_config.modeling_unit = c("cjkchar")
            config.decoding_method = c("greedy_search")
            config.max_active_paths = 4
            guard let handle = SherpaOnnxCreateOfflineRecognizer(&config) else {
                throw DictationFailure("The speech model could not load. Download it again in Dictation settings.")
            }
            self.handle = handle
        }
        deinit { SherpaOnnxDestroyOfflineRecognizer(handle) }
        func decode(_ samples: [Float]) throws -> String {
            guard let stream = SherpaOnnxCreateOfflineStream(handle) else { throw DictationFailure("Recognition could not start. Try again.") }
            defer { SherpaOnnxDestroyOfflineStream(stream) }
            samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16_000, $0.baseAddress, Int32($0.count)) }
            SherpaOnnxDecodeOfflineStream(handle, stream)
            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw DictationFailure("Recognition failed. Try again.") }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            return String(cString: result.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum DictationModelFiles {
    static let name = "sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"
    static let source = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(name).tar.bz2")!
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CapacityNotch/Dictation/\(name)", isDirectory: true)
    static let hashes = [
        "encoder.int8.onnx": "369f35a71bf288d3b8e0391fabd8dba5f2314088d440bca474056b7b4b6e66bf",
        "decoder.onnx": "38fc7475443ea2a26f63211ca350f73ac50fff824ab7a3876ee2bd610c53bbc4",
        "joiner.onnx": "602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c",
        "tokens.txt": "39abae20e692998290c574e606f11a9edef2902a1995463fcff63d1490cf22b7",
    ]
    static func exists(at folder: URL = directory) -> Bool {
        hashes.keys.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
    static func validate(_ folder: URL) throws {
        for (name, hash) in hashes {
            try Task.checkCancellation()
            let file = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
                throw DictationFailure("The speech model is missing or damaged. Download it again in Dictation settings.")
            }
        }
    }
    static func install(_ archive: URL) throws {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("install-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", staging.path] + (Array(hashes.keys) + ["LICENSE"]).map { name + "/" + $0 }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        while process.isRunning {
            if Task.isCancelled { process.terminate(); process.waitUntilExit(); throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DictationFailure("The download could not be unpacked. Check free disk space and try again.") }
        let extracted = staging.appendingPathComponent(name)
        try validate(extracted)
        try Task.checkCancellation()
        if fm.fileExists(atPath: directory.path) { _ = try fm.replaceItemAt(directory, withItemAt: extracted) }
        else { try fm.moveItem(at: extracted, to: directory) }
    }
}

final class DictationDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let changed: @Sendable (Double) -> Void
    init(changed: @escaping @Sendable (Double) -> Void) { self.changed = changed }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { changed(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}
