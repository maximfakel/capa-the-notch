//! The microphone, through `cpal` (ALSA/PipeWire/PulseAudio): an input-only
//! capture of 16 kHz mono `f32`, bounded at sixty seconds, that keeps
//! capturing across a change of default input and never opens an output
//! beside it. Raw audio stays in memory.
//!
//! `cpal`'s `Stream` is not `Send` on every backend, so a worker thread owns
//! it for the length of one recording.

use capa_core::dictation::{
    audio::{level_of, SampleBuffer},
    DictationFailure, Microphone, MicrophoneInput, MicrophonePermission, MicrophoneSink, MICROPHONE_COULD_NOT_START,
    NO_MICROPHONE,
};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

const TARGET_RATE: u32 = 16_000;

/// Averages whatever falls in each 1/16000 s into one sample. Plain, and good
/// enough for speech going into a recogniser that wants 16 kHz.
pub struct Resampler {
    step: f64,
    position: f64,
    sum: f32,
    count: u32,
}

impl Resampler {
    pub fn new(input_rate: u32) -> Self {
        Self { step: f64::from(input_rate) / f64::from(TARGET_RATE), position: 0.0, sum: 0.0, count: 0 }
    }

    /// Takes interleaved frames of `channels` and appends the mono 16 kHz samples they make.
    pub fn push(&mut self, input: &[f32], channels: usize, out: &mut Vec<f32>) {
        let channels = channels.max(1);
        for frame in input.chunks_exact(channels) {
            let mono = frame.iter().sum::<f32>() / channels as f32;
            self.sum += mono;
            self.count += 1;
            self.position += 1.0;
            if self.position >= self.step {
                out.push(self.sum / self.count as f32);
                self.position -= self.step;
                self.sum = 0.0;
                self.count = 0;
            }
        }
    }
}

/// The level is measured a tenth of a second at a time — 1,600 samples at
/// 16 kHz, the size of the Swift queue's buffers — whatever size the system's
/// own buffers are, so the orb hears the same rhythm on every platform.
pub struct LevelMeter {
    block: Vec<f32>,
}

impl LevelMeter {
    pub const BLOCK: usize = 1_600;

    pub fn new() -> Self {
        Self { block: Vec::with_capacity(Self::BLOCK) }
    }

    /// Takes 16 kHz mono samples and returns the level of each block they complete.
    pub fn push(&mut self, samples: &[f32]) -> Vec<f32> {
        let mut levels = Vec::new();
        let mut rest = samples;
        while !rest.is_empty() {
            let take = (Self::BLOCK - self.block.len()).min(rest.len());
            self.block.extend_from_slice(&rest[..take]);
            rest = &rest[take..];
            if self.block.len() == Self::BLOCK {
                levels.push(level_of(&self.block));
                self.block.clear();
            }
        }
        levels
    }
}

impl Default for LevelMeter {
    fn default() -> Self {
        Self::new()
    }
}

struct Shared {
    buffer: Mutex<SampleBuffer>,
    sink: Box<dyn MicrophoneSink>,
}

/// GNOME's switch for the microphone, for every application at once: Settings →
/// Privacy & Security → Microphone. Read, never written.
const PRIVACY_SCHEMA: &str = "org.gnome.desktop.privacy";
const PRIVACY_KEY: &str = "disable-microphone";

/// Whether the desktop has the microphone switched off: `Some(true)` when it
/// has, `None` where there is no such switch (not GNOME, no `gsettings`).
pub type PrivacyReader = Box<dyn Fn() -> Option<bool> + Send + Sync>;

/// GNOME's answer, through `gsettings get` (read-only).
pub fn gnome_microphone_disabled() -> Option<bool> {
    let output = std::process::Command::new("gsettings")
        .args(["get", PRIVACY_SCHEMA, PRIVACY_KEY])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_gsettings_bool(&String::from_utf8_lossy(&output.stdout))
}

/// `gsettings get` prints a boolean as `true` or `false`.
fn parse_gsettings_bool(printed: &str) -> Option<bool> {
    match printed.trim() {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

/// What the switch means for Dictation. Off is refused, as a Mac's microphone
/// refused in System Settings is (`denied`); there is no question to ask otherwise.
pub fn permission_from(disabled: Option<bool>) -> MicrophonePermission {
    if disabled == Some(true) {
        MicrophonePermission::Denied
    } else {
        MicrophonePermission::Authorized
    }
}

pub struct CpalMicrophone {
    worker: Option<(Sender<()>, JoinHandle<()>)>,
    shared: Option<Arc<Shared>>,
    privacy: PrivacyReader,
}

impl CpalMicrophone {
    pub fn new() -> Self {
        Self::with_privacy(Box::new(gnome_microphone_disabled))
    }

    /// Reading the desktop's microphone switch with `privacy`.
    pub fn with_privacy(privacy: PrivacyReader) -> Self {
        Self { worker: None, shared: None, privacy }
    }

    /// The names of the inputs there are, for a choice in Settings.
    pub fn inputs() -> Vec<String> {
        cpal::default_host()
            .input_devices()
            .map(|devices| devices.filter_map(|d| d.name().ok()).collect())
            .unwrap_or_default()
    }
}

impl Default for CpalMicrophone {
    fn default() -> Self {
        Self::new()
    }
}

/// Opens the default input and starts a stream into `shared`. `Err` is the
/// sentence for the capsule.
fn open(shared: &Arc<Shared>) -> Result<(cpal::Stream, MicrophoneInput, String), DictationFailure> {
    let host = cpal::default_host();
    let device = host.default_input_device().ok_or_else(|| DictationFailure::new(NO_MICROPHONE))?;
    let name = device.name().unwrap_or_default();
    let config = device.default_input_config().map_err(|_| DictationFailure::new(MICROPHONE_COULD_NOT_START))?;
    let (rate, channels, format) = (config.sample_rate().0, config.channels() as usize, config.sample_format());
    let stream_config: cpal::StreamConfig = config.into();

    let resampler = Mutex::new(Resampler::new(rate));
    let meter = Mutex::new(LevelMeter::new());
    let feed = {
        let shared = shared.clone();
        move |frames: &[f32]| {
            let mut mono = Vec::with_capacity(frames.len() / channels.max(1) / 2 + 1);
            resampler.lock().unwrap().push(frames, channels, &mut mono);
            if mono.is_empty() {
                return;
            }
            for level in meter.lock().unwrap().push(&mono) {
                shared.sink.level(level);
            }
            if shared.buffer.lock().unwrap().push(&mono) {
                shared.sink.limit_reached();
            }
        }
    };
    let on_error = |_error: cpal::StreamError| {};
    let stream = match format {
        cpal::SampleFormat::F32 => device.build_input_stream(&stream_config, move |d: &[f32], _| feed(d), on_error, None),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &stream_config,
            move |d: &[i16], _| feed(&d.iter().map(|s| f32::from(*s) / 32768.0).collect::<Vec<_>>()),
            on_error,
            None,
        ),
        cpal::SampleFormat::U16 => device.build_input_stream(
            &stream_config,
            move |d: &[u16], _| feed(&d.iter().map(|s| (f32::from(*s) - 32768.0) / 32768.0).collect::<Vec<_>>()),
            on_error,
            None,
        ),
        _ => return Err(DictationFailure::new(MICROPHONE_COULD_NOT_START)),
    }
    .map_err(|_| DictationFailure::new(MICROPHONE_COULD_NOT_START))?;
    stream.play().map_err(|_| DictationFailure::new(MICROPHONE_COULD_NOT_START))?;
    // What the device itself gives, as the Swift logs it: its own rate and
    // channels, not the 16 kHz mono they are turned into.
    let input = MicrophoneInput { sample_rate: rate, channels: u32::try_from(channels).unwrap_or(u32::MAX) };
    Ok((stream, input, name))
}

impl Microphone for CpalMicrophone {
    /// Native applications are not asked: there is no question to answer. Only
    /// GNOME's switch for every application can refuse the microphone.
    fn permission(&self) -> MicrophonePermission {
        permission_from((self.privacy)())
    }

    fn request_permission(&mut self) {}

    /// GNOME Settings' Privacy & Security, where the switch is.
    fn open_privacy_settings(&mut self) {
        let _ = std::process::Command::new("gnome-control-center")
            .arg("privacy")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }

    fn start(&mut self, sink: Box<dyn MicrophoneSink>) -> Result<MicrophoneInput, DictationFailure> {
        self.stop();
        let mut buffer = SampleBuffer::new();
        buffer.start();
        let shared = Arc::new(Shared { buffer: Mutex::new(buffer), sink });
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<MicrophoneInput, DictationFailure>>();
        let worker_shared = shared.clone();
        let handle = std::thread::spawn(move || {
            let mut current = match open(&worker_shared) {
                Ok((stream, input, name)) => {
                    let _ = ready_tx.send(Ok(input));
                    (stream, name)
                }
                Err(failure) => {
                    let _ = ready_tx.send(Err(failure));
                    return;
                }
            };
            // Parked until stopped; every half second, looking at whether the
            // default input is still the one in use.
            let finished = AtomicBool::new(false);
            while !finished.load(Ordering::Relaxed) {
                match stop_rx.recv_timeout(Duration::from_millis(500)) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => finished.store(true, Ordering::Relaxed),
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        let default = cpal::default_host().default_input_device().and_then(|d| d.name().ok()).unwrap_or_default();
                        if default != current.1 {
                            // A headset connecting or leaving: capture again on the new
                            // input, keeping what was already heard.
                            drop(current.0);
                            match open(&worker_shared) {
                                Ok((stream, input, name)) => {
                                    current = (stream, name);
                                    worker_shared.sink.input_changed(Some(input));
                                }
                                Err(_) => {
                                    worker_shared.sink.input_changed(None);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        });
        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(input)) => {
                self.worker = Some((stop_tx, handle));
                self.shared = Some(shared);
                Ok(input)
            }
            Ok(Err(failure)) => {
                let _ = handle.join();
                Err(failure)
            }
            Err(_) => Err(DictationFailure::new(MICROPHONE_COULD_NOT_START)),
        }
    }

    fn stop(&mut self) -> Vec<f32> {
        if let Some((stop, handle)) = self.worker.take() {
            let _ = stop.send(());
            let _ = handle.join();
        }
        self.shared.take().map(|s| s.buffer.lock().unwrap().take()).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forty_eight_thousand_hertz_stereo_becomes_sixteen_thousand_mono() {
        let mut r = Resampler::new(48_000);
        let mut out = Vec::new();
        // One second of stereo: left 0.2, right 0.4 -> mono 0.3.
        let input: Vec<f32> = (0..48_000).flat_map(|_| [0.2, 0.4]).collect();
        r.push(&input, 2, &mut out);
        assert_eq!(out.len(), 16_000);
        assert!(out.iter().all(|s| (s - 0.3).abs() < 1e-5));
    }

    #[test]
    fn already_sixteen_thousand_mono_passes_unchanged() {
        let mut r = Resampler::new(16_000);
        let mut out = Vec::new();
        r.push(&[0.1, 0.2, 0.3], 1, &mut out);
        assert_eq!(out, [0.1, 0.2, 0.3]);
    }

    #[test]
    fn a_rate_that_does_not_divide_evenly_keeps_the_count_right() {
        let mut r = Resampler::new(44_100);
        let mut out = Vec::new();
        r.push(&vec![0.0; 44_100], 1, &mut out);
        assert!((out.len() as i64 - 16_000).abs() <= 1, "{}", out.len());
    }

    #[test]
    fn the_level_is_measured_a_tenth_of_a_second_at_a_time() {
        let mut meter = LevelMeter::new();
        // Buffers of 441 samples: nothing until 1,600 have arrived, then one level each 1,600.
        let mut levels = Vec::new();
        for _ in 0..8 {
            levels.extend(meter.push(&[0.1; 441]));
        }
        assert_eq!(levels.len(), 8 * 441 / LevelMeter::BLOCK);
        assert!(levels.iter().all(|l| (*l - level_of(&[0.1; 16])).abs() < 1e-6));
        // One big buffer completes several blocks at once.
        assert_eq!(LevelMeter::new().push(&[0.0; 4_000]).len(), 2);
        assert!(LevelMeter::new().push(&[0.5; 1_599]).is_empty());
    }

    #[test]
    fn it_does_not_ask_permission_where_nothing_is_asked() {
        let free = CpalMicrophone::with_privacy(Box::new(|| None));
        assert_eq!(free.permission(), MicrophonePermission::Authorized);
        let on = CpalMicrophone::with_privacy(Box::new(|| Some(false)));
        assert_eq!(on.permission(), MicrophonePermission::Authorized);
    }

    #[test]
    fn gnomes_microphone_switch_turned_off_is_refused() {
        let off = CpalMicrophone::with_privacy(Box::new(|| Some(true)));
        assert_eq!(off.permission(), MicrophonePermission::Denied);
    }

    #[test]
    fn what_gsettings_prints_is_read() {
        assert_eq!(parse_gsettings_bool("true\n"), Some(true));
        assert_eq!(parse_gsettings_bool("false\n"), Some(false));
        assert_eq!(parse_gsettings_bool("No such schema\n"), None);
        assert_eq!(parse_gsettings_bool(""), None);
    }
}
