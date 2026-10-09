//! The Teleprompter Module: the `SurfaceModule` the hub hosts, over
//! `capa_core::teleprompter`. This crate is the part that talks to the machine:
//! it measures the row's type (`GeistMeasure`), keeps the preferences, asks the
//! platform for the global shortcuts (`hotkeys`), and runs the one timer the
//! playback needs — only while a Script is running or lingering. Off, it runs
//! nothing and registers nothing (ADR 0003).

mod geist_widths;
mod hotkeys;
mod measure;

pub use hotkeys::{Bound, ShellHotKeys};
pub use measure::GeistMeasure;

use capa_core::module::{BoxFuture, ModuleContext, SurfaceModule};
use capa_core::prefs::{self, Preferences};
use capa_core::surface::SurfacePage;
use capa_core::teleprompter::{
    HotKeys, KeyShortcut, TeleprompterAction, TeleprompterModel, TeleprompterModule as Observation, TeleprompterSettings,
    TeleprompterShortcuts, TeleprompterSurface, TeleprompterTextSize,
};
use chrono::{DateTime, Utc};
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
use tokio::task::JoinHandle;

/// The same value in another crate-module's type: the preferences keep the
/// Swift words for these, and the types are word-for-word the same JSON.
fn via_json<T: Serialize, U: DeserializeOwned>(value: &T) -> Option<U> {
    serde_json::from_value(serde_json::to_value(value).ok()?).ok()
}

/// What the preferences say, in the Module's own types.
fn settings_from(prefs: &Preferences) -> TeleprompterSettings {
    let mut shortcuts = BTreeMap::new();
    for action in TeleprompterAction::ALL {
        let Some(stored) = via_json::<_, prefs::TeleprompterAction>(&action).and_then(|a| prefs.teleprompter_shortcut(a)) else {
            continue;
        };
        if let Some(shortcut) = via_json::<_, KeyShortcut>(&stored) {
            // Only the ones that are not the standard ones are kept apart.
            if !shortcut.same_keys(&TeleprompterShortcuts::standard(action)) {
                shortcuts.insert(action, shortcut);
            }
        }
    }
    TeleprompterSettings {
        enabled: prefs.teleprompter_enabled(),
        script: prefs.script(),
        previous_script: prefs.previous_script(),
        multiplier: prefs.teleprompter_multiplier(),
        text_size: via_json(&prefs.teleprompter_text_size()).unwrap_or(TeleprompterTextSize::Medium),
        shortcuts,
    }
}

struct Inner {
    context: ModuleContext,
    model: Mutex<TeleprompterModel>,
    keys: Mutex<Box<dyn Bound>>,
    timer: Mutex<Option<JoinHandle<()>>>,
    runtime: tokio::runtime::Handle,
}

pub struct TeleprompterModule {
    inner: Arc<Inner>,
}

/// The keys the Shell extension binds: the hub only says which (`hotkeys`).
fn platform_keys(_press: Arc<dyn Fn(TeleprompterAction) + Send + Sync>) -> Box<dyn Bound> {
    Box::new(ShellHotKeys::default())
}

/// The Module for the hub. Needs a Tokio runtime to be running.
pub fn module(context: ModuleContext) -> Arc<dyn SurfaceModule> {
    TeleprompterModule::with_keys(context, platform_keys)
}

impl TeleprompterModule {
    /// With the keys a platform (or a test) provides; they are given the function to call on a press.
    pub fn with_keys(
        context: ModuleContext,
        keys: impl FnOnce(Arc<dyn Fn(TeleprompterAction) + Send + Sync>) -> Box<dyn Bound>,
    ) -> Arc<dyn SurfaceModule> {
        Arc::new(Self::build(context, keys))
    }

    pub fn build(
        context: ModuleContext,
        keys: impl FnOnce(Arc<dyn Fn(TeleprompterAction) + Send + Sync>) -> Box<dyn Bound>,
    ) -> Self {
        let now = (context.clock)();
        let model = TeleprompterModel::new(settings_from(&context.prefs), now, &GeistMeasure);
        let inner = Arc::new(Inner {
            context,
            model: Mutex::new(model),
            keys: Mutex::new(Box::new(ShellHotKeys::default())),
            timer: Mutex::new(None),
            runtime: tokio::runtime::Handle::current(),
        });
        // A press on a thread of the platform's own comes back through here.
        let weak = Arc::downgrade(&inner);
        let press: Arc<dyn Fn(TeleprompterAction) + Send + Sync> = Arc::new(move |action| {
            if let Some(inner) = weak.upgrade() {
                let runtime = inner.runtime.clone();
                runtime.spawn(async move { inner.hot_key(action) });
            }
        });
        *inner.keys.lock().unwrap() = keys(press);
        {
            // Already on at launch: register what it needs.
            let mut model = inner.model.lock().unwrap();
            let mut keys = inner.keys.lock().unwrap();
            model.start(&mut **keys as &mut dyn HotKeys);
        }
        inner.schedule();
        Self { inner }
    }
}

impl Inner {
    fn now(&self) -> DateTime<Utc> {
        (self.context.clock)()
    }

    /// Writes down what changed, and tells the hub.
    fn commit(&self, model: &mut TeleprompterModel) {
        let prefs = &self.context.prefs;
        if model.take_dirty() {
            let s = model.settings();
            if (prefs.teleprompter_multiplier() - s.multiplier).abs() > 1e-9 {
                prefs.set_teleprompter_multiplier(s.multiplier);
            }
            if let Some(size) = via_json::<_, prefs::TeleprompterTextSize>(&s.text_size) {
                if prefs.teleprompter_text_size() != size {
                    prefs.set_teleprompter_text_size(size);
                }
            }
        }
    }

    fn changed(self: &Arc<Self>) {
        self.schedule();
        (self.context.notify)();
    }

    fn hot_key(self: &Arc<Self>, action: TeleprompterAction) {
        let now = self.now();
        {
            let mut model = self.model.lock().unwrap();
            if !model.is_enabled() {
                return;
            }
            model.hot_key_pressed(action, now);
            self.commit(&mut model);
        }
        self.changed();
    }

    /// One timer, for the next moment the playback changes by itself: the last
    /// line reached, or the row leaving. None while stopped or paused.
    fn schedule(self: &Arc<Self>) {
        let mut timer = self.timer.lock().unwrap();
        if let Some(old) = timer.take() {
            old.abort();
        }
        let wake = {
            let model = self.model.lock().unwrap();
            if model.is_enabled() { model.next_wake() } else { None }
        };
        let Some(at) = wake else { return };
        let delay = (at - self.now()).to_std().unwrap_or_default();
        let this = Arc::clone(self);
        *timer = Some(self.runtime.spawn(async move {
            tokio::time::sleep(delay).await;
            {
                let mut model = this.model.lock().unwrap();
                model.tick(this.now());
            }
            // Not from under the lock: `changed` asks for the next wake.
            this.changed();
        }));
    }

    /// The preferences changed somewhere (Settings): take what concerns the Module.
    fn sync_from_preferences(self: &Arc<Self>) -> bool {
        let wanted = settings_from(&self.context.prefs);
        let now = self.now();
        let mut model = self.model.lock().unwrap();
        let have = model.settings();
        let mut changed = false;

        if wanted.enabled != have.enabled {
            let mut keys = self.keys.lock().unwrap();
            model.set_enabled(wanted.enabled, &mut **keys as &mut dyn HotKeys);
            changed = true;
        }
        if wanted.script != have.script {
            model.edit(&wanted.script, now, &GeistMeasure);
            changed = true;
        }
        if wanted.text_size != have.text_size {
            model.set_text_size(wanted.text_size, now, &GeistMeasure);
            changed = true;
        }
        if (wanted.multiplier - have.multiplier).abs() > 1e-9 {
            model.set_multiplier(wanted.multiplier, now);
            changed = true;
        }
        // The shortcuts Settings recorded: only those that differ from the
        // model's are set, each trading places with whichever of the four had
        // its keys (`setShortcut(_:for:)`); the one traded away is written back,
        // so the preferences say what the model does.
        let want = |action| wanted.shortcuts.get(&action).cloned().unwrap_or_else(|| TeleprompterShortcuts::standard(action));
        let recorded: Vec<TeleprompterAction> = TeleprompterAction::ALL
            .into_iter()
            .filter(|&action| model.shortcut_for(action).is_some_and(|s| !s.same_keys(&want(action))))
            .collect();
        for action in recorded {
            let shortcut = want(action);
            if model.shortcut_for(action).is_some_and(|s| !s.same_keys(&shortcut)) {
                let mut keys = self.keys.lock().unwrap();
                model.set_shortcut(shortcut, action, &mut **keys as &mut dyn HotKeys);
                changed = true;
            }
        }
        if changed {
            self.write_shortcuts(&model, &wanted.shortcuts);
        }
        // What is said now is what is kept: nothing else to write back.
        model.take_dirty();
        changed
    }

    /// The model's shortcuts into the preferences, where they differ from
    /// what the preferences already said.
    fn write_shortcuts(&self, model: &TeleprompterModel, kept: &BTreeMap<TeleprompterAction, KeyShortcut>) {
        let prefs = &self.context.prefs;
        for action in TeleprompterAction::ALL {
            let Some(have) = model.shortcut_for(action) else { continue };
            let said = kept.get(&action).cloned().unwrap_or_else(|| TeleprompterShortcuts::standard(action));
            if have.same_keys(&said) {
                continue;
            }
            if let (Some(a), Some(s)) = (via_json::<_, prefs::TeleprompterAction>(&action), via_json::<_, prefs::KeyShortcut>(&have)) {
                prefs.set_teleprompter_shortcut(&s, a);
            }
        }
    }
}

impl SurfaceModule for TeleprompterModule {
    fn id(&self) -> &'static str {
        "teleprompter"
    }

    fn page(&self) -> Option<SurfacePage> {
        self.inner.model.lock().unwrap().is_enabled().then_some(SurfacePage::Teleprompter)
    }

    fn state(&self) -> Value {
        let inner = &self.inner;
        let now = inner.now();
        let model = inner.model.lock().unwrap();
        let view = model.view(now);
        let motion = model.playback().motion();
        let sharing = inner.context.prefs.screen_sharing_allowed();
        // Each with whether the host said it could not have it, so a host that
        // finds otherwise (or a hub that started again) can say so.
        let unavailable = model.unavailable_shortcuts();
        let hot_keys: Vec<Value> = inner
            .keys
            .lock()
            .unwrap()
            .bound()
            .into_iter()
            .map(|(action, accelerator)| {
                json!({ "action": action, "accelerator": accelerator, "unavailable": unavailable.contains(&action) })
            })
            .collect();
        let mut value = serde_json::to_value(&view).unwrap_or(Value::Null);
        if let Value::Object(map) = &mut value {
            map.insert("serverNowMs".into(), json!(now.timestamp_millis()));
            map.insert(
                "motion".into(),
                json!({
                    "anchor": motion.anchor,
                    "anchoredAtMs": motion.anchored_at.timestamp_millis(),
                    "linesPerSecond": motion.lines_per_second,
                    "lastLine": motion.last_line,
                }),
            );
            map.insert("hotKeys".into(), Value::Array(hot_keys));
            map.insert("hoverOpens".into(), json!(TeleprompterSurface::hover_opens(model.state())));
            // A Script on screen is never shared; the host adds the Shelf's Clippings to this.
            map.insert(
                "excludedFromCapture".into(),
                json!(TeleprompterSurface::excluded_from_capture(sharing, model.is_showing_row(), false)),
            );
            map.insert("captureExclusion".into(), json!("unsupported"));
            map.insert("spoken".into(), json!(model.spoken()));
        }
        value
    }

    fn call(&self, method: &str, args: Value) -> BoxFuture<Result<Value, String>> {
        let inner = Arc::clone(&self.inner);
        let method = method.to_owned();
        Box::pin(async move {
            let now = inner.now();
            let action_arg = |args: &Value| -> Result<TeleprompterAction, String> {
                serde_json::from_value(args.get("action").cloned().unwrap_or(Value::Null)).map_err(|e| format!("action: {e}"))
            };
            {
                let mut model = inner.model.lock().unwrap();
                let prefs = &inner.context.prefs;
                match method.as_str() {
                    "toggle" => model.toggle(now),
                    "stop" => model.stop(),
                    "faster" => model.faster(now),
                    "slower" => model.slower(now),
                    "seek" => model.seek_to_fraction(args.get("fraction").and_then(Value::as_f64).ok_or("fraction")?, now),
                    "moveByLines" => model.move_by_lines(args.get("lines").and_then(Value::as_f64).ok_or("lines")?, now),
                    "hotKey" => {
                        let action = action_arg(&args)?;
                        if model.is_enabled() {
                            model.hot_key_pressed(action, now);
                        }
                    }
                    // Reads the clipboard now, and only now: the host read it at the click.
                    "paste" => {
                        let text = args.get("text").and_then(Value::as_str).ok_or("text")?;
                        if !text.trim().is_empty() {
                            prefs.replace_script(text);
                            model.paste(text, now, &GeistMeasure);
                        }
                    }
                    "restorePrevious" => {
                        prefs.restore_previous_script();
                        model.restore_previous_script(now, &GeistMeasure);
                    }
                    "setTextSize" => {
                        let size: TeleprompterTextSize =
                            serde_json::from_value(args.get("size").cloned().unwrap_or(Value::Null)).map_err(|e| format!("size: {e}"))?;
                        model.set_text_size(size, now, &GeistMeasure);
                    }
                    "setShortcut" => {
                        let action = action_arg(&args)?;
                        let shortcut: KeyShortcut =
                            serde_json::from_value(args.get("shortcut").cloned().unwrap_or(Value::Null)).map_err(|e| format!("shortcut: {e}"))?;
                        if let (Some(a), Some(s)) = (via_json::<_, prefs::TeleprompterAction>(&action), via_json::<_, prefs::KeyShortcut>(&shortcut)) {
                            prefs.set_teleprompter_shortcut(&s, a);
                        }
                        let mut keys = inner.keys.lock().unwrap();
                        model.set_shortcut(shortcut, action, &mut **keys as &mut dyn HotKeys);
                        // A shortcut traded with another is kept for both.
                        for other in TeleprompterAction::ALL {
                            if let (Some(s), Some(a)) = (model.shortcut_for(other), via_json::<_, prefs::TeleprompterAction>(&other)) {
                                if let Some(s) = via_json::<_, prefs::KeyShortcut>(&s) {
                                    prefs.set_teleprompter_shortcut(&s, a);
                                }
                            }
                        }
                    }
                    // The host that binds the keys could not have these: something
                    // else holds them (GNOME's own workspace keys, say).
                    "keysUnavailable" => {
                        let actions: BTreeSet<TeleprompterAction> =
                            serde_json::from_value(args.get("actions").cloned().unwrap_or(Value::Null)).map_err(|e| format!("actions: {e}"))?;
                        model.set_host_unavailable(actions);
                    }
                    "suspendShortcuts" => {
                        let suspended = args.get("suspended").and_then(Value::as_bool).ok_or("suspended")?;
                        let mut keys = inner.keys.lock().unwrap();
                        model.suspend_shortcuts(suspended, &mut **keys as &mut dyn HotKeys);
                    }
                    other => return Err(format!("teleprompter has no command {other}")),
                }
                inner.commit(&mut model);
            }
            inner.changed();
            Ok(Value::Null)
        })
    }

    fn preferences_changed(&self) {
        if self.inner.sync_from_preferences() {
            self.inner.schedule();
        }
    }

    /// Quiet while a Script is read aloud (ADR 0007; `Sounds.shared.isQuiet`).
    fn wants_quiet(&self) -> bool {
        self.inner.model.lock().unwrap().wants_quiet()
    }

    /// That it is on, and how long the Script is: never a word of it.
    fn observations(&self) -> Vec<String> {
        let prefs = &self.inner.context.prefs;
        vec![Observation::observation(prefs.teleprompter_enabled(), &prefs.script())]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::prefs::MemoryStore;
    use chrono::TimeZone;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    struct Rig {
        module: Arc<dyn SurfaceModule>,
        prefs: Arc<Preferences>,
        notified: Arc<AtomicUsize>,
    }

    /// A clock that follows Tokio's, so a test can move time with `advance`.
    fn rig() -> Rig {
        let prefs = Arc::new(Preferences::new(Arc::new(MemoryStore::new())));
        let notified = Arc::new(AtomicUsize::new(0));
        let base = tokio::time::Instant::now();
        let epoch = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let counter = notified.clone();
        let context = ModuleContext {
            prefs: prefs.clone(),
            clock: Arc::new(move || epoch + chrono::Duration::from_std(base.elapsed()).unwrap()),
            prefs_changed: Arc::new(|| {}),
            notify: Arc::new(move || {
                counter.fetch_add(1, Ordering::SeqCst);
            }),
            emit: Arc::new(|_, _, _| {}),
            sound: Arc::new(|_| {}),
        };
        let module = TeleprompterModule::with_keys(context, |_| Box::new(ShellHotKeys::default()));
        Rig { module, prefs, notified }
    }

    fn turn_on(r: &Rig) {
        r.prefs.set_teleprompter_enabled(true);
        r.module.preferences_changed();
    }

    async fn call(r: &Rig, method: &str, args: Value) {
        r.module.call(method, args).await.unwrap();
    }

    const SCRIPT: &str = "Good evening.\nWelcome to the show.\nWe begin with the news.";

    #[tokio::test(start_paused = true)]
    async fn off_it_has_no_page_no_keys_and_runs_nothing() {
        let r = rig();
        assert_eq!(r.module.page(), None);
        let state = r.module.state();
        assert_eq!(state["enabled"], false);
        assert_eq!(state["hotKeys"], json!([]));
        assert_eq!(state["showingRow"], false);
        // Commands are ignored while off.
        call(&r, "toggle", Value::Null).await;
        assert_eq!(r.module.state()["playback"]["state"], "stopped");
    }

    #[tokio::test(start_paused = true)]
    async fn turning_it_on_gives_it_a_page_and_asks_the_shell_for_four_keys() {
        let r = rig();
        turn_on(&r);
        assert_eq!(r.module.page(), Some(SurfacePage::Teleprompter));
        let keys = r.module.state()["hotKeys"].clone();
        assert_eq!(keys.as_array().unwrap().len(), 4);
        r.prefs.set_teleprompter_enabled(false);
        r.module.preferences_changed();
        assert_eq!(r.module.page(), None);
        assert_eq!(r.module.state()["hotKeys"], json!([]), "off, nothing is registered");
    }

    #[tokio::test(start_paused = true)]
    async fn pasting_a_script_keeps_the_one_before_and_runs_from_the_row() {
        let r = rig();
        turn_on(&r);
        call(&r, "paste", json!({"text": SCRIPT})).await;
        assert_eq!(r.prefs.script(), SCRIPT);
        let state = r.module.state();
        assert_eq!(state["lines"].as_array().unwrap().len(), 3);
        assert_eq!(state["wordCount"], 11);
        assert_eq!(state["showingRow"], false, "stopped, there is no row");

        call(&r, "paste", json!({"text": "Another script entirely."})).await;
        assert_eq!(r.prefs.previous_script().as_deref(), Some(SCRIPT));
        assert_eq!(r.module.state()["hasPreviousScript"], true);
        call(&r, "restorePrevious", Value::Null).await;
        assert_eq!(r.prefs.script(), SCRIPT);
        // Blank is not a Script.
        call(&r, "paste", json!({"text": "   \n "})).await;
        assert_eq!(r.prefs.script(), SCRIPT);
    }

    #[tokio::test(start_paused = true)]
    async fn running_shows_the_row_and_keeps_a_passing_pointer_from_opening_the_surface() {
        let r = rig();
        turn_on(&r);
        call(&r, "paste", json!({"text": SCRIPT})).await;
        call(&r, "toggle", Value::Null).await;
        let state = r.module.state();
        assert_eq!(state["playback"]["state"], "running");
        assert_eq!(state["showingRow"], true);
        assert_eq!(state["hoverOpens"], false);
        assert_eq!(state["excludedFromCapture"], true, "a Script on screen is never shared");
        assert!(state["motion"]["linesPerSecond"].as_f64().unwrap() > 0.0);
        call(&r, "toggle", Value::Null).await;
        assert_eq!(r.module.state()["playback"]["state"], "paused");
        assert_eq!(r.module.state()["hoverOpens"], true);
    }

    #[tokio::test(start_paused = true)]
    async fn the_timer_ends_the_script_then_lets_the_row_go() {
        let r = rig();
        turn_on(&r);
        call(&r, "paste", json!({"text": SCRIPT})).await;
        call(&r, "toggle", Value::Null).await;
        let before = r.notified.load(Ordering::SeqCst);

        // 11 words over 3 lines at 130 wpm: two lines take about 3.4 s, after the one-second hold.
        tokio::time::sleep(Duration::from_secs(5)).await;
        tokio::task::yield_now().await;
        assert_eq!(r.module.state()["playback"]["state"], "finished");
        assert!(r.notified.load(Ordering::SeqCst) > before, "the hub was told");

        tokio::time::sleep(Duration::from_secs(4)).await;
        tokio::task::yield_now().await;
        let state = r.module.state();
        assert_eq!(state["playback"]["state"], "stopped");
        assert_eq!(state["showingRow"], false);
    }

    #[tokio::test(start_paused = true)]
    async fn nothing_is_scheduled_while_stopped_or_paused() {
        let r = rig();
        turn_on(&r);
        call(&r, "paste", json!({"text": SCRIPT})).await;
        call(&r, "toggle", Value::Null).await;
        call(&r, "toggle", Value::Null).await; // paused
        let before = r.notified.load(Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(600)).await;
        tokio::task::yield_now().await;
        assert_eq!(r.notified.load(Ordering::SeqCst), before, "no timer ran");
        assert_eq!(r.module.state()["playback"]["state"], "paused");
    }

    #[tokio::test(start_paused = true)]
    async fn a_shortcut_pressed_works_the_script_and_speed_is_kept_in_the_preferences() {
        let r = rig();
        turn_on(&r);
        call(&r, "paste", json!({"text": SCRIPT})).await;
        call(&r, "hotKey", json!({"action": "startOrPause"})).await;
        assert_eq!(r.module.state()["playback"]["state"], "running");
        call(&r, "hotKey", json!({"action": "faster"})).await;
        assert_eq!(r.prefs.teleprompter_multiplier(), 1.25);
        call(&r, "hotKey", json!({"action": "slower"})).await;
        call(&r, "hotKey", json!({"action": "slower"})).await;
        assert_eq!(r.prefs.teleprompter_multiplier(), 0.75);
        call(&r, "hotKey", json!({"action": "stop"})).await;
        assert_eq!(r.module.state()["playback"]["state"], "stopped");
    }

    #[tokio::test(start_paused = true)]
    async fn the_text_size_relays_the_script_and_is_kept() {
        let r = rig();
        turn_on(&r);
        let long = "word ".repeat(200);
        call(&r, "paste", json!({"text": long})).await;
        let medium = r.module.state()["lines"].as_array().unwrap().len();
        call(&r, "setTextSize", json!({"size": "large"})).await;
        let large = r.module.state()["lines"].as_array().unwrap().len();
        assert!(large > medium, "{large} > {medium}");
        assert_eq!(r.prefs.teleprompter_text_size(), prefs::TeleprompterTextSize::Large);
        assert_eq!(r.module.state()["textSize"], "large");
    }

    #[tokio::test(start_paused = true)]
    async fn switching_it_off_while_running_stops_everything() {
        let r = rig();
        turn_on(&r);
        call(&r, "paste", json!({"text": SCRIPT})).await;
        call(&r, "toggle", Value::Null).await;
        r.prefs.set_teleprompter_enabled(false);
        r.module.preferences_changed();
        assert_eq!(r.module.state()["playback"]["state"], "stopped");
        let before = r.notified.load(Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(60)).await;
        tokio::task::yield_now().await;
        assert_eq!(r.notified.load(Ordering::SeqCst), before, "off, no timer waits for the end");
    }

    #[tokio::test(start_paused = true)]
    async fn a_script_typed_in_settings_reaches_the_row() {
        let r = rig();
        turn_on(&r);
        r.prefs.set_script("Typed in Settings.");
        r.module.preferences_changed();
        assert_eq!(r.module.state()["lines"], json!(["Typed in Settings."]));
    }

    #[tokio::test(start_paused = true)]
    async fn a_new_shortcut_is_kept_and_asked_of_the_shell_and_recording_suspends_the_old_ones() {
        let r = rig();
        turn_on(&r);
        let shortcut = json!({"keyCode": 35, "modifiers": 9, "keyLabel": "P"});
        call(&r, "setShortcut", json!({"action": "stop", "shortcut": shortcut})).await;
        let keys = r.module.state()["hotKeys"].clone();
        let stop = keys.as_array().unwrap().iter().find(|k| k["action"] == "stop").unwrap().clone();
        assert_eq!(stop["accelerator"], "<Control><Super>p", "{stop}");
        assert!(r.prefs.teleprompter_shortcut(prefs::TeleprompterAction::Stop).is_some_and(|s| s.key_code == 35));

        call(&r, "suspendShortcuts", json!({"suspended": true})).await;
        assert_eq!(r.module.state()["hotKeys"], json!([]));
        call(&r, "suspendShortcuts", json!({"suspended": false})).await;
        assert_eq!(r.module.state()["hotKeys"].as_array().unwrap().len(), 4);
    }

    #[tokio::test(start_paused = true)]
    async fn a_shortcut_recorded_in_settings_trades_places_and_the_preferences_say_so() {
        let r = rig();
        turn_on(&r);
        // Settings writes Faster's keys for Stop, and nothing else.
        let faster = r.prefs.teleprompter_shortcut(prefs::TeleprompterAction::Faster).unwrap();
        let stop = r.prefs.teleprompter_shortcut(prefs::TeleprompterAction::Stop).unwrap();
        r.prefs.set_teleprompter_shortcut(&faster, prefs::TeleprompterAction::Stop);
        r.module.preferences_changed();
        let keys = r.module.state()["hotKeys"].clone();
        let accel = |action: &str| keys.as_array().unwrap().iter().find(|k| k["action"] == action).unwrap()["accelerator"].clone();
        assert_eq!(accel("stop"), "<Control><Alt>Up");
        assert_eq!(accel("faster"), "<Control><Alt>Escape", "faster took stop's keys: one key, one action");
        assert_eq!(r.prefs.teleprompter_shortcut(prefs::TeleprompterAction::Faster).unwrap().key_code, stop.key_code, "and it is kept");
        // Read again, nothing moves.
        r.module.preferences_changed();
        let again = r.module.state()["hotKeys"].clone();
        assert_eq!(again, keys);
    }

    #[tokio::test(start_paused = true)]
    async fn the_shell_says_which_keys_it_could_not_have() {
        let r = rig();
        turn_on(&r);
        call(&r, "keysUnavailable", json!({"actions": ["faster", "slower"]})).await;
        let state = r.module.state();
        let marked: Vec<_> = state["shortcuts"].as_array().unwrap().iter().filter(|s| s["unavailable"] == true).map(|s| s["action"].clone()).collect();
        assert_eq!(marked, [json!("faster"), json!("slower")]);
        let flagged: Vec<_> = state["hotKeys"].as_array().unwrap().iter().filter(|k| k["unavailable"] == true).map(|k| k["action"].clone()).collect();
        assert_eq!(flagged, [json!("faster"), json!("slower")], "the shell can see what the hub believes");
        call(&r, "keysUnavailable", json!({"actions": []})).await;
        assert!(r.module.state()["shortcuts"].as_array().unwrap().iter().all(|s| s["unavailable"] == false));
        assert!(r.module.call("keysUnavailable", json!({"actions": ["sideways"]})).await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn it_wants_quiet_while_running_and_tells_diagnostics_only_a_count() {
        let r = rig();
        assert!(!r.module.wants_quiet());
        assert_eq!(r.module.observations(), ["teleprompter-off"]);
        turn_on(&r);
        call(&r, "paste", json!({"text": SCRIPT})).await;
        assert_eq!(r.module.observations(), ["teleprompter-on-11-words"]);
        assert!(!r.module.wants_quiet(), "stopped");
        call(&r, "toggle", Value::Null).await;
        assert!(r.module.wants_quiet(), "a Script read aloud");
        call(&r, "toggle", Value::Null).await;
        assert!(!r.module.wants_quiet(), "paused");
    }

    #[tokio::test(start_paused = true)]
    async fn an_unknown_command_is_an_error_not_a_crash() {
        let r = rig();
        assert!(r.module.call("explode", Value::Null).await.is_err());
        assert!(r.module.call("seek", json!({})).await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn the_state_never_carries_more_of_the_script_than_its_lines() {
        let r = rig();
        turn_on(&r);
        call(&r, "paste", json!({"text": "SECRET sentence"})).await;
        let state = r.module.state().to_string();
        assert!(state.contains("SECRET sentence"), "the row needs its lines");
        assert!(!state.contains("\"script\""), "but there is no field holding the Script as a whole");
        assert!(!state.contains("previousScript"));
    }
}

#[cfg(test)]
mod fixture {
    //! The row's numbers, written from the Rust and read by the JS tests, so the
    //! JS port of the layout cannot drift (`linux/js/test/teleprompter.test.js`).
    //! `TELEPROMPTER_WRITE_FIXTURE=1 cargo test -p capa-teleprompter fixture` rewrites it.

    use capa_core::teleprompter::{TeleprompterLayout, TeleprompterTextSize};
    use serde_json::{json, Value};

    fn expected() -> Value {
        let sizes: Vec<Value> = TeleprompterTextSize::ALL
            .into_iter()
            .map(|s| {
                json!({
                    "size": s,
                    "points": s.points(),
                    "lineHeight": TeleprompterLayout::line_height(s),
                    "pitch": TeleprompterLayout::pitch(s),
                    "kern": TeleprompterLayout::kern(s),
                    "rowLines": TeleprompterLayout::row_lines(s),
                    "textAreaHeight": TeleprompterLayout::text_area_height(s),
                    "rowHeight": TeleprompterLayout::row_height(s),
                    "previewHeight": TeleprompterLayout::preview_height(s),
                    "fadeBands": TeleprompterLayout::fade_bands(s),
                    "linesToDraw": ([0.0, 0.5, 3.2, 40.0].map(|p| TeleprompterLayout::lines_to_draw(p, s, 100).map(|r| vec![*r.start(), *r.end()]))),
                })
            })
            .collect();
        json!({
            "sizes": sizes,
            "opacity": (0..8).map(TeleprompterLayout::line_opacity).collect::<Vec<_>>(),
            "progressFill": ([[300.0, 0.0], [300.0, 0.5], [300.0, 2.0]].map(|[w, f]| TeleprompterLayout::progress_fill_width(w, f))),
            "speedText": ([0.5, 1.0, 1.25, 2.0].map(TeleprompterLayout::speed_text)),
        })
    }

    #[test]
    fn the_layout_fixture_is_current() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../js/test/fixtures/teleprompter.json");
        let want = serde_json::to_string_pretty(&expected()).unwrap() + "\n";
        if std::env::var_os("TELEPROMPTER_WRITE_FIXTURE").is_some() {
            std::fs::write(path, want).unwrap();
            return;
        }
        let have = std::fs::read_to_string(path).expect("run once with TELEPROMPTER_WRITE_FIXTURE=1");
        assert_eq!(have, want, "the layout changed: rewrite the fixture and the JS port with it");
    }
}
