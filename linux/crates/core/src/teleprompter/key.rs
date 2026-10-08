use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::ops::BitOr;

/// The modifiers held with a shortcut. Serialised as the raw bit set, as the
/// Mac stores it (control 1, option 2, shift 4, command 8).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Modifiers(pub u32);

impl Modifiers {
    pub const CONTROL: Self = Self(1 << 0);
    pub const OPTION: Self = Self(1 << 1);
    pub const SHIFT: Self = Self(1 << 2);
    pub const COMMAND: Self = Self(1 << 3);
    pub const NONE: Self = Self(0);

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }
}

impl BitOr for Modifiers {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

/// A global shortcut: the key, as the hardware numbers it, and the modifiers
/// held with it.
///
/// The key code is the Mac's virtual key code, because that is what is stored
/// and what the standard shortcuts are written in. Linux records a key by the
/// same numbers (Settings translates the key's place, `KeyboardEvent.code`),
/// and grabs it by them (`accelerator`); the label is only what is shown.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyShortcut {
    pub key_code: u32,
    pub modifiers: Modifiers,
    /// What the key is called, as it was when recorded: "Space", "Esc", "↑", "P".
    pub key_label: String,
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
        let mut caps: Vec<String> = self.modifier_symbols().into_iter().map(str::to_owned).collect();
        caps.push(self.as_stored().keycaps().pop().unwrap_or_default());
        caps
    }

    /// The same shortcut as Preferences keeps it, whose keycap names a
    /// function key stored by its number ("Key 96" is F5).
    fn as_stored(&self) -> crate::prefs::KeyShortcut {
        crate::prefs::KeyShortcut::new(self.key_code, crate::prefs::Modifiers(0), self.key_label.clone())
    }

    fn modifier_symbols(&self) -> Vec<&'static str> {
        [(Modifiers::CONTROL, "⌃"), (Modifiers::OPTION, "⌥"), (Modifiers::SHIFT, "⇧"), (Modifiers::COMMAND, "⌘")]
            .into_iter()
            .filter(|(m, _)| self.modifiers.contains(*m))
            .map(|(_, s)| s)
            .collect()
    }

    /// What to call a key just pressed, for its keycap. Keys the keyboard
    /// prints nothing readable for — Space, the arrows, function keys — are
    /// named, since their characters draw blank or as private symbols. The
    /// one table is Preferences' (`prefs::KeyShortcut::key_label_for`).
    pub fn key_label_for(key_code: u32, characters: Option<&str>) -> String {
        crate::prefs::KeyShortcut::key_label_for(key_code, characters)
    }

    /// The shortcut in the GTK / GNOME accelerator syntax (`<Control><Alt>space`),
    /// found by the key code as the Swift registers it, never by the label:
    /// `prefs::KeyShortcut::accelerator` has the table. Command maps to Super;
    /// `None` for a key nothing can name.
    pub fn accelerator(&self) -> Option<String> {
        crate::prefs::KeyShortcut::accelerator_for(self.key_code, crate::prefs::Modifiers(self.modifiers.0), &self.key_label)
    }

    /// The same key and modifiers, whatever it is called.
    pub fn same_keys(&self, other: &Self) -> bool {
        self.key_code == other.key_code && self.modifiers == other.modifiers
    }
}

/// The four things a shortcut can do to the Teleprompter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TeleprompterAction {
    StartOrPause,
    Stop,
    Faster,
    Slower,
}

impl TeleprompterAction {
    pub const ALL: [Self; 4] = [Self::StartOrPause, Self::Stop, Self::Faster, Self::Slower];

    pub fn title(self) -> &'static str {
        match self {
            Self::StartOrPause => "Start or pause",
            Self::Stop => "Stop",
            Self::Faster => "Faster",
            Self::Slower => "Slower",
        }
    }

    /// The name stored with a shortcut: `startOrPause`, …
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::StartOrPause => "startOrPause",
            Self::Stop => "stop",
            Self::Faster => "faster",
            Self::Slower => "slower",
        }
    }
}

pub struct TeleprompterShortcuts;

impl TeleprompterShortcuts {
    /// As drawn: Control-Option with Space, Escape and the up and down arrows.
    pub fn standard(action: TeleprompterAction) -> KeyShortcut {
        let (code, label) = match action {
            TeleprompterAction::StartOrPause => (49, "Space"),
            TeleprompterAction::Stop => (53, "Esc"),
            TeleprompterAction::Faster => (126, "↑"),
            TeleprompterAction::Slower => (125, "↓"),
        };
        KeyShortcut::new(code, Modifiers::CONTROL | Modifiers::OPTION, label)
    }

    pub fn all_standard() -> BTreeMap<TeleprompterAction, KeyShortcut> {
        TeleprompterAction::ALL.into_iter().map(|a| (a, Self::standard(a))).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recorded_key_is_named_as_the_keycap_shows_it() {
        let l = KeyShortcut::key_label_for;
        assert_eq!(l(49, Some(" ")), "Space", "space is named, not drawn blank");
        assert_eq!(l(126, Some("\u{F700}")), "↑", "an arrow is an arrow, not a private character");
        assert_eq!(l(36, Some("\r")), "Return", "return is named");
        assert_eq!(l(2, Some("d")), "D", "a letter is its capital");
        assert_eq!(l(122, Some("\u{F704}")), "F1", "a function key says its name");
        assert_eq!(l(105, Some("\u{F710}")), "Key 105", "a key with nothing printable says its number");
        assert_eq!(l(2, None), "Key 2", "and so does one with no characters");
        assert_eq!(l(2, Some("")), "Key 2");
        assert_eq!(l(2, Some("a b")), "Key 2", "whitespace inside is not a keycap");
    }

    #[test]
    fn a_shortcut_is_spelled_with_the_macs_symbols_in_the_macs_order() {
        let s = KeyShortcut::new(35, Modifiers::CONTROL | Modifiers::COMMAND, "P");
        assert_eq!(s.display(), "⌃⌘P");
        assert_eq!(s.keycaps(), ["⌃", "⌘", "P"]);
        let all = KeyShortcut::new(49, Modifiers::COMMAND | Modifiers::SHIFT | Modifiers::OPTION | Modifiers::CONTROL, "Space");
        assert_eq!(all.display(), "⌃⌥⇧⌘Space");
        assert_eq!(KeyShortcut::new(35, Modifiers::NONE, "P").display(), "P");
    }

    #[test]
    fn the_shortcuts_start_as_drawn() {
        let standard = TeleprompterShortcuts::all_standard();
        assert_eq!(standard[&TeleprompterAction::StartOrPause].display(), "⌃⌥Space");
        assert_eq!(standard[&TeleprompterAction::Stop].display(), "⌃⌥Esc");
        assert_eq!(standard[&TeleprompterAction::Faster].display(), "⌃⌥↑");
        assert_eq!(standard[&TeleprompterAction::Slower].display(), "⌃⌥↓");
        assert_eq!(standard[&TeleprompterAction::Faster].key_code, 126);
    }

    #[test]
    fn a_shortcut_stores_as_the_mac_stored_it() {
        let s = KeyShortcut::new(35, Modifiers::CONTROL | Modifiers::COMMAND, "P");
        let json = serde_json::to_string(&s).unwrap();
        assert_eq!(json, r#"{"keyCode":35,"modifiers":9,"keyLabel":"P"}"#);
        assert_eq!(serde_json::from_str::<KeyShortcut>(&json).unwrap(), s);
        assert_eq!(serde_json::to_string(&TeleprompterAction::StartOrPause).unwrap(), "\"startOrPause\"");
        assert_eq!(TeleprompterAction::Faster.raw_value(), "faster");
    }

    #[test]
    fn accelerators_for_the_standard_keys_and_for_letters() {
        assert_eq!(TeleprompterShortcuts::standard(TeleprompterAction::StartOrPause).accelerator().as_deref(), Some("<Control><Alt>space"));
        assert_eq!(TeleprompterShortcuts::standard(TeleprompterAction::Stop).accelerator().as_deref(), Some("<Control><Alt>Escape"));
        assert_eq!(TeleprompterShortcuts::standard(TeleprompterAction::Faster).accelerator().as_deref(), Some("<Control><Alt>Up"));
        assert_eq!(KeyShortcut::new(35, Modifiers::CONTROL | Modifiers::COMMAND, "P").accelerator().as_deref(), Some("<Control><Super>p"));
        assert_eq!(KeyShortcut::new(122, Modifiers::CONTROL, "Key 122").accelerator().as_deref(), Some("<Control>F1"));
        assert_eq!(KeyShortcut::new(999, Modifiers::CONTROL, "Key 999").accelerator(), None);
    }

    #[test]
    fn accelerators_come_from_the_key_code_not_the_label() {
        let ctrl_alt = Modifiers::CONTROL | Modifiers::OPTION;
        assert_eq!(KeyShortcut::new(35, ctrl_alt, "З").accelerator().as_deref(), Some("<Control><Alt>p"), "P under a Russian layout");
        assert_eq!(KeyShortcut::new(47, ctrl_alt, ".").accelerator().as_deref(), Some("<Control><Alt>period"));
        assert_eq!(KeyShortcut::new(30, ctrl_alt, "]").accelerator().as_deref(), Some("<Control><Alt>bracketright"));
        assert_eq!(KeyShortcut::new(19, ctrl_alt | Modifiers::SHIFT, "@").accelerator().as_deref(), Some("<Control><Alt><Shift>2"));
        assert_eq!(KeyShortcut::new(96, ctrl_alt, "Key 96").display(), "⌃⌥F5", "an F key recorded by its number shows its name");
        assert_eq!(KeyShortcut::new(96, ctrl_alt, "Key 96").keycaps(), ["⌃", "⌥", "F5"]);
    }

    #[test]
    fn same_keys_ignores_the_label() {
        let a = KeyShortcut::new(35, Modifiers::CONTROL, "P");
        let b = KeyShortcut::new(35, Modifiers::CONTROL, "p");
        assert!(a.same_keys(&b));
        assert!(!a.same_keys(&KeyShortcut::new(35, Modifiers::OPTION, "P")));
    }
}
