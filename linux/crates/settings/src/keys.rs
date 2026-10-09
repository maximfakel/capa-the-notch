//! A shortcut recorded in a web page or a GTK window, as the `KeyShortcut`
//! Preferences stores: the key by the Mac's virtual key code (the canonical
//! form, so one stored shortcut means one key everywhere), the modifiers as
//! Control, Option, Shift, Command. On Linux Ctrl is Control, Alt is Option
//! and the Super key is Command.

use capa_core::prefs::{KeyShortcut, Modifiers};
use serde::Deserialize;

/// What a keydown tells: `code` is the DOM `KeyboardEvent.code` (the key's
/// place, whatever the layout), `key` the character it types.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
pub struct KeyEvent {
    pub code: String,
    pub key: String,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub meta: bool,
}

/// The Mac virtual key code for a DOM key code, when the table knows it.
pub fn mac_key_code(code: &str) -> Option<u32> {
    let letters = [
        ("KeyA", 0), ("KeyS", 1), ("KeyD", 2), ("KeyF", 3), ("KeyH", 4), ("KeyG", 5), ("KeyZ", 6), ("KeyX", 7),
        ("KeyC", 8), ("KeyV", 9), ("KeyB", 11), ("KeyQ", 12), ("KeyW", 13), ("KeyE", 14), ("KeyR", 15),
        ("KeyY", 16), ("KeyT", 17), ("KeyO", 31), ("KeyU", 32), ("KeyI", 34), ("KeyP", 35), ("KeyL", 37),
        ("KeyJ", 38), ("KeyK", 40), ("KeyN", 45), ("KeyM", 46),
    ];
    let others = [
        ("Digit1", 18), ("Digit2", 19), ("Digit3", 20), ("Digit4", 21), ("Digit6", 22), ("Digit5", 23),
        ("Equal", 24), ("Digit9", 25), ("Digit7", 26), ("Minus", 27), ("Digit8", 28), ("Digit0", 29),
        ("BracketRight", 30), ("BracketLeft", 33), ("Enter", 36), ("Quote", 39), ("Semicolon", 41),
        ("Backslash", 42), ("Comma", 43), ("Slash", 44), ("Period", 47), ("Tab", 48), ("Space", 49),
        ("Backquote", 50), ("Backspace", 51), ("Escape", 53), ("ArrowLeft", 123), ("ArrowRight", 124),
        ("ArrowDown", 125), ("ArrowUp", 126), ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96),
        ("F6", 97), ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
    ];
    letters.iter().chain(others.iter()).find(|(c, _)| *c == code).map(|(_, v)| *v)
}

/// The shortcut a key event records, or `None` when it cannot be one: the key
/// is not on the table, or there is no Control, Option (Alt) or Command
/// (Win/Super) among the modifiers — a bare letter would take that letter from
/// every application.
pub fn shortcut_from(event: &KeyEvent) -> Option<KeyShortcut> {
    let key_code = mac_key_code(&event.code)?;
    let mut modifiers = Modifiers::default();
    if event.ctrl {
        modifiers = modifiers.union(Modifiers::CONTROL);
    }
    if event.alt {
        modifiers = modifiers.union(Modifiers::OPTION);
    }
    if event.shift {
        modifiers = modifiers.union(Modifiers::SHIFT);
    }
    if event.meta {
        modifiers = modifiers.union(Modifiers::COMMAND);
    }
    let strong = Modifiers::CONTROL.union(Modifiers::OPTION).union(Modifiers::COMMAND);
    if modifiers.0 & strong.0 == 0 {
        return None;
    }
    // The key as the layout types it, upper-cased, for showing only: the key
    // is grabbed by its code. The named ones keep their words.
    let typed = if event.key.chars().count() == 1 { Some(event.key.as_str()) } else { None };
    Some(KeyShortcut::new(key_code, modifiers, KeyShortcut::key_label_for(key_code, typed)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(code: &str, key: &str, ctrl: bool, alt: bool, shift: bool, meta: bool) -> KeyEvent {
        KeyEvent { code: code.into(), key: key.into(), ctrl, alt, shift, meta }
    }

    #[test]
    fn ctrl_alt_d_is_the_standard_dictation_shortcut() {
        let s = shortcut_from(&press("KeyD", "d", true, true, false, false)).unwrap();
        assert_eq!(s, capa_core::prefs::default_dictation_shortcut());
    }

    #[test]
    fn a_bare_key_or_shift_alone_is_no_shortcut() {
        assert_eq!(shortcut_from(&press("KeyD", "d", false, false, false, false)), None);
        assert_eq!(shortcut_from(&press("KeyD", "D", false, false, true, false)), None);
    }

    #[test]
    fn named_keys_keep_their_words_and_unknown_keys_are_refused() {
        let s = shortcut_from(&press("Space", " ", true, true, false, false)).unwrap();
        assert_eq!((s.key_code, s.key_label.as_str()), (49, "Space"));
        let s = shortcut_from(&press("ArrowUp", "ArrowUp", true, true, false, false)).unwrap();
        assert_eq!(s.key_label, "↑");
        assert_eq!(shortcut_from(&press("NumpadAdd", "+", true, true, false, false)), None);
    }

    #[test]
    fn the_super_key_is_command() {
        let s = shortcut_from(&press("KeyP", "p", false, false, false, true)).unwrap();
        assert!(s.modifiers.contains(Modifiers::COMMAND));
        assert_eq!(s.key_label, "P");
    }

    #[test]
    fn the_key_is_stored_by_its_place_and_grabbed_by_it_whatever_the_layout_types() {
        // P under a Russian layout types "з": shown as typed, grabbed as P.
        let s = shortcut_from(&press("KeyP", "з", true, true, false, false)).unwrap();
        assert_eq!((s.key_code, s.key_label.as_str()), (35, "З"));
        assert_eq!(s.accelerator().as_deref(), Some("<Control><Alt>p"));
        let cases = [
            ("Comma", ",", false, "<Control><Alt>comma"),
            ("Slash", "/", false, "<Control><Alt>slash"),
            ("BracketLeft", "[", false, "<Control><Alt>bracketleft"),
            ("Minus", "-", false, "<Control><Alt>minus"),
            ("Digit1", "!", true, "<Control><Alt><Shift>1"),
            ("F5", "F5", false, "<Control><Alt>F5"),
        ];
        for (code, key, shift, accelerator) in cases {
            let s = shortcut_from(&press(code, key, true, true, shift, false)).unwrap();
            assert_eq!(s.accelerator().as_deref(), Some(accelerator), "{code}");
        }
    }

    #[test]
    fn a_function_key_is_called_what_its_keycap_says() {
        let s = shortcut_from(&press("F5", "F5", true, false, false, false)).unwrap();
        assert_eq!((s.key_code, s.key_label.as_str()), (96, "F5"));
        assert_eq!(s.display(), "⌃F5");
    }

    #[test]
    fn every_table_entry_translates_to_linux_too() {
        for code in ["KeyA", "Digit1", "Space", "Escape", "ArrowLeft", "F5", "Enter", "Quote", "Backquote", "Backslash"] {
            let s = shortcut_from(&press(code, "x", true, false, false, false)).unwrap();
            assert!(s.linux_evdev().is_some(), "{code}");
            assert!(s.accelerator().is_some_and(|a| !a.contains("0x")), "{code} has a keysym");
        }
    }
}
