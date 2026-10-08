//! The Module's global shortcuts. An application cannot grab a key on Wayland,
//! so the hub only *says which keys it wants* (`bound()`, published in the
//! Module's state as `hotKeys`) and the Shell extension binds them with
//! `Main.wm.addKeybinding`; a press comes back as the command `hotKey`.
//!
//! Registered only while the Module is on, and while Settings is not
//! recording a new shortcut (`TeleprompterModel` decides; this only does it).

use capa_core::teleprompter::{HotKeys, KeyShortcut, TeleprompterAction};

/// What the platform's keys can say about themselves.
pub trait Bound: HotKeys + Send {
    /// The shortcuts that are wanted now, as the host binds them: `(action, accelerator)`.
    fn bound(&self) -> Vec<(TeleprompterAction, String)>;
}

/// Records what is wanted, for a host that binds the keys itself.
#[derive(Default)]
pub struct ShellHotKeys {
    wanted: Vec<(TeleprompterAction, String)>,
}

impl HotKeys for ShellHotKeys {
    fn register(&mut self, shortcut: &KeyShortcut, action: TeleprompterAction) -> bool {
        // A key the host has no name for cannot be bound: unavailable.
        let Some(accelerator) = shortcut.accelerator() else { return false };
        self.wanted.retain(|(a, _)| *a != action);
        self.wanted.push((action, accelerator));
        true
    }

    fn unregister_all(&mut self) {
        self.wanted.clear();
    }
}

impl Bound for ShellHotKeys {
    fn bound(&self) -> Vec<(TeleprompterAction, String)> {
        self.wanted.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::teleprompter::TeleprompterShortcuts;

    #[test]
    fn the_shell_is_told_the_keys_it_is_to_bind() {
        let mut keys = ShellHotKeys::default();
        for action in TeleprompterAction::ALL {
            assert!(keys.register(&TeleprompterShortcuts::standard(action), action));
        }
        let bound = keys.bound();
        assert_eq!(bound.len(), 4);
        assert!(bound.iter().any(|(a, k)| *a == TeleprompterAction::StartOrPause && k == "<Control><Alt>space"), "{bound:?}");
        keys.unregister_all();
        assert!(keys.bound().is_empty());
    }

    #[test]
    fn a_key_is_bound_by_its_code_whatever_it_is_called() {
        use capa_core::teleprompter::Modifiers;
        let mut keys = ShellHotKeys::default();
        let ctrl_alt = Modifiers::CONTROL | Modifiers::OPTION;
        assert!(keys.register(&KeyShortcut::new(35, ctrl_alt, "З"), TeleprompterAction::StartOrPause));
        assert!(keys.register(&KeyShortcut::new(96, ctrl_alt, "Key 96"), TeleprompterAction::Stop));
        assert!(keys.register(&KeyShortcut::new(43, ctrl_alt, ","), TeleprompterAction::Faster));
        assert!(!keys.register(&KeyShortcut::new(999, ctrl_alt, "Key 999"), TeleprompterAction::Slower), "a key nothing names");
        let bound = keys.bound();
        let accelerator = |action| bound.iter().find(|(a, _)| *a == action).map(|(_, k)| k.as_str());
        assert_eq!(accelerator(TeleprompterAction::StartOrPause), Some("<Control><Alt>p"));
        assert_eq!(accelerator(TeleprompterAction::Stop), Some("<Control><Alt>F5"));
        assert_eq!(accelerator(TeleprompterAction::Faster), Some("<Control><Alt>comma"));
    }

    #[test]
    fn registering_an_action_again_replaces_its_key() {
        let mut keys = ShellHotKeys::default();
        let standard = TeleprompterShortcuts::standard(TeleprompterAction::Faster);
        keys.register(&standard, TeleprompterAction::Faster);
        keys.register(&TeleprompterShortcuts::standard(TeleprompterAction::Slower), TeleprompterAction::Faster);
        assert_eq!(keys.bound().len(), 1);
    }
}
