use super::playback::PlaybackState;
use serde::{Deserialize, Serialize};

/// How the Teleprompter changes the rest of the surface while it shows.
pub struct TeleprompterSurface;

/// What sits under the compact strip.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompactRow {
    None,
    Music,
    Teleprompter,
}

impl TeleprompterSurface {
    /// The Teleprompter Row takes the music row's place — nearness to the
    /// camera is the point — and shows over a fullscreen application too, where
    /// music does not: calls are often fullscreen.
    pub fn compact_row(teleprompter_showing: bool, music_shown: bool, fullscreen: bool) -> CompactRow {
        if teleprompter_showing {
            CompactRow::Teleprompter
        } else if music_shown && !fullscreen {
            CompactRow::Music
        } else {
            CompactRow::None
        }
    }

    /// A Script on screen is never shared, whatever "Appear in screen sharing
    /// and recordings" says: a Script the audience can read is no help to the
    /// one reading it. Nor is the surface while the Shelf holds a Clipping:
    /// that switch is there to show Capacity on a call, not the token copied a
    /// minute ago (ADR 0005).
    ///
    /// Platform requirement: macOS sets the window's sharing type; GNOME has
    /// nothing to ask for this, and the surface there says so rather than
    /// promise it.
    pub fn excluded_from_capture(sharing_allowed: bool, teleprompter_showing: bool, holds_clippings: bool) -> bool {
        teleprompter_showing || holds_clippings || !sharing_allowed
    }

    /// While the Script runs a pointer passing over the notch does not open the
    /// surface over it; a click still does.
    pub fn hover_opens(teleprompter: PlaybackState) -> bool {
        teleprompter != PlaybackState::Running
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_teleprompter_row_takes_the_place_of_the_music_row() {
        assert_eq!(TeleprompterSurface::compact_row(true, true, false), CompactRow::Teleprompter, "while it shows, music gives way");
        assert_eq!(TeleprompterSurface::compact_row(true, false, true), CompactRow::Teleprompter, "it shows over a fullscreen application too");
        assert_eq!(TeleprompterSurface::compact_row(false, true, true), CompactRow::None, "music still does not");
        assert_eq!(TeleprompterSurface::compact_row(false, true, false), CompactRow::Music, "stopped, music comes back");
        assert_eq!(TeleprompterSurface::compact_row(false, false, false), CompactRow::None);
    }

    #[test]
    fn while_it_shows_the_surface_stays_out_of_capture_and_hover_does_not_open_it() {
        assert!(TeleprompterSurface::excluded_from_capture(true, true, false), "whatever the switch says, a Script on screen is not shared");
        assert!(!TeleprompterSurface::excluded_from_capture(true, false, false), "stopped, the switch decides again");
        assert!(TeleprompterSurface::excluded_from_capture(false, false, false), "off is off");
        assert!(TeleprompterSurface::excluded_from_capture(true, false, true), "nor while the Shelf holds a Clipping");
        assert!(!TeleprompterSurface::hover_opens(PlaybackState::Running), "reading, a passing pointer does not open it");
        assert!(TeleprompterSurface::hover_opens(PlaybackState::Paused), "paused, it does");
        assert!(TeleprompterSurface::hover_opens(PlaybackState::Stopped));
    }

    #[test]
    fn rows_are_json_words() {
        assert_eq!(serde_json::to_string(&CompactRow::Teleprompter).unwrap(), "\"teleprompter\"");
    }
}
