//! Port of `Preferences.swift`: every choice a person has made, behind a
//! key-value store.

mod keyshortcut;
mod preferences;
mod store;
mod values;

pub use keyshortcut::{KeyShortcut, Modifiers, Platform};
pub use preferences::{
    default_dictation_shortcut, provider_raw, standard_teleprompter_shortcut, Preferences, KAPA_DEFAULT, KAPA_KEY,
    REFRESH_CHOICES, SOUND_DEFAULT, SOUND_KEY,
};
pub use store::{JsonFileStore, KeyValueStore, MemoryStore};
pub use values::{
    clamped_multiplier, Appearance, AppLanguage, ClippingLimit, CompactWindowChoice, TeleprompterAction,
    TeleprompterTextSize, TELEPROMPTER_MULTIPLIERS,
};

#[cfg(test)]
mod tests;
