use serde::{Deserialize, Serialize};

/// What Kapa shows: one pose for each thing the surface can honestly say
/// (ADR 0006). Every one is read off a signal that already exists — a
/// Capacity Snapshot, a dictation's phase, a drag over the Shelf, a track —
/// and none is invented: there is no "thinking Claude", no dancing to a beat
/// that is never measured.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KapaExpression {
    /// Plenty left; nothing happening.
    Rest,
    /// A Quota Window tightening: attentive, not alarmed.
    Focused,
    /// The empty Shelf, inviting a file.
    Curious,
    /// A track playing.
    Music,
    /// A track loaded and paused.
    Paused,
    /// A file held over the Shelf: the mouth opens.
    DropReady,
    /// Something landed on the Shelf.
    Received,
    /// A dictation recording.
    Listening,
    /// A dictation being recognised.
    Thinking,
    /// Dictated text inserted (and copied).
    Inserted,
    /// Dictated text copied only — not inserted.
    Copied,
    /// A Quota Window unsustainable: below a tenth.
    Worried,
    /// A Quota Window used up, waiting for its reset.
    Waiting,
    /// Capacity stale, or still connecting: no judgement on old numbers.
    Stale,
    /// A Provider disconnected.
    Puzzled,
    /// A dictation that failed.
    Failed,
    /// Nothing connected yet: the first launch.
    Hello,
    /// Beside the Teleprompter's controls: still, whatever the Script does —
    /// nothing moves near a person reading.
    Quiet,
}

impl KapaExpression {
    /// Every pose, in the order the Swift enum declares them.
    pub const ALL: [KapaExpression; 18] = [
        Self::Rest,
        Self::Focused,
        Self::Curious,
        Self::Music,
        Self::Paused,
        Self::DropReady,
        Self::Received,
        Self::Listening,
        Self::Thinking,
        Self::Inserted,
        Self::Copied,
        Self::Worried,
        Self::Waiting,
        Self::Stale,
        Self::Puzzled,
        Self::Failed,
        Self::Hello,
        Self::Quiet,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Eyes {
    /// Round, with a catch-light.
    Open,
    /// Larger and higher: something is coming.
    Wide,
    /// Upturned arcs: pleased.
    Happy,
    /// Downturned arcs: calm, waiting with eyes shut.
    Closed,
    /// A lid drawn flat across the top half: sleepy, unsure.
    Lidded,
    /// Narrowed: working something out.
    Narrowed,
    /// One eye smaller than the other: puzzled.
    Uneven,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mouth {
    Smile,
    Small,
    Line,
    /// An open "o", for the file about to be swallowed.
    Open,
    /// An open smile.
    Grin,
    /// A turned-down curve.
    Worried,
    /// A wavy line: not sure.
    Wobble,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Brows {
    None,
    /// Inner ends raised.
    Worried,
    /// One raised, one flat.
    Puzzled,
}

/// The one sign beside Kapa that carries the meaning colour alone must not
/// (ADR 0006: the body never changes colour).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Badge {
    None,
    Check,
    Alert,
    Clock,
    DashedClock,
    Cross,
    Clipboard,
    File,
    Note,
    Unplugged,
    Sparkle,
    Pause,
}

/// A one-off movement when the pose is entered, never repeated.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reaction {
    None,
    /// A small nod: a track starts, text goes in.
    Nod,
    /// Squash and recover: the Shelf took something.
    Gulp,
    /// A little hop: hello.
    Hop,
}

/// A turn of the head: yaw to the right, pitch upwards, in radians.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KapaLook {
    pub yaw: f64,
    pub pitch: f64,
}

impl KapaLook {
    pub const AHEAD: KapaLook = KapaLook { yaw: 0.0, pitch: 0.0 };
    /// Up and to the left: where the Dictation Capsule's orb is from the
    /// corner Kapa sits in.
    pub const TOWARD_THE_ORB: KapaLook = KapaLook { yaw: -0.2, pitch: 0.15 };

    pub const fn new(yaw: f64, pitch: f64) -> Self {
        Self { yaw, pitch }
    }
}

/// The face, as parts. A pose is a face; the renderer draws parts, so a new
/// pose is a new row in `KapaFace::of`, not a new drawing.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KapaFace {
    pub eyes: Eyes,
    pub mouth: Mouth,
    pub brows: Brows,
    pub badge: Badge,
    pub headphones: bool,
    pub blush: bool,
    /// Where Kapa looks, as turns of the head (see `KapaGaze`).
    pub look: KapaLook,
    /// Lean of the whole body, in degrees; negative leans left.
    pub tilt: f64,
    pub reaction: Reaction,
}

impl KapaFace {
    fn new(eyes: Eyes, mouth: Mouth) -> Self {
        Self {
            eyes,
            mouth,
            brows: Brows::None,
            badge: Badge::None,
            headphones: false,
            blush: false,
            look: KapaLook::AHEAD,
            tilt: 0.0,
            reaction: Reaction::None,
        }
    }

    pub fn of(expression: KapaExpression) -> Self {
        use KapaExpression as E;
        let base = Self::new;
        match expression {
            E::Rest => base(Eyes::Open, Mouth::Smile),
            E::Focused => base(Eyes::Open, Mouth::Line),
            E::Curious => Self { look: KapaLook::new(0.12, 0.12), ..base(Eyes::Open, Mouth::Small) },
            E::Music => Self {
                badge: Badge::Note,
                headphones: true,
                reaction: Reaction::Nod,
                ..base(Eyes::Happy, Mouth::Grin)
            },
            E::Paused => Self { headphones: true, ..base(Eyes::Open, Mouth::Line) },
            E::DropReady => Self {
                badge: Badge::File,
                look: KapaLook::new(-0.08, 0.14),
                ..base(Eyes::Wide, Mouth::Open)
            },
            E::Received => Self {
                badge: Badge::Check,
                blush: true,
                reaction: Reaction::Gulp,
                ..base(Eyes::Happy, Mouth::Small)
            },
            E::Listening => Self { look: KapaLook::TOWARD_THE_ORB, ..base(Eyes::Open, Mouth::Small) },
            E::Thinking => Self { look: KapaLook::TOWARD_THE_ORB, ..base(Eyes::Narrowed, Mouth::Line) },
            E::Inserted => Self { badge: Badge::Check, reaction: Reaction::Nod, ..base(Eyes::Happy, Mouth::Grin) },
            E::Copied => Self {
                badge: Badge::Clipboard,
                look: KapaLook::TOWARD_THE_ORB,
                ..base(Eyes::Open, Mouth::Small)
            },
            E::Worried => Self { brows: Brows::Worried, badge: Badge::Alert, ..base(Eyes::Open, Mouth::Worried) },
            E::Waiting => Self { badge: Badge::Clock, ..base(Eyes::Closed, Mouth::Line) },
            E::Stale => Self { badge: Badge::DashedClock, ..base(Eyes::Lidded, Mouth::Line) },
            E::Puzzled => Self {
                brows: Brows::Puzzled,
                badge: Badge::Unplugged,
                tilt: -4.0,
                ..base(Eyes::Uneven, Mouth::Wobble)
            },
            E::Failed => Self {
                brows: Brows::Puzzled,
                badge: Badge::Cross,
                tilt: -4.0,
                ..base(Eyes::Uneven, Mouth::Wobble)
            },
            E::Hello => Self { badge: Badge::Sparkle, reaction: Reaction::Hop, ..base(Eyes::Happy, Mouth::Grin) },
            E::Quiet => Self { badge: Badge::Pause, ..base(Eyes::Open, Mouth::Line) },
        }
    }
}
