//! Whether the system starts CapaTheNotch when the person logs in. The system
//! holds the truth, not a preference: someone can turn this off without telling
//! us, so the stored choice is only ever reconciled against what is found here.
//!
//! Linux: an XDG autostart entry (`~/.config/autostart`). On GNOME CapaTheNotch
//! is the Shell extension, which loads with the Shell whatever this says; at
//! login it stays dormant unless this entry is there and enabled, and the entry
//! itself only asks the extension to show itself (`tech.capathenotch.Shell`'s
//! `Show`) — it never starts a daemon of its own, the extension does that.
//! Off, nothing appears at login until CapaTheNotch is launched from its
//! application entry, as `SMAppService` leaves it on macOS.

use std::path::{Path, PathBuf};

const ENTRY: &str = "capa-the-notch.desktop";

/// What launching CapaTheNotch is on GNOME: asking the extension to show itself.
pub const SHOW_COMMAND: &str =
    "gdbus call --session --dest tech.capathenotch.Shell --object-path /tech/capathenotch/Shell --method tech.capathenotch.Shell.Show";

/// An autostart entry in `dir`.
pub struct Autostart {
    pub dir: PathBuf,
}

impl Autostart {
    pub fn xdg() -> Self {
        let config = capa_core::dirs::config(&capa_core::dirs::home());
        // `dirs::config` is the app's folder: autostart lives beside it, in the user's config root.
        let root = config.parent().map(Path::to_path_buf).unwrap_or(config);
        Self { dir: root.join("autostart") }
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join(ENTRY)
    }

    /// The extension reads the same file the same way (`extension.js`).
    pub fn is_enabled(&self) -> bool {
        std::fs::read_to_string(self.path())
            .map(|text| !text.lines().any(|l| l.trim() == "Hidden=true" || l.trim() == "X-GNOME-Autostart-enabled=false"))
            .unwrap_or(false)
    }

    pub fn desktop_entry(&self) -> String {
        format!(
            "[Desktop Entry]\nType=Application\nName=CapaTheNotch\n\
             Exec={SHOW_COMMAND}\nIcon=tech.capathenotch.CapaTheNotch\nTerminal=false\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n"
        )
    }

    /// Returns what ended up being the case, which is not always what was asked.
    pub fn set(&self, enabled: bool) -> bool {
        if enabled {
            if std::fs::create_dir_all(&self.dir).is_ok() {
                let _ = std::fs::write(self.path(), self.desktop_entry());
            }
        } else {
            let _ = std::fs::remove_file(self.path());
        }
        self.is_enabled()
    }
}

pub fn is_enabled() -> bool {
    Autostart::xdg().is_enabled()
}

pub fn set(enabled: bool) -> bool {
    Autostart::xdg().set(enabled)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> Autostart {
        let dir = std::env::temp_dir().join(format!("capa-autostart-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Autostart { dir }
    }

    #[test]
    fn turning_it_on_writes_an_entry_and_off_removes_it() {
        let a = scratch("onoff");
        assert!(!a.is_enabled());
        assert!(a.set(true));
        let text = std::fs::read_to_string(a.path()).unwrap();
        assert!(text.contains(&format!("Exec={SHOW_COMMAND}")), "it wakes the extension: {text}");
        assert!(!text.contains("capa-daemon"), "and starts no daemon of its own: {text}");
        assert!(text.contains("Type=Application"));
        assert!(!text.contains("Comment"), "no sentence the Swift app never says: {text}");
        assert!(!a.set(false));
        assert!(!a.path().exists());
        assert!(!a.set(false), "off twice is still off");
    }

    #[test]
    fn what_the_system_says_wins_over_what_was_asked() {
        let a = scratch("hidden");
        a.set(true);
        // Someone disables it in the desktop's own startup settings.
        let text = std::fs::read_to_string(a.path()).unwrap().replace("X-GNOME-Autostart-enabled=true", "X-GNOME-Autostart-enabled=false");
        std::fs::write(a.path(), text).unwrap();
        assert!(!a.is_enabled());
    }

    #[test]
    fn a_folder_that_cannot_be_made_reads_as_not_enabled() {
        let a = Autostart { dir: PathBuf::from("/proc/capa-cannot/autostart") };
        assert!(!a.set(true));
    }
}
