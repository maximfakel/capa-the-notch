//! The hub's one task for Dictation: events in, the state machine's effects
//! carried out on the platform. `DictationController` in Swift, without the
//! decisions — those are `capa_core::dictation::Dictation`'s, tested there.

use crate::bridge::{Bridge, Target};
use crate::download::{self, Failure};
use crate::view;
use capa_core::dictation::{
    Cue, Dictation, DictationFailure, Effect, LogEvent, Microphone, MicrophoneInput, MicrophoneSink, RecognitionError,
    Recogniser, SessionId, Settings, TextInserter, ClipboardWriter, GlobalHotKey, MicrophoneHelp, NO_SPEECH_RECORDED,
};
use capa_core::prefs::{KeyShortcut, Preferences};
use capa_core::sound::SoundCue;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

/// What recognition and the model download need that is not the machine's: given by the platform.
pub trait Downloader: Send + Sync {
    /// Whether the speech model, and whatever runs it, are on disk.
    fn is_ready(&self) -> bool;
    /// Fetches and installs what is missing, reporting a 0–1 fraction of the model's bytes.
    fn install(&self, reporter: &dyn download::Reporter, cancelled: &dyn Fn() -> bool) -> Result<(), Failure>;
}

/// Tells when the system is about to sleep (logind's `PrepareForSleep`).
/// Started once, when the Module is first on; `will_sleep` may be called from any thread.
pub trait SleepWatch: Send {
    fn start(self: Box<Self>, will_sleep: Box<dyn Fn() + Send + Sync>);
}

/// Everything the driver touches the machine through.
pub struct Platform {
    pub microphone: Box<dyn Microphone + Send>,
    pub recogniser: Arc<Mutex<Box<dyn Recogniser + Send>>>,
    pub inserter: Arc<Mutex<Box<dyn TextInserter + Send>>>,
    pub clipboard: Box<dyn ClipboardWriter + Send>,
    pub hotkey: Box<dyn GlobalHotKey + Send>,
    pub downloader: Arc<dyn Downloader>,
    /// What says the system is going to sleep; taken when it is started.
    pub sleep: Option<Box<dyn SleepWatch>>,
}

/// What the driver needs from the hub.
#[derive(Clone)]
pub struct Context {
    pub prefs: Arc<Preferences>,
    pub clock: Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>,
    pub notify: Arc<dyn Fn() + Send + Sync>,
    pub sound: Arc<dyn Fn(SoundCue) + Send + Sync>,
}

pub enum Event {
    /// A command from a surface or a host; the answer goes back on `reply`.
    Command { method: String, args: Value, reply: oneshot::Sender<Result<Value, String>> },
    Level(SessionId, f32),
    LimitReached(SessionId),
    InputChanged(Option<MicrophoneInput>),
    ClockTick(SessionId, u32),
    Recognised { id: SessionId, samples: usize, result: Result<String, RecognitionError> },
    Delivered(Option<String>),
    Dismiss(u64),
    DownloadProgress(f64),
    DownloadAnswered(u16, u64),
    DownloadDone(Result<(), Failure>),
    /// The model has not been used for a while: let it go.
    Unload(u64),
    /// A preference was changed elsewhere.
    Resync,
    /// The system is going to sleep: nothing held survives it.
    SystemWillSleep,
}

struct Sink {
    id: SessionId,
    tx: mpsc::UnboundedSender<Event>,
}

impl MicrophoneSink for Sink {
    fn level(&self, level: f32) {
        let _ = self.tx.send(Event::Level(self.id, level));
    }
    fn limit_reached(&self) {
        let _ = self.tx.send(Event::LimitReached(self.id));
    }
    fn input_changed(&self, input: Option<MicrophoneInput>) {
        let _ = self.tx.send(Event::InputChanged(input));
    }
}

struct DownloadReporter {
    tx: mpsc::UnboundedSender<Event>,
}

impl download::Reporter for DownloadReporter {
    fn progress(&self, fraction: f64) {
        let _ = self.tx.send(Event::DownloadProgress(fraction));
    }
    fn answered(&self, status: u16, bytes: u64) {
        let _ = self.tx.send(Event::DownloadAnswered(status, bytes));
    }
}

/// How the log reads: codes and counts, never what was said.
const LOG_LINES: usize = 100;

pub struct Driver {
    machine: Dictation,
    platform: Platform,
    bridge: Bridge,
    ctx: Context,
    tx: mpsc::UnboundedSender<Event>,
    published: Arc<Mutex<Value>>,
    cancel_recognition: Arc<AtomicBool>,
    cancel_warm_up: Arc<AtomicBool>,
    cancel_download: Arc<AtomicBool>,
    clock: Option<JoinHandle<()>>,
    dismiss: Option<JoinHandle<()>>,
    unload: Option<(u64, JoinHandle<()>)>,
    unload_serial: u64,
    log: VecDeque<String>,
    last_publish: Option<std::time::Instant>,
}

impl Driver {
    pub fn new(
        platform: Platform,
        bridge: Bridge,
        ctx: Context,
        tx: mpsc::UnboundedSender<Event>,
        published: Arc<Mutex<Value>>,
    ) -> Self {
        let prefs = &ctx.prefs;
        let settings = Settings {
            enabled: prefs.dictation_enabled(),
            keeps_history: prefs.dictation_keeps_history(),
            replacements: prefs.dictation_replacements(),
            history: prefs.dictation_history(),
            shortcut: prefs.dictation_shortcut(),
            model_ready: platform.downloader.is_ready(),
            microphone: platform.microphone.permission(),
            microphone_entitled: true,
            insertion_allowed: bridge.insertion_allowed_now(),
            help: MicrophoneHelp::Linux,
            registers_shortcuts: true,
        };
        Self {
            machine: Dictation::new(settings),
            platform,
            bridge,
            ctx,
            tx,
            published,
            cancel_recognition: Arc::new(AtomicBool::new(false)),
            cancel_warm_up: Arc::new(AtomicBool::new(false)),
            cancel_download: Arc::new(AtomicBool::new(false)),
            clock: None,
            dismiss: None,
            unload: None,
            unload_serial: 0,
            log: VecDeque::new(),
            last_publish: None,
        }
    }

    /// What a bug report and the log say about Dictation now.
    pub fn observation(&self) -> capa_core::dictation::DictationObservation {
        self.machine.observation()
    }

    /// Runs until every sender is gone. Nothing runs before the module is on:
    /// the machine registers the shortcut only when it is enabled.
    pub async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Event>) {
        if self.machine.is_enabled() {
            let effects = self.machine.set_enabled(true);
            self.execute(effects);
        }
        self.watch_sleep();
        self.publish(true);
        while let Some(event) = rx.recv().await {
            self.handle(event);
            self.watch_sleep();
        }
        // Gone: nothing is left running.
        self.stop_everything();
    }

    /// Listens for the system going to sleep, from the first time the Module is on.
    fn watch_sleep(&mut self) {
        if !self.machine.is_enabled() {
            return;
        }
        if let Some(watch) = self.platform.sleep.take() {
            let tx = self.tx.clone();
            watch.start(Box::new(move || {
                let _ = tx.send(Event::SystemWillSleep);
            }));
        }
    }

    fn stop_everything(&mut self) {
        let effects = self.machine.set_enabled(false);
        self.execute(effects);
    }

    fn now(&self) -> DateTime<Utc> {
        (self.ctx.clock)()
    }

    fn handle(&mut self, event: Event) {
        let mut effects = Vec::new();
        let mut force = true;
        let mut reply = None;
        match event {
            Event::Command { method, args, reply: to } => {
                let answer = self.command(&method, args, &mut effects);
                reply = Some((to, answer));
            }
            Event::Level(id, level) => {
                self.machine.level_changed(id, level);
                force = false;
            }
            Event::LimitReached(id) => effects = self.machine.recording_limit_reached(id),
            Event::InputChanged(input) => effects = self.machine.microphone_input_changed(input),
            Event::ClockTick(id, elapsed) => effects = self.machine.clock_tick(id, elapsed),
            Event::Recognised { id, samples, result } => {
                let now = self.now();
                effects = self.machine.recognition_finished(id, samples, result, now);
                self.schedule_unload();
            }
            Event::Delivered(message) => {
                let now = self.now();
                effects = self.machine.delivery_finished(message, now);
            }
            Event::Dismiss(token) => effects = self.machine.dismiss_elapsed(token),
            Event::DownloadProgress(fraction) => {
                effects = self.machine.download_progress_changed(fraction);
                force = false;
            }
            Event::DownloadAnswered(status, bytes) => effects = self.machine.download_answered(status, bytes),
            Event::DownloadDone(result) => {
                effects = match result {
                    Ok(()) => {
                        self.machine.set_model_ready(true);
                        self.machine.download_installed()
                    }
                    Err(Failure::Cancelled) => self.machine.download_cancelled(),
                    Err(Failure::Download) => self.machine.download_failed(false),
                    Err(Failure::Install) => self.machine.download_failed(true),
                };
            }
            Event::Unload(serial) => {
                if self.unload.as_ref().is_some_and(|(s, _)| *s == serial) {
                    self.unload = None;
                    effects = vec![Effect::UnloadRecogniser];
                }
            }
            Event::Resync => effects = self.resync(),
            Event::SystemWillSleep => {
                effects = self.machine.system_will_sleep();
                // The host stops listening for a release that is not coming.
                self.bridge.end_hold();
            }
        }
        self.execute(effects);
        self.publish(force);
        // The answer is the state after what the command set going, not before.
        if let Some((to, answer)) = reply {
            let _ = to.send(answer.map(|()| view::state_json(&self.machine, &self.bridge, &self.platform, &self.log)));
        }
    }

    /// Reads the preferences again after another part of the application changed one.
    fn resync(&mut self) -> Vec<Effect> {
        let prefs = self.ctx.prefs.clone();
        let mut effects = Vec::new();
        if prefs.dictation_enabled() != self.machine.is_enabled() {
            effects.extend(self.machine.set_enabled(prefs.dictation_enabled()));
        }
        if prefs.dictation_keeps_history() != self.machine.keeps_history() {
            effects.extend(self.machine.set_keeps_history(prefs.dictation_keeps_history()));
        }
        if prefs.dictation_replacements() != self.machine.replacements() {
            effects.extend(self.machine.set_replacements(prefs.dictation_replacements()));
        }
        if &prefs.dictation_shortcut() != self.machine.shortcut() {
            effects.extend(self.machine.set_shortcut(prefs.dictation_shortcut()));
        }
        // Settings clears the history, or deletes from it, through the
        // preferences: what it removed must not come back with the next
        // dictation, which would write the old copy back.
        let history = prefs.dictation_history();
        if &history != self.machine.history() {
            self.machine.set_history(history);
        }
        effects
    }

    // MARK: - Commands

    fn command(&mut self, method: &str, args: Value, effects: &mut Vec<Effect>) -> Result<(), String> {
        let flag = |key: &str| args.get(key).and_then(Value::as_bool);
        match method {
            // A host: the shortcut.
            "host_ready" => {
                self.bridge.host_ready(args.get("insert").and_then(Value::as_bool).unwrap_or(false));
                self.machine.set_permissions(self.platform.microphone.permission(), self.bridge.insertion_allowed_now());
                // The host that has just connected is told what to grab.
                let (shortcut, escape) = self.bridge.registration();
                if shortcut.is_some() || escape {
                    let _ = self.platform.hotkey.register(shortcut.as_ref());
                    self.platform.hotkey.capture_escape(escape);
                }
            }
            "hotkey_pressed" => {
                let target: Option<Target> = args.get("target").and_then(|t| serde_json::from_value(t.clone()).ok());
                self.bridge.set_target(target);
                self.machine.set_permissions(self.platform.microphone.permission(), self.bridge.insertion_allowed_now());
                self.machine.set_model_ready(self.platform.downloader.is_ready());
                *effects = self.machine.key_pressed();
            }
            "hotkey_released" => *effects = self.machine.key_released(),
            "escape_pressed" => *effects = self.machine.escape_pressed(),
            "shortcut_registered" => self.machine.shortcut_registered(flag("ok").unwrap_or(true)),
            "inserted" => {
                let token = args.get("token").and_then(Value::as_u64).ok_or("no token")?;
                let message = args.get("message").and_then(Value::as_str).map(str::to_owned);
                self.bridge.inserted(token, message);
            }
            // Settings and the capsule.
            "set_enabled" => *effects = self.machine.set_enabled(flag("enabled").ok_or("no `enabled`")?),
            "set_keeps_history" => *effects = self.machine.set_keeps_history(flag("keeps").ok_or("no `keeps`")?),
            "set_shortcut" => {
                let shortcut: KeyShortcut =
                    serde_json::from_value(args.get("shortcut").cloned().ok_or("no shortcut")?).map_err(|e| e.to_string())?;
                *effects = self.machine.set_shortcut(shortcut);
            }
            "suspend_shortcut" => *effects = self.machine.suspend_shortcut(flag("suspend").ok_or("no `suspend`")?),
            "set_replacements" => {
                let rules = serde_json::from_value(args.get("replacements").cloned().ok_or("no replacements")?)
                    .map_err(|e| e.to_string())?;
                *effects = self.machine.set_replacements(rules);
            }
            "delete_history_entry" => {
                *effects = self.machine.delete_history_entry(args.get("id").and_then(Value::as_u64).ok_or("no id")?);
            }
            "clear_history" => *effects = self.machine.clear_history(),
            "copy_history_entry" => {
                let id = args.get("id").and_then(Value::as_u64).ok_or("no id")?;
                if let Some(entry) = self.machine.history().entries().iter().find(|e| e.id == id) {
                    let text = entry.text.clone();
                    *effects = vec![Effect::CopyToClipboard(text)];
                }
            }
            // Nothing is asked of the system for the microphone: Linux has no
            // question to answer. A microphone GNOME has switched off is read
            // again, and if it is still off its switch is shown, as the Swift
            // opens System Settings for a refused microphone.
            "request_microphone" => {
                self.machine.set_permissions(self.platform.microphone.permission(), self.bridge.insertion_allowed_now());
                if self.machine.is_enabled() && self.machine.model_ready() && !self.machine.microphone_allowed() {
                    self.platform.microphone.open_privacy_settings();
                }
            }
            // Nor for inserting text: a host that can paste says so when it connects.
            "request_insertion" => (self.ctx.notify)(),
            // Show the model where it is kept, in the file manager.
            "reveal_model" => {
                let folder = capa_core::dictation::model::directory(&crate::data_directory());
                crate::open_in_file_manager(&folder);
            }
            "start_download" => *effects = self.machine.start_download(),
            "cancel_download" => *effects = self.machine.cancel_download(),
            // The capsule: Escape-less dismissal by a tap on Dismiss, and the open-settings request.
            "dismiss" => *effects = self.machine.cancel(),
            "open_settings" => (self.ctx.notify)(),
            "state" => {}
            other => return Err(format!("dictation has no command {other}")),
        }
        Ok(())
    }

    // MARK: - Effects

    fn execute(&mut self, effects: Vec<Effect>) {
        let mut queue: VecDeque<Effect> = effects.into();
        while let Some(effect) = queue.pop_front() {
            match effect {
                Effect::CaptureTarget => {
                    let captured = self.platform.inserter.lock().unwrap().capture();
                    self.machine.target_captured(captured);
                }
                Effect::StartMicrophone(id) => {
                    match self.platform.microphone.start(Box::new(Sink { id, tx: self.tx.clone() })) {
                        Ok(input) => {
                            queue.extend(self.machine.microphone_started(id, input));
                            self.warm_up();
                        }
                        Err(_) => queue.extend(self.machine.microphone_failed(id)),
                    }
                }
                Effect::StartClock(id) => {
                    self.abort(Slot::Clock);
                    let tx = self.tx.clone();
                    self.clock = Some(tokio::spawn(async move {
                        let mut elapsed = 0;
                        let mut tick = tokio::time::interval(Duration::from_secs(1));
                        tick.tick().await;
                        loop {
                            tick.tick().await;
                            elapsed += 1;
                            if tx.send(Event::ClockTick(id, elapsed)).is_err() {
                                return;
                            }
                        }
                    }));
                }
                Effect::StopClock => self.abort(Slot::Clock),
                Effect::StopAndRecognise(id) => {
                    let samples = self.platform.microphone.stop();
                    queue.extend(self.machine.recording_stopped(samples.len()));
                    if samples.is_empty() {
                        // A quick tap heard nothing: said at once, as the Swift
                        // engine says it before loading the model, and not after
                        // the warm-up has let the recogniser go.
                        let result = Err(RecognitionError::Dictation(DictationFailure::new(NO_SPEECH_RECORDED)));
                        let _ = self.tx.send(Event::Recognised { id, samples: 0, result });
                        continue;
                    }
                    self.cancel_recognition.store(false, Ordering::SeqCst);
                    self.cancel_unload();
                    let (recogniser, cancelled, tx) =
                        (self.platform.recogniser.clone(), self.cancel_recognition.clone(), self.tx.clone());
                    tokio::task::spawn_blocking(move || {
                        let count = samples.len();
                        let result = recogniser.lock().unwrap().recognise(&samples, &|| cancelled.load(Ordering::SeqCst));
                        let _ = tx.send(Event::Recognised { id, samples: count, result });
                    });
                }
                Effect::CancelRecognition => {
                    self.cancel_recognition.store(true, Ordering::SeqCst);
                    self.cancel_warm_up.store(true, Ordering::SeqCst);
                }
                Effect::StopMicrophone => {
                    let _ = self.platform.microphone.stop();
                }
                Effect::CopyToClipboard(text) => self.platform.clipboard.copy(&text),
                Effect::Deliver(text) => {
                    let (inserter, tx) = (self.platform.inserter.clone(), self.tx.clone());
                    tokio::task::spawn_blocking(move || {
                        let message = inserter.lock().unwrap().insert(&text);
                        let _ = tx.send(Event::Delivered(message));
                    });
                }
                Effect::CaptureEscape(active) => self.platform.hotkey.capture_escape(active),
                Effect::RegisterShortcut(shortcut) => {
                    let ok = self.platform.hotkey.register(shortcut.as_ref());
                    if shortcut.is_some() {
                        self.machine.shortcut_registered(ok);
                    }
                }
                Effect::ScheduleDismiss { token, after } => {
                    self.abort(Slot::Dismiss);
                    let tx = self.tx.clone();
                    self.dismiss = Some(tokio::spawn(async move {
                        tokio::time::sleep(after).await;
                        let _ = tx.send(Event::Dismiss(token));
                    }));
                }
                Effect::CancelDismiss => self.abort(Slot::Dismiss),
                Effect::PlaySound(cue) => (self.ctx.sound)(match cue {
                    Cue::DictationModelReady => SoundCue::DictationModelReady,
                    Cue::DictationInserted => SoundCue::DictationInserted,
                    Cue::DictationCopied => SoundCue::DictationCopied,
                    Cue::DictationFailed => SoundCue::DictationFailed,
                }),
                Effect::Log(event) => self.note(&event),
                Effect::PersistEnabled(on) => self.ctx.prefs.set_dictation_enabled(on),
                Effect::PersistShortcut => self.ctx.prefs.set_dictation_shortcut(self.machine.shortcut()),
                Effect::PersistHistory => self.ctx.prefs.set_dictation_history(self.machine.history()),
                Effect::PersistReplacements => self.ctx.prefs.set_dictation_replacements(self.machine.replacements()),
                Effect::PersistKeepsHistory => self.ctx.prefs.set_dictation_keeps_history(self.machine.keeps_history()),
                Effect::StartDownload => {
                    self.cancel_download.store(false, Ordering::SeqCst);
                    let (downloader, cancelled, tx) =
                        (self.platform.downloader.clone(), self.cancel_download.clone(), self.tx.clone());
                    tokio::task::spawn_blocking(move || {
                        let reporter = DownloadReporter { tx: tx.clone() };
                        let result = downloader.install(&reporter, &|| cancelled.load(Ordering::SeqCst));
                        let _ = tx.send(Event::DownloadDone(result));
                    });
                }
                Effect::CancelDownload => self.cancel_download.store(true, Ordering::SeqCst),
                Effect::UnloadRecogniser => {
                    self.cancel_unload();
                    self.cancel_warm_up.store(true, Ordering::SeqCst);
                    self.platform.recogniser.lock().unwrap().unload();
                }
            }
        }
    }

    fn abort(&mut self, slot: Slot) {
        let handle = match slot {
            Slot::Clock => self.clock.take(),
            Slot::Dismiss => self.dismiss.take(),
        };
        if let Some(handle) = handle {
            handle.abort();
        }
    }

    /// Loading the model takes seconds (about thirteen on a laptop CPU, the
    /// first time), and speaking takes about as long: so it loads while the
    /// person speaks, by recognising a tenth of a second of silence, and is
    /// ready by the time the key is let go. If nothing follows, it is let go
    /// after the usual five minutes. A session cancelled, or the Module
    /// switched off, stops it where it can stop.
    fn warm_up(&mut self) {
        self.cancel_warm_up.store(false, Ordering::SeqCst);
        let (recogniser, cancelled) = (self.platform.recogniser.clone(), self.cancel_warm_up.clone());
        tokio::task::spawn_blocking(move || {
            if cancelled.load(Ordering::SeqCst) {
                return;
            }
            let _ = recogniser.lock().unwrap().recognise(&[0.0; 1_600], &|| cancelled.load(Ordering::SeqCst));
        });
        self.schedule_unload();
    }

    /// The model is let go five minutes after its last use.
    fn schedule_unload(&mut self) {
        self.cancel_unload();
        self.unload_serial += 1;
        let (serial, tx) = (self.unload_serial, self.tx.clone());
        let handle = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(capa_core::dictation::model::engine::UNLOAD_AFTER_SECONDS)).await;
            let _ = tx.send(Event::Unload(serial));
        });
        self.unload = Some((serial, handle));
    }

    fn cancel_unload(&mut self) {
        if let Some((_, handle)) = self.unload.take() {
            handle.abort();
        }
    }

    fn note(&mut self, event: &LogEvent) {
        if self.log.len() == LOG_LINES {
            self.log.pop_front();
        }
        self.log.push_back(view::log_line(event));
    }

    /// Hands the state to the module, and tells the hub. Level changes are
    /// throttled to about thirty a second; everything else goes at once.
    fn publish(&mut self, force: bool) {
        let now = std::time::Instant::now();
        if !force && self.last_publish.is_some_and(|t| now.duration_since(t) < Duration::from_millis(33)) {
            return;
        }
        self.last_publish = Some(now);
        *self.published.lock().unwrap() = view::state_json(&self.machine, &self.bridge, &self.platform, &self.log);
        (self.ctx.notify)();
    }
}

enum Slot {
    Clock,
    Dismiss,
}

