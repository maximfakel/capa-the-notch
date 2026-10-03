import Foundation

/// Renders a `SoundPatch` to samples, as procedural-sounds' player renders it
/// offline through Web Audio (lib/audio/synth.ts and effects.ts, adapted in
/// turn from @web-kits/audio and cuelume; MIT, THIRD_PARTY_NOTICES.md): each
/// layer's source started at its delay, through its filters, shaped by its
/// envelope's gain automation, through its echo, and summed. Mono, as theirs
/// is. A sound is a fraction of a second, so it is drawn whole once and played
/// as a buffer, never synthesised live in the audio thread.
public enum SoundSynth {
    /// Web Audio's floor for the envelope: exponential ramps cannot reach zero.
    static let silence = 0.0001

    public static func render(_ patch: SoundPatch, sampleRate: Double = 44100) -> [Float] {
        let seconds = min(duration(of: patch) + 0.05, 8)
        let count = max(1, Int((seconds * sampleRate).rounded(.up)))
        var out = [Double](repeating: 0, count: count)
        var noise = Noise(seed: 0x5EED)
        for layer in patch.layers {
            let layerOut = render(layer, count: count, sampleRate: sampleRate, noise: &noise)
            for i in 0 ..< count { out[i] += layerOut[i] }
        }
        return out.map(Float.init)
    }

    /// How long a patch rings, its echoes included (synth.ts patchDuration).
    public static func duration(of patch: SoundPatch) -> Double {
        let each = patch.layers.map { layer -> Double in
            let envelope = layer.envelope.map { ($0.attack ?? 0) + $0.decay + ($0.release ?? 0) } ?? 0.5
            let tail = layer.effects.map(echoTail).max() ?? 0
            return (layer.delay ?? 0) + envelope + tail
        }
        return (each.max() ?? 0) + 0.15
    }

    /// How long an echo rings after its source ends (cuelume shimmerTail).
    static func echoTail(_ echo: SoundPatch.Echo) -> Double {
        if echo.feedback <= 0 { return 0 }
        if echo.feedback >= 1 { return echo.delay }
        return echo.delay * (1 + (log(0.001) / log(echo.feedback)).rounded(.up))
    }

    private static func render(_ layer: SoundPatch.Layer, count: Int, sampleRate: Double, noise: inout Noise) -> [Double] {
        let start = layer.delay ?? 0
        let gain = layer.gain ?? 0.5
        let envelope = Automation(layer.envelope, gain: gain, at: start)
        // The source plays from its start to 0.1 s past its envelope.
        let stop = start + envelope.length + 0.1
        var signal = [Double](repeating: 0, count: count)

        var filters = layer.filters.map { Biquad($0, sampleRate: sampleRate) }
        var pink = PinkNoise(), brown = 0.0
        for i in 0 ..< count {
            let t = Double(i) / sampleRate
            var sample = 0.0
            if t >= start, t < stop {
                switch layer.source {
                case let .oscillator(waveform, frequency):
                    // From the exact moment the layer starts, between samples
                    // as it usually is, as Web Audio starts an oscillator.
                    let cycles = (t - start) * frequency
                    sample = Self.wave(waveform, phase: cycles - cycles.rounded(.down))
                case let .noise(color):
                    let white = noise.next()
                    switch color {
                    case .white: sample = white
                    case .pink: sample = pink.next(white)
                    case .brown:
                        brown = (brown + 0.02 * white) / 1.02
                        sample = brown * 3.5
                    }
                }
            }
            for f in filters.indices { sample = filters[f].process(sample) }
            signal[i] = sample * envelope.value(at: t)
        }
        for echo in layer.effects {
            var line = Echo(echo, sampleRate: sampleRate)
            for i in 0 ..< count { signal[i] = line.process(signal[i]) }
        }
        return signal
    }

    /// Web Audio's built-in waveforms, from a phase that starts at zero.
    static func wave(_ waveform: SoundPatch.Waveform, phase: Double) -> Double {
        switch waveform {
        case .sine: return sin(2 * .pi * phase)
        case .triangle:
            // Up from 0 to 1 at a quarter, down to -1 at three quarters, back.
            if phase < 0.25 { return 4 * phase }
            if phase < 0.75 { return 2 - 4 * phase }
            return 4 * phase - 4
        case .square: return phase < 0.5 ? 1 : -1
        case .sawtooth: return phase < 0.5 ? 2 * phase : 2 * phase - 2
        }
    }

    /// The envelope as the gain automation synth.ts schedules: "ramp" rises
    /// and falls exponentially from the floor; otherwise a linear rise and
    /// an exponential approach to the floor with a third of the decay as its
    /// time constant (setTargetAtTime).
    struct Automation {
        let start: Double
        let attack: Double
        let decay: Double
        let peak: Double
        let ramp: Bool
        let none: Bool
        let length: Double

        init(_ envelope: SoundPatch.Envelope?, gain: Double, at start: Double) {
            self.start = start
            guard let envelope else {
                attack = 0; decay = 0.15; peak = gain; ramp = false; none = true; length = 0.5
                return
            }
            attack = envelope.attack ?? 0
            decay = envelope.decay
            ramp = envelope.curve == "ramp"
            peak = ramp ? max(gain, SoundSynth.silence) : gain
            none = false
            // Sustain stays at the floor in the sounds played here, so the
            // release only lengthens the source, as in synth.ts.
            length = attack + decay + (envelope.release ?? 0)
        }

        func value(at t: Double) -> Double {
            let floor = SoundSynth.silence
            let x = t - start
            guard x >= 0 else { return 0 }
            if none { return floor + (peak - floor) * exp(-x / decay) }
            if ramp {
                if attack > 0, x < attack { return floor * pow(peak / floor, x / attack) }
                let fall = x - attack
                return fall < decay ? peak * pow(floor / peak, fall / decay) : floor
            }
            if attack > 0, x < attack { return floor + (peak - floor) * x / attack }
            return floor + (peak - floor) * exp(-(x - attack) / (decay / 3))
        }
    }

    /// Web Audio's BiquadFilterNode: the Audio EQ Cookbook, with Q read in
    /// decibels for low- and high-pass and as Q for band-pass, as the spec
    /// has it.
    struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(_ filter: SoundPatch.Filter, sampleRate: Double) {
            self.init(kind: filter.type, frequency: filter.frequency, q: filter.Q ?? 1, sampleRate: sampleRate)
        }

        init(kind: SoundPatch.Filter.Kind, frequency: Double, q: Double, sampleRate: Double) {
            let w0 = 2 * .pi * min(frequency, sampleRate / 2) / sampleRate
            let cosW = cos(w0), sinW = sin(w0)
            let a0: Double
            switch kind {
            case .lowpass, .highpass:
                let alpha = sinW / 2 * pow(10, -q / 20)
                a0 = 1 + alpha
                let low = kind == .lowpass
                b0 = (low ? 1 - cosW : 1 + cosW) / 2
                b1 = low ? 1 - cosW : -(1 + cosW)
                b2 = b0
                a1 = -2 * cosW
                a2 = 1 - alpha
            case .bandpass:
                let alpha = sinW / (2 * q)
                a0 = 1 + alpha
                b0 = alpha; b1 = 0; b2 = -alpha
                a1 = -2 * cosW
                a2 = 1 - alpha
            }
            b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// cuelume's shimmer: the dry sound through, and a delay line whose
    /// output is low-passed, fed back into it and sent to the output.
    struct Echo {
        var buffer: [Double]
        var write = 0
        let delay: Double
        let feedback: Double
        let wet: Double
        var lowpass: Biquad

        init(_ echo: SoundPatch.Echo, sampleRate: Double) {
            delay = echo.delay * sampleRate
            buffer = [Double](repeating: 0, count: Int(delay.rounded(.up)) + 2)
            feedback = echo.feedback
            wet = echo.wet
            lowpass = Biquad(kind: .lowpass, frequency: echo.lowpass ?? 4000, q: 1, sampleRate: sampleRate)
        }

        mutating func process(_ x: Double) -> Double {
            // Read `delay` samples back, between two samples as Web Audio does.
            let n = buffer.count
            let back = Double(write) - delay
            let i0 = Int(back.rounded(.down)), fraction = back - Double(i0)
            let a = buffer[((i0 % n) + n) % n], b = buffer[(((i0 + 1) % n) + n) % n]
            let delayed = lowpass.process(a + (b - a) * fraction)
            buffer[write] = x + feedback * delayed
            write = (write + 1) % n
            return x + wet * delayed
        }
    }

    /// A repeatable white noise: a sound is drawn once, so its grain is fixed.
    struct Noise {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    struct PinkNoise {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        mutating func next(_ white: Double) -> Double {
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.969 * b2 + white * 0.153852
            b3 = 0.8665 * b3 + white * 0.3104856
            b4 = 0.55 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.016898
            let out = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11
            b6 = white * 0.115926
            return out
        }
    }
}
