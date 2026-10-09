//! The Linux `AudioOutput`: the default sink's level and mute, through
//! PipeWire's `wpctl` (PulseAudio's `pactl` where there is no WirePlumber).
//! Both are on every Arch GNOME install that has sound; a machine with
//! neither has no speaker, and the page shows no bar.
//!
//! No command runs on the caller's thread: the model reads what was last
//! heard, writes go to a thread of their own, and the Module's lock is never
//! held across a process. It listens only while a bar is on screen (ADR 0003):
//! to `pactl subscribe` where there is one, else asking twice a second; and a
//! new default sink is a new device, which the model follows
//! (`SystemVolume.follow`, as the Swift does on `kAudioHardwarePropertyDefaultOutputDevice`).

use capa_core::music::AudioOutput;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Reading {
    pub level: f64,
    pub muted: bool,
}

/// `Volume: 0.58` or `Volume: 0.58 [MUTED]`.
pub fn parse_wpctl(output: &str) -> Option<Reading> {
    let line = output.lines().find(|l| l.trim_start().starts_with("Volume:"))?;
    let rest = line.trim_start().strip_prefix("Volume:")?.trim();
    let level: f64 = rest.split_whitespace().next()?.parse().ok()?;
    Some(Reading { level: level.clamp(0.0, 1.0), muted: rest.contains("[MUTED]") })
}

/// `pactl get-sink-volume` (`Volume: front-left: 38000 /  58% / ...`) and `get-sink-mute` (`Mute: yes`).
pub fn parse_pactl(volume: &str, mute: &str) -> Option<Reading> {
    let percent = volume.split('/').find_map(|part| part.trim().strip_suffix('%')?.trim().parse::<f64>().ok())?;
    let muted = mute.lines().find_map(|l| l.trim().strip_prefix("Mute:")).is_some_and(|v| v.trim() == "yes");
    Some(Reading { level: (percent / 100.0).clamp(0.0, 1.0), muted })
}

/// A `pactl subscribe` line that can change what the bar shows: the sinks
/// (level, mute) and the server (which sink is the default). Not the streams
/// (`sink-input`), which change all the time and say nothing of the output.
pub fn event_matters(line: &str) -> bool {
    line.contains(" on sink #") || line.contains(" on server")
}

fn run(program: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(program).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Tool {
    Wpctl,
    Pactl,
}

const SINK: &str = "@DEFAULT_AUDIO_SINK@";

fn read_with(tool: Tool) -> Option<Reading> {
    match tool {
        Tool::Wpctl => parse_wpctl(&run("wpctl", &["get-volume", SINK])?),
        Tool::Pactl => parse_pactl(&run("pactl", &["get-sink-volume", "@DEFAULT_SINK@"])?, &run("pactl", &["get-sink-mute", "@DEFAULT_SINK@"])?),
    }
}

/// Which sink is the default: its name, or WirePlumber's id for it.
fn default_sink() -> Option<String> {
    run("pactl", &["get-default-sink"])
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .or_else(|| run("wpctl", &["inspect", SINK]).and_then(|s| s.lines().next().map(|l| l.trim().to_owned())))
}

/// The tool that answers, and what it says.
fn detect_tool() -> (Option<Tool>, Option<Reading>) {
    for tool in [Tool::Wpctl, Tool::Pactl] {
        if let Some(reading) = read_with(tool) {
            return (Some(tool), Some(reading));
        }
    }
    (None, None)
}

/// What was last heard of the output; read by the model without running anything.
#[derive(Debug, Default)]
struct Heard {
    tool: Option<Tool>,
    reading: Option<Reading>,
    sink: Option<String>,
    /// The default sink changed since the model last asked.
    device_changed: bool,
}

enum Write {
    Level(f64),
    Muted(bool),
}

pub struct LinuxOutput {
    heard: Arc<Mutex<Heard>>,
    /// Called when the level, the mute or the device changed under a bar that is on screen.
    on_change: Arc<dyn Fn() + Send + Sync>,
    listening: Option<Listener>,
    writes: Option<Sender<Write>>,
}

struct Listener {
    alive: Arc<AtomicBool>,
    subscription: Arc<Mutex<Option<Child>>>,
}

impl LinuxOutput {
    /// Runs the tools to find which one answers: call it where no lock is held.
    pub fn detect(on_change: Arc<dyn Fn() + Send + Sync>) -> Self {
        let (tool, reading) = detect_tool();
        let sink = tool.and_then(|_| default_sink());
        Self::with_heard(Heard { tool, reading, sink, device_changed: false }, on_change)
    }

    fn with_heard(heard: Heard, on_change: Arc<dyn Fn() + Send + Sync>) -> Self {
        Self { heard: Arc::new(Mutex::new(heard)), on_change, listening: None, writes: None }
    }

    fn reading(&self) -> Option<Reading> {
        self.heard.lock().unwrap().reading
    }

    /// Sends a write to the writer thread, starting it the first time.
    fn send(&mut self, write: Write) {
        if self.heard.lock().unwrap().tool.is_none() {
            return;
        }
        let writes = self.writes.get_or_insert_with(|| {
            let (tx, rx) = channel::<Write>();
            let (heard, on_change) = (self.heard.clone(), self.on_change.clone());
            std::thread::spawn(move || {
                while let Ok(first) = rx.recv() {
                    // A drag sends many: only the last of each is written.
                    let (mut level, mut muted) = (None, None);
                    for write in std::iter::once(first).chain(rx.try_iter()) {
                        match write {
                            Write::Level(l) => level = Some(l),
                            Write::Muted(m) => muted = Some(m),
                        }
                    }
                    let tool = heard.lock().unwrap().tool;
                    if let Some(tool) = tool {
                        if let Some(m) = muted {
                            write_muted(tool, m);
                        }
                        if let Some(l) = level {
                            write_level(tool, l);
                        }
                    }
                    refresh(&heard, on_change.as_ref());
                }
            });
            tx
        });
        let _ = writes.send(write);
    }
}

fn write_level(tool: Tool, level: f64) {
    match tool {
        Tool::Wpctl => {
            let _ = run("wpctl", &["set-volume", SINK, &format!("{level:.3}")]);
        }
        Tool::Pactl => {
            let _ = run("pactl", &["set-sink-volume", "@DEFAULT_SINK@", &format!("{}%", (level * 100.0).round())]);
        }
    }
}

fn write_muted(tool: Tool, muted: bool) {
    let flag = if muted { "1" } else { "0" };
    match tool {
        Tool::Wpctl => {
            let _ = run("wpctl", &["set-mute", SINK, flag]);
        }
        Tool::Pactl => {
            let _ = run("pactl", &["set-sink-mute", "@DEFAULT_SINK@", flag]);
        }
    }
}

/// Asks the audio system again (no lock held while it answers), and says so
/// when anything differs. A new default sink is detected afresh.
fn refresh(heard: &Mutex<Heard>, on_change: &(dyn Fn() + Send + Sync)) {
    let (tool, known_sink) = {
        let h = heard.lock().unwrap();
        (h.tool, h.sink.clone())
    };
    let sink = default_sink();
    let new_device = sink != known_sink;
    let (tool, reading) = match tool {
        Some(tool) if !new_device => (Some(tool), read_with(tool)),
        _ => detect_tool(),
    };
    let changed = {
        let mut h = heard.lock().unwrap();
        let changed = new_device || h.tool != tool || h.reading != reading;
        h.tool = tool;
        h.reading = reading;
        h.sink = sink;
        h.device_changed |= new_device;
        changed
    };
    if changed {
        on_change();
    }
}

/// `pactl subscribe`, its lines told on `events`; `None` where it cannot run.
fn subscribe(events: Sender<()>, slot: &Mutex<Option<Child>>) -> Option<()> {
    let mut child = Command::new("pactl")
        .arg("subscribe")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    *slot.lock().unwrap() = Some(child);
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if event_matters(&line) && events.send(()).is_err() {
                break;
            }
        }
    });
    Some(())
}

impl AudioOutput for LinuxOutput {
    fn level_settable(&self) -> bool {
        self.heard.lock().unwrap().tool.is_some()
    }

    fn read_level(&self) -> f64 {
        self.reading().map_or(0.0, |r| r.level)
    }

    fn mute_settable(&self) -> bool {
        self.level_settable()
    }

    fn read_muted(&self) -> bool {
        self.reading().is_some_and(|r| r.muted)
    }

    /// Shown at once, written on the writer thread.
    fn write_level(&mut self, level: f64) {
        let level = level.clamp(0.0, 1.0);
        if let Some(r) = self.heard.lock().unwrap().reading.as_mut() {
            r.level = level;
        }
        self.send(Write::Level(level));
    }

    fn write_muted(&mut self, muted: bool) {
        if let Some(r) = self.heard.lock().unwrap().reading.as_mut() {
            r.muted = muted;
        }
        self.send(Write::Muted(muted));
    }

    fn start_listening(&mut self) {
        self.stop_listening();
        let alive = Arc::new(AtomicBool::new(true));
        let subscription = Arc::new(Mutex::new(None));
        self.listening = Some(Listener { alive: alive.clone(), subscription: subscription.clone() });
        let (heard, on_change) = (self.heard.clone(), self.on_change.clone());
        std::thread::spawn(move || {
            // What was heard may be old: the bar was not on screen.
            refresh(&heard, on_change.as_ref());
            let (tx, rx) = channel::<()>();
            let mut polling = subscribe(tx, &subscription).is_none();
            while alive.load(Ordering::Relaxed) {
                if polling {
                    std::thread::sleep(Duration::from_millis(500));
                    if alive.load(Ordering::Relaxed) {
                        refresh(&heard, on_change.as_ref());
                    }
                    continue;
                }
                match rx.recv_timeout(Duration::from_millis(500)) {
                    Ok(()) => {
                        // A burst (a drag, a device switch) is one look.
                        while rx.try_recv().is_ok() {}
                        if alive.load(Ordering::Relaxed) {
                            refresh(&heard, on_change.as_ref());
                        }
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    // `pactl subscribe` ended: ask twice a second from here on.
                    Err(RecvTimeoutError::Disconnected) => polling = true,
                }
            }
            if let Some(mut child) = subscription.lock().unwrap().take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        });
    }

    fn stop_listening(&mut self) {
        if let Some(listener) = self.listening.take() {
            listener.alive.store(false, Ordering::Relaxed);
            // Ends the subscription now; its thread reaps it.
            if let Some(child) = listener.subscription.lock().unwrap().as_mut() {
                let _ = child.kill();
            }
        }
    }

    fn take_device_changed(&mut self) -> bool {
        std::mem::take(&mut self.heard.lock().unwrap().device_changed)
    }
}

impl Drop for LinuxOutput {
    fn drop(&mut self) {
        self.stop_listening();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wpctl_says_the_level_and_whether_it_is_muted() {
        assert_eq!(parse_wpctl("Volume: 0.58\n"), Some(Reading { level: 0.58, muted: false }));
        assert_eq!(parse_wpctl("Volume: 0.30 [MUTED]\n"), Some(Reading { level: 0.30, muted: true }));
        assert_eq!(parse_wpctl("Volume: 1.20\n").unwrap().level, 1.0, "over-amplified is full");
        assert_eq!(parse_wpctl("Could not find node\n"), None);
        assert_eq!(parse_wpctl(""), None);
    }

    #[test]
    fn pactl_says_it_in_percent() {
        let volume = "Volume: front-left: 38000 /  58% / -14.74 dB,   front-right: 38000 /  58% / -14.74 dB\n        balance 0.00\n";
        assert_eq!(parse_pactl(volume, "Mute: no\n"), Some(Reading { level: 0.58, muted: false }));
        assert!(parse_pactl(volume, "Mute: yes\n").unwrap().muted);
        assert_eq!(parse_pactl("garbage", "Mute: no"), None);
    }

    #[test]
    fn only_sink_and_server_events_are_looked_at() {
        assert!(event_matters("Event 'change' on sink #52"));
        assert!(event_matters("Event 'change' on server #0"));
        assert!(!event_matters("Event 'change' on sink-input #108"));
        assert!(!event_matters("Event 'new' on client #9"));
        assert!(!event_matters("Event 'change' on source #53"));
    }

    #[test]
    fn without_either_tool_there_is_no_speaker() {
        let mut out = LinuxOutput::with_heard(Heard::default(), Arc::new(|| {}));
        assert!(!out.level_settable());
        assert_eq!(out.read_level(), 0.0);
        out.write_level(0.5);
        assert!(out.writes.is_none(), "nothing to write to, so no writer");
    }

    #[test]
    fn the_model_reads_what_was_heard_and_a_new_device_is_said_once() {
        let heard = Heard { tool: None, reading: Some(Reading { level: 0.4, muted: true }), sink: None, device_changed: true };
        let mut out = LinuxOutput::with_heard(heard, Arc::new(|| {}));
        assert_eq!((out.read_level(), out.read_muted()), (0.4, true));
        assert!(out.take_device_changed());
        assert!(!out.take_device_changed(), "once");
    }
}
