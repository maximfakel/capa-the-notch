import Foundation

/// A rendered sound as a mono 16-bit WAV in memory, cut as procedural-sounds
/// cuts its exports (lib/audio/export/wav.ts): the silence before and after
/// trimmed, and both new edges faded so the cut cannot click.
public enum SoundFile {
    public static func wav(_ samples: [Float], sampleRate: Int = 44100) -> Data {
        let trimmed = trimAndFade(samples, sampleRate: Double(sampleRate))
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(trimmed.count * 2)
        ascii("RIFF"); u32(36 + bytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(bytes)
        for sample in trimmed {
            let clamped = max(-1, min(1, sample))
            u16(UInt16(bitPattern: Int16((clamped < 0 ? clamped * 32768 : clamped * 32767).rounded())))
        }
        return data
    }

    static func trimAndFade(_ samples: [Float], sampleRate: Double) -> [Float] {
        let silence: Float = 0.0001
        let peak = samples.map(abs).max() ?? 0
        guard peak > silence else { return Array(samples.prefix(Int((sampleRate * 0.01).rounded(.up)))) }
        var start = 0
        while start < samples.count, abs(samples[start]) < silence { start += 1 }
        var end = samples.count
        while end > start, abs(samples[end - 1]) < silence { end -= 1 }
        var out = Array(samples[start ..< end])
        let n = out.count
        guard n > 0 else { return out }
        var onset = 0
        while onset < n, abs(out[onset]) < peak * 0.01 { onset += 1 }
        let fadeIn = min(Int((sampleRate * 0.002).rounded()), onset)
        let fadeOut = min(Int((sampleRate * 0.006).rounded()), n / 4)
        for i in 0 ..< fadeIn { out[i] *= Float(i) / Float(fadeIn) }
        for i in 0 ..< fadeOut { out[n - 1 - i] *= Float(i) / Float(fadeOut) }
        return out
    }
}
