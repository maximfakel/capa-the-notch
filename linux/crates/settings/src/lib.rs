//! The Settings Module: every choice, and nothing beyond a choice
//! (`SettingsModel.swift`). It writes to `Preferences` — the one place the
//! hub and the other Modules read — and tells the hub, so a switch flicked in
//! Settings or in onboarding takes effect at once. It also carries the state
//! both windows draw from, and the rules the Swift model enforced: two
//! Providers at most, consent before Claude Code or OpenCode is read, the
//! refresh paces on offer, a shortcut that needs Control, Option or Command.
//!
//! The windows themselves are the shared page in `linux/js/settings`.

mod keys;
mod login;

pub use keys::{mac_key_code, shortcut_from, KeyEvent};
pub use login::{LoginItem, MemoryLogin, SystemLogin};

use capa_core::dictation::{DictationHistory, DictationReplacement};
use capa_core::loc::{self, AppLanguage as LocLanguage};
use capa_core::module::{BoxFuture, ModuleContext, SurfaceModule};
use capa_core::prefs::{
    self, standard_teleprompter_shortcut, Appearance, AppLanguage, ClippingLimit, CompactWindowChoice, KeyShortcut,
    Platform, Preferences, TeleprompterAction, TeleprompterTextSize, REFRESH_CHOICES,
};
use capa_core::sound::SoundCue;
use capa_core::surface::Releases;
use capa_core::teleprompter::TeleprompterScript;
use capa_core::Provider;
use serde_json::{json, Value};
use std::sync::Arc;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Every command a surface may send, for the page's test that it sends none other.
pub const COMMANDS: &[&str] = &[
    "set", "setShortcut", "setProvider", "giveConsent", "faster", "slower", "replaceScript",
    "restorePreviousScript", "deleteHistoryEntry", "clearHistory", "finishOnboarding", "restartOnboarding",
    "checkForUpdates", "diagnosticsInfo",
];

/// Every key `set` takes (the ones with a Provider or an action in them end in `.`).
pub const KEYS: &[&str] = &[
    "language", "appearance", "launchAtLogin", "displayId", "screenSharingAllowed", "showsKapa", "playsSounds",
    "compactWindow", "backgroundRefreshSeconds", "alertsEnabled", "alertsFor.", "keepsDiagnosticLog",
    "musicEnabled", "teleprompterEnabled", "script", "teleprompterMultiplier", "teleprompterTextSize",
    "shelfEnabled", "shelfTakesClipboardImages", "shelfKeepsText", "clippingLimit", "clippingsExpire",
    "clipboardExcludedApplications", "dictationEnabled", "dictationKeepsHistory", "dictationReplacements",
];

pub struct SettingsModule {
    context: ModuleContext,
    login: Box<dyn LoginItem>,
    log_path: std::path::PathBuf,
    platform: Platform,
}

pub fn module(context: ModuleContext) -> Arc<dyn SurfaceModule> {
    Arc::new(SettingsModule::new(context, Box::new(SystemLogin), capa_platform::diagnostics::DiagnosticLog::default_path(), Platform::Linux))
}

fn provider_name(raw: &str) -> Option<Provider> {
    Provider::ALL.into_iter().find(|p| prefs::provider_raw(*p) == raw)
}

fn action_name(raw: &str) -> Option<TeleprompterAction> {
    TeleprompterAction::ALL.into_iter().find(|a| a.raw() == raw)
}

impl SettingsModule {
    pub fn new(context: ModuleContext, login: Box<dyn LoginItem>, log_path: std::path::PathBuf, platform: Platform) -> Self {
        Self { context, login, log_path, platform }
    }

    fn prefs(&self) -> &Preferences {
        &self.context.prefs
    }

    pub fn log_path(&self) -> &std::path::Path {
        &self.log_path
    }

    fn changed(&self) {
        (self.context.prefs_changed)();
    }

    fn shortcut_json(&self, shortcut: Option<&KeyShortcut>) -> Value {
        match shortcut {
            Some(s) => {
                // The caps from the parts, never from the joined words: a "+" key is a cap of its own.
                json!({ "caps": shortcut_caps(s, self.platform), "display": s.display_for(self.platform) })
            }
            None => Value::Null,
        }
    }

    /// Whether this Provider may be turned on beside those already on, and
    /// whether it is waiting for the person's consent first.
    fn provider_json(&self, provider: Provider) -> Value {
        let p = self.prefs();
        json!({
            "provider": provider,
            "name": provider.spoken_name(),
            "on": p.connects_at_launch(provider),
            "canConnect": p.can_connect(provider),
            "needsConsent": needs_consent(p, provider),
        })
    }

    fn state_value(&self) -> Value {
        let p = self.prefs();
        let words = TeleprompterScript::word_count(&p.script());
        let multiplier = p.teleprompter_multiplier();
        let history = p.dictation_history();
        let shortcuts: serde_json::Map<String, Value> = TeleprompterAction::ALL
            .into_iter()
            .map(|a| (a.raw().to_owned(), self.shortcut_json(p.teleprompter_shortcut(a).as_ref())))
            .collect();
        json!({
            "version": VERSION,
            "platform": "linux",
            "language": p.language().raw(),
            "appearance": p.appearance().raw(),
            "launchAtLogin": self.login.is_enabled(),
            "displayId": p.preferred_display_id().unwrap_or(0),
            "screenSharingAllowed": p.screen_sharing_allowed(),
            "showsKapa": p.shows_kapa(),
            "playsSounds": p.plays_sounds(),
            "providers": Provider::ALL.into_iter().map(|x| self.provider_json(x)).collect::<Vec<_>>(),
            "compactWindow": p.compact_window().raw(),
            "backgroundRefreshSeconds": p.background_refresh_seconds(),
            "alertsEnabled": p.alerts_enabled(),
            "alertsFor": Provider::ALL.into_iter()
                .map(|x| (prefs::provider_raw(x).to_owned(), Value::Bool(p.alerts_enabled_for(x))))
                .collect::<serde_json::Map<_, _>>(),
            "keepsDiagnosticLog": p.keeps_diagnostic_log(),
            "logPath": self.log_path.display().to_string(),
            "music": { "enabled": p.music_enabled() },
            "teleprompter": {
                "enabled": p.teleprompter_enabled(),
                "script": p.script(),
                "hasPreviousScript": p.previous_script().is_some(),
                "multiplier": multiplier,
                "textSize": p.teleprompter_text_size().raw(),
                "wordCount": words,
                "minutes": TeleprompterScript::minutes(words, 130.0 * multiplier),
                "shortcuts": shortcuts,
            },
            "shelf": {
                "enabled": p.shelf_enabled(),
                "takesClipboardImages": p.shelf_takes_clipboard_images(),
                "keepsText": p.shelf_keeps_text(),
                "clippingLimit": p.clipping_limit().raw(),
                "clippingsExpire": p.clippings_expire(),
                "excludedApplications": p.clipboard_excluded_applications(),
            },
            "dictation": {
                "enabled": p.dictation_enabled(),
                "keepsHistory": p.dictation_keeps_history(),
                "shortcut": self.shortcut_json(Some(&p.dictation_shortcut())),
                "replacements": p.dictation_replacements(),
                "history": history.entries().iter()
                    .map(|e| json!({ "id": e.id, "date": e.date.timestamp(), "text": e.text }))
                    .collect::<Vec<_>>(),
            },
            "consent": { "claudeCode": p.claude_consent_given(), "openCode": p.open_code_consent_given() },
            "onboarding": { "needed": p.needs_onboarding(), "finished": p.has_finished_onboarding() },
            "choices": {
                "language": AppLanguage::ALL.iter().map(|l| json!({ "id": l.raw(), "title": l.title() })).collect::<Vec<_>>(),
                "appearance": Appearance::ALL.iter().map(|a| json!({ "id": a.raw(), "title": a.title() })).collect::<Vec<_>>(),
                "compactWindow": CompactWindowChoice::ALL.iter().map(|c| json!({ "id": c.raw(), "title": c.title() })).collect::<Vec<_>>(),
                "refresh": REFRESH_CHOICES,
                "clippingLimit": ClippingLimit::ALL.iter().map(|l| l.raw()).collect::<Vec<_>>(),
                "textSize": TeleprompterTextSize::ALL.iter().map(|s| json!({ "id": s.raw(), "title": s.title() })).collect::<Vec<_>>(),
                "teleprompterActions": TeleprompterAction::ALL.iter().map(|a| json!({ "id": a.raw(), "title": a.title() })).collect::<Vec<_>>(),
            },
        })
    }

    // MARK: - Commands

    /// Writes one choice. The keys are the closed list in `KEYS`.
    pub fn set(&self, key: &str, value: Value) -> Result<Value, String> {
        let p = self.prefs();
        let bad = || format!("{key}: not a value it takes");
        let flag = || value.as_bool().ok_or_else(bad);
        let text = || value.as_str().ok_or_else(bad);

        if let Some(raw) = key.strip_prefix("alertsFor.") {
            let provider = provider_name(raw).ok_or_else(bad)?;
            p.set_alerts_enabled_for(provider, flag()?);
            return Ok(Value::Null);
        }

        match key {
            "language" => {
                let language = AppLanguage::from_raw(text()?).ok_or_else(bad)?;
                p.set_language(language);
                // Words said by the core in its own voice follow at once.
                loc::set_current(LocLanguage::from(language));
            }
            "appearance" => p.set_appearance(Appearance::from_raw(text()?).ok_or_else(bad)?),
            "launchAtLogin" => {
                // The system has the last word; a switch that did nothing must not stay on.
                let settled = self.login.set(flag()?);
                p.set_launch_at_login(settled);
            }
            "displayId" => {
                let id = value.as_u64().ok_or_else(bad)? as u32;
                p.set_preferred_display_id(if id == 0 { None } else { Some(id) });
            }
            "screenSharingAllowed" => p.set_screen_sharing_allowed(flag()?),
            "showsKapa" => p.set_shows_kapa(flag()?),
            "playsSounds" => p.set_plays_sounds(flag()?),
            "compactWindow" => p.set_compact_window(CompactWindowChoice::from_raw(text()?).ok_or_else(bad)?),
            "backgroundRefreshSeconds" => {
                let seconds = value.as_f64().ok_or_else(bad)?;
                if !REFRESH_CHOICES.contains(&seconds) {
                    return Err(format!("{key}: only {REFRESH_CHOICES:?} are on offer"));
                }
                p.set_background_refresh_seconds(seconds);
            }
            "alertsEnabled" => p.set_alerts_enabled(flag()?),
            "keepsDiagnosticLog" => p.set_keeps_diagnostic_log(flag()?),
            "musicEnabled" => p.set_music_enabled(flag()?),
            "teleprompterEnabled" => p.set_teleprompter_enabled(flag()?),
            "script" => p.set_script(text()?),
            "teleprompterMultiplier" => p.set_teleprompter_multiplier(value.as_f64().ok_or_else(bad)?),
            "teleprompterTextSize" => p.set_teleprompter_text_size(TeleprompterTextSize::from_raw(text()?).ok_or_else(bad)?),
            "shelfEnabled" => p.set_shelf_enabled(flag()?),
            "shelfTakesClipboardImages" => p.set_shelf_takes_clipboard_images(flag()?),
            "shelfKeepsText" => p.set_shelf_keeps_text(flag()?),
            "clippingLimit" => p.set_clipping_limit(ClippingLimit::from_raw(value.as_i64().ok_or_else(bad)?).ok_or_else(bad)?),
            "clippingsExpire" => p.set_clippings_expire(flag()?),
            "clipboardExcludedApplications" => {
                let list: Vec<String> = serde_json::from_value(value.clone()).map_err(|_| bad())?;
                p.set_clipboard_excluded_applications(&list);
            }
            "dictationEnabled" => p.set_dictation_enabled(flag()?),
            "dictationKeepsHistory" => p.set_dictation_keeps_history(flag()?),
            "dictationReplacements" => {
                let rules: Vec<DictationReplacement> = serde_json::from_value(value.clone()).map_err(|_| bad())?;
                p.set_dictation_replacements(&rules);
            }
            other => return Err(format!("{other}: no such choice")),
        }
        Ok(Value::Null)
    }

    /// Turns a Provider on or off with the Swift rules: refused past two, and
    /// never on before the person has agreed to what is read.
    pub fn set_provider(&self, provider: Provider, on: bool) -> Result<Value, String> {
        let p = self.prefs();
        if on && needs_consent(p, provider) {
            return Err("consent".into());
        }
        if !p.set_connects_at_launch(provider, on) {
            return Err("refused".into());
        }
        Ok(Value::Null)
    }

    pub fn give_consent(&self, provider: Provider) {
        match provider {
            Provider::ClaudeCode => self.prefs().set_claude_consent_given(true),
            Provider::OpenCode => self.prefs().set_open_code_consent_given(true),
            Provider::Codex => {}
        }
    }

    /// Records a shortcut from the keys a person pressed. `target` is
    /// `dictation` or `teleprompter.<action>`. A key that cannot be a
    /// shortcut is refused and nothing changes.
    pub fn set_shortcut(&self, target: &str, event: &KeyEvent) -> Result<Value, String> {
        let shortcut = shortcut_from(event).ok_or_else(|| "not a shortcut".to_owned())?;
        if target == "dictation" {
            self.prefs().set_dictation_shortcut(&shortcut);
        } else if let Some(action) = target.strip_prefix("teleprompter.").and_then(action_name) {
            self.prefs().set_teleprompter_shortcut(&shortcut, action);
        } else {
            return Err(format!("{target}: no such shortcut"));
        }
        Ok(Value::Null)
    }

    fn step_speed(&self, direction: f64) {
        let p = self.prefs();
        p.set_teleprompter_multiplier(p.teleprompter_multiplier() + 0.25 * direction);
    }

    fn history_without(&self, id: Option<u64>) {
        let p = self.prefs();
        let mut history: DictationHistory = p.dictation_history();
        match id {
            Some(id) => history.delete(id),
            None => history.clear(),
        }
        p.set_dictation_history(&history);
    }

    /// Dispatches a command; the notify is the caller's.
    pub fn handle(&self, method: &str, args: Value) -> Result<Value, String> {
        let provider_of = |args: &Value| {
            args.get("provider").and_then(Value::as_str).and_then(provider_name).ok_or_else(|| "no such provider".to_owned())
        };
        match method {
            "set" => {
                let key = args.get("key").and_then(Value::as_str).ok_or("set needs a key")?;
                self.set(key, args.get("value").cloned().unwrap_or(Value::Null))
            }
            "setShortcut" => {
                let target = args.get("target").and_then(Value::as_str).ok_or("setShortcut needs a target")?;
                let event: KeyEvent = serde_json::from_value(args.get("event").cloned().unwrap_or_default())
                    .map_err(|e| e.to_string())?;
                self.set_shortcut(target, &event)
            }
            "setProvider" => {
                let on = args.get("on").and_then(Value::as_bool).ok_or("setProvider needs on")?;
                self.set_provider(provider_of(&args)?, on)
            }
            "giveConsent" => {
                self.give_consent(provider_of(&args)?);
                Ok(Value::Null)
            }
            "faster" => {
                self.step_speed(1.0);
                Ok(Value::Null)
            }
            "slower" => {
                self.step_speed(-1.0);
                Ok(Value::Null)
            }
            "replaceScript" => {
                self.prefs().replace_script(args.get("text").and_then(Value::as_str).ok_or("replaceScript needs text")?);
                Ok(Value::Null)
            }
            "restorePreviousScript" => {
                self.prefs().restore_previous_script();
                Ok(Value::Null)
            }
            "deleteHistoryEntry" => {
                self.history_without(Some(args.get("id").and_then(Value::as_u64).ok_or("needs an id")?));
                Ok(Value::Null)
            }
            "clearHistory" => {
                self.history_without(None);
                Ok(Value::Null)
            }
            "finishOnboarding" => {
                self.prefs().set_has_finished_onboarding(true);
                (self.context.sound)(SoundCue::OnboardingFinished);
                // The surface opens on what was chosen (`AppDelegate.finishOnboarding`).
                (self.context.emit)("settings", "onboardingFinished", Value::Null);
                Ok(Value::Null)
            }
            "restartOnboarding" => {
                // `startOnboarding(force: true)`: the first run is not finished again until it is.
                self.prefs().set_has_finished_onboarding(false);
                (self.context.emit)("settings", "openOnboarding", Value::Null);
                Ok(Value::Null)
            }
            "checkForUpdates" => Ok(json!({ "url": Releases::LATEST })),
            "diagnosticsInfo" => Ok(json!({
                "logPath": self.log_path.display().to_string(),
                "keepsLog": self.prefs().keeps_diagnostic_log(),
            })),
            other => Err(format!("settings has no command {other}")),
        }
    }
}

/// A shortcut's keycaps, one per part: the Mac's symbols there, the other
/// keyboards' words elsewhere ("Ctrl", "Alt", "Shift", "Super", then the key).
fn shortcut_caps(s: &KeyShortcut, platform: Platform) -> Vec<String> {
    if platform == Platform::Mac {
        return s.keycaps();
    }
    let mut caps: Vec<String> = [
        (prefs::Modifiers::CONTROL, "Ctrl"),
        (prefs::Modifiers::OPTION, "Alt"),
        (prefs::Modifiers::SHIFT, "Shift"),
        (prefs::Modifiers::COMMAND, "Super"),
    ]
    .into_iter()
    .filter(|(m, _)| s.modifiers.contains(*m))
    .map(|(_, word)| word.to_owned())
    .collect();
    caps.push(s.key_label.clone());
    caps
}

/// Claude Code and OpenCode are read only after the person has agreed to what
/// is read (ADR 0001): Codex needs nothing from them.
fn needs_consent(p: &Preferences, provider: Provider) -> bool {
    match provider {
        Provider::Codex => false,
        Provider::ClaudeCode => !p.claude_consent_given(),
        Provider::OpenCode => !p.open_code_consent_given(),
    }
}

impl SurfaceModule for SettingsModule {
    fn id(&self) -> &'static str {
        "settings"
    }

    fn state(&self) -> Value {
        self.state_value()
    }

    fn call(&self, method: &str, args: Value) -> BoxFuture<Result<Value, String>> {
        let answer = self.handle(method, args);
        if answer.is_ok() && method != "checkForUpdates" && method != "diagnosticsInfo" {
            self.changed();
        }
        Box::pin(std::future::ready(answer))
    }
}

/// The standard shortcuts the Teleprompter starts with, as the state spells them: for the page's tests.
pub fn standard_shortcuts(platform: Platform) -> Vec<(String, String)> {
    TeleprompterAction::ALL
        .into_iter()
        .map(|a| (a.raw().to_owned(), standard_teleprompter_shortcut(a).display_for(platform)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::prefs::MemoryStore;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;

    struct Rig {
        module: SettingsModule,
        prefs: Arc<Preferences>,
        notified: Arc<AtomicUsize>,
        events: Arc<Mutex<Vec<(String, String)>>>,
        sounds: Arc<Mutex<Vec<SoundCue>>>,
    }

    fn rig() -> Rig {
        let prefs = Arc::new(Preferences::new(Arc::new(MemoryStore::new())));
        let notified = Arc::new(AtomicUsize::new(0));
        let events = Arc::new(Mutex::new(vec![]));
        let sounds = Arc::new(Mutex::new(vec![]));
        let (n, e, s) = (notified.clone(), events.clone(), sounds.clone());
        let context = ModuleContext {
            prefs: prefs.clone(),
            clock: Arc::new(chrono::Utc::now),
            notify: Arc::new(|| {}),
            prefs_changed: Arc::new(move || {
                n.fetch_add(1, Ordering::SeqCst);
            }),
            emit: Arc::new(move |m, name, _| e.lock().unwrap().push((m.into(), name.into()))),
            sound: Arc::new(move |c| s.lock().unwrap().push(c)),
        };
        let log = std::env::temp_dir().join(format!("capa-settings-{}.log", std::process::id()));
        let module = SettingsModule::new(context, Box::new(MemoryLogin::default()), log, Platform::Linux);
        Rig { module, prefs, notified, events, sounds }
    }

    fn call(r: &Rig, method: &str, args: Value) -> Result<Value, String> {
        let mut future = r.module.call(method, args);
        // The answer is ready at once.
        let waker = std::task::Waker::noop();
        match future.as_mut().poll(&mut std::task::Context::from_waker(waker)) {
            std::task::Poll::Ready(answer) => answer,
            std::task::Poll::Pending => panic!("a settings command waits"),
        }
    }

    fn set(r: &Rig, key: &str, value: Value) -> Result<Value, String> {
        call(r, "set", json!({ "key": key, "value": value }))
    }

    #[test]
    fn a_third_provider_is_refused_and_the_others_stay_on() {
        let r = rig();
        r.module.give_consent(Provider::ClaudeCode);
        r.module.give_consent(Provider::OpenCode);
        for p in Provider::ALL {
            r.prefs.set_connects_at_launch(p, false);
        }
        assert!(call(&r, "setProvider", json!({"provider": "codex", "on": true})).is_ok());
        assert!(call(&r, "setProvider", json!({"provider": "claudeCode", "on": true})).is_ok());
        assert_eq!(call(&r, "setProvider", json!({"provider": "openCode", "on": true})), Err("refused".into()));
        assert_eq!(r.prefs.connected_providers(), [Provider::Codex, Provider::ClaudeCode]);
        assert!(call(&r, "setProvider", json!({"provider": "codex", "on": false})).is_ok());
        assert!(call(&r, "setProvider", json!({"provider": "openCode", "on": true})).is_ok(), "one off, one may go on");
    }

    #[test]
    fn claude_code_and_opencode_are_not_read_before_the_person_agrees_and_codex_needs_nothing() {
        let r = rig();
        assert_eq!(call(&r, "setProvider", json!({"provider": "claudeCode", "on": true})), Err("consent".into()));
        assert_eq!(call(&r, "setProvider", json!({"provider": "openCode", "on": true})), Err("consent".into()));
        assert!(!r.prefs.connects_at_launch(Provider::ClaudeCode), "refused for consent: still off");
        assert!(call(&r, "setProvider", json!({"provider": "codex", "on": true})).is_ok());

        call(&r, "giveConsent", json!({"provider": "claudeCode"})).unwrap();
        assert!(call(&r, "setProvider", json!({"provider": "claudeCode", "on": true})).is_ok());
        assert!(r.prefs.claude_consent_given() && !r.prefs.open_code_consent_given(), "one consent is not the other's");
        // Turning off asks for nothing.
        assert!(call(&r, "setProvider", json!({"provider": "openCode", "on": false})).is_ok());
    }

    #[test]
    fn the_state_says_which_switch_waits_for_another_to_go_and_which_for_consent() {
        let r = rig();
        r.module.give_consent(Provider::ClaudeCode);
        r.module.give_consent(Provider::OpenCode);
        r.prefs.set_connects_at_launch(Provider::Codex, true);
        r.prefs.set_connects_at_launch(Provider::ClaudeCode, true);
        let state = r.module.state();
        let providers = state["providers"].as_array().unwrap();
        assert_eq!(providers[2]["canConnect"], false, "a third cannot");
        assert_eq!(providers[0]["canConnect"], true, "one already on may stay");
        let fresh = rig();
        assert_eq!(fresh.module.state()["providers"][1]["needsConsent"], true);
        assert_eq!(fresh.module.state()["providers"][0]["needsConsent"], false);
    }

    #[test]
    fn the_refresh_pace_is_one_of_those_on_offer() {
        let r = rig();
        for seconds in REFRESH_CHOICES {
            assert!(set(&r, "backgroundRefreshSeconds", json!(seconds)).is_ok());
            assert_eq!(r.prefs.background_refresh_seconds(), seconds);
        }
        assert!(set(&r, "backgroundRefreshSeconds", json!(1.0)).is_err());
        assert_eq!(r.prefs.background_refresh_seconds(), 900.0, "a refusal changes nothing");
    }

    #[test]
    fn language_appearance_and_the_strip_window_are_choices_from_a_closed_list() {
        let r = rig();
        assert!(set(&r, "language", json!("russian")).is_ok());
        assert_eq!(r.prefs.language(), AppLanguage::Russian);
        assert!(set(&r, "language", json!("klingon")).is_err());
        assert!(set(&r, "appearance", json!("dark")).is_ok());
        assert_eq!(r.prefs.appearance(), Appearance::Dark);
        assert!(set(&r, "compactWindow", json!("weekly")).is_ok());
        assert_eq!(r.prefs.compact_window(), CompactWindowChoice::Weekly);
        assert!(set(&r, "compactWindow", json!("never")).is_err());
        assert!(set(&r, "teleprompterTextSize", json!("large")).is_ok());
        assert!(set(&r, "teleprompterTextSize", json!("huge")).is_err());
        assert!(set(&r, "clippingLimit", json!(50)).is_ok());
        assert!(set(&r, "clippingLimit", json!(7)).is_err());
        loc::set_current(LocLanguage::English);
    }

    #[test]
    fn display_zero_is_the_built_in_one() {
        let r = rig();
        set(&r, "displayId", json!(3)).unwrap();
        assert_eq!(r.prefs.preferred_display_id(), Some(3));
        set(&r, "displayId", json!(0)).unwrap();
        assert_eq!(r.prefs.preferred_display_id(), None);
    }

    #[test]
    fn alerts_are_silenced_for_one_provider_without_silencing_the_other() {
        let r = rig();
        set(&r, "alertsEnabled", json!(true)).unwrap();
        set(&r, "alertsFor.codex", json!(false)).unwrap();
        assert!(!r.prefs.alerts_enabled_for(Provider::Codex));
        assert!(r.prefs.alerts_enabled_for(Provider::ClaudeCode));
        assert!(set(&r, "alertsFor.nobody", json!(true)).is_err());
        set(&r, "alertsEnabled", json!(false)).unwrap();
        assert!(!r.prefs.alerts_enabled_for(Provider::ClaudeCode), "the global switch outranks it");
    }

    #[test]
    fn launch_at_login_reads_back_what_the_system_settled() {
        let r = rig();
        assert_eq!(r.module.state()["launchAtLogin"], false);
        set(&r, "launchAtLogin", json!(true)).unwrap();
        assert_eq!(r.module.state()["launchAtLogin"], true);
        assert!(r.prefs.launch_at_login());
        set(&r, "launchAtLogin", json!(false)).unwrap();
        assert_eq!(r.module.state()["launchAtLogin"], false);
    }

    #[test]
    fn module_switches_and_the_shelf_choices_write_through() {
        let r = rig();
        for (key, read) in [
            ("musicEnabled", (|p: &Preferences| p.music_enabled()) as fn(&Preferences) -> bool),
            ("teleprompterEnabled", |p| p.teleprompter_enabled()),
            ("shelfEnabled", |p| p.shelf_enabled()),
            ("shelfTakesClipboardImages", |p| p.shelf_takes_clipboard_images()),
            ("shelfKeepsText", |p| p.shelf_keeps_text()),
            ("dictationEnabled", |p| p.dictation_enabled()),
            ("dictationKeepsHistory", |p| p.dictation_keeps_history()),
            ("showsKapa", |p| p.shows_kapa()),
            ("playsSounds", |p| p.plays_sounds()),
            ("keepsDiagnosticLog", |p| p.keeps_diagnostic_log()),
        ] {
            set(&r, key, json!(true)).unwrap();
            assert!(read(&r.prefs), "{key} on");
            set(&r, key, json!(false)).unwrap();
            assert!(!read(&r.prefs), "{key} off");
        }
        assert!(set(&r, "musicEnabled", json!("yes")).is_err(), "a switch takes a bool");
        set(&r, "clippingsExpire", json!(false)).unwrap();
        assert!(!r.prefs.clippings_expire());
        set(&r, "clipboardExcludedApplications", json!(["org.keepassxc.KeePassXC", "firefox"])).unwrap();
        assert_eq!(r.prefs.clipboard_excluded_applications(), ["org.keepassxc.KeePassXC", "firefox"]);
        assert!(set(&r, "clipboardExcludedApplications", json!("not a list")).is_err());
        assert!(set(&r, "nonsense", json!(1)).is_err());
    }

    #[test]
    fn the_script_keeps_one_step_back_and_the_speed_moves_in_quarters_within_bounds() {
        let r = rig();
        call(&r, "replaceScript", json!({"text": "first"})).unwrap();
        call(&r, "replaceScript", json!({"text": "second"})).unwrap();
        assert_eq!(r.module.state()["teleprompter"]["script"], "second");
        assert_eq!(r.module.state()["teleprompter"]["hasPreviousScript"], true);
        call(&r, "restorePreviousScript", Value::Null).unwrap();
        assert_eq!(r.prefs.script(), "first");
        call(&r, "restorePreviousScript", Value::Null).unwrap();
        assert_eq!(r.prefs.script(), "second", "a second restore undoes the first");

        call(&r, "faster", Value::Null).unwrap();
        assert_eq!(r.prefs.teleprompter_multiplier(), 1.25);
        for _ in 0..10 {
            call(&r, "faster", Value::Null).unwrap();
        }
        assert_eq!(r.prefs.teleprompter_multiplier(), 2.0);
        for _ in 0..10 {
            call(&r, "slower", Value::Null).unwrap();
        }
        assert_eq!(r.prefs.teleprompter_multiplier(), 0.5);
    }

    #[test]
    fn the_script_is_counted_and_timed_as_the_surface_does() {
        let r = rig();
        set(&r, "script", json!("one two three — four")).unwrap();
        let t = &r.module.state()["teleprompter"];
        assert_eq!(t["wordCount"], 4, "a dash alone is not a word");
        assert_eq!(t["minutes"], 1, "a minute at least for anything at all");
    }

    #[test]
    fn a_recorded_shortcut_needs_control_alt_or_the_system_key_and_a_refusal_changes_nothing() {
        let r = rig();
        let event = |code: &str, key: &str, ctrl: bool, alt: bool| json!({"code": code, "key": key, "ctrl": ctrl, "alt": alt});
        call(&r, "setShortcut", json!({"target": "dictation", "event": event("KeyG", "g", true, true)})).unwrap();
        assert_eq!(r.prefs.dictation_shortcut().key_label, "G");
        let before = r.prefs.dictation_shortcut();
        assert!(call(&r, "setShortcut", json!({"target": "dictation", "event": event("KeyH", "h", false, false)})).is_err());
        assert_eq!(r.prefs.dictation_shortcut(), before);

        call(&r, "setShortcut", json!({"target": "teleprompter.faster", "event": event("KeyF", "f", true, true)})).unwrap();
        assert_eq!(r.prefs.teleprompter_shortcut(TeleprompterAction::Faster).unwrap().key_label, "F");
        assert!(call(&r, "setShortcut", json!({"target": "teleprompter.sideways", "event": event("KeyF", "f", true, true)})).is_err());
        let shown = &r.module.state()["teleprompter"]["shortcuts"]["faster"];
        assert_eq!(shown["display"], "Ctrl+Alt+F");
        assert_eq!(shown["caps"], json!(["Ctrl", "Alt", "F"]));

        // A key that is itself "+": one cap for it, not two empty ones.
        call(&r, "setShortcut", json!({"target": "teleprompter.faster", "event": event("Equal", "+", true, false)})).unwrap();
        let shown = &r.module.state()["teleprompter"]["shortcuts"]["faster"];
        let label = r.prefs.teleprompter_shortcut(TeleprompterAction::Faster).unwrap().key_label;
        assert_eq!(shown["caps"], json!(["Ctrl", label]));
    }

    #[test]
    fn dictation_history_entries_go_one_at_a_time_or_all_at_once() {
        let r = rig();
        let mut history = DictationHistory::new();
        let now = chrono::Utc::now();
        history.append("one", true, now);
        history.append("two", true, now);
        r.prefs.set_dictation_history(&history);
        let first = r.prefs.dictation_history().entries()[0].id;
        call(&r, "deleteHistoryEntry", json!({"id": first})).unwrap();
        assert_eq!(r.prefs.dictation_history().entries().len(), 1);
        call(&r, "clearHistory", Value::Null).unwrap();
        assert!(r.prefs.dictation_history().entries().is_empty());
    }

    #[test]
    fn dictation_replacements_are_a_list_the_page_edits_whole() {
        let r = rig();
        let rules = json!([{"id": 1, "heard": "гит", "replacement": "Git", "enabled": true}]);
        set(&r, "dictationReplacements", rules).unwrap();
        assert_eq!(r.prefs.dictation_replacements().len(), 1);
        assert_eq!(r.module.state()["dictation"]["replacements"][0]["heard"], "гит");
        assert!(set(&r, "dictationReplacements", json!([{"nope": 1}])).is_err());
    }

    #[test]
    fn finishing_onboarding_is_remembered_and_heard_and_running_it_again_unfinishes_it() {
        let r = rig();
        assert_eq!(r.module.state()["onboarding"]["needed"], true);
        call(&r, "finishOnboarding", Value::Null).unwrap();
        assert!(r.prefs.has_finished_onboarding());
        assert_eq!(r.module.state()["onboarding"]["needed"], false);
        assert_eq!(*r.sounds.lock().unwrap(), [SoundCue::OnboardingFinished]);
        assert_eq!(*r.events.lock().unwrap(), [("settings".to_owned(), "onboardingFinished".to_owned())]);
        call(&r, "restartOnboarding", Value::Null).unwrap();
        assert_eq!(r.events.lock().unwrap().last().unwrap(), &("settings".to_owned(), "openOnboarding".to_owned()));
        assert!(!r.prefs.has_finished_onboarding(), "the first run is unfinished again, as `startOnboarding(force: true)` leaves it");
    }

    #[test]
    fn a_deliberate_connect_ends_the_first_run_but_codexs_default_does_not() {
        let r = rig();
        assert!(r.prefs.connects_at_launch(Provider::Codex), "Codex is on by default");
        assert_eq!(r.module.state()["onboarding"]["needed"], true);
        call(&r, "setProvider", json!({"provider": "codex", "on": true})).unwrap();
        assert_eq!(r.module.state()["onboarding"]["needed"], false, "a person chose it");
    }

    #[test]
    fn a_change_tells_the_hub_and_a_question_does_not() {
        let r = rig();
        set(&r, "showsKapa", json!(false)).unwrap();
        assert_eq!(r.notified.load(Ordering::SeqCst), 1);
        call(&r, "checkForUpdates", Value::Null).unwrap();
        call(&r, "diagnosticsInfo", Value::Null).unwrap();
        assert_eq!(r.notified.load(Ordering::SeqCst), 1);
        assert!(set(&r, "nonsense", json!(1)).is_err());
        assert_eq!(r.notified.load(Ordering::SeqCst), 1, "a refusal is not a change");
    }

    #[test]
    fn updates_open_the_latest_release_and_the_log_path_is_where_the_log_is() {
        let r = rig();
        assert_eq!(call(&r, "checkForUpdates", Value::Null).unwrap()["url"], Releases::LATEST);
        let info = call(&r, "diagnosticsInfo", Value::Null).unwrap();
        assert_eq!(info["logPath"], r.module.log_path().display().to_string());
        assert_eq!(info["keepsLog"], false);
    }

    #[test]
    fn the_state_is_complete_json_the_page_can_bind_to() {
        let r = rig();
        let state = r.module.state();
        for key in [
            "version", "platform", "language", "appearance", "launchAtLogin", "displayId", "screenSharingAllowed",
            "showsKapa", "playsSounds", "providers", "compactWindow", "backgroundRefreshSeconds", "alertsEnabled",
            "alertsFor", "keepsDiagnosticLog", "logPath", "music", "teleprompter", "shelf", "dictation",
            "consent", "onboarding", "choices",
        ] {
            assert!(state.get(key).is_some(), "{key}");
        }
        assert_eq!(state["version"], VERSION);
        assert_eq!(state["choices"]["refresh"], json!([60.0, 300.0, 900.0]));
        assert_eq!(state["teleprompter"]["shortcuts"]["startOrPause"]["display"], "Ctrl+Alt+Space");
        assert_eq!(state["dictation"]["shortcut"]["display"], "Ctrl+Alt+D");
    }

    /// What the page's tests read: the state the module publishes (for a person who has
    /// touched nothing, and for one who has turned everything on), the commands and keys
    /// it answers, and the Russian table. Written from here so the page cannot drift:
    /// `SETTINGS_WRITE_FIXTURE=1 cargo test -p capa-settings fixture` writes it; without
    /// the variable the test fails if the file is not what this code says.
    #[test]
    fn the_fixture_the_pages_tests_read_is_what_the_module_says() {
        let r = rig();
        let quiet = r.module.state();
        for key in ["musicEnabled", "teleprompterEnabled", "shelfEnabled", "dictationEnabled", "alertsEnabled",
            "shelfTakesClipboardImages", "shelfKeepsText", "dictationKeepsHistory"] {
            set(&r, key, json!(true)).unwrap();
        }
        r.module.give_consent(Provider::ClaudeCode);
        r.module.give_consent(Provider::OpenCode);
        call(&r, "replaceScript", json!({"text": "Good evening. This is the Script."})).unwrap();
        call(&r, "replaceScript", json!({"text": "Good evening. This is the new Script."})).unwrap();
        set(&r, "clipboardExcludedApplications", json!(["org.keepassxc.KeePassXC"])).unwrap();
        let busy = r.module.state();
        loc::set_current(LocLanguage::English);
        let fixture = json!({
            "quiet": quiet,
            "busy": busy,
            "commands": COMMANDS,
            "keys": KEYS,
            "dictionaryRu": serde_json::from_str::<Value>(&loc::dictionary_json(LocLanguage::Russian)).unwrap(),
        });
        let text = serde_json::to_string_pretty(&fixture).unwrap() + "\n";
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../js/settings/fixtures/state.json");
        if std::env::var_os("SETTINGS_WRITE_FIXTURE").is_some() {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, &text).unwrap();
        } else {
            // The version and the log path vary by machine and are left out of the comparison.
            let on_disk: Value = serde_json::from_str(&std::fs::read_to_string(&path).expect("fixture missing")).unwrap();
            let mut ours = fixture.clone();
            for v in [&mut ours, &mut on_disk.clone()] {
                for which in ["quiet", "busy"] {
                    v[which].as_object_mut().unwrap().remove("logPath");
                }
            }
            let mut theirs = on_disk;
            for which in ["quiet", "busy"] {
                theirs[which].as_object_mut().unwrap().remove("logPath");
            }
            assert_eq!(ours, theirs, "the fixture is stale: SETTINGS_WRITE_FIXTURE=1 cargo test -p capa-settings fixture");
        }
    }

    #[test]
    fn every_command_and_every_key_listed_is_one_the_module_answers() {
        let r = rig();
        for command in COMMANDS {
            let answer = r.module.handle(command, json!({}));
            // A command may refuse the empty arguments, but never as an unknown command.
            if let Err(e) = answer {
                assert!(!e.contains("has no command"), "{command}: {e}");
            }
        }
        for key in KEYS {
            let key = if key.ends_with('.') { format!("{key}codex") } else { (*key).to_owned() };
            let answer = r.module.set(&key, Value::Null);
            if let Err(e) = answer {
                assert!(!e.contains("no such choice"), "{key}: {e}");
            }
        }
    }
}
