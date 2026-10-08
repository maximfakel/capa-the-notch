//! The Dictation Capsule: the temporary indicator beneath the Notch Surface.
//! Everything about it a surface needs to draw it the same way — its size,
//! where it sits, how each state looks and what each state says — without the
//! orb itself, which each surface draws (the Murmur "limn" style).

use serde::{Deserialize, Serialize};

/// What the capsule is showing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Presentation {
    #[default]
    Hidden,
    Recording,
    Recognizing,
    Inserted,
    Copied,
    Error,
}

/// The orb's state, in the words of its renderer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OrbState {
    Idle,
    Listening,
    Thinking,
    Success,
    Error,
}

pub type Rgb = (f64, f64, f64);

/// The orb's two tones. The orb's own motion alone read as still listening
/// once it was done, so the outcome is also its colour.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Tones {
    pub tone: Rgb,
    pub tone2: Rgb,
}

/// The ink the orb is drawn in.
pub const ORB_INK: Rgb = (23.0 / 255.0, 23.0 / 255.0, 23.0 / 255.0);

/// A rectangle, y running down.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn bottom(&self) -> f64 {
        self.y + self.height
    }
}

pub const ORB: f64 = 100.0;
/// The room round the capsule for its shadow.
pub const MARGIN: f64 = 16.0;
/// Kapa beside the orb, four and a half times the corner it first sat in:
/// dictation is the moment it is most worth watching (ADR 0006).
pub const KAPA_SIZE: f64 = 136.0;
pub const GAP: f64 = 6.0;
/// How far under the surface the capsule hangs.
pub const BELOW_SURFACE: f64 = 12.0;
/// The shadow under it: black at 20%, blur radius 9, 5 down.
pub const SHADOW_OPACITY: f64 = 0.2;
pub const SHADOW_RADIUS: f64 = 9.0;
pub const SHADOW_OFFSET_Y: f64 = 5.0;
/// Where Kapa looks: at the orb.
pub const KAPA_LOOK_YAW: f64 = -0.3;
pub const KAPA_LOOK_PITCH: f64 = 0.12;
/// How long an inserted or copied capsule stays, and an error that needs
/// nothing from the person (no speech heard).
pub const SUCCESS_SECONDS: f64 = 1.4;
pub const QUIET_ERROR_SECONDS: f64 = 2.5;

impl Presentation {
    /// The orb alone, or the orb and Kapa side by side, tops level.
    pub fn size(showing_kapa: bool) -> (f64, f64) {
        if showing_kapa { (ORB + GAP + KAPA_SIZE, KAPA_SIZE) } else { (ORB, ORB) }
    }

    /// The panel's frame (content and margin) for a surface at `surface`: the
    /// orb centred under it, twelve points below, Kapa to its right.
    pub fn panel_frame(surface: Rect, showing_kapa: bool) -> Option<Rect> {
        if surface.width == 0.0 && surface.height == 0.0 {
            return None;
        }
        let (w, h) = Self::size(showing_kapa);
        Some(Rect {
            x: surface.mid_x() - ORB / 2.0 - MARGIN,
            y: surface.bottom() + BELOW_SURFACE - MARGIN,
            width: w + MARGIN * 2.0,
            height: h + MARGIN * 2.0,
        })
    }

    pub fn orb_state(self) -> OrbState {
        match self {
            Self::Hidden => OrbState::Idle,
            Self::Recording => OrbState::Listening,
            Self::Recognizing => OrbState::Thinking,
            Self::Inserted | Self::Copied => OrbState::Success,
            Self::Error => OrbState::Error,
        }
    }

    pub fn tones(self) -> Tones {
        match self {
            Self::Inserted | Self::Copied => Tones {
                tone: (52.0 / 255.0, 199.0 / 255.0, 89.0 / 255.0),
                tone2: (134.0 / 255.0, 239.0 / 255.0, 128.0 / 255.0),
            },
            Self::Error => Tones {
                tone: (229.0 / 255.0, 62.0 / 255.0, 62.0 / 255.0),
                tone2: (1.0, 122.0 / 255.0, 92.0 / 255.0),
            },
            _ => Tones {
                tone: (34.0 / 255.0, 183.0 / 255.0, 202.0 / 255.0),
                tone2: (86.0 / 255.0, 223.0 / 255.0, 154.0 / 255.0),
            },
        }
    }

    /// Kapa's pose beside the orb: it listens, thinks, nods at what went in,
    /// is puzzled at what did not. The orb already turns green and red, so
    /// Kapa adds no sign. The words are `KapaExpression`'s.
    pub fn kapa_expression(self) -> &'static str {
        match self {
            Self::Hidden => "rest",
            Self::Recording => "listening",
            Self::Recognizing => "thinking",
            Self::Inserted => "inserted",
            Self::Copied => "copied",
            Self::Error => "failed",
        }
    }

    /// Nothing is drawn while hidden: a view in a window off screen still runs
    /// its timeline, and the orb kept drawing thirty frames a second between
    /// dictations.
    pub fn is_drawn(self) -> bool {
        self != Self::Hidden
    }

    /// Only a recording moves the orb and Kapa with the voice.
    pub fn follows_voice(self) -> bool {
        self == Self::Recording
    }

    /// A tap opens the details only where there are details.
    pub fn has_details(self) -> bool {
        matches!(self, Self::Error | Self::Copied)
    }

    /// What VoiceOver (and any screen reader) says: keys of the translations.
    pub fn accessibility_label(self) -> &'static str {
        match self {
            Self::Recording => "Recording. Release the shortcut to recognise. Escape cancels.",
            Self::Recognizing => "Recognising speech. Escape cancels.",
            Self::Inserted => "Text inserted and copied",
            Self::Copied => "Text copied to clipboard. Tap for insertion details.",
            Self::Error => "Dictation error. Show details.",
            Self::Hidden => "Dictation",
        }
    }

    /// The popover a tap opens on an error or a copy.
    pub fn details(self, error: Option<&str>, delivery_message: Option<&str>) -> Option<Details> {
        match self {
            Self::Copied => Some(Details {
                title: "Text copied, not inserted",
                body: delivery_message.unwrap_or("Insertion was unavailable.").to_owned(),
                offers_settings: false,
            }),
            Self::Error => Some(Details {
                title: "Dictation stopped",
                body: error.unwrap_or("Try again.").to_owned(),
                offers_settings: true,
            }),
            _ => None,
        }
    }
}

/// What the details popover says. `title` is a translation key; `body` is one
/// of Dictation's sentences, also a key. Buttons: "Open Dictation Settings"
/// (when `offers_settings`) and "Dismiss".
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Details {
    pub title: &'static str,
    pub body: String,
    pub offers_settings: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_capsule_is_the_orb_alone_or_the_orb_and_kapa() {
        assert_eq!(Presentation::size(false), (100.0, 100.0));
        assert_eq!(Presentation::size(true), (242.0, 136.0));
    }

    #[test]
    fn it_hangs_twelve_points_under_the_surface_with_the_orb_centred() {
        let surface = Rect { x: 700.0, y: 0.0, width: 560.0, height: 210.0 };
        let frame = Presentation::panel_frame(surface, true).unwrap();
        // The orb's left edge is half an orb left of the surface's middle (980).
        assert_eq!(frame.x + MARGIN, 930.0);
        // The content starts twelve points under the surface.
        assert_eq!(frame.y + MARGIN, 222.0);
        assert_eq!((frame.width, frame.height), (242.0 + 32.0, 136.0 + 32.0));
        let alone = Presentation::panel_frame(surface, false).unwrap();
        assert_eq!((alone.width, alone.height), (132.0, 132.0));
        assert_eq!(alone.x, frame.x, "Kapa grows to the right; the orb stays put");
        assert_eq!(Presentation::panel_frame(Rect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 }, true), None);
    }

    #[test]
    fn each_state_has_its_orb_pose_and_kapa_expression() {
        use Presentation::*;
        let table = [
            (Hidden, OrbState::Idle, "rest"),
            (Recording, OrbState::Listening, "listening"),
            (Recognizing, OrbState::Thinking, "thinking"),
            (Inserted, OrbState::Success, "inserted"),
            (Copied, OrbState::Success, "copied"),
            (Error, OrbState::Error, "failed"),
        ];
        for (p, orb, kapa) in table {
            assert_eq!(p.orb_state(), orb);
            assert_eq!(p.kapa_expression(), kapa);
        }
    }

    #[test]
    fn the_outcome_is_also_the_colour() {
        let teal = Presentation::Recording.tones();
        assert_eq!(Presentation::Recognizing.tones(), teal);
        assert_eq!(Presentation::Hidden.tones(), teal);
        assert_ne!(Presentation::Inserted.tones(), teal);
        assert_eq!(Presentation::Inserted.tones(), Presentation::Copied.tones());
        assert_ne!(Presentation::Error.tones(), Presentation::Inserted.tones());
        assert_eq!(Presentation::Error.tones().tone, (229.0 / 255.0, 62.0 / 255.0, 62.0 / 255.0));
    }

    #[test]
    fn only_a_recording_follows_the_voice_and_only_an_outcome_has_details() {
        assert!(Presentation::Recording.follows_voice());
        assert!(!Presentation::Recognizing.follows_voice());
        assert!(!Presentation::Hidden.is_drawn());
        assert!(Presentation::Recording.is_drawn());
        assert!(Presentation::Error.has_details() && Presentation::Copied.has_details());
        assert!(!Presentation::Inserted.has_details());

        let copied = Presentation::Copied.details(None, Some("The text could not be pasted. It is still in the clipboard.")).unwrap();
        assert_eq!(copied.title, "Text copied, not inserted");
        assert!(!copied.offers_settings);
        assert_eq!(Presentation::Copied.details(None, None).unwrap().body, "Insertion was unavailable.");
        let error = Presentation::Error.details(Some("No microphone"), None).unwrap();
        assert_eq!((error.title, error.body.as_str(), error.offers_settings), ("Dictation stopped", "No microphone", true));
        assert_eq!(Presentation::Error.details(None, None).unwrap().body, "Try again.");
        assert!(Presentation::Inserted.details(None, None).is_none());
    }

    #[test]
    fn every_state_has_a_spoken_label() {
        use Presentation::*;
        for p in [Hidden, Recording, Recognizing, Inserted, Copied, Error] {
            assert!(!p.accessibility_label().is_empty());
        }
        assert_eq!(Hidden.accessibility_label(), "Dictation");
    }
}
