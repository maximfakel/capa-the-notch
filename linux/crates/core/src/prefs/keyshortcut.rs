//! A global shortcut, as the Swift `KeyShortcut` has it. The key is stored the
//! way the Mac numbers it (its virtual key codes), which is what a macOS
//! recording writes; the Linux table here translates those numbers, so one
//! stored shortcut means the same key everywhere.

use serde::{Deserialize, Serialize};

/// Control, Option, Shift, Command: one bit each, as in Swift's `OptionSet`
/// (`rawValue` 1, 2, 4, 8), so the JSON is the same number.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Modifiers(pub u32);

impl Modifiers {
    pub const CONTROL: Modifiers = Modifiers(1);
    pub const OPTION: Modifiers = Modifiers(2);
    pub const SHIFT: Modifiers = Modifiers(4);
    pub const COMMAND: Modifiers = Modifiers(8);

    pub const fn union(self, other: Modifiers) -> Modifiers {
        Modifiers(self.0 | other.0)
    }

    pub const fn contains(self, other: Modifiers) -> bool {
        self.0 & other.0 == other.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyShortcut {
    pub key_code: u32,
    pub modifiers: Modifiers,
    /// What the key is called, as it was when recorded: "Space", "Esc", "↑", "P".
    pub key_label: String,
}

/// Which keyboard's words to write a shortcut in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Mac,
    Linux,
}

impl KeyShortcut {
    pub fn new(key_code: u32, modifiers: Modifiers, key_label: impl Into<String>) -> Self {
        Self { key_code, modifiers, key_label: key_label.into() }
    }

    /// The modifiers in the Mac's own order, then the key: "⌃⌥Space".
    pub fn display(&self) -> String {
        self.keycaps().concat()
    }

    /// Each keycap on its own, for drawing them apart.
    pub fn keycaps(&self) -> Vec<String> {
        let mut caps = self.modifier_symbols();
        caps.push(self.label().to_owned());
        caps
    }

    /// The same shortcut in the words of another keyboard: "Ctrl+Alt+Space".
    /// Command is the Super key there.
    pub fn display_for(&self, platform: Platform) -> String {
        if platform == Platform::Mac {
            return self.display();
        }
        let mut parts: Vec<&str> = Vec::new();
        if self.modifiers.contains(Modifiers::CONTROL) {
            parts.push("Ctrl");
        }
        if self.modifiers.contains(Modifiers::OPTION) {
            parts.push("Alt");
        }
        if self.modifiers.contains(Modifiers::SHIFT) {
            parts.push("Shift");
        }
        if self.modifiers.contains(Modifiers::COMMAND) {
            parts.push("Super");
        }
        parts.push(self.label());
        parts.join("+")
    }

    /// The key's keycap. A function key recorded before they had names
    /// ("Key 96") is called what it is ("F5").
    fn label(&self) -> &str {
        match FUNCTION_KEYS.iter().find(|(code, _)| *code == self.key_code) {
            Some((_, name)) if self.key_label == format!("Key {}", self.key_code) => name,
            _ => &self.key_label,
        }
    }

    fn modifier_symbols(&self) -> Vec<String> {
        [(Modifiers::CONTROL, "⌃"), (Modifiers::OPTION, "⌥"), (Modifiers::SHIFT, "⇧"), (Modifiers::COMMAND, "⌘")]
            .into_iter()
            .filter(|(m, _)| self.modifiers.contains(*m))
            .map(|(_, s)| s.to_owned())
            .collect()
    }

    /// What to call a key just pressed, for its keycap. Keys the keyboard
    /// prints nothing readable for — Space, the arrows, function keys — are
    /// named, since their characters draw blank or as private symbols.
    pub fn key_label_for(key_code: u32, characters: Option<&str>) -> String {
        match key_code {
            49 => return "Space".into(),
            53 => return "Esc".into(),
            36 => return "Return".into(),
            48 => return "Tab".into(),
            51 => return "Delete".into(),
            123 => return "←".into(),
            124 => return "→".into(),
            125 => return "↓".into(),
            126 => return "↑".into(),
            _ => {}
        }
        // A function key is called what its keycap says, which its private-use character is not.
        if let Some((_, name)) = FUNCTION_KEYS.iter().find(|(code, _)| *code == key_code) {
            return (*name).into();
        }
        // The arrows' and function keys' characters live in the private use area.
        match characters {
            Some(chars)
                if !chars.is_empty()
                    && chars.chars().all(|c| {
                        !('\u{E000}'..='\u{F8FF}').contains(&c) && !c.is_whitespace() && !c.is_control()
                    }) =>
            {
                chars.to_uppercase()
            }
            _ => format!("Key {key_code}"),
        }
    }

    /// The Linux evdev key code (`KEY_*`) for this key, when the table knows it.
    pub fn linux_evdev(&self) -> Option<u32> {
        KEYS.iter().find(|k| k.mac == self.key_code).map(|k| k.evdev)
    }

    /// The shortcut as GTK and Mutter write an accelerator: `<Control><Alt>p`.
    /// Command is the Super key.
    ///
    /// The key is the one the code names, as the Swift registers a hot key by
    /// its key code (`RegisterEventHotKey(keyCode, …)`), and never what its
    /// label says: a letter recorded under another layout (P is "З" in a
    /// Russian one), punctuation, Shift with a digit ("!") and the function
    /// keys are all the key that was pressed. A key the table knows but has
    /// no fixed keysym for (the keypad) is grabbed by its X key code,
    /// `0x<evdev + 8>`. `None` for a key no one can name.
    pub fn accelerator(&self) -> Option<String> {
        Self::accelerator_for(self.key_code, self.modifiers, &self.key_label)
    }

    /// `accelerator` for any shortcut written as these three. A key code the
    /// table does not know is read from its label, as shortcuts once were all
    /// read, so one stored that way still works.
    pub fn accelerator_for(key_code: u32, modifiers: Modifiers, key_label: &str) -> Option<String> {
        let key = match KEYS.iter().find(|k| k.mac == key_code) {
            Some(Key { keysym: Some(keysym), .. }) => (*keysym).to_owned(),
            Some(Key { evdev, .. }) => format!("0x{:x}", evdev + 8),
            None => Self::keysym_of_label(key_label)?,
        };
        let mut out = String::new();
        for (bit, name) in [
            (Modifiers::CONTROL, "<Control>"),
            (Modifiers::OPTION, "<Alt>"),
            (Modifiers::SHIFT, "<Shift>"),
            (Modifiers::COMMAND, "<Super>"),
        ] {
            if modifiers.contains(bit) {
                out.push_str(name);
            }
        }
        Some(out + &key)
    }

    /// What a label alone can name: the named keys, a Latin letter or a digit, a function key.
    fn keysym_of_label(label: &str) -> Option<String> {
        let named = match label {
            "Space" => "space",
            "Esc" => "Escape",
            "Return" => "Return",
            "Tab" => "Tab",
            "Delete" => "BackSpace",
            "←" => "Left",
            "→" => "Right",
            "↓" => "Down",
            "↑" => "Up",
            other => {
                let mut chars = other.chars();
                return match (chars.next(), chars.next()) {
                    (Some(c), None) if c.is_ascii_alphanumeric() => Some(c.to_ascii_lowercase().to_string()),
                    _ => FUNCTION_KEYS.iter().find(|(_, name)| *name == other).map(|(_, name)| (*name).to_owned()),
                };
            }
        };
        Some(named.to_owned())
    }
}

struct Key {
    mac: u32,
    evdev: u32,
    /// The X keysym the key types on a US keyboard, as an accelerator names
    /// it; `None` for a key whose keysym changes with Num Lock, which is
    /// grabbed by its key code instead.
    keysym: Option<&'static str>,
}

const fn key(mac: u32, evdev: u32, keysym: &'static str) -> Key {
    Key { mac, evdev, keysym: Some(keysym) }
}

const fn pad(mac: u32, evdev: u32) -> Key {
    Key { mac, evdev, keysym: None }
}

/// The keys a shortcut can reasonably use, by the Mac's number, with the
/// Linux evdev code of the same key and the keysym it types.
const KEYS: &[Key] = &[
    // Letters (US layout positions).
    key(0, 30, "a"), key(11, 48, "b"), key(8, 46, "c"), key(2, 32, "d"), key(14, 18, "e"),
    key(3, 33, "f"), key(5, 34, "g"), key(4, 35, "h"), key(34, 23, "i"), key(38, 36, "j"),
    key(40, 37, "k"), key(37, 38, "l"), key(46, 50, "m"), key(45, 49, "n"), key(31, 24, "o"),
    key(35, 25, "p"), key(12, 16, "q"), key(15, 19, "r"), key(1, 31, "s"), key(17, 20, "t"),
    key(32, 22, "u"), key(9, 47, "v"), key(13, 17, "w"), key(7, 45, "x"), key(16, 21, "y"),
    key(6, 44, "z"),
    // Digits.
    key(29, 11, "0"), key(18, 2, "1"), key(19, 3, "2"), key(20, 4, "3"), key(21, 5, "4"),
    key(23, 6, "5"), key(22, 7, "6"), key(26, 8, "7"), key(28, 9, "8"), key(25, 10, "9"),
    // Punctuation.
    key(27, 12, "minus"), key(24, 13, "equal"), key(33, 26, "bracketleft"), key(30, 27, "bracketright"),
    key(42, 43, "backslash"), key(41, 39, "semicolon"), key(39, 40, "apostrophe"), key(43, 51, "comma"),
    key(47, 52, "period"), key(44, 53, "slash"), key(50, 41, "grave"),
    // Editing and navigation.
    key(36, 28, "Return"), key(48, 15, "Tab"), key(49, 57, "space"), key(51, 14, "BackSpace"), key(53, 1, "Escape"),
    key(123, 105, "Left"), key(124, 106, "Right"), key(125, 108, "Down"), key(126, 103, "Up"),
    // Function keys.
    key(122, 59, "F1"), key(120, 60, "F2"), key(99, 61, "F3"), key(118, 62, "F4"), key(96, 63, "F5"),
    key(97, 64, "F6"), key(98, 65, "F7"), key(100, 66, "F8"), key(101, 67, "F9"), key(109, 68, "F10"),
    key(103, 87, "F11"), key(111, 88, "F12"),
    key(115, 102, "Home"), key(119, 107, "End"), key(116, 104, "Prior"), key(121, 109, "Next"), key(117, 111, "Delete"),
    // The keypad: what it types depends on Num Lock, so it is the key itself.
    pad(82, 82), pad(83, 79), pad(84, 80), pad(85, 81), pad(86, 75), pad(87, 76), pad(88, 77), pad(89, 71),
    pad(91, 72), pad(92, 73), pad(65, 83), pad(67, 55), pad(69, 78), pad(75, 98), pad(76, 96), pad(78, 74),
    pad(81, 117),
];

/// The function keys by the Mac's number, as their keycaps say: F1 is 122.
const FUNCTION_KEYS: [(u32, &str); 12] = [
    (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
    (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
];

#[cfg(test)]
mod tests {
    use super::*;

    fn ctrl_opt() -> Modifiers {
        Modifiers::CONTROL.union(Modifiers::OPTION)
    }

    #[test]
    fn a_shortcut_is_drawn_in_the_macs_order_and_in_other_keyboards_words() {
        let s = KeyShortcut::new(2, ctrl_opt(), "D");
        assert_eq!(s.display(), "⌃⌥D");
        assert_eq!(s.keycaps(), ["⌃", "⌥", "D"]);
        assert_eq!(s.display_for(Platform::Linux), "Ctrl+Alt+D");
        let all = KeyShortcut::new(49, ctrl_opt().union(Modifiers::SHIFT).union(Modifiers::COMMAND), "Space");
        assert_eq!(all.display(), "⌃⌥⇧⌘Space");
        assert_eq!(all.display_for(Platform::Linux), "Ctrl+Alt+Shift+Super+Space");
    }

    #[test]
    fn keys_the_keyboard_prints_nothing_for_are_named() {
        let label = KeyShortcut::key_label_for;
        assert_eq!(label(49, Some(" ")), "Space");
        assert_eq!(label(53, None), "Esc");
        assert_eq!(label(126, Some("\u{F700}")), "↑");
        assert_eq!(label(35, Some("p")), "P");
        assert_eq!(label(122, Some("\u{F704}")), "F1", "a function key is its keycap, not its private-use character");
        assert_eq!(label(96, None), "F5");
        assert_eq!(label(105, Some("\u{F710}")), "Key 105", "a key with nothing printable says its number");
        assert_eq!(label(7, Some("")), "Key 7");
        assert_eq!(label(7, None), "Key 7");
    }

    #[test]
    fn json_is_the_swift_shape() {
        let s = KeyShortcut::new(2, ctrl_opt(), "D");
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json, serde_json::json!({"keyCode": 2, "modifiers": 3, "keyLabel": "D"}));
        assert_eq!(serde_json::from_value::<KeyShortcut>(json).unwrap(), s);
    }

    #[test]
    fn the_shortcuts_the_app_ships_translate() {
        // Control-Option with D, Space, Escape and the arrows.
        let d = KeyShortcut::new(2, ctrl_opt(), "D");
        assert_eq!(d.linux_evdev(), Some(32));
        let space = KeyShortcut::new(49, ctrl_opt(), "Space");
        assert_eq!(space.linux_evdev(), Some(57));
        let esc = KeyShortcut::new(53, ctrl_opt(), "Esc");
        assert_eq!(esc.linux_evdev(), Some(1));
        let up = KeyShortcut::new(126, ctrl_opt(), "↑");
        assert_eq!(up.linux_evdev(), Some(103));
        let down = KeyShortcut::new(125, ctrl_opt(), "↓");
        assert_eq!(down.linux_evdev(), Some(108));
        assert_eq!(KeyShortcut::new(999, Modifiers::default(), "?").linux_evdev(), None);
    }

    #[test]
    fn the_accelerator_is_the_key_pressed_whatever_its_label_says() {
        let accel = |code: u32, modifiers: Modifiers, label: &str| KeyShortcut::new(code, modifiers, label).accelerator();
        assert_eq!(accel(2, ctrl_opt(), "D").as_deref(), Some("<Control><Alt>d"));
        assert_eq!(accel(2, ctrl_opt(), "В").as_deref(), Some("<Control><Alt>d"), "D, recorded under a Russian layout");
        assert_eq!(accel(35, Modifiers::CONTROL, "З").as_deref(), Some("<Control>p"));
        assert_eq!(accel(43, ctrl_opt(), ",").as_deref(), Some("<Control><Alt>comma"));
        assert_eq!(accel(44, ctrl_opt(), "/").as_deref(), Some("<Control><Alt>slash"));
        assert_eq!(accel(33, ctrl_opt(), "[").as_deref(), Some("<Control><Alt>bracketleft"));
        assert_eq!(accel(27, ctrl_opt(), "-").as_deref(), Some("<Control><Alt>minus"));
        assert_eq!(accel(50, ctrl_opt(), "`").as_deref(), Some("<Control><Alt>grave"));
        assert_eq!(accel(18, Modifiers::CONTROL.union(Modifiers::SHIFT), "!").as_deref(), Some("<Control><Shift>1"), "Shift with a digit");
        assert_eq!(accel(96, Modifiers::COMMAND, "F5").as_deref(), Some("<Super>F5"));
        assert_eq!(accel(96, Modifiers::COMMAND, "Key 96").as_deref(), Some("<Super>F5"), "an F key stored by its number");
        assert_eq!(accel(49, Modifiers::CONTROL.union(Modifiers::SHIFT), "Space").as_deref(), Some("<Control><Shift>space"));
        assert_eq!(accel(53, Modifiers::default(), "Esc").as_deref(), Some("Escape"));
        assert_eq!(accel(126, Modifiers::OPTION, "↑").as_deref(), Some("<Alt>Up"));
        assert_eq!(accel(51, Modifiers::CONTROL, "Delete").as_deref(), Some("<Control>BackSpace"));
        assert_eq!(accel(69, Modifiers::CONTROL, "+").as_deref(), Some("<Control>0x56"), "the keypad, by its X key code");
    }

    #[test]
    fn a_key_the_table_does_not_know_is_read_from_its_label_as_before() {
        let accel = |label: &str| KeyShortcut::new(999, Modifiers::CONTROL, label).accelerator();
        assert_eq!(accel("Q").as_deref(), Some("<Control>q"));
        assert_eq!(accel("Space").as_deref(), Some("<Control>space"));
        assert_eq!(accel("F7").as_deref(), Some("<Control>F7"));
        assert_eq!(accel("Key 999"), None);
        assert_eq!(accel("Й"), None, "a letter of another alphabet names no key");
    }

    #[test]
    fn a_function_key_shows_its_name_even_as_stored_by_its_number() {
        let old = KeyShortcut::new(96, ctrl_opt(), "Key 96");
        assert_eq!(old.display(), "⌃⌥F5");
        assert_eq!(old.display_for(Platform::Linux), "Ctrl+Alt+F5");
        assert_eq!(KeyShortcut::new(105, ctrl_opt(), "Key 105").display(), "⌃⌥Key 105");
    }

    #[test]
    fn no_key_is_in_the_table_twice() {
        for (i, a) in KEYS.iter().enumerate() {
            for b in &KEYS[i + 1..] {
                assert_ne!(a.mac, b.mac);
                assert_ne!(a.evdev, b.evdev, "evdev {}", a.evdev);
            }
        }
    }
}
