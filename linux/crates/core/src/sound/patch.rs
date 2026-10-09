//! A sound as a recipe, in the format procedural-sounds exports
//! (github.com/m1ckc3s/procedural-sounds, lib/audio/patch.ts): one layer or
//! several, each a source shaped by an envelope, filtered, echoed and summed.
//! Only what CapaTheNotch's own sounds use is read — oscillators at a fixed
//! pitch, noise, the two envelopes, biquad filters and the feedback echo; a
//! recipe asking for more does not decode. MIT, as is the code this follows
//! (THIRD_PARTY_NOTICES.md).

use serde_json::{Map, Value};
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub struct SoundPatch {
    pub layers: Vec<Layer>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Layer {
    pub source: Source,
    pub envelope: Option<Envelope>,
    pub gain: Option<f64>,
    /// Seconds after the sound starts that this layer starts.
    pub delay: Option<f64>,
    pub filters: Vec<Filter>,
    pub effects: Vec<Echo>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    Oscillator { waveform: Waveform, frequency: f64 },
    Noise(NoiseColor),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Waveform {
    Sine,
    Triangle,
    Square,
    Sawtooth,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoiseColor {
    White,
    Pink,
    Brown,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Envelope {
    pub attack: Option<f64>,
    pub decay: f64,
    pub sustain: Option<f64>,
    pub release: Option<f64>,
    /// "ramp": exponential in and out; otherwise linear in, exponential out.
    pub curve: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Filter {
    pub kind: FilterKind,
    pub frequency: f64,
    pub q: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilterKind {
    Lowpass,
    Highpass,
    Bandpass,
}

/// The feedback echo ("delay"): the dry sound untouched, and its repeats
/// darkened by a low-pass in the loop.
#[derive(Debug, Clone, PartialEq)]
pub struct Echo {
    pub kind: String,
    pub delay: f64,
    pub feedback: f64,
    pub wet: f64,
    pub lowpass: Option<f64>,
}

/// Why a recipe does not decode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatchError(pub String);

impl fmt::Display for PatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PatchError {}

fn err<T>(message: impl Into<String>) -> Result<T, PatchError> {
    Err(PatchError(message.into()))
}

fn number(object: &Map<String, Value>, key: &str) -> Result<Option<f64>, PatchError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_f64().map(Some).ok_or_else(|| PatchError(format!("`{key}` is not a number"))),
    }
}

fn required_number(object: &Map<String, Value>, key: &str) -> Result<f64, PatchError> {
    number(object, key)?.ok_or_else(|| PatchError(format!("`{key}` is missing")))
}

fn text(object: &Map<String, Value>, key: &str) -> Result<Option<String>, PatchError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => err(format!("`{key}` is not text")),
    }
}

fn object<'a>(value: &'a Value, what: &str) -> Result<&'a Map<String, Value>, PatchError> {
    value.as_object().ok_or_else(|| PatchError(format!("{what} is not an object")))
}

impl Source {
    fn parse(value: &Value) -> Result<Source, PatchError> {
        let o = object(value, "`source`")?;
        let kind = text(o, "type")?.ok_or_else(|| PatchError("`type` is missing".into()))?;
        if kind == "noise" {
            let color = match text(o, "color")?.as_deref() {
                None | Some("white") => NoiseColor::White,
                Some("pink") => NoiseColor::Pink,
                Some("brown") => NoiseColor::Brown,
                Some(other) => return err(format!("Unknown noise colour {other}")),
            };
            return Ok(Source::Noise(color));
        }
        let waveform = match kind.as_str() {
            "sine" => Waveform::Sine,
            "triangle" => Waveform::Triangle,
            "square" => Waveform::Square,
            "sawtooth" => Waveform::Sawtooth,
            other => return err(format!("Unknown source {other}")),
        };
        Ok(Source::Oscillator { waveform, frequency: required_number(o, "frequency")? })
    }
}

impl Envelope {
    fn parse(value: &Value) -> Result<Envelope, PatchError> {
        let o = object(value, "`envelope`")?;
        Ok(Envelope {
            attack: number(o, "attack")?,
            decay: required_number(o, "decay")?,
            sustain: number(o, "sustain")?,
            release: number(o, "release")?,
            curve: text(o, "curve")?,
        })
    }
}

impl Filter {
    fn parse(value: &Value) -> Result<Filter, PatchError> {
        let o = object(value, "`filter`")?;
        let kind = match text(o, "type")?.as_deref() {
            Some("lowpass") => FilterKind::Lowpass,
            Some("highpass") => FilterKind::Highpass,
            Some("bandpass") => FilterKind::Bandpass,
            Some(other) => return err(format!("Unknown filter {other}")),
            None => return err("`type` is missing"),
        };
        Ok(Filter { kind, frequency: required_number(o, "frequency")?, q: number(o, "Q")? })
    }
}

impl Echo {
    fn parse(value: &Value) -> Result<Echo, PatchError> {
        let o = object(value, "an effect")?;
        Ok(Echo {
            kind: text(o, "type")?.ok_or_else(|| PatchError("`type` is missing".into()))?,
            delay: required_number(o, "delay")?,
            feedback: required_number(o, "feedback")?,
            wet: required_number(o, "wet")?,
            lowpass: number(o, "lowpass")?,
        })
    }
}

impl Layer {
    fn parse(value: &Value) -> Result<Layer, PatchError> {
        let o = object(value, "a layer")?;
        let source = Source::parse(o.get("source").ok_or_else(|| PatchError("`source` is missing".into()))?)?;
        // One filter or a chain of them.
        let filters = match o.get("filter") {
            None | Some(Value::Null) => vec![],
            Some(Value::Array(many)) => many.iter().map(Filter::parse).collect::<Result<_, _>>()?,
            Some(one) => vec![Filter::parse(one)?],
        };
        let effects = match o.get("effects") {
            None | Some(Value::Null) => vec![],
            Some(Value::Array(many)) => many.iter().map(Echo::parse).collect::<Result<_, _>>()?,
            Some(_) => return err("`effects` is not a list"),
        };
        Ok(Layer {
            source,
            envelope: o.get("envelope").filter(|v| !v.is_null()).map(Envelope::parse).transpose()?,
            gain: number(o, "gain")?,
            delay: number(o, "delay")?,
            filters,
            effects,
        })
    }
}

impl SoundPatch {
    /// `{ "layers": [...] }`, or a single layer on its own.
    pub fn from_json(json: &str) -> Result<SoundPatch, PatchError> {
        let value: Value = serde_json::from_str(json).map_err(|e| PatchError(e.to_string()))?;
        let layers = match value.as_object().and_then(|o| o.get("layers")) {
            Some(Value::Array(many)) => many.iter().map(Layer::parse).collect::<Result<Vec<_>, _>>()?,
            Some(_) => return err("`layers` is not a list"),
            None => vec![Layer::parse(&value)?],
        };
        if !layers.iter().all(|l| l.effects.iter().all(|e| e.kind == "delay")) {
            return err("Only the delay effect is played");
        }
        Ok(SoundPatch { layers })
    }
}
