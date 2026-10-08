//! Where this user's settings, state and Providers' own files live, after the
//! XDG base directories. One place, so nothing drifts apart.

use std::path::{Path, PathBuf};

fn absolute_env(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).map(PathBuf::from).filter(|p| p.is_absolute())
}

/// The user's home: `$HOME`.
pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(Into::into)
        .unwrap_or_else(|| ".".into())
}

/// Settings: `$XDG_CONFIG_HOME` or `~/.config`.
pub fn config(home: &Path) -> PathBuf {
    absolute_env("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config")).join("capa-the-notch")
}

/// What is remembered between runs: `$XDG_STATE_HOME` or `~/.local/state`.
pub fn state(home: &Path) -> PathBuf {
    absolute_env("XDG_STATE_HOME").unwrap_or_else(|| home.join(".local/state")).join("capa-the-notch")
}

/// What the application keeps of its own beyond settings and state — the
/// Dictation model, Claude Code's status-line bridge reading:
/// `$XDG_DATA_HOME/capa-the-notch` (`~/.local/share/capa-the-notch`).
pub fn data(home: &Path) -> PathBuf {
    absolute_env("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local/share")).join("capa-the-notch")
}

/// OpenCode keeps its sign-in under `$XDG_DATA_HOME` or `~/.local/share`: it
/// takes the location from `xdg-basedir`.
pub fn opencode_data(home: &Path) -> PathBuf {
    absolute_env("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local/share")).join("opencode")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directories_hang_off_the_home_by_default() {
        // Only meaningful where the environment does not override them.
        if std::env::var_os("XDG_CONFIG_HOME").is_none() {
            assert_eq!(config(Path::new("/h")), Path::new("/h/.config/capa-the-notch"));
        }
        if std::env::var_os("XDG_STATE_HOME").is_none() {
            assert_eq!(state(Path::new("/h")), Path::new("/h/.local/state/capa-the-notch"));
        }
        if std::env::var_os("XDG_DATA_HOME").is_none() {
            assert_eq!(opencode_data(Path::new("/h")), Path::new("/h/.local/share/opencode"));
        }
    }
}
