use super::key::{KeyShortcut, TeleprompterAction, TeleprompterShortcuts};
use super::layout::{TeleprompterLayout, TextMeasure, TEXT_WIDTH};
use super::playback::{PlaybackState, PlaybackView, TeleprompterPlayback};
use super::script::{ScriptStore, TeleprompterScript, TeleprompterTextSize};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// The platform's global shortcuts: Carbon hot keys on the Mac, the global
/// shortcuts portal or the shell's keybindings on GNOME. Needs no
/// Accessibility access, which a keyboard monitor would.
pub trait HotKeys {
    /// False when the system will not have it — usually because something else
    /// already does. The platform calls `TeleprompterModel::hot_key_pressed`
    /// with the action when it fires, on the model's thread.
    fn register(&mut self, shortcut: &KeyShortcut, action: TeleprompterAction) -> bool;
    fn unregister_all(&mut self);
}

/// What is kept between runs: the Module's switch, the Script and the one
/// before it, the speed, the size, the shortcuts that are not the standard
/// ones. The Script never reaches diagnostics or a log.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeleprompterSettings {
    pub enabled: bool,
    pub script: String,
    pub previous_script: Option<String>,
    pub multiplier: f64,
    pub text_size: TeleprompterTextSize,
    /// Only the shortcuts a person changed; the rest are the standard ones.
    pub shortcuts: BTreeMap<TeleprompterAction, KeyShortcut>,
}

impl Default for TeleprompterSettings {
    /// Off until asked for (ADR 0003), at 1.00x, the mockup's size, the
    /// shortcuts as drawn.
    fn default() -> Self {
        Self {
            enabled: false,
            script: String::new(),
            previous_script: None,
            multiplier: 1.0,
            text_size: TeleprompterTextSize::Medium,
            shortcuts: BTreeMap::new(),
        }
    }
}

/// One shortcut as Settings shows it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutView {
    pub action: TeleprompterAction,
    pub title: String,
    pub keycaps: Vec<String>,
    pub display: String,
    /// The system would not register it, usually because something else holds it.
    pub unavailable: bool,
}

/// Everything a surface draws of the Teleprompter Module. Never the Script
/// itself beyond the lines the row shows.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeleprompterView {
    pub enabled: bool,
    /// The Teleprompter Row is in view: the Module on and the Script running,
    /// paused or just finished.
    pub showing_row: bool,
    pub text_size: TeleprompterTextSize,
    pub lines: Vec<String>,
    pub word_count: usize,
    pub minutes: usize,
    pub has_previous_script: bool,
    pub playback: PlaybackView,
    pub shortcuts: Vec<ShortcutView>,
}

/// The Teleprompter Module as the application runs it: the Script laid out
/// into lines for the row, the playback moving over them, and the global
/// shortcuts. Off, it registers nothing and shows nothing (ADR 0003).
///
/// Pure: time comes in as an argument, text is measured by the caller's
/// `TextMeasure`, shortcuts are registered through `HotKeys`. Whoever owns it
/// persists `settings()` whenever `take_dirty()` says so, and sets a timer for
/// `next_wake()`, calling `tick` when it fires.
#[derive(Debug, Clone)]
pub struct TeleprompterModel {
    enabled: bool,
    store: ScriptStore,
    text_size: TeleprompterTextSize,
    lines: Vec<String>,
    playback: TeleprompterPlayback,
    shortcuts: BTreeMap<TeleprompterAction, KeyShortcut>,
    unavailable: BTreeSet<TeleprompterAction>,
    /// What a host that binds the keys itself (the GNOME Shell) said it could
    /// not have, after the fact: `register` cannot know there.
    host_unavailable: BTreeSet<TeleprompterAction>,
    /// While Settings records a new shortcut, the old ones stand aside, or
    /// pressing one would work it rather than record it.
    suspended: bool,
    dirty: bool,
}

impl TeleprompterModel {
    pub fn new(settings: TeleprompterSettings, now: DateTime<Utc>, measure: &dyn TextMeasure) -> Self {
        let mut model = Self {
            enabled: settings.enabled,
            store: ScriptStore { script: settings.script, previous_script: settings.previous_script },
            text_size: settings.text_size,
            lines: vec![],
            playback: TeleprompterPlayback::new(0, 0, settings.multiplier),
            shortcuts: settings.shortcuts,
            unavailable: BTreeSet::new(),
            host_unavailable: BTreeSet::new(),
            suspended: false,
            dirty: false,
        };
        model.relayout(now, measure);
        model
    }

    pub fn settings(&self) -> TeleprompterSettings {
        TeleprompterSettings {
            enabled: self.enabled,
            script: self.store.script.clone(),
            previous_script: self.store.previous_script.clone(),
            multiplier: self.playback.multiplier(),
            text_size: self.text_size,
            shortcuts: self.shortcuts.clone(),
        }
    }

    /// Whether something changed that `settings()` should be saved for.
    pub fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn script(&self) -> &str {
        &self.store.script
    }

    pub fn lines(&self) -> &[String] {
        &self.lines
    }

    pub fn text_size(&self) -> TeleprompterTextSize {
        self.text_size
    }

    pub fn set_multiplier(&mut self, value: f64, now: DateTime<Utc>) {
        self.playback.set_multiplier(value, now);
    }

    pub fn playback(&self) -> &TeleprompterPlayback {
        &self.playback
    }

    pub fn word_count(&self) -> usize {
        self.playback.word_count()
    }

    /// Whether the Teleprompter Row is in view: the Module on and the Script
    /// running, paused or just finished.
    pub fn is_showing_row(&self) -> bool {
        self.enabled && self.playback.is_showing()
    }

    pub fn has_previous_script(&self) -> bool {
        self.store.has_previous()
    }

    /// The shortcuts the system would not have (`unavailableShortcuts`, shown
    /// in Settings): refused at registration, or reported by the host.
    pub fn unavailable_shortcuts(&self) -> BTreeSet<TeleprompterAction> {
        self.unavailable.union(&self.host_unavailable).copied().collect()
    }

    /// The host that binds the keys says which of them it could not have
    /// (`teleprompter.keysUnavailable`). Off, there is nothing bound to report.
    pub fn set_host_unavailable(&mut self, actions: BTreeSet<TeleprompterAction>) {
        self.host_unavailable = if self.enabled { actions } else { BTreeSet::new() };
    }

    /// Quiet while a Script is read aloud (ADR 0007): on, and running.
    pub fn wants_quiet(&self) -> bool {
        self.enabled && self.playback.state() == PlaybackState::Running
    }

    // MARK: - The Module

    pub fn set_enabled(&mut self, enabled: bool, hot_keys: &mut dyn HotKeys) {
        if enabled == self.enabled {
            return;
        }
        self.dirty = true;
        if enabled {
            self.enabled = true;
            self.register_shortcuts(hot_keys);
        } else {
            // Stopped before it is off: off, nothing runs — not even the timer
            // waiting for the Script's end (ADR 0003).
            self.playback.stop();
            self.enabled = false;
            hot_keys.unregister_all();
            self.unavailable.clear();
            self.host_unavailable.clear();
        }
    }

    /// The Module was already on when the application started: register what
    /// it needs.
    pub fn start(&mut self, hot_keys: &mut dyn HotKeys) {
        if self.enabled {
            self.register_shortcuts(hot_keys);
        }
    }

    // MARK: - The Script

    /// Typing in Settings changes the Script itself; only Paste keeps the one
    /// before.
    pub fn edit(&mut self, text: &str, now: DateTime<Utc>, measure: &dyn TextMeasure) {
        if text == self.store.script {
            return;
        }
        self.store.script = text.to_owned();
        self.dirty = true;
        self.relayout(now, measure);
    }

    /// The clipboard's text, read by the caller now and only now. Blank text is
    /// not a Script.
    pub fn paste(&mut self, clipboard: &str, now: DateTime<Utc>, measure: &dyn TextMeasure) {
        if clipboard.trim().is_empty() {
            return;
        }
        self.store.replace_script(clipboard);
        self.script_changed(now, measure);
    }

    pub fn restore_previous_script(&mut self, now: DateTime<Utc>, measure: &dyn TextMeasure) {
        self.store.restore_previous_script();
        self.script_changed(now, measure);
    }

    fn script_changed(&mut self, now: DateTime<Utc>, measure: &dyn TextMeasure) {
        self.dirty = true;
        self.playback.stop();
        self.relayout(now, measure);
    }

    pub fn set_text_size(&mut self, size: TeleprompterTextSize, now: DateTime<Utc>, measure: &dyn TextMeasure) {
        self.text_size = size;
        self.dirty = true;
        self.relayout(now, measure);
    }

    /// Lay the Script out again — after a size, a Script, or a surface that has
    /// found the type's real widths.
    pub fn relayout(&mut self, now: DateTime<Utc>, measure: &dyn TextMeasure) {
        self.lines = TeleprompterLayout::lines(&self.store.script, self.text_size, TEXT_WIDTH, measure);
        self.playback.relayout(TeleprompterScript::word_count(&self.store.script), self.lines.len(), now);
    }

    // MARK: - Playback

    pub fn toggle(&mut self, now: DateTime<Utc>) {
        self.change(|p| p.toggle(now));
    }

    pub fn stop(&mut self) {
        self.change(|p| p.stop());
    }

    pub fn faster(&mut self, now: DateTime<Utc>) {
        self.change(|p| p.faster(now));
    }

    pub fn slower(&mut self, now: DateTime<Utc>) {
        self.change(|p| p.slower(now));
    }

    pub fn seek_to_fraction(&mut self, fraction: f64, now: DateTime<Utc>) {
        self.change(|p| p.seek_to_fraction(fraction, now));
    }

    pub fn move_by_lines(&mut self, lines: f64, now: DateTime<Utc>) {
        self.change(|p| p.move_by_lines(lines, now));
    }

    fn change(&mut self, body: impl FnOnce(&mut TeleprompterPlayback)) {
        if !self.enabled {
            return;
        }
        let speed = self.playback.multiplier();
        body(&mut self.playback);
        if self.playback.multiplier() != speed {
            self.dirty = true;
        }
    }

    /// When to wake next: the Script reaches its end, or its row leaves;
    /// nothing ticks in between — the row's motion is the surface's.
    pub fn next_wake(&self) -> Option<DateTime<Utc>> {
        self.playback.next_wake()
    }

    /// The timer fired.
    pub fn tick(&mut self, now: DateTime<Utc>) {
        self.playback.advance(now);
    }

    pub fn view(&self, now: DateTime<Utc>) -> TeleprompterView {
        TeleprompterView {
            enabled: self.enabled,
            showing_row: self.is_showing_row(),
            text_size: self.text_size,
            lines: self.lines.clone(),
            word_count: self.word_count(),
            minutes: TeleprompterScript::minutes(self.word_count(), self.playback.words_per_minute()),
            has_previous_script: self.has_previous_script(),
            playback: self.playback.view(now),
            shortcuts: TeleprompterAction::ALL
                .into_iter()
                .filter_map(|action| {
                    let shortcut = self.shortcut_for(action)?;
                    Some(ShortcutView {
                        action,
                        title: action.title().into(),
                        keycaps: shortcut.keycaps(),
                        display: shortcut.display(),
                        unavailable: self.unavailable.contains(&action) || self.host_unavailable.contains(&action),
                    })
                })
                .collect(),
        }
    }

    // MARK: - Shortcuts

    /// The shortcut for an action: the one chosen, or the standard one.
    pub fn shortcut_for(&self, action: TeleprompterAction) -> Option<KeyShortcut> {
        Some(self.shortcuts.get(&action).cloned().unwrap_or_else(|| TeleprompterShortcuts::standard(action)))
    }

    /// A shortcut already given to another of the four trades places with it:
    /// one key, one action.
    pub fn set_shortcut(&mut self, shortcut: KeyShortcut, action: TeleprompterAction, hot_keys: &mut dyn HotKeys) {
        let other = TeleprompterAction::ALL.into_iter().find(|&other| {
            other != action && self.shortcut_for(other).is_some_and(|s| shortcut.same_keys(&s))
        });
        if let (Some(other), Some(previous)) = (other, self.shortcut_for(action)) {
            self.shortcuts.insert(other, previous);
        }
        self.shortcuts.insert(action, shortcut);
        self.dirty = true;
        if self.enabled {
            self.register_shortcuts(hot_keys);
        }
    }

    pub fn suspend_shortcuts(&mut self, suspended: bool, hot_keys: &mut dyn HotKeys) {
        self.suspended = suspended;
        if !self.enabled {
            return;
        }
        if suspended {
            hot_keys.unregister_all();
        } else {
            self.register_shortcuts(hot_keys);
        }
    }

    pub fn register_shortcuts(&mut self, hot_keys: &mut dyn HotKeys) {
        hot_keys.unregister_all();
        self.unavailable.clear();
        if self.suspended || !self.enabled {
            return;
        }
        for action in TeleprompterAction::ALL {
            let Some(shortcut) = self.shortcut_for(action) else { continue };
            if !hot_keys.register(&shortcut, action) {
                self.unavailable.insert(action);
            }
        }
    }

    /// A registered shortcut was pressed.
    pub fn hot_key_pressed(&mut self, action: TeleprompterAction, now: DateTime<Utc>) {
        match action {
            TeleprompterAction::StartOrPause => self.toggle(now),
            TeleprompterAction::Stop => self.stop(),
            TeleprompterAction::Faster => self.faster(now),
            TeleprompterAction::Slower => self.slower(now),
        }
    }

    /// A spoken state for screen readers.
    pub fn spoken(&self) -> &'static str {
        self.playback.state().spoken()
    }

    pub fn state(&self) -> PlaybackState {
        self.playback.state()
    }
}

#[cfg(test)]
mod tests {
    use super::super::key::Modifiers;
    use super::super::layout::ApproximateMeasure;
    use super::*;
    use chrono::{Duration, TimeZone};

    fn t0() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    #[derive(Default)]
    struct Keys {
        registered: Vec<(KeyShortcut, TeleprompterAction)>,
        refuse: Vec<TeleprompterAction>,
        cleared: u32,
    }

    impl HotKeys for Keys {
        fn register(&mut self, shortcut: &KeyShortcut, action: TeleprompterAction) -> bool {
            if self.refuse.contains(&action) {
                return false;
            }
            self.registered.push((shortcut.clone(), action));
            true
        }
        fn unregister_all(&mut self) {
            self.registered.clear();
            self.cleared += 1;
        }
    }

    const SCRIPT: &str = "Добрый день. Сегодня я покажу, как CapaTheNotch держит лимиты Claude и Codex прямо у камеры, и почему это удобнее, чем вкладка со счётчиком, открытая весь день.\n\nСначала — как выглядит полоса. Потом — что происходит, когда лимит подходит к концу.";

    fn model(enabled: bool) -> (TeleprompterModel, Keys) {
        let mut keys = Keys::default();
        let mut m = TeleprompterModel::new(
            TeleprompterSettings { enabled, script: SCRIPT.into(), ..Default::default() },
            t0(),
            &ApproximateMeasure,
        );
        m.start(&mut keys);
        (m, keys)
    }

    #[test]
    fn it_is_off_with_quiet_defaults_and_registers_nothing() {
        let d = TeleprompterSettings::default();
        assert!(!d.enabled, "off until turned on (ADR 0003)");
        assert_eq!(d.multiplier, 1.0);
        assert_eq!(d.text_size, TeleprompterTextSize::Medium, "the mockup's size");
        let (m, keys) = model(false);
        assert!(keys.registered.is_empty() && !m.is_showing_row());
        assert_eq!(m.shortcut_for(TeleprompterAction::StartOrPause).unwrap().display(), "⌃⌥Space", "the shortcuts start as drawn");
    }

    #[test]
    fn it_lays_the_script_out_and_counts_its_words() {
        let (m, _) = model(true);
        assert!(m.lines().len() > 3, "{:?}", m.lines());
        assert!(m.lines().contains(&String::new()), "the blank line stays a gap");
        assert_eq!(m.word_count(), TeleprompterScript::word_count(SCRIPT));
    }

    #[test]
    fn turning_it_on_registers_the_four_shortcuts_and_off_clears_them() {
        let (mut m, mut keys) = model(false);
        m.set_enabled(true, &mut keys);
        assert_eq!(keys.registered.len(), 4);
        assert!(m.take_dirty(), "the switch is a setting");
        m.toggle(t0());
        assert!(m.is_showing_row());
        m.set_enabled(false, &mut keys);
        assert!(keys.registered.is_empty(), "off, no shortcuts");
        assert!(!m.is_showing_row(), "stopped before it is off");
        assert_eq!(m.next_wake(), None, "not even the timer waiting for the Script's end");
        assert!(m.unavailable_shortcuts().is_empty());
    }

    #[test]
    fn a_shortcut_the_system_refuses_is_marked_unavailable() {
        let mut keys = Keys { refuse: vec![TeleprompterAction::Stop], ..Keys::default() };
        let mut m = TeleprompterModel::new(TeleprompterSettings { enabled: true, ..Default::default() }, t0(), &ApproximateMeasure);
        m.start(&mut keys);
        assert!(m.unavailable_shortcuts().contains(&TeleprompterAction::Stop));
        assert_eq!(keys.registered.len(), 3);
        let view = m.view(t0());
        assert!(view.shortcuts.iter().find(|s| s.action == TeleprompterAction::Stop).unwrap().unavailable);
    }

    #[test]
    fn a_shortcut_the_host_could_not_bind_is_marked_unavailable_until_it_says_otherwise() {
        let (mut m, _) = model(true);
        m.set_host_unavailable([TeleprompterAction::Faster, TeleprompterAction::Slower].into());
        let view = m.view(t0());
        let marked: Vec<_> = view.shortcuts.iter().filter(|s| s.unavailable).map(|s| s.action).collect();
        assert_eq!(marked, [TeleprompterAction::Faster, TeleprompterAction::Slower]);
        assert_eq!(m.unavailable_shortcuts().len(), 2);
        m.set_host_unavailable(BTreeSet::new());
        assert!(m.unavailable_shortcuts().is_empty());

        m.set_host_unavailable([TeleprompterAction::Stop].into());
        let mut keys = Keys::default();
        m.set_enabled(false, &mut keys);
        assert!(m.unavailable_shortcuts().is_empty(), "off, nothing is unavailable");
        m.set_host_unavailable([TeleprompterAction::Stop].into());
        assert!(m.unavailable_shortcuts().is_empty(), "and nothing can be reported");
    }

    #[test]
    fn it_wants_quiet_only_while_on_and_running() {
        let (mut m, mut keys) = model(true);
        assert!(!m.wants_quiet());
        m.toggle(t0());
        assert!(m.wants_quiet());
        m.toggle(t0());
        assert!(!m.wants_quiet(), "paused");
        m.toggle(t0());
        m.set_enabled(false, &mut keys);
        assert!(!m.wants_quiet(), "off");
    }

    #[test]
    fn a_shortcut_given_to_another_trades_places_with_it() {
        let (mut m, mut keys) = model(true);
        let faster = m.shortcut_for(TeleprompterAction::Faster).unwrap();
        let stop_before = m.shortcut_for(TeleprompterAction::Stop).unwrap();
        m.set_shortcut(faster.clone(), TeleprompterAction::Stop, &mut keys);
        assert_eq!(m.shortcut_for(TeleprompterAction::Stop).unwrap(), faster, "stop has faster's keys");
        assert_eq!(m.shortcut_for(TeleprompterAction::Faster).unwrap(), stop_before, "and faster has stop's: one key, one action");
        assert_eq!(keys.registered.len(), 4, "registered again");
        assert!(m.take_dirty());
        assert_eq!(m.settings().shortcuts.len(), 2, "only the two that changed are kept");
    }

    #[test]
    fn a_shortcut_is_remembered_and_spelled() {
        let (mut m, mut keys) = model(true);
        let shortcut = KeyShortcut::new(35, Modifiers::CONTROL | Modifiers::COMMAND, "P");
        m.set_shortcut(shortcut.clone(), TeleprompterAction::Stop, &mut keys);
        assert_eq!(m.shortcut_for(TeleprompterAction::Stop).unwrap(), shortcut);
        assert_eq!(shortcut.display(), "⌃⌘P");
        let kept = TeleprompterModel::new(m.settings(), t0(), &ApproximateMeasure);
        assert_eq!(kept.shortcut_for(TeleprompterAction::Stop).unwrap(), shortcut);
    }

    #[test]
    fn while_a_shortcut_is_recorded_the_old_ones_stand_aside() {
        let (mut m, mut keys) = model(true);
        m.suspend_shortcuts(true, &mut keys);
        assert!(keys.registered.is_empty());
        m.suspend_shortcuts(false, &mut keys);
        assert_eq!(keys.registered.len(), 4);
        let (mut off, mut off_keys) = model(false);
        off.suspend_shortcuts(false, &mut off_keys);
        assert!(off_keys.registered.is_empty(), "off, nothing comes back");
    }

    #[test]
    fn a_pressed_shortcut_works_the_playback() {
        let (mut m, _) = model(true);
        m.hot_key_pressed(TeleprompterAction::StartOrPause, t0());
        assert_eq!(m.state(), PlaybackState::Running);
        m.hot_key_pressed(TeleprompterAction::Faster, t0());
        assert_eq!(m.playback().multiplier(), 1.25);
        assert!(m.take_dirty(), "the speed is a setting");
        m.hot_key_pressed(TeleprompterAction::Slower, t0());
        m.hot_key_pressed(TeleprompterAction::Stop, t0());
        assert_eq!(m.state(), PlaybackState::Stopped);
    }

    #[test]
    fn controls_do_nothing_while_the_module_is_off() {
        let (mut m, _) = model(false);
        m.toggle(t0());
        m.faster(t0());
        assert_eq!(m.state(), PlaybackState::Stopped);
        assert_eq!(m.playback().multiplier(), 1.0);
        assert!(!m.take_dirty());
    }

    #[test]
    fn the_speed_is_dirty_only_when_it_changed() {
        let (mut m, _) = model(true);
        m.toggle(t0());
        assert!(!m.take_dirty(), "starting changes no setting");
        m.faster(t0());
        assert!(m.take_dirty());
        for _ in 0..10 {
            m.faster(t0());
        }
        m.take_dirty();
        m.faster(t0());
        assert!(!m.take_dirty(), "at the top it no longer changes");
    }

    #[test]
    fn typing_changes_the_script_and_keeps_no_previous_while_paste_does() {
        let (mut m, _) = model(true);
        m.edit("one two three", t0(), &ApproximateMeasure);
        assert!(!m.has_previous_script(), "typing keeps nothing");
        assert!(m.take_dirty());
        m.edit("one two three", t0(), &ApproximateMeasure);
        assert!(!m.take_dirty(), "the same text changes nothing");

        m.paste("pasted text", t0(), &ApproximateMeasure);
        assert!(m.has_previous_script(), "paste keeps the one before");
        assert_eq!(m.script(), "pasted text");
        m.restore_previous_script(t0(), &ApproximateMeasure);
        assert_eq!(m.script(), "one two three");
    }

    #[test]
    fn a_blank_clipboard_is_not_a_script() {
        let (mut m, _) = model(true);
        m.paste("  \n\t ", t0(), &ApproximateMeasure);
        assert_eq!(m.script(), SCRIPT);
        assert!(!m.take_dirty());
    }

    #[test]
    fn a_new_script_stops_the_reading_and_a_new_size_keeps_the_place() {
        let (mut m, _) = model(true);
        m.toggle(t0());
        assert!(m.is_showing_row());
        m.paste("something else entirely", t0(), &ApproximateMeasure);
        assert!(!m.is_showing_row(), "another Script is read from the top");

        let (mut m, _) = model(true);
        m.toggle(t0());
        let later = t0() + Duration::seconds(10);
        let before = m.playback().progress(later);
        m.set_text_size(TeleprompterTextSize::Large, later, &ApproximateMeasure);
        assert!(m.is_showing_row(), "a size does not stop it");
        assert!((m.playback().progress(later) - before).abs() < 0.05, "and it keeps its share of the Script");
        assert_eq!(m.text_size(), TeleprompterTextSize::Large);
    }

    #[test]
    fn the_end_of_the_script_is_a_wake_and_the_row_leaves_three_seconds_after() {
        let (mut m, _) = model(true);
        m.toggle(t0());
        let end = m.next_wake().expect("running knows when it ends");
        m.tick(end + Duration::milliseconds(1));
        assert_eq!(m.state(), PlaybackState::Finished);
        let leaves = m.next_wake().expect("and then when the row goes");
        m.tick(leaves);
        assert!(!m.is_showing_row());
        assert_eq!(m.next_wake(), None);
    }

    #[test]
    fn the_view_is_json_and_carries_no_more_of_the_script_than_its_lines() {
        let (mut m, _) = model(true);
        m.toggle(t0());
        let json = serde_json::to_value(m.view(t0() + Duration::seconds(2))).unwrap();
        assert_eq!(json["enabled"], true);
        assert_eq!(json["showingRow"], true);
        assert_eq!(json["playback"]["state"], "running");
        assert_eq!(json["shortcuts"].as_array().unwrap().len(), 4);
        assert_eq!(json["shortcuts"][0]["display"], "⌃⌥Space");
        assert!(json.get("script").is_none(), "the Script itself is not in the view");
        assert!(json["minutes"].as_u64().unwrap() >= 1);
    }

    #[test]
    fn settings_round_trip_through_json() {
        let (mut m, mut keys) = model(true);
        m.faster(t0());
        m.set_shortcut(KeyShortcut::new(35, Modifiers::CONTROL, "P"), TeleprompterAction::Stop, &mut keys);
        let json = serde_json::to_string(&m.settings()).unwrap();
        let back: TeleprompterSettings = serde_json::from_str(&json).unwrap();
        assert_eq!(back, m.settings());
        assert!(json.contains("\"textSize\":\"medium\"") && json.contains("\"stop\""));
    }
}
