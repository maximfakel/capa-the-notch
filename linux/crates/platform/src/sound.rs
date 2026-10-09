//! Playing the few sounds (ADR 0007). The core draws them (`SoundBank`) and
//! decides when they may play (`SoundPolicy`); this plays a buffer by handing a
//! WAV to PipeWire's or PulseAudio's own player.
//!
//! Nothing here runs while sounds are off: no player is looked for, no sound
//! drawn, no thread started.

use capa_core::prefs::Preferences;
use capa_core::sound::{SoundBank, SoundBuffer, SoundCue, SoundOut, SoundPolicy};
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The sounds as the hub uses them: the bank, where they are played, and the
/// rules for when. `play` is cheap to call from anywhere.
pub struct Sounds {
    bank: SoundBank,
    out: Arc<dyn SoundOut>,
    prefs: Arc<Preferences>,
    /// Something on the surface wants quiet: the Teleprompter running.
    quiet: AtomicBool,
    interface: Box<dyn Fn() -> bool + Send + Sync>,
    prepared: AtomicBool,
}

impl Sounds {
    pub fn new(prefs: Arc<Preferences>, out: Arc<dyn SoundOut>) -> Self {
        Self::with_interface_probe(prefs, out, Box::new(system_interface_sounds_on()))
    }

    pub fn with_interface_probe(
        prefs: Arc<Preferences>,
        out: Arc<dyn SoundOut>,
        interface: Box<dyn Fn() -> bool + Send + Sync>,
    ) -> Self {
        Self { bank: SoundBank::new(), out, prefs, quiet: AtomicBool::new(false), interface, prepared: AtomicBool::new(false) }
    }

    /// The player this machine has.
    pub fn system(prefs: Arc<Preferences>) -> Self {
        Self::new(prefs, Arc::new(system_out()))
    }

    pub fn set_quiet(&self, quiet: bool) {
        self.quiet.store(quiet, Ordering::Relaxed);
    }

    pub fn policy(&self) -> SoundPolicy {
        SoundPolicy {
            enabled: self.prefs.plays_sounds(),
            interface_sounds_on: (self.interface)(),
            quiet: self.quiet.load(Ordering::Relaxed),
        }
    }

    /// Plays the cue if the policy allows. Returns whether it did.
    pub fn play(&self, cue: SoundCue) -> bool {
        self.bank.play(cue, &self.policy(), self.out.as_ref())
    }

    /// Draws every sound ahead of the first that plays, off the calling
    /// thread, once — and only if sounds are on.
    pub fn prepare(self: &Arc<Self>) {
        if !self.prefs.plays_sounds() || self.prepared.swap(true, Ordering::SeqCst) {
            return;
        }
        let this = self.clone();
        std::thread::spawn(move || this.bank.prepare());
    }
}

/// Whether the system's own "play interface sound effects" is on. GNOME has the
/// same switch (Settings ▸ Sound ▸ System Sounds → `event-sounds`); where
/// there is none the answer is yes. Asked at most every few seconds.
fn system_interface_sounds_on() -> impl Fn() -> bool + Send + Sync {
    let cache: Mutex<Option<(Instant, bool)>> = Mutex::new(None);
    move || {
        let mut cache = cache.lock().unwrap();
        if let Some((at, value)) = *cache {
            if at.elapsed() < Duration::from_secs(5) {
                return value;
            }
        }
        let value = read_event_sounds();
        *cache = Some((Instant::now(), value));
        value
    }
}

#[cfg(target_os = "linux")]
fn read_event_sounds() -> bool {
    Command::new("gsettings")
        .args(["get", "org.gnome.desktop.sound", "event-sounds"])
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| parse_gsettings_bool(&String::from_utf8_lossy(&o.stdout)))
        .unwrap_or(true)
}

#[cfg(not(target_os = "linux"))]
fn read_event_sounds() -> bool {
    true
}

/// `true\n` or `false\n`; anything else reads as on.
pub fn parse_gsettings_bool(text: &str) -> bool {
    text.trim() != "false"
}

fn system_out() -> CommandOut {
    CommandOut::new(cache_dir(), find_player())
}

fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("capa-the-notch")
}

/// The first of PipeWire's, PulseAudio's and ALSA's players that is installed.
pub fn find_player() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    ["pw-play", "paplay", "aplay"]
        .into_iter()
        .find_map(|name| std::env::split_paths(&path).map(|d| d.join(name)).find(|p| p.is_file()))
}

/// Plays a cue by writing its WAV once to a file and handing the file to a
/// player program. A cue that is already sounding is stopped and started again,
/// as `NSSound.stop()` then `play()` does.
pub struct CommandOut {
    dir: PathBuf,
    player: Option<PathBuf>,
    sounding: Mutex<HashMap<SoundCue, Child>>,
}

impl CommandOut {
    pub fn new(dir: PathBuf, player: Option<PathBuf>) -> Self {
        Self { dir, player, sounding: Mutex::new(HashMap::new()) }
    }

    fn file_for(&self, cue: SoundCue, buffer: &SoundBuffer) -> Option<PathBuf> {
        let path = self.dir.join(format!("{}.wav", cue.recipe().name()));
        // Written once per recipe; rewritten if it is not what the synth drew.
        if std::fs::read(&path).ok().as_deref() != Some(buffer.wav.as_slice()) {
            std::fs::create_dir_all(&self.dir).ok()?;
            std::fs::write(&path, &buffer.wav).ok()?;
        }
        Some(path)
    }
}

impl SoundOut for CommandOut {
    fn play(&self, cue: SoundCue, buffer: &SoundBuffer) {
        let Some(player) = &self.player else { return };
        let Some(file) = self.file_for(cue, buffer) else { return };
        let mut sounding = self.sounding.lock().unwrap();
        if let Some(mut old) = sounding.remove(&cue) {
            let _ = old.kill();
            let _ = old.wait();
        }
        // Finished players are reaped on the way, so none is left a zombie.
        sounding.retain(|_, child| child.try_wait().map(|s| s.is_none()).unwrap_or(false));
        if let Ok(child) = Command::new(player).arg(&file).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
            sounding.insert(cue, child);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::prefs::MemoryStore;

    #[derive(Default)]
    struct Recording(Mutex<Vec<(SoundCue, Vec<i16>)>>);

    impl SoundOut for Recording {
        fn play(&self, cue: SoundCue, buffer: &SoundBuffer) {
            self.0.lock().unwrap().push((cue, buffer.pcm.clone()));
        }
    }

    fn sounds(on: bool, interface: bool) -> (Arc<Sounds>, Arc<Recording>, Arc<Preferences>) {
        let prefs = Arc::new(Preferences::new(Arc::new(MemoryStore::new())));
        prefs.set_plays_sounds(on);
        let out = Arc::new(Recording::default());
        let s = Sounds::with_interface_probe(prefs.clone(), out.clone(), Box::new(move || interface));
        (Arc::new(s), out, prefs)
    }

    #[test]
    fn what_is_played_is_what_the_synth_drew_for_every_cue() {
        let (s, out, _) = sounds(true, true);
        for cue in SoundCue::ALL {
            assert!(s.play(cue), "{cue:?}");
        }
        let played = out.0.lock().unwrap();
        assert_eq!(played.len(), SoundCue::ALL.len());
        for (cue, pcm) in played.iter() {
            assert_eq!(*pcm, SoundBuffer::render(&cue.patch()).pcm, "{cue:?}");
            assert!(!pcm.is_empty(), "{cue:?}");
        }
    }

    #[test]
    fn nothing_plays_while_off_while_the_system_is_quiet_or_while_the_teleprompter_runs() {
        let (s, out, prefs) = sounds(false, true);
        assert!(!s.play(SoundCue::CapacityAlert));
        prefs.set_plays_sounds(true);
        assert!(s.play(SoundCue::CapacityAlert));
        s.set_quiet(true);
        assert!(!s.play(SoundCue::CapacityAlert), "a Script being read aloud is on a call");
        s.set_quiet(false);
        assert_eq!(out.0.lock().unwrap().len(), 1);

        let (muted, out, _) = sounds(true, false);
        assert!(!muted.play(SoundCue::KapaTapped), "the system's own interface sounds are off");
        assert!(out.0.lock().unwrap().is_empty());
    }

    #[test]
    fn preparing_does_nothing_while_sounds_are_off() {
        let (s, _, _) = sounds(false, true);
        s.prepare();
        assert!(!s.prepared.load(Ordering::SeqCst));
    }

    #[test]
    fn the_command_player_writes_the_wav_the_synth_made_and_hands_it_over() {
        let dir = std::env::temp_dir().join(format!("capa-sound-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let out = CommandOut::new(dir.clone(), Some(PathBuf::from("/bin/true")));
        let buffer = SoundBuffer::render(&SoundCue::CapacityAlert.patch());
        out.play(SoundCue::CapacityAlert, &buffer);
        out.play(SoundCue::CapacityAlert, &buffer); // restarts, does not pile up
        let written = std::fs::read(dir.join("warning.wav")).unwrap();
        assert_eq!(written, buffer.wav);
        assert!(out.sounding.lock().unwrap().len() <= 1);
        // No player: silence, not a crash.
        CommandOut::new(dir, None).play(SoundCue::KapaTapped, &buffer);
    }

    #[test]
    fn the_systems_event_sounds_switch_reads_true_unless_it_says_false() {
        assert!(parse_gsettings_bool("true\n"));
        assert!(!parse_gsettings_bool("false\n"));
        assert!(parse_gsettings_bool("garbage"));
    }
}
