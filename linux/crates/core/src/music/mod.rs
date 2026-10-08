//! The Music Module's logic: what is playing, what the strip's row and the
//! music page show of it, how the progress bar seeks, what the volume bar
//! means, and the traits the platform code fills in. Port of
//! `CapacityNotchCore/Music` and the decisions in `MusicReader`,
//! `SystemVolume` and `MusicViews`.

mod b64;
mod command;
mod equalizer;
pub mod layout;
mod now_playing;
mod presence;
mod progress;
mod session;
mod source;
mod speaker;

pub use command::{MusicCommand, MusicModule};
pub use equalizer::{cubic_bezier, ease_in_out, Bar, BarRandom, Equalizer};
pub use now_playing::{NowPlaying, NowPlayingReading, NowPlayingStream};
pub use presence::{MusicPresence, RememberedTrack};
pub use progress::{clock_text, MusicProgress, ProgressView, Sought};
pub use session::{MusicSession, MusicView};
pub use source::{MediaEvent, MediaSource, ReaderAction, ReaderSupervisor};
pub use speaker::{AudioOutput, Speaker, SpeakerIcon, SystemVolume};
