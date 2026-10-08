//! The small enums a choice can be. Each stores as the same word the Swift
//! raw value is, so a stored value means the same thing in both.

use serde::{Deserialize, Serialize};

/// Which window each Provider shows in the closed strip while both are on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompactWindowChoice {
    #[default]
    FiveHour,
    Weekly,
    LeastLeft,
}

impl CompactWindowChoice {
    pub const ALL: [Self; 3] = [Self::FiveHour, Self::Weekly, Self::LeastLeft];

    pub fn raw(self) -> &'static str {
        match self {
            Self::FiveHour => "fiveHour",
            Self::Weekly => "weekly",
            Self::LeastLeft => "leastLeft",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|c| c.raw() == raw)
    }

    /// The words in Settings, as drawn: a key into the translations.
    pub fn title(self) -> &'static str {
        match self {
            Self::FiveHour => "Five-hour",
            Self::Weekly => "Weekly",
            Self::LeastLeft => "Least left",
        }
    }
}

/// The language the interface speaks: the system's until chosen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AppLanguage {
    #[default]
    System,
    English,
    Russian,
}

impl AppLanguage {
    pub const ALL: [Self; 3] = [Self::System, Self::English, Self::Russian];

    pub fn raw(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::English => "english",
            Self::Russian => "russian",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|l| l.raw() == raw)
    }

    /// Each language names itself, so it can be found by someone who cannot
    /// read the other; System is the one word that is translated (its key).
    pub fn title(self) -> &'static str {
        match self {
            Self::System => "System",
            Self::English => "English",
            Self::Russian => "Русский",
        }
    }

    /// System becomes Russian when Russian is the first language preferred
    /// (a locale such as `ru`, `ru-RU`, `ru_RU.UTF-8`), and English otherwise.
    pub fn resolved(self, preferred: &[&str]) -> Self {
        if self != Self::System {
            return self;
        }
        let russian = preferred.first().is_some_and(|l| l.to_ascii_lowercase().starts_with("ru"));
        if russian { Self::Russian } else { Self::English }
    }
}

/// How windows look; the surface is black whatever this says.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Appearance {
    #[default]
    System,
    Light,
    Dark,
}

impl Appearance {
    pub const ALL: [Self; 3] = [Self::System, Self::Light, Self::Dark];

    pub fn raw(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|a| a.raw() == raw)
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::System => "System",
            Self::Light => "Light",
            Self::Dark => "Dark",
        }
    }
}

/// How many Clippings the Clipboard tab keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ClippingLimit {
    #[default]
    Twenty,
    Fifty,
    Hundred,
}

impl ClippingLimit {
    pub const ALL: [Self; 3] = [Self::Twenty, Self::Fifty, Self::Hundred];

    pub fn raw(self) -> i64 {
        match self {
            Self::Twenty => 20,
            Self::Fifty => 50,
            Self::Hundred => 100,
        }
    }

    pub fn from_raw(raw: i64) -> Option<Self> {
        Self::ALL.into_iter().find(|l| l.raw() == raw)
    }

    pub fn count(self) -> usize {
        self.raw() as usize
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TeleprompterTextSize {
    Small,
    #[default]
    Medium,
    Large,
}

impl TeleprompterTextSize {
    pub const ALL: [Self; 3] = [Self::Small, Self::Medium, Self::Large];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Small => "small",
            Self::Medium => "medium",
            Self::Large => "large",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.raw() == raw)
    }

    pub fn points(self) -> f64 {
        match self {
            Self::Small => 15.0,
            Self::Medium => 17.0,
            Self::Large => 20.0,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Small => "Small",
            Self::Medium => "Medium",
            Self::Large => "Large",
        }
    }
}

/// The four things a shortcut can do to the Teleprompter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TeleprompterAction {
    StartOrPause,
    Stop,
    Faster,
    Slower,
}

impl TeleprompterAction {
    pub const ALL: [Self; 4] = [Self::StartOrPause, Self::Stop, Self::Faster, Self::Slower];

    pub fn raw(self) -> &'static str {
        match self {
            Self::StartOrPause => "startOrPause",
            Self::Stop => "stop",
            Self::Faster => "faster",
            Self::Slower => "slower",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::StartOrPause => "Start or pause",
            Self::Stop => "Stop",
            Self::Faster => "Faster",
            Self::Slower => "Slower",
        }
    }
}

/// The Teleprompter's speed range and the rounding every stored speed gets.
pub const TELEPROMPTER_MULTIPLIERS: std::ops::RangeInclusive<f64> = 0.5..=2.0;

pub fn clamped_multiplier(value: f64) -> f64 {
    let clamped = value.clamp(*TELEPROMPTER_MULTIPLIERS.start(), *TELEPROMPTER_MULTIPLIERS.end());
    (clamped * 100.0).round() / 100.0
}

// The same choices are named in `loc` and `surface`; these carry one to the other.
impl From<AppLanguage> for crate::loc::AppLanguage {
    fn from(l: AppLanguage) -> Self {
        match l {
            AppLanguage::System => Self::System,
            AppLanguage::English => Self::English,
            AppLanguage::Russian => Self::Russian,
        }
    }
}

impl From<crate::loc::AppLanguage> for AppLanguage {
    fn from(l: crate::loc::AppLanguage) -> Self {
        match l {
            crate::loc::AppLanguage::System => Self::System,
            crate::loc::AppLanguage::English => Self::English,
            crate::loc::AppLanguage::Russian => Self::Russian,
        }
    }
}

impl From<CompactWindowChoice> for crate::surface::CompactWindowChoice {
    fn from(c: CompactWindowChoice) -> Self {
        match c {
            CompactWindowChoice::FiveHour => Self::FiveHour,
            CompactWindowChoice::Weekly => Self::Weekly,
            CompactWindowChoice::LeastLeft => Self::LeastLeft,
        }
    }
}

impl From<crate::surface::CompactWindowChoice> for CompactWindowChoice {
    fn from(c: crate::surface::CompactWindowChoice) -> Self {
        match c {
            crate::surface::CompactWindowChoice::FiveHour => Self::FiveHour,
            crate::surface::CompactWindowChoice::Weekly => Self::Weekly,
            crate::surface::CompactWindowChoice::LeastLeft => Self::LeastLeft,
        }
    }
}
