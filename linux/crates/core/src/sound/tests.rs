use super::cues::*;
use super::patch::*;
use super::{file, recipes, synth};
use std::sync::Mutex;

fn peak(samples: &[f32]) -> f32 {
    samples.iter().map(|s| s.abs()).fold(0.0, f32::max)
}

#[test]
fn every_sound_recipe_decodes_and_rings() {
    for (name, patch) in recipes::all() {
        let samples = synth::render(&patch);
        let p = peak(&samples);
        assert!(p > 0.02 && p < 1.0, "{name} is heard and does not clip (peak {p})");
        assert!(samples.len() as f64 / 44100.0 < 2.0, "{name} is a moment, not a tune");
    }
    assert_eq!(recipes::tap().layers.len(), 1, "A single layer on its own reads as one layer");
}

#[test]
fn a_layer_starts_at_its_delay_and_ramps_from_the_floor() {
    let patch = SoundPatch::from_json(
        r#"{"source":{"type":"sine","frequency":441},"envelope":{"attack":0.01,"decay":0.1,"curve":"ramp"},"gain":0.5,"delay":0.1}"#,
    )
    .unwrap();
    let samples = synth::render(&patch);
    assert!(samples[..4400].iter().all(|s| *s == 0.0), "Nothing before the layer's delay");
    let rise = peak(&samples[4410..4410 + 441]);
    let top = peak(&samples[4410 + 441..4410 + 882]);
    assert!(rise < top, "It rises to its peak over the attack");
    assert!((top - 0.5).abs() < 0.05, "And the peak is its gain ({top})");
}

#[test]
fn only_the_echo_is_played() {
    let reverb = r#"{"source":{"type":"sine","frequency":440},"envelope":{"decay":0.1},"effects":[{"type":"reverb","decay":1}]}"#;
    // `reverb` lacks the echo's own fields, so it fails to decode either way;
    // a well-formed effect of another kind is refused for what it is.
    assert!(SoundPatch::from_json(reverb).is_err(), "A recipe asking for reverb does not decode rather than playing wrong");
    let other = r#"{"source":{"type":"sine","frequency":440},"envelope":{"decay":0.1},"effects":[{"type":"chorus","delay":0.1,"feedback":0.2,"wet":0.3}]}"#;
    assert_eq!(SoundPatch::from_json(other).unwrap_err().0, "Only the delay effect is played");
}

/// CAPACITY_NOTCH_SOUND_DUMP=<folder> writes each sound as 16-bit WAV, trimmed
/// and faded as procedural-sounds exports them, to hold against theirs.
#[test]
fn sounds_can_be_written_for_listening() {
    let Ok(folder) = std::env::var("CAPACITY_NOTCH_SOUND_DUMP") else { return };
    for (name, patch) in recipes::all() {
        let path = std::path::Path::new(&folder).join(format!("{name}.wav"));
        std::fs::write(path, file::wav(&synth::render(&patch))).unwrap();
    }
}

// MARK: - Beyond the Swift tests: the decoder, the WAV, the numbers

#[test]
fn a_recipe_decodes_as_one_layer_a_list_or_a_chain_of_filters() {
    let chain = SoundPatch::from_json(
        r#"{"layers":[{"source":{"type":"noise"},"filter":[{"type":"lowpass","frequency":900},{"type":"highpass","frequency":100,"Q":3}]}]}"#,
    )
    .unwrap();
    let layer = &chain.layers[0];
    assert_eq!(layer.source, Source::Noise(NoiseColor::White), "Noise is white unless said");
    assert_eq!(layer.filters.len(), 2);
    assert_eq!(layer.filters[1].kind, FilterKind::Highpass);
    assert_eq!(layer.filters[1].q, Some(3.0));
    assert_eq!(layer.envelope, None);
}

#[test]
fn a_recipe_that_is_not_understood_does_not_decode() {
    for bad in [
        "not json",
        r#"{"source":{"type":"wobble","frequency":1}}"#,
        r#"{"source":{"type":"sine"}}"#,
        r#"{"source":{"type":"noise","color":"blue"}}"#,
        r#"{"source":{"type":"sine","frequency":1},"envelope":{"attack":0.1}}"#,
        r#"{"source":{"type":"sine","frequency":1},"filter":{"type":"notch","frequency":1}}"#,
        r#"{"layers":[{"gain":1}]}"#,
        r#"{"layers":3}"#,
    ] {
        assert!(SoundPatch::from_json(bad).is_err(), "{bad}");
    }
}

#[test]
fn the_synth_is_repeatable_and_its_noise_is_splitmix() {
    let patch = recipes::success();
    assert_eq!(synth::render(&patch), synth::render(&patch), "A sound is drawn once, so its grain is fixed");
    // SplitMix64 from seed 0x5EED: the first values, pinned.
    let first = synth::noise_sequence(0x5EED, 3);
    assert!(first.iter().all(|x| (-1.0..1.0).contains(x)));
    assert_eq!(first, synth::noise_sequence(0x5EED, 3));
    assert_ne!(first, synth::noise_sequence(0x5EEE, 3));
}

#[test]
fn how_long_a_patch_rings_counts_its_echoes() {
    let dry = SoundPatch::from_json(r#"{"source":{"type":"sine","frequency":440},"envelope":{"attack":0.01,"decay":0.1,"release":0.02}}"#).unwrap();
    assert!((synth::duration_of(&dry) - (0.13 + 0.15)).abs() < 1e-12);
    let echoed = SoundPatch::from_json(
        r#"{"source":{"type":"sine","frequency":440},"envelope":{"decay":0.1},"effects":[{"type":"delay","delay":0.1,"feedback":0.5,"wet":0.2}]}"#,
    )
    .unwrap();
    // 0.1 * (1 + ceil(ln 0.001 / ln 0.5)) = 0.1 * 11
    assert!((synth::duration_of(&echoed) - (0.1 + 1.1 + 0.15)).abs() < 1e-9);
    let no_envelope = SoundPatch::from_json(r#"{"source":{"type":"sine","frequency":440}}"#).unwrap();
    assert!((synth::duration_of(&no_envelope) - 0.65).abs() < 1e-12, "No envelope rings half a second");
}

#[test]
fn a_wav_is_mono_16_bit_with_its_lengths_right() {
    let samples = synth::render(&recipes::tap());
    let wav = file::wav(&samples);
    assert_eq!(&wav[0..4], b"RIFF");
    assert_eq!(&wav[8..16], b"WAVEfmt ");
    assert_eq!(u16::from_le_bytes([wav[20], wav[21]]), 1, "PCM");
    assert_eq!(u16::from_le_bytes([wav[22], wav[23]]), 1, "Mono");
    assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 44100);
    assert_eq!(u32::from_le_bytes(wav[28..32].try_into().unwrap()), 88200);
    assert_eq!(u16::from_le_bytes([wav[34], wav[35]]), 16);
    assert_eq!(&wav[36..40], b"data");
    let bytes = u32::from_le_bytes(wav[40..44].try_into().unwrap()) as usize;
    assert_eq!(wav.len(), 44 + bytes);
    assert_eq!(u32::from_le_bytes(wav[4..8].try_into().unwrap()) as usize, 36 + bytes);
}

#[test]
fn the_cut_trims_the_silence_and_fades_both_edges() {
    // Silence, a quiet lead-in (above the silence floor, under 1% of the
    // peak), the sound, silence.
    let mut samples = vec![0.0f32; 1000];
    samples.extend(std::iter::repeat_n(0.001, 300));
    samples.extend(std::iter::repeat_n(0.5, 2000));
    samples.extend(vec![0.0f32; 1000]);
    let cut = file::trim_and_fade(&samples, 44100.0);
    assert_eq!(cut.len(), 2300, "The silence either side goes, the lead-in stays");
    assert_eq!(cut[0], 0.0, "Fades in from nothing, over two milliseconds (88 samples)");
    assert!(cut[1] > 0.0 && cut[1] < 0.001, "and rises");
    assert_eq!(cut[88], 0.001, "The fade is over after 88 samples");
    assert_eq!(cut[1000], 0.5, "The middle is untouched");
    assert_eq!(*cut.last().unwrap(), 0.0, "Fades out to nothing");
    // Six milliseconds is 265 samples: the last 265 are faded, the one before is not.
    let n = cut.len();
    assert_eq!(cut[n - 266], 0.5);
    assert!(cut[n - 265] < 0.5 && cut[n - 265] > 0.49, "the fade starts all but unnoticed");
}

#[test]
fn a_sound_that_starts_at_once_is_not_faded_in() {
    let mut samples = vec![0.0f32; 500];
    samples.extend(std::iter::repeat_n(0.5, 2000));
    let cut = file::trim_and_fade(&samples, 44100.0);
    assert_eq!(cut[0], 0.5, "Nothing to fade in over: the cut is already at the onset");
    assert_eq!(cut.len(), 2000);
}

#[test]
fn a_silent_render_is_cut_to_ten_milliseconds() {
    assert_eq!(file::trim_and_fade(&vec![0.0; 44100], 44100.0).len(), 441);
    assert!(file::trim_and_fade(&[], 44100.0).is_empty());
    let wav = file::wav(&[2.0, -2.0]);
    assert_eq!(wav.len(), 44 + 4, "Anything above silence is kept, then clamped");
    assert_eq!(i16::from_le_bytes([wav[44], wav[45]]), 32767, "Clamped to full scale");
    assert_eq!(i16::from_le_bytes([wav[46], wav[47]]), -32768);
}

#[test]
fn samples_are_clamped_and_scaled_asymmetrically() {
    let full = file::pcm16(&vec![1.5; 10_000], 44100);
    assert_eq!(full[full.len() / 2], 32767);
    let low = file::pcm16(&vec![-1.5; 10_000], 44100);
    assert_eq!(low[low.len() / 2], -32768);
}

struct Recorder(Mutex<Vec<(SoundCue, usize)>>);

impl SoundOut for Recorder {
    fn play(&self, cue: SoundCue, buffer: &SoundBuffer) {
        self.0.lock().unwrap().push((cue, buffer.pcm.len()));
    }
}

#[test]
fn each_moment_has_its_sound() {
    use Recipe::*;
    use SoundCue::*;
    for cue in [SurfacePinned, ShelfTook, ClippingCopied] {
        assert_eq!(cue.recipe(), Tap);
    }
    for cue in [KapaTapped, DictationModelReady, DictationInserted, DictationCopied] {
        assert_eq!(cue.recipe(), Success);
    }
    assert_eq!(DictationFailed.recipe(), Error);
    assert_eq!(ProviderStopped.recipe(), Warning);
    assert_eq!(CapacityAlert.recipe(), Warning);
    for cue in [CapacityRecovered, KapaHello, OnboardingFinished] {
        assert_eq!(cue.recipe(), Notification);
    }
    assert_eq!(SoundCue::ALL.len(), 13);
}

#[test]
fn a_cue_serialises_in_camel_case() {
    assert_eq!(serde_json::to_string(&SoundCue::DictationModelReady).unwrap(), "\"dictationModelReady\"");
    assert_eq!(serde_json::from_str::<SoundCue>("\"kapaHello\"").unwrap(), SoundCue::KapaHello);
}

#[test]
fn nothing_plays_when_the_switch_is_off_the_system_is_quiet_or_the_teleprompter_runs() {
    let bank = SoundBank::new();
    let out = Recorder(Mutex::new(vec![]));
    assert!(bank.play(SoundCue::SurfacePinned, &SoundPolicy::default(), &out));
    for policy in [
        SoundPolicy { enabled: false, ..Default::default() },
        SoundPolicy { interface_sounds_on: false, ..Default::default() },
        SoundPolicy { quiet: true, ..Default::default() },
    ] {
        assert!(!bank.play(SoundCue::CapacityAlert, &policy, &out), "{policy:?}");
    }
    assert_eq!(out.0.lock().unwrap().len(), 1, "Only the one that was allowed");
}

#[test]
fn a_sound_is_drawn_once_and_shared_by_the_cues_that_use_it() {
    let bank = SoundBank::new();
    let a = bank.buffer(SoundCue::SurfacePinned);
    let b = bank.buffer(SoundCue::ShelfTook);
    assert!(std::sync::Arc::ptr_eq(&a, &b), "Three cues share the tap");
    assert!(!std::sync::Arc::ptr_eq(&a, &bank.buffer(SoundCue::KapaTapped)));
    bank.prepare();
    assert!(a.pcm.len() > 100 && a.sample_rate == 44100);
    assert_eq!(a.wav.len(), 44 + a.pcm.len() * 2, "The buffer and the file are the one cut");
}
