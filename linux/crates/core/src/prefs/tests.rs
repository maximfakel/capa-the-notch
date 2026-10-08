use super::*;
use crate::dictation::{DictationHistory, DictationReplacement};
use crate::snapshot::Provider;
use chrono::{TimeZone, Utc};
use serde_json::json;
use std::sync::Arc;

fn fresh() -> (Preferences, Arc<MemoryStore>) {
    let store = Arc::new(MemoryStore::new());
    (Preferences::new(store.clone()), store)
}

#[test]
fn nothing_is_enabled_on_anybodys_behalf() {
    let (p, _) = fresh();
    assert!(!p.alerts_enabled(), "Alerts are not switched on for anyone");
    assert!(!p.launch_at_login(), "Nor is launching at login");
    assert!(!p.screen_sharing_allowed(), "Nor is appearing in a shared screen");
    assert!(!p.keeps_diagnostic_log(), "Nor is keeping a log");
    assert!(!p.checks_for_updates(), "Nor is asking the network about updates");
    assert!(!p.music_enabled(), "Nor is reading what is playing");
    assert!(!p.has_finished_onboarding(), "A first run has not been through onboarding");
    assert!(!p.claude_consent_given(), "And has consented to nothing");
    assert!(!p.open_code_consent_given(), "Least of all to OpenCode's key being read");
    assert!(!p.shelf_enabled() && !p.shelf_takes_clipboard_images() && !p.shelf_keeps_text(), "The Shelf keeps nothing until asked");
    assert!(!p.teleprompter_enabled());
    assert!(!p.dictation_enabled() && !p.dictation_keeps_history(), "Quiet defaults");
}

#[test]
fn the_defaults_that_are_on_are_the_ones_that_ask_for_nothing() {
    let (p, _) = fresh();
    assert!(p.shows_kapa(), "Kapa asks for nothing and reads nothing new");
    assert!(p.plays_sounds(), "Sounds are on, with one switch to turn them off");
    assert!(p.clippings_expire(), "Clippings go after a day unless that is switched off");
    p.set_shows_kapa(false);
    p.set_plays_sounds(false);
    assert!(!p.shows_kapa() && !p.plays_sounds());
}

#[test]
fn codex_starts_connected_and_claude_does_not() {
    let (p, _) = fresh();
    assert!(p.connects_at_launch(Provider::Codex), "Codex asks nothing of the person, so it is read without being asked for");
    assert!(!p.connects_at_launch(Provider::ClaudeCode), "Claude Code is explained and asked for first");
}

#[test]
fn a_deliberate_disconnect_outlives_the_launch_it_was_made_in() {
    let (p, store) = fresh();
    p.set_connects_at_launch(Provider::Codex, false);
    p.set_connects_at_launch(Provider::ClaudeCode, true);

    // The next launch reads the same store.
    let next = Preferences::new(store);
    assert!(!next.connects_at_launch(Provider::Codex), "A Provider disconnected on purpose stays disconnected");
    assert!(next.connects_at_launch(Provider::ClaudeCode), "And one connected on purpose comes back connected");
}

#[test]
fn a_choice_made_anywhere_is_the_same_choice() {
    let (p, store) = fresh();
    p.set_alerts_enabled(true);
    p.set_launch_at_login(true);
    p.set_preferred_display_id(Some(7));
    p.set_background_refresh_seconds(900.0);

    let elsewhere = Preferences::new(store.clone());
    assert!(elsewhere.alerts_enabled(), "Alerts");
    assert!(elsewhere.launch_at_login(), "Launch at login");
    assert_eq!(elsewhere.preferred_display_id(), Some(7), "The chosen display");
    assert_eq!(elsewhere.background_refresh_seconds(), 900.0, "The background pace");

    elsewhere.set_preferred_display_id(None);
    assert_eq!(
        Preferences::new(store).preferred_display_id(),
        None,
        "Clearing the chosen display returns to whichever display is built in"
    );
}

#[test]
fn onboarding_is_offered_only_to_someone_who_has_connected_nothing() {
    let (p, _) = fresh();
    assert!(p.needs_onboarding(), "A first run is offered onboarding");

    // Connected from onboarding, the menu or a card, then the window closed
    // without Continue: that person has been through the first run.
    p.set_connects_at_launch(Provider::ClaudeCode, true);
    assert!(!p.needs_onboarding(), "Someone who connected a Provider should not be welcomed again at every launch");

    p.set_connects_at_launch(Provider::ClaudeCode, false);
    assert!(p.needs_onboarding(), "With everything deliberately disconnected and onboarding never finished, it is offered again");

    p.set_has_finished_onboarding(true);
    assert!(!p.needs_onboarding(), "Finishing onboarding ends it");
}

#[test]
fn the_background_pace_falls_back_to_the_schedule_it_came_from() {
    let (p, _) = fresh();
    assert_eq!(
        p.background_refresh_seconds(),
        crate::schedule::RefreshSchedule::STANDARD.while_compact.as_secs_f64(),
        "Unset, the pace is the schedule's own"
    );
    assert!(
        REFRESH_CHOICES.contains(&crate::schedule::RefreshSchedule::STANDARD.while_compact.as_secs_f64()),
        "And the schedule's own pace is one a person can choose"
    );
    p.set_background_refresh_seconds(-5.0);
    assert_eq!(p.background_refresh_seconds(), 300.0, "A pace that is not positive is no pace");
}

#[test]
fn the_appearance_follows_the_system_until_chosen() {
    let (p, store) = fresh();
    assert_eq!(p.appearance(), Appearance::System, "Until chosen, the windows look as the system does");

    p.set_appearance(Appearance::Dark);
    assert_eq!(Preferences::new(store.clone()).appearance(), Appearance::Dark, "A chosen appearance outlives the launch it was chosen in");

    store.set("appearance", json!("sepia"));
    assert_eq!(p.appearance(), Appearance::System, "Something stored that is not an appearance falls back to the system's");
}

/// Preferences keep the two-at-most rule wherever a Provider is turned on.
#[test]
fn preferences_refuse_a_provider_past_the_limit() {
    use Provider::*;
    let (p, _) = fresh();
    p.set_connects_at_launch(ClaudeCode, true);
    assert_eq!(p.connected_providers(), [Codex, ClaudeCode], "Codex by default, and Claude Code turned on");
    assert!(p.can_connect(Codex) && p.can_connect(ClaudeCode), "Both on, both may stay on");
    assert!(!p.can_connect(OpenCode), "Two on, a third may not");
    assert!(!p.set_connects_at_launch(OpenCode, true), "Turning it on is refused");
    assert!(!p.connects_at_launch(OpenCode), "And it stays off");
    p.set_connects_at_launch(Codex, false);
    assert_eq!(p.connected_providers(), [ClaudeCode], "One switched off");
    assert!(p.can_connect(Codex), "And the other may come back");
    assert!(p.set_connects_at_launch(OpenCode, true), "Or OpenCode in its place");
    assert_eq!(p.connected_providers(), [ClaudeCode, OpenCode], "In surface order");
}

#[test]
fn three_chosen_somewhere_the_rule_was_not_kept_read_as_two() {
    use Provider::*;
    let (_, store) = fresh();
    for provider in ["codex", "claudeCode", "openCode"] {
        store.set(&format!("connectsAtLaunch.{provider}"), json!(true));
    }
    assert_eq!(Preferences::new(store).connected_providers(), [Codex, ClaudeCode]);
}

#[test]
fn alerts_need_both_the_global_switch_and_the_providers() {
    use Provider::*;
    let (p, _) = fresh();
    assert!(!p.alerts_enabled_for(Codex), "Off globally, off for all");
    p.set_alerts_enabled(true);
    assert!(p.alerts_enabled_for(Codex) && p.alerts_enabled_for(ClaudeCode), "On globally, a Provider not silenced is heard");
    p.set_alerts_enabled_for(Codex, false);
    assert!(!p.alerts_enabled_for(Codex) && p.alerts_enabled_for(ClaudeCode), "One silenced without silencing the other");
    p.set_alerts_enabled(false);
    assert!(!p.alerts_enabled_for(ClaudeCode));
}

#[test]
fn the_compact_window_and_the_language_fall_back_when_what_is_stored_is_not_theirs() {
    let (p, store) = fresh();
    assert_eq!(p.compact_window(), CompactWindowChoice::FiveHour);
    assert_eq!(p.language(), AppLanguage::System);
    p.set_compact_window(CompactWindowChoice::LeastLeft);
    p.set_language(AppLanguage::Russian);
    assert_eq!(p.compact_window(), CompactWindowChoice::LeastLeft);
    assert_eq!(p.language(), AppLanguage::Russian);
    store.set("compactWindow", json!("monthly"));
    store.set("language", json!(42));
    assert_eq!(p.compact_window(), CompactWindowChoice::FiveHour);
    assert_eq!(p.language(), AppLanguage::System);
    assert_eq!(store.get("compactWindow"), Some(json!("monthly")), "reading never rewrites what is stored");
}

#[test]
fn the_system_language_is_russian_only_when_russian_comes_first() {
    assert_eq!(AppLanguage::System.resolved(&["ru-RU", "en"]), AppLanguage::Russian);
    assert_eq!(AppLanguage::System.resolved(&["ru_RU.UTF-8"]), AppLanguage::Russian);
    assert_eq!(AppLanguage::System.resolved(&["en-US", "ru"]), AppLanguage::English);
    assert_eq!(AppLanguage::System.resolved(&[]), AppLanguage::English);
    assert_eq!(AppLanguage::English.resolved(&["ru"]), AppLanguage::English, "a chosen language is not second-guessed");
    assert_eq!(AppLanguage::Russian.title(), "Русский", "each language names itself");
}

#[test]
fn the_clipping_limit_is_twenty_unless_chosen_and_expiry_is_stored_as_its_opposite() {
    let (p, store) = fresh();
    assert_eq!(p.clipping_limit(), ClippingLimit::Twenty);
    p.set_clipping_limit(ClippingLimit::Hundred);
    assert_eq!(p.clipping_limit().count(), 100);
    store.set("clippingLimit", json!(30));
    assert_eq!(p.clipping_limit(), ClippingLimit::Twenty, "a number that is not a choice is the default");

    assert!(p.clippings_expire());
    p.set_clippings_expire(false);
    assert_eq!(store.get("clippingsKeptPastADay"), Some(json!(true)), "the key it was first written under");
    assert!(!p.clippings_expire());
}

#[test]
fn the_shelfs_keys_are_the_ones_the_macos_app_wrote() {
    let (p, store) = fresh();
    p.set_shelf_takes_clipboard_images(true);
    assert_eq!(store.get("shelfTakesScreenshots"), Some(json!(true)), "from when it took screenshots alone");
    p.set_clipboard_excluded_applications(&["org.keepassxc.keepassxc".to_owned()]);
    assert_eq!(p.clipboard_excluded_applications(), ["org.keepassxc.keepassxc"]);
    assert!(Preferences::new(Arc::new(MemoryStore::new())).clipboard_excluded_applications().is_empty());
}

#[test]
fn a_pasted_script_keeps_the_one_before_and_restoring_trades_places() {
    let (p, _) = fresh();
    p.replace_script("one");
    assert_eq!((p.script().as_str(), p.previous_script()), ("one", None), "an empty script is not worth keeping");
    p.replace_script("one");
    assert_eq!(p.previous_script(), None, "pasting the same text changes nothing");
    p.replace_script("two");
    assert_eq!((p.script().as_str(), p.previous_script().as_deref()), ("two", Some("one")));
    p.replace_script("three");
    assert_eq!(p.previous_script().as_deref(), Some("two"), "one step back, no more");

    p.restore_previous_script();
    assert_eq!((p.script().as_str(), p.previous_script().as_deref()), ("two", Some("three")));
    p.restore_previous_script();
    assert_eq!((p.script().as_str(), p.previous_script().as_deref()), ("three", Some("two")), "a second restore undoes the first");

    let (empty, _) = fresh();
    empty.restore_previous_script();
    assert_eq!(empty.script(), "", "nothing to restore");
    empty.set_script("x");
    empty.set_script("");
    empty.replace_script("y");
    assert_eq!(empty.previous_script(), None);
}

#[test]
fn the_teleprompter_speed_is_clamped_and_rounded_and_unset_is_normal() {
    let (p, store) = fresh();
    assert_eq!(p.teleprompter_multiplier(), 1.0);
    p.set_teleprompter_multiplier(9.0);
    assert_eq!(p.teleprompter_multiplier(), 2.0);
    p.set_teleprompter_multiplier(0.1);
    assert_eq!(p.teleprompter_multiplier(), 0.5);
    p.set_teleprompter_multiplier(1.2345);
    assert_eq!(p.teleprompter_multiplier(), 1.23);
    store.set("teleprompterMultiplier", json!(-3));
    assert_eq!(p.teleprompter_multiplier(), 1.0, "not a speed");
    assert_eq!(p.teleprompter_text_size(), TeleprompterTextSize::Medium);
    p.set_teleprompter_text_size(TeleprompterTextSize::Large);
    assert_eq!(p.teleprompter_text_size().points(), 20.0);
}

#[test]
fn the_teleprompters_shortcuts_are_the_standard_until_recorded() {
    let (p, store) = fresh();
    let standard = [
        (TeleprompterAction::StartOrPause, "⌃⌥Space"),
        (TeleprompterAction::Stop, "⌃⌥Esc"),
        (TeleprompterAction::Faster, "⌃⌥↑"),
        (TeleprompterAction::Slower, "⌃⌥↓"),
    ];
    for (action, shown) in standard {
        assert_eq!(p.teleprompter_shortcut(action).unwrap().display(), shown);
    }
    let mine = KeyShortcut::new(35, Modifiers::COMMAND.union(Modifiers::SHIFT), "P");
    p.set_teleprompter_shortcut(&mine, TeleprompterAction::Stop);
    assert_eq!(p.teleprompter_shortcut(TeleprompterAction::Stop), Some(mine));
    store.set("teleprompterShortcut.faster", json!("garbage"));
    assert_eq!(p.teleprompter_shortcut(TeleprompterAction::Faster), None, "unreadable is no shortcut, not the standard one");
}

#[test]
fn dictation_has_quiet_defaults_and_keeps_what_it_is_given() {
    let (p, store) = fresh();
    assert!(!p.dictation_enabled() && !p.dictation_keeps_history(), "Quiet defaults");
    assert_eq!(p.dictation_shortcut().display(), "⌃⌥D");
    assert_eq!(p.dictation_replacements(), DictationReplacement::defaults());

    let mut history = DictationHistory::new();
    history.append("private", false, Utc.timestamp_opt(0, 0).unwrap());
    assert!(history.entries().is_empty(), "No implicit retention");
    for i in 0..55 {
        history.append(&format!("Result {i}"), true, Utc.timestamp_opt(1_700_000_000 + i, 0).unwrap());
    }
    p.set_dictation_history(&history);
    let restored = Preferences::new(store.clone()).dictation_history();
    assert_eq!(restored, history, "History survives reopening");
    assert_eq!(restored.entries().len(), 50);

    let rules = vec![DictationReplacement::new(1, "привет", "hello")];
    p.set_dictation_replacements(&rules);
    assert_eq!(Preferences::new(store.clone()).dictation_replacements(), rules);
    store.set("dictation.replacements", json!("broken"));
    assert_eq!(p.dictation_replacements(), DictationReplacement::defaults(), "unreadable falls back to the defaults");

    let shortcut = KeyShortcut::new(49, Modifiers::CONTROL.union(Modifiers::SHIFT), "Space");
    p.set_dictation_shortcut(&shortcut);
    assert_eq!(p.dictation_shortcut(), shortcut);
}

#[test]
fn a_json_file_makes_preferences_that_survive_a_restart() {
    let dir = std::env::temp_dir().join(format!("capa-prefs-file-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let path = dir.join("preferences.json");
    {
        let p = Preferences::new(Arc::new(JsonFileStore::open(&path)));
        p.set_connects_at_launch(Provider::OpenCode, true);
        p.set_language(AppLanguage::Russian);
        p.replace_script("текст");
    }
    let p = Preferences::new(Arc::new(JsonFileStore::open(&path)));
    assert!(p.connects_at_launch(Provider::OpenCode));
    assert_eq!(p.language(), AppLanguage::Russian);
    assert_eq!(p.script(), "текст");
}

#[test]
fn the_hubs_settings_file_and_these_preferences_say_the_same_things() {
    use Provider::*;
    let (p, _) = fresh();
    p.set_connects_at_launch(Codex, false);
    p.set_connects_at_launch(ClaudeCode, true);
    p.set_connects_at_launch(OpenCode, true);
    p.set_alerts_enabled(true);
    p.set_alerts_enabled_for(OpenCode, false);
    let json = p.to_hub_json();
    assert_eq!(json, json!({"connected": ["claudeCode", "openCode"], "alertsEnabled": true, "alertsSilencedFor": ["openCode"]}));

    // A file the hub wrote before these preferences existed.
    let (q, _) = fresh();
    q.import_hub_json(&json!({"connected": ["openCode"], "alertsEnabled": false, "alertsSilencedFor": ["codex"]}));
    assert_eq!(q.connected_providers(), [OpenCode], "what the hub says is on, and not Codex by default");
    assert!(!q.alerts_enabled());
    q.set_alerts_enabled(true);
    assert!(!q.alerts_enabled_for(Codex) && q.alerts_enabled_for(ClaudeCode));

    // Nothing to import changes nothing.
    let (r, _) = fresh();
    r.import_hub_json(&json!({}));
    assert_eq!(r.connected_providers(), [Codex]);
    // More than two is trimmed the way the hub trims it.
    r.import_hub_json(&json!({"connected": ["openCode", "claudeCode", "codex"]}));
    assert_eq!(r.connected_providers(), [Codex, ClaudeCode]);
}
