import CapacityNotchCore
import Foundation

func everySoundRecipeDecodesAndRings() throws {
    for (name, patch) in SoundRecipes.all {
        let samples = SoundSynth.render(patch)
        let peak = samples.map(abs).max() ?? 0
        try expect(peak > 0.02 && peak < 1, "\(name) is heard and does not clip (peak \(peak))")
        try expect(Double(samples.count) / 44100 < 2, "\(name) is a moment, not a tune")
    }
    try expect(SoundRecipes.tap.layers.count == 1, "A single layer on its own reads as one layer")
}

func aLayerStartsAtItsDelayAndRampsFromTheFloor() throws {
    let patch = try SoundPatch(json: #"{"source":{"type":"sine","frequency":441},"envelope":{"attack":0.01,"decay":0.1,"curve":"ramp"},"gain":0.5,"delay":0.1}"#)
    let samples = SoundSynth.render(patch)
    try expect(samples[0 ..< 4400].allSatisfy { $0 == 0 }, "Nothing before the layer's delay")
    let rise = samples[4410 ..< 4410 + 441].map(abs).max() ?? 0
    let top = samples[4410 + 441 ..< 4410 + 882].map(abs).max() ?? 0
    try expect(rise < top, "It rises to its peak over the attack")
    try expect(abs(top - 0.5) < 0.05, "And the peak is its gain (\(top))")
}

func onlyTheEchoIsPlayed() throws {
    let reverb = #"{"source":{"type":"sine","frequency":440},"envelope":{"decay":0.1},"effects":[{"type":"reverb","decay":1}]}"#
    try expect((try? SoundPatch(json: reverb)) == nil, "A recipe asking for reverb does not decode rather than playing wrong")
}

/// CAPACITY_NOTCH_SOUND_DUMP=<folder> writes each sound as 16-bit WAV, trimmed
/// and faded as procedural-sounds exports them, to hold against theirs.
func soundsCanBeWrittenForListening() throws {
    guard let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_SOUND_DUMP"] else { return }
    for (name, patch) in SoundRecipes.all {
        try SoundFile.wav(SoundSynth.render(patch)).write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).wav"))
    }
}
