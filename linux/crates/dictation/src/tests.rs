//! The whole flow with fakes for the machine: key down, record, recognise,
//! deliver — and every way it ends.

use crate::bridge::{Bridge, HostHotKey};
use crate::download::{Failure, Reporter};
use crate::driver::{Downloader, Platform, SleepWatch};
use crate::with_platform;
use capa_core::dictation::{
    DictationFailure, Microphone, MicrophoneInput, MicrophonePermission, MicrophoneSink, RecognitionError, Recogniser,
    MICROPHONE_COULD_NOT_START, MICROPHONE_REQUIRED_LINUX, MODEL_MISSING, NO_EXTERNAL_APPLICATION, NO_SPEECH_RECORDED,
};
use capa_core::module::{ModuleContext, SurfaceModule};
use capa_core::prefs::{MemoryStore, Preferences};
use capa_core::sound::SoundCue;
use chrono::Utc;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

struct Mic {
    started: Arc<AtomicUsize>,
    fails: bool,
    sink: Arc<Mutex<Option<Box<dyn MicrophoneSink>>>>,
    samples: Vec<f32>,
    permission: MicrophonePermission,
    settings_opened: Arc<AtomicUsize>,
}

impl Microphone for Mic {
    fn permission(&self) -> MicrophonePermission {
        self.permission
    }
    fn request_permission(&mut self) {}
    fn open_privacy_settings(&mut self) {
        self.settings_opened.fetch_add(1, Ordering::SeqCst);
    }
    fn start(&mut self, sink: Box<dyn MicrophoneSink>) -> Result<MicrophoneInput, DictationFailure> {
        self.started.fetch_add(1, Ordering::SeqCst);
        if self.fails {
            return Err(DictationFailure::new(MICROPHONE_COULD_NOT_START));
        }
        sink.level(0.7);
        *self.sink.lock().unwrap() = Some(sink);
        Ok(MicrophoneInput { sample_rate: 16_000, channels: 1 })
    }
    /// What one recording heard: the samples, each time a started recording stops.
    fn stop(&mut self) -> Vec<f32> {
        if self.sink.lock().unwrap().take().is_some() { self.samples.clone() } else { Vec::new() }
    }
}

struct Said(Result<String, RecognitionError>);

impl Recogniser for Said {
    fn recognise(&mut self, samples: &[f32], _cancelled: &dyn Fn() -> bool) -> Result<String, RecognitionError> {
        assert!(!samples.is_empty());
        self.0.clone()
    }
    fn unload(&mut self) {}
}

/// A model that takes its time to load: the first call (the warm-up) holds
/// the recogniser until it is cancelled or `load` has passed.
struct Slow {
    load: Duration,
    loaded: bool,
    warm_up_cancelled: Arc<AtomicBool>,
}

impl Recogniser for Slow {
    fn recognise(&mut self, samples: &[f32], cancelled: &dyn Fn() -> bool) -> Result<String, RecognitionError> {
        if !self.loaded {
            let start = std::time::Instant::now();
            while start.elapsed() < self.load {
                if cancelled() {
                    self.warm_up_cancelled.store(true, Ordering::SeqCst);
                    return Err(RecognitionError::Other("cancelled".into()));
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            self.loaded = true;
        }
        assert!(!samples.is_empty(), "nothing is recognised from no audio");
        Ok("медленно".into())
    }
    fn unload(&mut self) {}
}

/// Says the system is going to sleep when the test does.
#[derive(Clone, Default)]
struct Sleep(Arc<Mutex<Option<WillSleep>>>);

type WillSleep = Box<dyn Fn() + Send + Sync>;

impl SleepWatch for Sleep {
    fn start(self: Box<Self>, will_sleep: Box<dyn Fn() + Send + Sync>) {
        *self.0.lock().unwrap() = Some(will_sleep);
    }
}

impl Sleep {
    fn now(&self) {
        (self.0.lock().unwrap().as_ref().expect("listening for sleep"))();
    }
    fn is_listening(&self) -> bool {
        self.0.lock().unwrap().is_some()
    }
}

struct Model {
    ready: AtomicBool,
    fail: Mutex<Option<Failure>>,
}

impl Downloader for Model {
    fn is_ready(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
    }
    fn install(&self, reporter: &dyn Reporter, _cancelled: &dyn Fn() -> bool) -> Result<(), Failure> {
        reporter.answered(200, 170_000_000);
        reporter.progress(0.5);
        if let Some(failure) = self.fail.lock().unwrap().take() {
            return Err(failure);
        }
        reporter.progress(1.0);
        self.ready.store(true, Ordering::SeqCst);
        Ok(())
    }
}

struct Rig {
    module: Arc<dyn SurfaceModule>,
    events: mpsc::Receiver<(String, String, Value)>,
    sounds: Arc<Mutex<Vec<SoundCue>>>,
    mic_started: Arc<AtomicUsize>,
    prefs: Arc<Preferences>,
    sleep: Sleep,
    settings_opened: Arc<AtomicUsize>,
}

struct Options {
    enabled: bool,
    model_ready: bool,
    mic_fails: bool,
    heard: Result<String, RecognitionError>,
    /// What one recording hears.
    samples: Vec<f32>,
    permission: MicrophonePermission,
    /// A recogniser of its own in place of one that says `heard`.
    recogniser: Option<Box<dyn Recogniser + Send>>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            enabled: true,
            model_ready: true,
            mic_fails: false,
            heard: Ok("привет мир".into()),
            samples: vec![0.1; 16_000],
            permission: MicrophonePermission::Authorized,
            recogniser: None,
        }
    }
}

fn rig(options: Options) -> Rig {
    let prefs = Arc::new(Preferences::new(Arc::new(MemoryStore::new())));
    prefs.set_dictation_enabled(options.enabled);
    let (tx, events) = mpsc::channel();
    let sounds = Arc::new(Mutex::new(Vec::new()));
    let sound_log = sounds.clone();
    let context = ModuleContext {
        prefs: prefs.clone(),
        clock: Arc::new(Utc::now),
        prefs_changed: Arc::new(|| {}),
        notify: Arc::new(|| {}),
        emit: Arc::new(move |module, name, data| {
            let _ = tx.send((module.to_owned(), name.to_owned(), data));
        }),
        sound: Arc::new(move |cue| sound_log.lock().unwrap().push(cue)),
    };
    let emit_context = context.clone();
    let bridge = Bridge::new(Arc::new(move |name, data| (emit_context.emit)("dictation", name, data)));
    let mic_started = Arc::new(AtomicUsize::new(0));
    let settings_opened = Arc::new(AtomicUsize::new(0));
    let sleep = Sleep::default();
    let platform = Platform {
        microphone: Box::new(Mic {
            started: mic_started.clone(),
            fails: options.mic_fails,
            sink: Default::default(),
            samples: options.samples,
            permission: options.permission,
            settings_opened: settings_opened.clone(),
        }),
        recogniser: Arc::new(Mutex::new(options.recogniser.unwrap_or_else(|| Box::new(Said(options.heard))))),
        inserter: Arc::new(Mutex::new(Box::new(bridge.clone()))),
        clipboard: Box::new(bridge.clone()),
        hotkey: Box::new(HostHotKey::new(bridge.clone())),
        downloader: Arc::new(Model { ready: AtomicBool::new(options.model_ready), fail: Mutex::new(None) }),
        sleep: Some(Box::new(sleep.clone())),
    };
    Rig { module: with_platform(context, platform, bridge), events, sounds, mic_started, prefs, sleep, settings_opened }
}

impl Rig {
    async fn call(&self, method: &str, args: Value) -> Value {
        self.module.call(method, args).await.expect(method)
    }

    /// Polls the published state until `done` says so.
    async fn until(&self, what: &str, done: impl Fn(&Value) -> bool) -> Value {
        for _ in 0..400 {
            let state = self.call("state", Value::Null).await;
            if done(&state) {
                return state;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("never: {what}; state: {}", self.module.state());
    }

    fn drain(&self) -> Vec<(String, Value)> {
        let mut out = Vec::new();
        while let Ok((module, name, data)) = self.events.try_recv() {
            assert_eq!(module, "dictation");
            out.push((name, data));
        }
        out
    }

    /// A host that can paste: it answers each `insert` with `message`.
    async fn answer_insert(&self, message: Option<&str>) -> Value {
        for _ in 0..400 {
            let events = self.drain();
            if let Some((_, data)) = events.iter().find(|(n, _)| n == "insert") {
                self.call("inserted", json!({"token": data["token"], "message": message})).await;
                return data.clone();
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("no insert was asked for");
    }
}

fn editor() -> Value {
    json!({"target": {"app": "editor", "window": "42", "secure": false, "own": false}})
}

#[tokio::test]
async fn a_held_key_records_a_release_recognises_and_the_text_goes_in() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;

    let state = r.call("hotkey_pressed", editor()).await;
    assert_eq!(state["presentation"], "recording");
    assert_eq!(state["orb"]["state"], "listening");
    assert_eq!(state["kapa"], "listening");
    let state = r.until("a level", |s| s["level"].as_f64().unwrap_or(0.0) > 0.5).await;
    assert!(state["level"].as_f64().unwrap() > 0.5);

    r.call("hotkey_released", Value::Null).await;
    let sent = r.answer_insert(None).await;
    assert_eq!(sent["text"], "привет мир");
    assert_eq!(sent["target"]["window"], "42", "the window in front when recording began");

    let state = r.until("inserted", |s| s["presentation"] == "inserted").await;
    assert_eq!(state["orb"]["tone"], json!([52.0 / 255.0, 199.0 / 255.0, 89.0 / 255.0]));
    assert_eq!(*r.sounds.lock().unwrap(), [SoundCue::DictationInserted]);
    // After 1.4 s the capsule is gone.
    r.until("hidden again", |s| s["presentation"] == "hidden").await;
    assert_eq!(state["history"], json!([]), "history is off unless turned on");
}

#[tokio::test]
async fn it_copies_before_it_pastes_and_says_what_it_copied() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;
    r.call("hotkey_pressed", editor()).await;
    r.call("hotkey_released", Value::Null).await;
    // `copy` then `insert`, in that order, with the same text.
    let mut names = Vec::new();
    for _ in 0..400 {
        names.extend(r.drain());
        if names.iter().any(|(n, _)| n == "insert") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let order: Vec<&str> = names.iter().map(|(n, _)| n.as_str()).filter(|n| *n == "copy" || *n == "insert").collect();
    assert_eq!(order, ["copy", "insert"]);
    let copy = names.iter().find(|(n, _)| n == "copy").unwrap();
    assert_eq!(copy.1["text"], "привет мир");
}

#[tokio::test]
async fn with_no_application_in_front_the_text_waits_on_the_clipboard_and_the_capsule_says_why() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;
    r.call("hotkey_pressed", json!({"target": null})).await;
    r.call("hotkey_released", Value::Null).await;
    let state = r.until("copied", |s| s["presentation"] == "copied").await;
    assert_eq!(state["deliveryMessage"], NO_EXTERNAL_APPLICATION);
    assert_eq!(state["details"]["title"], "Text copied, not inserted");
    assert_eq!(state["details"]["body"], NO_EXTERNAL_APPLICATION);
    assert_eq!(*r.sounds.lock().unwrap(), [SoundCue::DictationCopied]);
    assert!(r.drain().iter().any(|(n, d)| n == "copy" && d["text"] == "привет мир"));
}

#[tokio::test]
async fn a_password_field_is_never_a_target() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;
    r.call("hotkey_pressed", json!({"target": {"app": "browser", "window": "1", "secure": true}})).await;
    r.call("hotkey_released", Value::Null).await;
    let state = r.until("copied", |s| s["presentation"] == "copied").await;
    assert_eq!(state["deliveryMessage"], NO_EXTERNAL_APPLICATION);
    assert!(!r.drain().iter().any(|(n, _)| n == "insert"), "nothing is pasted into it");
}

#[tokio::test]
async fn a_host_that_cannot_paste_leaves_the_text_on_the_clipboard() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": false})).await;
    r.call("hotkey_pressed", editor()).await;
    r.call("hotkey_released", Value::Null).await;
    let state = r.until("copied", |s| s["presentation"] == "copied").await;
    assert_eq!(state["insertionAllowed"], false);
    assert!(state["deliveryMessage"].as_str().unwrap().contains("still in the clipboard"));
}

#[tokio::test]
async fn escape_cancels_a_recording_and_nothing_is_delivered() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;
    r.call("hotkey_pressed", editor()).await;
    let state = r.call("escape_pressed", Value::Null).await;
    assert_eq!(state["presentation"], "hidden");
    r.call("hotkey_released", Value::Null).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!r.drain().iter().any(|(n, _)| n == "copy" || n == "insert"));
    assert!(r.sounds.lock().unwrap().is_empty());
}

#[tokio::test]
async fn silence_is_an_error_that_hides_itself() {
    let r = rig(Options { heard: Ok(String::new()), ..Options::default() });
    r.call("host_ready", json!({"insert": true})).await;
    r.call("hotkey_pressed", editor()).await;
    r.call("hotkey_released", Value::Null).await;
    let state = r.until("an error", |s| s["presentation"] == "error").await;
    assert!(state["error"].as_str().unwrap().contains("No speech was recognised"));
    assert_eq!(state["orb"]["tone"], json!([229.0 / 255.0, 62.0 / 255.0, 62.0 / 255.0]));
}

#[tokio::test]
async fn a_missing_model_refuses_before_recording_and_the_microphone_never_opens() {
    let r = rig(Options { model_ready: false, ..Options::default() });
    let state = r.call("hotkey_pressed", editor()).await;
    assert_eq!(state["presentation"], "error");
    assert_eq!(state["error"], MODEL_MISSING);
    assert_eq!(r.mic_started.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_microphone_that_will_not_open_is_an_error() {
    let r = rig(Options { mic_fails: true, ..Options::default() });
    let state = r.call("hotkey_pressed", editor()).await;
    assert_eq!(state["presentation"], "error");
    assert_eq!(state["error"], MICROPHONE_COULD_NOT_START);
}

#[tokio::test]
async fn while_off_nothing_runs() {
    let r = rig(Options { enabled: false, ..Options::default() });
    r.call("host_ready", json!({"insert": true})).await;
    let state = r.call("hotkey_pressed", editor()).await;
    assert_eq!(state["presentation"], "hidden");
    assert_eq!(r.mic_started.load(Ordering::SeqCst), 0);
    assert!(r.drain().is_empty(), "no shortcut is grabbed while off");
}

#[tokio::test]
async fn switching_on_grabs_the_shortcut_and_switching_off_lets_it_go_and_is_remembered() {
    let r = rig(Options { enabled: false, ..Options::default() });
    r.call("set_enabled", json!({"enabled": true})).await;
    let events = r.drain();
    let register = events.iter().rev().find(|(n, _)| n == "register").expect("the shortcut is registered");
    assert_eq!(register.1["shortcut"]["keyLabel"], "D");
    assert!(r.prefs.dictation_enabled());

    r.call("set_enabled", json!({"enabled": false})).await;
    let events = r.drain();
    assert!(events.iter().any(|(n, d)| n == "register" && d["shortcut"].is_null()));
    assert!(!r.prefs.dictation_enabled());
}

#[tokio::test]
async fn history_is_kept_only_when_on_and_can_be_copied_and_deleted() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;
    r.call("set_keeps_history", json!({"keeps": true})).await;
    r.call("hotkey_pressed", editor()).await;
    r.call("hotkey_released", Value::Null).await;
    r.answer_insert(None).await;
    let state = r.until("a history", |s| s["history"].as_array().is_some_and(|h| !h.is_empty())).await;
    let id = state["history"][0]["id"].clone();
    assert_eq!(state["history"][0]["text"], "привет мир");
    assert_eq!(r.prefs.dictation_history().entries().len(), 1, "and kept for the next start");

    r.drain();
    r.call("copy_history_entry", json!({"id": id})).await;
    assert!(r.drain().iter().any(|(n, d)| n == "copy" && d["text"] == "привет мир"));
    let state = r.call("delete_history_entry", json!({"id": id})).await;
    assert_eq!(state["history"], json!([]));
}

#[tokio::test]
async fn setting_up_downloads_the_model_and_says_when_it_is_ready() {
    let r = rig(Options { model_ready: false, ..Options::default() });
    let state = r.call("start_download", Value::Null).await;
    assert!(state["download"].is_object());
    let state = r.until("ready", |s| s["modelReady"] == true).await;
    assert!(state["download"].is_null());
    assert_eq!(*r.sounds.lock().unwrap(), [SoundCue::DictationModelReady]);
}

#[tokio::test]
async fn a_shortcut_is_changed_through_the_machine_and_remembered() {
    let r = rig(Options::default());
    let new = json!({"keyCode": 40, "modifiers": 3, "keyLabel": "K"});
    let state = r.call("set_shortcut", json!({"shortcut": new})).await;
    assert_eq!(state["shortcut"]["shortcut"]["keyLabel"], "K");
    assert_eq!(state["shortcut"]["display"], "Ctrl+Alt+K");
    assert_eq!(r.prefs.dictation_shortcut().key_label, "K");
}

#[tokio::test]
async fn an_unknown_command_is_an_error() {
    let r = rig(Options::default());
    assert!(r.module.call("fly", Value::Null).await.is_err());
    assert_eq!(r.mic_started.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_history_cleared_in_settings_does_not_come_back() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;
    r.call("set_keeps_history", json!({"keeps": true})).await;
    r.call("hotkey_pressed", editor()).await;
    r.call("hotkey_released", Value::Null).await;
    r.answer_insert(None).await;
    r.until("a history", |s| s["history"].as_array().is_some_and(|h| h.len() == 1)).await;

    // Settings clears it through the preferences, and the hub says so.
    r.prefs.set_dictation_history(&capa_core::dictation::DictationHistory::new());
    r.module.preferences_changed();
    r.until("cleared", |s| s["history"] == json!([])).await;

    let state = r.until("idle", |s| s["presentation"] == "hidden").await;
    assert_eq!(state["history"], json!([]));
    r.call("hotkey_pressed", editor()).await;
    r.call("hotkey_released", Value::Null).await;
    r.answer_insert(None).await;
    let state = r.until("the next one", |s| s["history"].as_array().is_some_and(|h| !h.is_empty())).await;
    assert_eq!(state["history"].as_array().unwrap().len(), 1, "only the new dictation");
    assert_eq!(r.prefs.dictation_history().entries().len(), 1);
}

#[tokio::test]
async fn the_stop_is_logged_when_the_key_is_let_go_with_what_was_taken() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;
    r.call("hotkey_pressed", editor()).await;
    let state = r.call("hotkey_released", Value::Null).await;
    let log: Vec<String> = serde_json::from_value(state["log"].clone()).unwrap();
    assert!(log.iter().any(|l| l == "recording-stopped samples=16000"), "{log:?}");
}

#[tokio::test]
async fn a_report_and_the_launch_log_say_what_the_swift_says() {
    let r = rig(Options::default());
    r.until("published", |s| s["observation"].is_array()).await;
    let notes = r.module.observations();
    assert!(!notes.is_empty());
    assert!(notes.iter().all(|n| n.starts_with("dictation-") && n.len() < 32), "{notes:?}");
    let events = r.module.launch_events();
    assert_eq!(events.len(), 1);
    assert!(matches!(events[0], capa_core::diagnostics::DiagnosticEvent::Dictation(_)));
    assert!(events[0].line().starts_with("dictation model-ready mic-authorized"), "{}", events[0].line());
}

#[tokio::test]
async fn a_quick_tap_says_no_speech_at_once_without_waiting_for_the_model() {
    let cancelled = Arc::new(AtomicBool::new(false));
    let slow = Slow { load: Duration::from_secs(10), loaded: false, warm_up_cancelled: cancelled.clone() };
    let r = rig(Options { samples: Vec::new(), recogniser: Some(Box::new(slow)), ..Options::default() });
    r.call("host_ready", json!({"insert": true})).await;
    r.call("hotkey_pressed", editor()).await;
    let started = std::time::Instant::now();
    r.call("hotkey_released", Value::Null).await;
    let state = r.until("an error", |s| s["presentation"] == "error").await;
    assert_eq!(state["error"], NO_SPEECH_RECORDED);
    assert!(started.elapsed() < Duration::from_secs(2), "not after the model's ten seconds: {:?}", started.elapsed());
    // The warm-up is still loading; dismissing cuts it short.
    r.call("dismiss", Value::Null).await;
    for _ in 0..200 {
        if cancelled.load(Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(cancelled.load(Ordering::SeqCst), "the warm-up heard it was cancelled");
}

#[tokio::test]
async fn escape_stops_the_warm_up_too() {
    let cancelled = Arc::new(AtomicBool::new(false));
    let slow = Slow { load: Duration::from_secs(10), loaded: false, warm_up_cancelled: cancelled.clone() };
    let r = rig(Options { recogniser: Some(Box::new(slow)), ..Options::default() });
    r.call("host_ready", json!({"insert": true})).await;
    r.call("hotkey_pressed", editor()).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    r.call("escape_pressed", Value::Null).await;
    for _ in 0..200 {
        if cancelled.load(Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(cancelled.load(Ordering::SeqCst));
}

#[tokio::test]
async fn sleep_ends_a_recording_and_the_host_stops_holding_the_key() {
    let r = rig(Options::default());
    r.call("host_ready", json!({"insert": true})).await;
    assert!(r.sleep.is_listening(), "listening once the Module is on");
    let state = r.call("hotkey_pressed", editor()).await;
    assert_eq!(state["presentation"], "recording");
    r.drain();
    r.sleep.now();
    let state = r.until("hidden", |s| s["presentation"] == "hidden").await;
    assert_eq!(state["registration"]["escape"], false);
    let events = r.drain();
    assert!(events.iter().any(|(n, _)| n == "end_hold"), "{events:?}");
    // The key's release after waking delivers nothing.
    r.call("hotkey_released", Value::Null).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!r.drain().iter().any(|(n, _)| n == "copy" || n == "insert"));
    assert!(r.sounds.lock().unwrap().is_empty());
}

#[tokio::test]
async fn sleep_is_not_listened_for_while_off() {
    let r = rig(Options { enabled: false, ..Options::default() });
    r.call("state", Value::Null).await;
    assert!(!r.sleep.is_listening());
    r.call("set_enabled", json!({"enabled": true})).await;
    assert!(r.sleep.is_listening());
}

#[tokio::test]
async fn a_microphone_gnome_has_switched_off_is_refused_and_its_switch_is_shown() {
    let r = rig(Options { permission: MicrophonePermission::Denied, ..Options::default() });
    r.call("host_ready", json!({"insert": true})).await;
    let state = r.call("hotkey_pressed", editor()).await;
    assert_eq!(state["microphoneAllowed"], false);
    assert_eq!(state["presentation"], "error");
    assert_eq!(state["error"], MICROPHONE_REQUIRED_LINUX);
    assert_eq!(r.mic_started.load(Ordering::SeqCst), 0, "the microphone is never opened");
    r.call("request_microphone", Value::Null).await;
    assert_eq!(r.settings_opened.load(Ordering::SeqCst), 1);
    let allowed = rig(Options::default());
    allowed.call("request_microphone", Value::Null).await;
    assert_eq!(allowed.settings_opened.load(Ordering::SeqCst), 0, "nothing to show when it is on");
}
