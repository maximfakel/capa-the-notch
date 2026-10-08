//! Every choice a person has made, in one place.
//!
//! Settings and onboarding write here and the application reads here, so a
//! choice made in either is the same choice. Nothing is enabled on anyone's
//! behalf: each default is the quiet one, except connecting a Provider the
//! person already installed, which is the whole point of the surface.
//!
//! The keys are the Swift `UserDefaults` keys, word for word, so a settings
//! file can be read by either application.

use super::keyshortcut::{KeyShortcut, Modifiers};
use super::store::KeyValueStore;
use super::values::*;
use crate::dictation::{DictationHistory, DictationReplacement};
use crate::schedule::RefreshSchedule;
use crate::selection::{self, VISIBLE_LIMIT};
use crate::snapshot::Provider;
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::Arc;

/// Whether Kapa is drawn (ADR 0006). The one default that is on: it asks for
/// nothing and reads nothing new.
pub const KAPA_KEY: &str = "showsKapa";
pub const KAPA_DEFAULT: bool = true;

/// Whether sounds play (ADR 0007): on, with one switch to turn them off.
pub const SOUND_KEY: &str = "playsSounds";
pub const SOUND_DEFAULT: bool = true;

/// The paces a person can choose for a closed surface, in seconds.
pub const REFRESH_CHOICES: [f64; 3] = [60.0, 300.0, 900.0];

#[derive(Clone)]
pub struct Preferences {
    store: Arc<dyn KeyValueStore>,
}

impl Preferences {
    pub fn new(store: Arc<dyn KeyValueStore>) -> Self {
        Self { store }
    }

    // MARK: - Reading the store the way `UserDefaults` answers

    /// `bool(forKey:)`: false for anything missing or not a bool.
    fn bool(&self, key: &str) -> bool {
        self.store.get(key).and_then(|v| v.as_bool()).unwrap_or(false)
    }

    fn bool_or(&self, key: &str, default: bool) -> bool {
        self.store.get(key).and_then(|v| v.as_bool()).unwrap_or(default)
    }

    fn has(&self, key: &str) -> bool {
        self.store.get(key).is_some()
    }

    fn set_bool(&self, key: &str, value: bool) {
        self.store.set(key, Value::Bool(value));
    }

    /// `integer(forKey:)`: 0 for anything missing or not a number.
    fn integer(&self, key: &str) -> i64 {
        self.store
            .get(key)
            .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
            .unwrap_or(0)
    }

    /// `double(forKey:)`.
    fn double(&self, key: &str) -> f64 {
        self.store.get(key).and_then(|v| v.as_f64()).unwrap_or(0.0)
    }

    fn string(&self, key: &str) -> Option<String> {
        self.store.get(key).and_then(|v| v.as_str().map(str::to_owned))
    }

    fn set_string(&self, key: &str, value: Option<&str>) {
        match value {
            Some(v) => self.store.set(key, Value::String(v.to_owned())),
            None => self.store.remove(key),
        }
    }

    fn decoded<T: DeserializeOwned>(&self, key: &str) -> Option<T> {
        self.store.get(key).and_then(|v| serde_json::from_value(v).ok())
    }

    fn encode<T: Serialize>(&self, key: &str, value: &T) {
        if let Ok(v) = serde_json::to_value(value) {
            self.store.set(key, v);
        }
    }

    // MARK: - Kapa and sounds

    pub fn shows_kapa(&self) -> bool {
        self.bool_or(KAPA_KEY, KAPA_DEFAULT)
    }
    pub fn set_shows_kapa(&self, on: bool) {
        self.set_bool(KAPA_KEY, on);
    }

    pub fn plays_sounds(&self) -> bool {
        self.bool_or(SOUND_KEY, SOUND_DEFAULT)
    }
    pub fn set_plays_sounds(&self, on: bool) {
        self.set_bool(SOUND_KEY, on);
    }

    // MARK: - Providers

    fn connect_key(provider: Provider) -> String {
        format!("connectsAtLaunch.{}", provider_raw(provider))
    }

    /// Chosen on purpose, or — never chosen — Codex, which needs nothing from
    /// the person. Claude Code is asked for once and explained first.
    fn chosen(&self, provider: Provider) -> bool {
        let key = Self::connect_key(provider);
        if !self.has(&key) {
            return provider == Provider::Codex;
        }
        self.bool(&key)
    }

    /// The Providers to be read, in surface order, two at most: a third chosen
    /// somewhere this rule was not kept is read as off.
    pub fn connected_providers(&self) -> Vec<Provider> {
        selection::to_connect(Provider::ALL.into_iter().filter(|p| self.chosen(*p)), VISIBLE_LIMIT)
    }

    /// Whether this Provider is read without being asked for.
    pub fn connects_at_launch(&self, provider: Provider) -> bool {
        self.connected_providers().contains(&provider)
    }

    /// Whether this Provider may be turned on beside those already on.
    pub fn can_connect(&self, provider: Provider) -> bool {
        let on: HashSet<_> = self.connected_providers().into_iter().collect();
        selection::can_turn_on(provider, &on, VISIBLE_LIMIT)
    }

    /// Remembers a deliberate Connect or Disconnect, so it outlives the launch
    /// it was made in. A Connect past the two-at-most rule is refused.
    pub fn set_connects_at_launch(&self, provider: Provider, connects: bool) -> bool {
        if connects && !self.can_connect(provider) {
            return false;
        }
        self.set_bool(&Self::connect_key(provider), connects);
        true
    }

    // MARK: - The surface

    pub fn preferred_display_id(&self) -> Option<u32> {
        let stored = self.integer("preferredDisplayID");
        (stored > 0).then_some(stored as u32)
    }
    pub fn set_preferred_display_id(&self, id: Option<u32>) {
        match id {
            Some(id) => self.store.set("preferredDisplayID", json!(id)),
            None => self.store.remove("preferredDisplayID"),
        }
    }

    /// Off by default: Capacity is the person's account standing, and a shared
    /// screen is the easiest way to show it to a room by accident.
    pub fn screen_sharing_allowed(&self) -> bool {
        self.bool("allowScreenSharing")
    }
    pub fn set_screen_sharing_allowed(&self, on: bool) {
        self.set_bool("allowScreenSharing", on);
    }

    // MARK: - Behaviour

    pub fn alerts_enabled(&self) -> bool {
        self.bool("alertsEnabled")
    }
    pub fn set_alerts_enabled(&self, on: bool) {
        self.set_bool("alertsEnabled", on);
    }

    fn alert_key(provider: Provider) -> String {
        format!("alertsEnabled.{}", provider_raw(provider))
    }

    /// Alerts can be silenced for one Provider without silencing the other. A
    /// Provider is heard only when both this and the global switch allow it.
    pub fn alerts_enabled_for(&self, provider: Provider) -> bool {
        if !self.alerts_enabled() {
            return false;
        }
        self.bool_or(&Self::alert_key(provider), true)
    }
    pub fn set_alerts_enabled_for(&self, provider: Provider, on: bool) {
        self.set_bool(&Self::alert_key(provider), on);
    }

    pub fn launch_at_login(&self) -> bool {
        self.bool("launchAtLogin")
    }
    pub fn set_launch_at_login(&self, on: bool) {
        self.set_bool("launchAtLogin", on);
    }

    /// How often a Provider is read while the surface is closed, in seconds.
    /// The open pace is not a choice: an open surface is being watched.
    pub fn background_refresh_seconds(&self) -> f64 {
        let stored = self.double("backgroundRefreshSeconds");
        if stored > 0.0 { stored } else { RefreshSchedule::STANDARD.while_compact.as_secs_f64() }
    }
    pub fn set_background_refresh_seconds(&self, seconds: f64) {
        self.store.set("backgroundRefreshSeconds", json!(seconds));
    }

    /// Whether the App Server's own output is kept for a bug report. Off by
    /// default; a diagnostic nobody asked for is a log nobody consented to.
    pub fn keeps_diagnostic_log(&self) -> bool {
        self.bool("keepsDiagnosticLog")
    }
    pub fn set_keeps_diagnostic_log(&self, on: bool) {
        self.set_bool("keepsDiagnosticLog", on);
    }

    /// Which window the closed strip shows for each Provider while both are on.
    pub fn compact_window(&self) -> CompactWindowChoice {
        self.string("compactWindow").and_then(|s| CompactWindowChoice::from_raw(&s)).unwrap_or_default()
    }
    pub fn set_compact_window(&self, choice: CompactWindowChoice) {
        self.set_string("compactWindow", Some(choice.raw()));
    }

    /// The language the interface speaks: the system's until chosen.
    pub fn language(&self) -> AppLanguage {
        self.string("language").and_then(|s| AppLanguage::from_raw(&s)).unwrap_or_default()
    }
    pub fn set_language(&self, language: AppLanguage) {
        self.set_string("language", Some(language.raw()));
    }

    /// Off until asked for, like every other default here: checking would be
    /// the application's first network request of its own.
    pub fn checks_for_updates(&self) -> bool {
        self.bool("checksForUpdates")
    }
    pub fn set_checks_for_updates(&self, on: bool) {
        self.set_bool("checksForUpdates", on);
    }

    // MARK: - Modules

    /// The Music Module. Off until asked for, like every Module but Capacity
    /// (ADR 0003): while off, nothing is read.
    pub fn music_enabled(&self) -> bool {
        self.bool("musicEnabled")
    }
    pub fn set_music_enabled(&self, on: bool) {
        self.set_bool("musicEnabled", on);
    }

    /// The Shelf Module. Off until asked for; what it holds is never stored,
    /// only whether it is on (ADR 0005).
    pub fn shelf_enabled(&self) -> bool {
        self.bool("shelfEnabled")
    }
    pub fn set_shelf_enabled(&self, on: bool) {
        self.set_bool("shelfEnabled", on);
    }

    /// Images copied to the clipboard land on the Shelf. Off until asked for:
    /// it means watching the clipboard (ADR 0005, amended). The key is the one
    /// it had when it took screenshots alone.
    pub fn shelf_takes_clipboard_images(&self) -> bool {
        self.bool("shelfTakesScreenshots")
    }
    pub fn set_shelf_takes_clipboard_images(&self, on: bool) {
        self.set_bool("shelfTakesScreenshots", on);
    }

    /// Text copied lands under the Shelf's Clipboard tab. Off until asked for,
    /// on its own switch.
    pub fn shelf_keeps_text(&self) -> bool {
        self.bool("shelfKeepsText")
    }
    pub fn set_shelf_keeps_text(&self, on: bool) {
        self.set_bool("shelfKeepsText", on);
    }

    /// How many Clippings are kept: 20 unless chosen.
    pub fn clipping_limit(&self) -> ClippingLimit {
        ClippingLimit::from_raw(self.integer("clippingLimit")).unwrap_or_default()
    }
    pub fn set_clipping_limit(&self, limit: ClippingLimit) {
        self.store.set("clippingLimit", json!(limit.raw()));
    }

    /// Each Clipping goes after a day, unless this is switched off. Stored
    /// the way it was first written: as the opposite.
    pub fn clippings_expire(&self) -> bool {
        !self.bool("clippingsKeptPastADay")
    }
    pub fn set_clippings_expire(&self, expire: bool) {
        self.set_bool("clippingsKeptPastADay", !expire);
    }

    /// Applications nothing is kept from while they are in front, chosen in
    /// Settings, by identifier (a bundle identifier on a Mac, on Linux an
    /// application id or `WM_CLASS`).
    pub fn clipboard_excluded_applications(&self) -> Vec<String> {
        self.decoded("clipboardExcludedApplications").unwrap_or_default()
    }
    pub fn set_clipboard_excluded_applications(&self, applications: &[String]) {
        self.encode("clipboardExcludedApplications", &applications);
    }

    /// The Teleprompter Module. Off until asked for (ADR 0003): while off, no
    /// shortcut is registered and nothing is shown.
    pub fn teleprompter_enabled(&self) -> bool {
        self.bool("teleprompterEnabled")
    }
    pub fn set_teleprompter_enabled(&self, on: bool) {
        self.set_bool("teleprompterEnabled", on);
    }

    /// The Script, kept on this machine. It never reaches diagnostics or a log.
    pub fn script(&self) -> String {
        self.string("teleprompterScript").unwrap_or_default()
    }
    pub fn set_script(&self, text: &str) {
        self.set_string("teleprompterScript", Some(text));
    }

    /// The Script before the last one given — one step back, no more.
    pub fn previous_script(&self) -> Option<String> {
        self.string("teleprompterPreviousScript")
    }

    /// Paste from Clipboard: the new Script replaces the current one, which is
    /// kept as the one before.
    pub fn replace_script(&self, text: &str) {
        let current = self.script();
        if text == current {
            return;
        }
        if !current.is_empty() {
            self.set_string("teleprompterPreviousScript", Some(&current));
        }
        self.set_script(text);
    }

    /// Restore Previous Script: the two trade places, so a second restore
    /// undoes the first.
    pub fn restore_previous_script(&self) {
        let Some(previous) = self.previous_script() else { return };
        let current = self.script();
        self.set_string("teleprompterPreviousScript", if current.is_empty() { None } else { Some(&current) });
        self.set_script(&previous);
    }

    /// The Teleprompter's speed, as last turned on the page or in Settings.
    pub fn teleprompter_multiplier(&self) -> f64 {
        let stored = self.double("teleprompterMultiplier");
        if stored > 0.0 { stored } else { 1.0 }
    }
    pub fn set_teleprompter_multiplier(&self, value: f64) {
        self.store.set("teleprompterMultiplier", json!(clamped_multiplier(value)));
    }

    pub fn teleprompter_text_size(&self) -> TeleprompterTextSize {
        self.string("teleprompterTextSize").and_then(|s| TeleprompterTextSize::from_raw(&s)).unwrap_or_default()
    }
    pub fn set_teleprompter_text_size(&self, size: TeleprompterTextSize) {
        self.set_string("teleprompterTextSize", Some(size.raw()));
    }

    fn shortcut_key(action: TeleprompterAction) -> String {
        format!("teleprompterShortcut.{}", action.raw())
    }

    /// The shortcut for an action: the standard one until recorded. A stored
    /// value that cannot be read is no shortcut at all, not the standard one.
    pub fn teleprompter_shortcut(&self, action: TeleprompterAction) -> Option<KeyShortcut> {
        let key = Self::shortcut_key(action);
        match self.store.get(&key) {
            None => Some(standard_teleprompter_shortcut(action)),
            Some(value) => serde_json::from_value(value).ok(),
        }
    }
    pub fn set_teleprompter_shortcut(&self, shortcut: &KeyShortcut, action: TeleprompterAction) {
        self.encode(&Self::shortcut_key(action), shortcut);
    }

    // MARK: - Windows

    pub fn appearance(&self) -> Appearance {
        self.string("appearance").and_then(|s| Appearance::from_raw(&s)).unwrap_or_default()
    }
    pub fn set_appearance(&self, appearance: Appearance) {
        self.set_string("appearance", Some(appearance.raw()));
    }

    // MARK: - Onboarding

    pub fn has_finished_onboarding(&self) -> bool {
        self.bool("hasFinishedOnboarding")
    }
    pub fn set_has_finished_onboarding(&self, done: bool) {
        self.set_bool("hasFinishedOnboarding", done);
    }

    /// Whether launch should open the first-run path.
    ///
    /// Not only until Continue is pressed: someone who connected a Provider —
    /// from onboarding, the menu or a card — and closed the window has been
    /// through the first run, and being welcomed again at every launch, with
    /// nothing read until they answer, is the opposite of help. Only a
    /// deliberate Connect counts; Codex's default does not.
    pub fn needs_onboarding(&self) -> bool {
        if self.has_finished_onboarding() {
            return false;
        }
        !Provider::ALL.into_iter().any(|p| {
            let key = Self::connect_key(p);
            self.has(&key) && self.bool(&key)
        })
    }

    pub fn claude_consent_given(&self) -> bool {
        self.bool("claudeCodeConsentGiven")
    }
    pub fn set_claude_consent_given(&self, given: bool) {
        self.set_bool("claudeCodeConsentGiven", given);
    }

    /// The person agreed that CapaTheNotch reads OpenCode's key from its own
    /// file to ask for its Go plan's usage (ADR 0001, amended).
    pub fn open_code_consent_given(&self) -> bool {
        self.bool("openCodeConsentGiven")
    }
    pub fn set_open_code_consent_given(&self, given: bool) {
        self.set_bool("openCodeConsentGiven", given);
    }

    /// Whether moving Claude Code's status-line bridge to the renamed
    /// application has been settled. macOS history; on other systems nothing
    /// ever needs moving, and this stays false.
    pub fn claude_bridge_move_settled(&self) -> bool {
        self.bool("claudeBridgeMoveSettled")
    }
    pub fn set_claude_bridge_move_settled(&self, settled: bool) {
        self.set_bool("claudeBridgeMoveSettled", settled);
    }

    // MARK: - Dictation

    pub fn dictation_enabled(&self) -> bool {
        self.bool("dictation.enabled")
    }
    pub fn set_dictation_enabled(&self, on: bool) {
        self.set_bool("dictation.enabled", on);
    }

    pub fn dictation_keeps_history(&self) -> bool {
        self.bool("dictation.keepsHistory")
    }
    pub fn set_dictation_keeps_history(&self, on: bool) {
        self.set_bool("dictation.keepsHistory", on);
    }

    pub fn dictation_shortcut(&self) -> KeyShortcut {
        self.decoded("dictation.shortcut").unwrap_or_else(default_dictation_shortcut)
    }
    pub fn set_dictation_shortcut(&self, shortcut: &KeyShortcut) {
        self.encode("dictation.shortcut", shortcut);
    }

    pub fn dictation_replacements(&self) -> Vec<DictationReplacement> {
        self.decoded("dictation.replacements").unwrap_or_else(DictationReplacement::defaults)
    }
    pub fn set_dictation_replacements(&self, replacements: &[DictationReplacement]) {
        self.encode("dictation.replacements", &replacements);
    }

    pub fn dictation_history(&self) -> DictationHistory {
        self.decoded("dictation.history").unwrap_or_default()
    }
    pub fn set_dictation_history(&self, history: &DictationHistory) {
        self.encode("dictation.history", history);
    }

    // MARK: - The hub's settings file

    /// The subset `linux/crates/hub/src/settings.rs` keeps — `connected`,
    /// `alertsEnabled`, `alertsSilencedFor` — written from these choices.
    pub fn to_hub_json(&self) -> Value {
        json!({
            "connected": self.connected_providers(),
            "alertsEnabled": self.alerts_enabled(),
            "alertsSilencedFor": self.alerts_silenced_for(),
        })
    }

    /// The Providers whose alerts the person silenced one by one, whatever the
    /// global switch says: what the hub's state and settings file both call `alertsSilencedFor`.
    pub fn alerts_silenced_for(&self) -> Vec<Provider> {
        Provider::ALL
            .into_iter()
            .filter(|p| self.has(&Self::alert_key(*p)) && !self.bool(&Self::alert_key(*p)))
            .collect()
    }

    /// Takes what the hub's file says as the choice, for a file written before
    /// these preferences existed. Fields it lacks are left as they are.
    pub fn import_hub_json(&self, json: &Value) {
        if let Some(connected) = json.get("connected").and_then(|v| serde_json::from_value::<Vec<Provider>>(v.clone()).ok()) {
            let on: HashSet<_> = selection::to_connect(connected, VISIBLE_LIMIT).into_iter().collect();
            for p in Provider::ALL {
                self.set_bool(&Self::connect_key(p), on.contains(&p));
            }
        }
        if let Some(enabled) = json.get("alertsEnabled").and_then(Value::as_bool) {
            self.set_alerts_enabled(enabled);
        }
        if let Some(silenced) = json
            .get("alertsSilencedFor")
            .and_then(|v| serde_json::from_value::<Vec<Provider>>(v.clone()).ok())
        {
            for p in Provider::ALL {
                self.set_alerts_enabled_for(p, !silenced.contains(&p));
            }
        }
    }
}

/// The word a Provider is stored under: Swift's raw value.
pub fn provider_raw(provider: Provider) -> &'static str {
    match provider {
        Provider::Codex => "codex",
        Provider::ClaudeCode => "claudeCode",
        Provider::OpenCode => "openCode",
    }
}

/// As drawn: Control-Option with Space, Escape and the up and down arrows.
pub fn standard_teleprompter_shortcut(action: TeleprompterAction) -> KeyShortcut {
    let modifiers = Modifiers::CONTROL.union(Modifiers::OPTION);
    match action {
        TeleprompterAction::StartOrPause => KeyShortcut::new(49, modifiers, "Space"),
        TeleprompterAction::Stop => KeyShortcut::new(53, modifiers, "Esc"),
        TeleprompterAction::Faster => KeyShortcut::new(126, modifiers, "↑"),
        TeleprompterAction::Slower => KeyShortcut::new(125, modifiers, "↓"),
    }
}

/// Hold Control-Option-D.
pub fn default_dictation_shortcut() -> KeyShortcut {
    KeyShortcut::new(2, Modifiers::CONTROL.union(Modifiers::OPTION), "D")
}
