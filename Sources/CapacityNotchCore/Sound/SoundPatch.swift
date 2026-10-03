import Foundation

/// A sound as a recipe, in the format procedural-sounds exports
/// (github.com/m1ckc3s/procedural-sounds, lib/audio/patch.ts): one layer or
/// several, each a source shaped by an envelope, filtered, echoed and
/// summed. Only what CapaTheNotch's own sounds use is read — oscillators at a
/// fixed pitch, noise, the two envelopes, biquad filters and the feedback
/// echo; a recipe asking for more does not decode. MIT, as is the code this
/// follows (THIRD_PARTY_NOTICES.md).
public struct SoundPatch: Decodable, Equatable, Sendable {
    public var layers: [Layer]

    public struct Layer: Decodable, Equatable, Sendable {
        public var source: Source
        public var envelope: Envelope?
        public var gain: Double?
        /// Seconds after the sound starts that this layer starts.
        public var delay: Double?
        public var filters: [Filter]
        public var effects: [Echo]

        enum CodingKeys: String, CodingKey { case source, envelope, gain, delay, filter, effects }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(Source.self, forKey: .source)
            envelope = try c.decodeIfPresent(Envelope.self, forKey: .envelope)
            gain = try c.decodeIfPresent(Double.self, forKey: .gain)
            delay = try c.decodeIfPresent(Double.self, forKey: .delay)
            // One filter or a chain of them.
            if let one = try? c.decodeIfPresent(Filter.self, forKey: .filter) {
                filters = [one]
            } else {
                filters = try c.decodeIfPresent([Filter].self, forKey: .filter) ?? []
            }
            effects = try c.decodeIfPresent([Echo].self, forKey: .effects) ?? []
        }
    }

    public enum Source: Decodable, Equatable, Sendable {
        case oscillator(Waveform, frequency: Double)
        case noise(NoiseColor)

        enum CodingKeys: String, CodingKey { case type, frequency, color }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            if type == "noise" {
                self = .noise(try c.decodeIfPresent(NoiseColor.self, forKey: .color) ?? .white)
            } else if let waveform = Waveform(rawValue: type) {
                self = .oscillator(waveform, frequency: try c.decode(Double.self, forKey: .frequency))
            } else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown source \(type)")
            }
        }
    }

    public enum Waveform: String, Decodable, Sendable { case sine, triangle, square, sawtooth }
    public enum NoiseColor: String, Decodable, Sendable { case white, pink, brown }

    public struct Envelope: Decodable, Equatable, Sendable {
        public var attack: Double?
        public var decay: Double
        public var sustain: Double?
        public var release: Double?
        /// "ramp": exponential in and out; otherwise linear in, exponential out.
        public var curve: String?
    }

    public struct Filter: Decodable, Equatable, Sendable {
        public var type: Kind
        public var frequency: Double
        public var Q: Double?

        public enum Kind: String, Decodable, Sendable { case lowpass, highpass, bandpass }
    }

    /// The feedback echo ("delay"): the dry sound untouched, and its repeats
    /// darkened by a low-pass in the loop.
    public struct Echo: Decodable, Equatable, Sendable {
        public var type: String
        public var delay: Double
        public var feedback: Double
        public var wet: Double
        public var lowpass: Double?
    }

    enum CodingKeys: String, CodingKey { case layers }

    /// `{ "layers": [...] }`, or a single layer on its own.
    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.layers) {
            layers = try c.decode([Layer].self, forKey: .layers)
        } else {
            layers = [try Layer(from: decoder)]
        }
        guard layers.allSatisfy({ $0.effects.allSatisfy { $0.type == "delay" } }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Only the delay effect is played"))
        }
    }

    public init(json: String) throws {
        self = try JSONDecoder().decode(SoundPatch.self, from: Data(json.utf8))
    }
}
