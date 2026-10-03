import Foundation

/// CapaTheNotch's sounds, chosen by ear in procedural-sounds and exported as
/// recipes with their loudness baked in; kept here as exported, so each can be
/// held against its WAV.
public enum SoundRecipes {
    /// procedural-sounds "success-403y1".
    public static let success = SoundPatch.recipe(#"{"layers":[{"source":{"type":"noise","color":"white"},"envelope":{"attack":0.001,"decay":0.017870585743931692,"sustain":0,"release":0.004,"curve":"ramp"},"gain":0.03468576627794493,"filter":{"type":"bandpass","frequency":657.1238317520585,"Q":2.33},"effects":[{"type":"delay","delay":0.111,"feedback":0.224,"wet":0.165,"lowpass":3984}]},{"source":{"type":"sine","frequency":368.3322090367748},"envelope":{"attack":0.005,"decay":0.2309698338484762,"sustain":0,"release":0.004,"curve":"ramp"},"gain":0.15297515453750005,"effects":[{"type":"delay","delay":0.111,"feedback":0.224,"wet":0.165,"lowpass":3984}]},{"source":{"type":"sine","frequency":491.6641552842549},"envelope":{"attack":0.005,"decay":0.1487057769068815,"sustain":0,"release":0.004,"curve":"ramp"},"gain":0.1006937539784058,"delay":0.10359468005457505,"effects":[{"type":"delay","delay":0.111,"feedback":0.224,"wet":0.165,"lowpass":3984}]},{"source":{"type":"sine","frequency":656.2935694260105},"envelope":{"attack":0.005,"decay":0.14884005598209496,"sustain":0,"release":0.004,"curve":"ramp"},"gain":0.049555348760552585,"delay":0.18106548426930075,"effects":[{"type":"delay","delay":0.111,"feedback":0.224,"wet":0.165,"lowpass":3984}]}]}"#)

    /// procedural-sounds "warning-ypa7f".
    public static let warning = SoundPatch.recipe(#"{"layers":[{"source":{"type":"triangle","frequency":184.6774033652657},"envelope":{"attack":0.004,"decay":0.057441796600893914,"sustain":0,"release":0.004,"curve":"ramp"},"gain":0.222,"effects":[{"type":"delay","delay":0.092,"feedback":0.297,"wet":0.13,"lowpass":3344}]},{"source":{"type":"triangle","frequency":165.1372455467869},"envelope":{"attack":0.004,"decay":0.14265843300922143,"sustain":0,"release":0.004,"curve":"ramp"},"gain":0.213,"delay":0.1575770502139612,"effects":[{"type":"delay","delay":0.092,"feedback":0.297,"wet":0.13,"lowpass":3344}]}]}"#)

    /// procedural-sounds "error-2y2wb".
    public static let error = SoundPatch.recipe(#"{"layers":[{"source":{"type":"triangle","frequency":159.208},"envelope":{"attack":0.022,"decay":0.07,"sustain":0,"release":0},"gain":0.139,"filter":{"type":"lowpass","frequency":1119,"Q":0.814},"effects":[{"type":"delay","delay":0.134,"feedback":0.28,"wet":0.161,"lowpass":3124}]},{"source":{"type":"triangle","frequency":133.877},"envelope":{"attack":0.022,"decay":0.245,"sustain":0,"release":0},"gain":0.128,"delay":0.129,"filter":{"type":"lowpass","frequency":1486,"Q":1.202},"effects":[{"type":"delay","delay":0.134,"feedback":0.28,"wet":0.161,"lowpass":3124}]}]}"#)

    /// procedural-sounds "notification-bxat6".
    public static let notification = SoundPatch.recipe(#"{"layers":[{"source":{"type":"sine","frequency":655.495},"envelope":{"attack":0.004,"decay":0.12,"sustain":0,"release":0,"curve":"ramp"},"gain":0.15,"effects":[{"type":"delay","delay":0.096,"feedback":0.301,"wet":0.153,"lowpass":2574}]},{"source":{"type":"sine","frequency":982.133},"envelope":{"attack":0.004,"decay":0.21,"sustain":0,"release":0,"curve":"ramp"},"gain":0.149,"delay":0.073,"effects":[{"type":"delay","delay":0.096,"feedback":0.301,"wet":0.153,"lowpass":2574}]}]}"#)

    /// procedural-sounds "tap-0t8w2".
    public static let tap = SoundPatch.recipe(#"{"source":{"type":"sine","frequency":519.776},"envelope":{"attack":0,"decay":0.04,"sustain":0,"release":0.015},"gain":0.771,"filter":{"type":"bandpass","frequency":1760,"Q":2}}"#)

    public static let all: [(name: String, patch: SoundPatch)] = [
        ("success", success), ("warning", warning), ("error", error), ("notification", notification), ("tap", tap),
    ]
}

extension SoundPatch {
    /// A recipe written into the application: one that does not decode is a
    /// mistake in this file, caught by its test.
    static func recipe(_ json: String) -> SoundPatch {
        do { return try SoundPatch(json: json) } catch { preconditionFailure("A sound recipe does not decode: \(error)") }
    }
}
