//! The Teleprompter Module's logic: the Script and its words, the playback
//! that moves over its lines, the row's layout, the shortcuts, and the model
//! that ties them to a clock, a text measure and the platform's hot keys.
//! Port of `CapacityNotchCore/Teleprompter` and the decisions in
//! `TeleprompterController` and `TeleprompterViews`.

mod key;
mod layout;
mod model;
mod playback;
mod script;
mod surface;

pub use key::{KeyShortcut, Modifiers, TeleprompterAction, TeleprompterShortcuts};
pub use layout::{
    wrap_paragraph, ActionGlyph, ApproximateMeasure, FadeBand, PreviewLine, TeleprompterLayout, TextMeasure,
    BOTTOM_INSET, COMPACT_TELEPROMPTER_ROW, CONTROLS_GAP, CONTROLS_WIDTH, LINE_GAP, ROW_WIDTH, STRIP_GAP,
    TEXT_INSET, TEXT_WIDTH, TOP_INSET, VISIBLE_LINES,
};
pub use model::{HotKeys, ShortcutView, TeleprompterModel, TeleprompterSettings, TeleprompterView};
pub use playback::{PlaybackMotion, PlaybackState, PlaybackView, TeleprompterPlayback};
pub use script::{ScriptStore, TeleprompterModule, TeleprompterScript, TeleprompterTextSize};
pub use surface::{CompactRow, TeleprompterSurface};
