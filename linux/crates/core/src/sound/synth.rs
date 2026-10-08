//! Renders a `SoundPatch` to samples, as procedural-sounds' player renders it
//! offline through Web Audio (lib/audio/synth.ts and effects.ts, adapted in
//! turn from @web-kits/audio and cuelume; MIT, THIRD_PARTY_NOTICES.md): each
//! layer's source started at its delay, through its filters, shaped by its
//! envelope's gain automation, through its echo, and summed. Mono, as theirs
//! is. A sound is a fraction of a second, so it is drawn whole once and played
//! as a buffer, never synthesised live in the audio thread.
//!
//! The arithmetic is the Swift `SoundSynth`'s, step for step, in the same
//! precision, so a patch renders to the same samples here as there.

use super::patch::{Echo as EchoSpec, Envelope, Filter, FilterKind, Layer, NoiseColor, Source, SoundPatch, Waveform};
use std::f64::consts::PI;

/// Web Audio's floor for the envelope: exponential ramps cannot reach zero.
const SILENCE: f64 = 0.0001;

pub const SAMPLE_RATE: f64 = 44100.0;

pub fn render(patch: &SoundPatch) -> Vec<f32> {
    render_at(patch, SAMPLE_RATE)
}

pub fn render_at(patch: &SoundPatch, sample_rate: f64) -> Vec<f32> {
    let seconds = (duration_of(patch) + 0.05).min(8.0);
    let count = ((seconds * sample_rate).ceil() as usize).max(1);
    let mut out = vec![0.0f64; count];
    let mut noise = Noise::new(0x5EED);
    for layer in &patch.layers {
        let layer_out = render_layer(layer, count, sample_rate, &mut noise);
        for (sum, sample) in out.iter_mut().zip(layer_out) {
            *sum += sample;
        }
    }
    out.into_iter().map(|x| x as f32).collect()
}

/// How long a patch rings, its echoes included (synth.ts patchDuration).
pub fn duration_of(patch: &SoundPatch) -> f64 {
    let longest = patch
        .layers
        .iter()
        .map(|layer| {
            let envelope = layer
                .envelope
                .as_ref()
                .map(|e| e.attack.unwrap_or(0.0) + e.decay + e.release.unwrap_or(0.0))
                .unwrap_or(0.5);
            let tail = layer.effects.iter().map(echo_tail).fold(None, |m: Option<f64>, t| Some(m.map_or(t, |m| m.max(t)))).unwrap_or(0.0);
            layer.delay.unwrap_or(0.0) + envelope + tail
        })
        .fold(None, |m: Option<f64>, t| Some(m.map_or(t, |m| m.max(t))))
        .unwrap_or(0.0);
    longest + 0.15
}

/// How long an echo rings after its source ends (cuelume shimmerTail).
fn echo_tail(echo: &EchoSpec) -> f64 {
    if echo.feedback <= 0.0 {
        return 0.0;
    }
    if echo.feedback >= 1.0 {
        return echo.delay;
    }
    echo.delay * (1.0 + (0.001f64.ln() / echo.feedback.ln()).ceil())
}

fn render_layer(layer: &Layer, count: usize, sample_rate: f64, noise: &mut Noise) -> Vec<f64> {
    let start = layer.delay.unwrap_or(0.0);
    let gain = layer.gain.unwrap_or(0.5);
    let envelope = Automation::new(layer.envelope.as_ref(), gain, start);
    // The source plays from its start to 0.1 s past its envelope.
    let stop = start + envelope.length + 0.1;
    let mut signal = vec![0.0f64; count];

    let mut filters: Vec<Biquad> = layer.filters.iter().map(|f| Biquad::from_filter(f, sample_rate)).collect();
    let mut pink = PinkNoise::default();
    let mut brown = 0.0f64;
    for (i, out) in signal.iter_mut().enumerate() {
        let t = i as f64 / sample_rate;
        let mut sample = 0.0;
        if t >= start && t < stop {
            match &layer.source {
                Source::Oscillator { waveform, frequency } => {
                    // From the exact moment the layer starts, between samples
                    // as it usually is, as Web Audio starts an oscillator.
                    let cycles = (t - start) * frequency;
                    sample = wave(*waveform, cycles - cycles.floor());
                }
                Source::Noise(color) => {
                    let white = noise.next();
                    sample = match color {
                        NoiseColor::White => white,
                        NoiseColor::Pink => pink.next(white),
                        NoiseColor::Brown => {
                            brown = (brown + 0.02 * white) / 1.02;
                            brown * 3.5
                        }
                    };
                }
            }
        }
        for filter in &mut filters {
            sample = filter.process(sample);
        }
        *out = sample * envelope.value(t);
    }
    for spec in &layer.effects {
        let mut line = EchoLine::new(spec, sample_rate);
        for sample in &mut signal {
            *sample = line.process(*sample);
        }
    }
    signal
}

/// Web Audio's built-in waveforms, from a phase that starts at zero.
fn wave(waveform: Waveform, phase: f64) -> f64 {
    match waveform {
        Waveform::Sine => (2.0 * PI * phase).sin(),
        Waveform::Triangle => {
            // Up from 0 to 1 at a quarter, down to -1 at three quarters, back.
            if phase < 0.25 {
                4.0 * phase
            } else if phase < 0.75 {
                2.0 - 4.0 * phase
            } else {
                4.0 * phase - 4.0
            }
        }
        Waveform::Square => {
            if phase < 0.5 {
                1.0
            } else {
                -1.0
            }
        }
        Waveform::Sawtooth => {
            if phase < 0.5 {
                2.0 * phase
            } else {
                2.0 * phase - 2.0
            }
        }
    }
}

/// The envelope as the gain automation synth.ts schedules: "ramp" rises and
/// falls exponentially from the floor; otherwise a linear rise and an
/// exponential approach to the floor with a third of the decay as its time
/// constant (setTargetAtTime).
struct Automation {
    start: f64,
    attack: f64,
    decay: f64,
    peak: f64,
    ramp: bool,
    none: bool,
    length: f64,
}

impl Automation {
    fn new(envelope: Option<&Envelope>, gain: f64, start: f64) -> Self {
        let Some(envelope) = envelope else {
            return Self { start, attack: 0.0, decay: 0.15, peak: gain, ramp: false, none: true, length: 0.5 };
        };
        let attack = envelope.attack.unwrap_or(0.0);
        let decay = envelope.decay;
        let ramp = envelope.curve.as_deref() == Some("ramp");
        Self {
            start,
            attack,
            decay,
            peak: if ramp { gain.max(SILENCE) } else { gain },
            ramp,
            none: false,
            // Sustain stays at the floor in the sounds played here, so the
            // release only lengthens the source, as in synth.ts.
            length: attack + decay + envelope.release.unwrap_or(0.0),
        }
    }

    fn value(&self, t: f64) -> f64 {
        let floor = SILENCE;
        let x = t - self.start;
        if x < 0.0 {
            return 0.0;
        }
        if self.none {
            return floor + (self.peak - floor) * (-x / self.decay).exp();
        }
        if self.ramp {
            if self.attack > 0.0 && x < self.attack {
                return floor * (self.peak / floor).powf(x / self.attack);
            }
            let fall = x - self.attack;
            return if fall < self.decay { self.peak * (floor / self.peak).powf(fall / self.decay) } else { floor };
        }
        if self.attack > 0.0 && x < self.attack {
            return floor + (self.peak - floor) * x / self.attack;
        }
        floor + (self.peak - floor) * (-(x - self.attack) / (self.decay / 3.0)).exp()
    }
}

/// Web Audio's BiquadFilterNode: the Audio EQ Cookbook, with Q read in
/// decibels for low- and high-pass and as Q for band-pass, as the spec has it.
#[derive(Default)]
struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

impl Biquad {
    fn from_filter(filter: &Filter, sample_rate: f64) -> Self {
        Self::new(filter.kind, filter.frequency, filter.q.unwrap_or(1.0), sample_rate)
    }

    fn new(kind: FilterKind, frequency: f64, q: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * frequency.min(sample_rate / 2.0) / sample_rate;
        let (cos_w, sin_w) = (w0.cos(), w0.sin());
        let mut f = Biquad::default();
        let a0;
        match kind {
            FilterKind::Lowpass | FilterKind::Highpass => {
                let alpha = sin_w / 2.0 * 10f64.powf(-q / 20.0);
                a0 = 1.0 + alpha;
                let low = kind == FilterKind::Lowpass;
                f.b0 = (if low { 1.0 - cos_w } else { 1.0 + cos_w }) / 2.0;
                f.b1 = if low { 1.0 - cos_w } else { -(1.0 + cos_w) };
                f.b2 = f.b0;
                f.a1 = -2.0 * cos_w;
                f.a2 = 1.0 - alpha;
            }
            FilterKind::Bandpass => {
                let alpha = sin_w / (2.0 * q);
                a0 = 1.0 + alpha;
                f.b0 = alpha;
                f.b1 = 0.0;
                f.b2 = -alpha;
                f.a1 = -2.0 * cos_w;
                f.a2 = 1.0 - alpha;
            }
        }
        f.b0 /= a0;
        f.b1 /= a0;
        f.b2 /= a0;
        f.a1 /= a0;
        f.a2 /= a0;
        f
    }

    fn process(&mut self, x: f64) -> f64 {
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }
}

/// cuelume's shimmer: the dry sound through, and a delay line whose output is
/// low-passed, fed back into it and sent to the output.
struct EchoLine {
    buffer: Vec<f64>,
    write: usize,
    delay: f64,
    feedback: f64,
    wet: f64,
    lowpass: Biquad,
}

impl EchoLine {
    fn new(echo: &EchoSpec, sample_rate: f64) -> Self {
        let delay = echo.delay * sample_rate;
        Self {
            buffer: vec![0.0; delay.ceil() as usize + 2],
            write: 0,
            delay,
            feedback: echo.feedback,
            wet: echo.wet,
            lowpass: Biquad::new(FilterKind::Lowpass, echo.lowpass.unwrap_or(4000.0), 1.0, sample_rate),
        }
    }

    fn process(&mut self, x: f64) -> f64 {
        // Read `delay` samples back, between two samples as Web Audio does.
        let n = self.buffer.len() as i64;
        let back = self.write as f64 - self.delay;
        let i0 = back.floor() as i64;
        let fraction = back - i0 as f64;
        let a = self.buffer[(((i0 % n) + n) % n) as usize];
        let b = self.buffer[((((i0 + 1) % n) + n) % n) as usize];
        let delayed = self.lowpass.process(a + (b - a) * fraction);
        self.buffer[self.write] = x + self.feedback * delayed;
        self.write = (self.write + 1) % self.buffer.len();
        x + self.wet * delayed
    }
}

/// A repeatable white noise: a sound is drawn once, so its grain is fixed.
/// SplitMix64, as the Swift synth has it.
struct Noise {
    state: u64,
}

impl Noise {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next(&mut self) -> f64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
    }
}

#[derive(Default)]
struct PinkNoise {
    b0: f64,
    b1: f64,
    b2: f64,
    b3: f64,
    b4: f64,
    b5: f64,
    b6: f64,
}

impl PinkNoise {
    fn next(&mut self, white: f64) -> f64 {
        self.b0 = 0.99886 * self.b0 + white * 0.0555179;
        self.b1 = 0.99332 * self.b1 + white * 0.0750759;
        self.b2 = 0.969 * self.b2 + white * 0.153852;
        self.b3 = 0.8665 * self.b3 + white * 0.3104856;
        self.b4 = 0.55 * self.b4 + white * 0.5329522;
        self.b5 = -0.7616 * self.b5 - white * 0.016898;
        let out = (self.b0 + self.b1 + self.b2 + self.b3 + self.b4 + self.b5 + self.b6 + white * 0.5362) * 0.11;
        self.b6 = white * 0.115926;
        out
    }
}

#[cfg(test)]
pub(crate) fn noise_sequence(seed: u64, n: usize) -> Vec<f64> {
    let mut noise = Noise::new(seed);
    (0..n).map(|_| noise.next()).collect()
}
