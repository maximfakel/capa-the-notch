//! The platform side of the Music Module: where "what is playing" comes from
//! and where the controls go. macOS reads it through mediaremote-adapter,
//! Linux through MPRIS on the session bus; each looks like a `MediaSource` to
//! the rest of the application.

use super::command::MusicCommand;
use super::now_playing::NowPlayingReading;
use serde::{Deserialize, Serialize};
use std::sync::mpsc::Sender;

/// What a source tells the Module.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "camelCase")]
// Carries a `NowPlayingReading` as it is (see there).
#[allow(clippy::large_enum_variant)]
pub enum MediaEvent {
    /// One observation: a track, or nothing loaded.
    Reading { reading: NowPlayingReading },
    /// The source stopped or failed: nothing is known to be loaded any more.
    Lost,
    /// Whether the system still lets the application read what is playing.
    Unreadable { unreadable: bool },
}

/// A source of Now Playing and a way to control it.
///
/// - `start` begins reporting on `events`, and keeps doing so (reconnecting as
///   it must) until `stop`. Reports come from any thread.
/// - A reading is the whole picture of the *one* player the system considers
///   current — the platform's own choice, as macOS's Now Playing is: what a
///   person would see in the system's media controls. A player that shows its
///   track there is supported, one that does not is not.
/// - Position is reported as `elapsed` at `elapsed_at` with a `rate`, never as
///   a stream of ticks: the Module moves it on itself.
/// - `send` is fire and forget: the source reports what changed.
///
/// Implementations needed: `macos` (mediaremote-adapter, see `ReaderSupervisor`
/// for its test-then-stream policy), `linux` (MPRIS: choose the playing player,
/// else the most recently active; map `PlaybackStatus`, `Metadata`, `Position`,
/// `Rate`, `mpris:artUrl`).
pub trait MediaSource: Send {
    fn start(&mut self, events: Sender<MediaEvent>);
    fn stop(&mut self);
    fn send(&self, command: MusicCommand);
}

/// What the reader's supervisor asks the platform code to do next.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ReaderAction {
    /// Run the adapter's own `test`, then report back with `test_finished`.
    RunTest,
    /// Start streaming readings.
    StartStream,
    /// End the stream.
    StopStream,
    /// Call `retry_due` after this many seconds.
    ScheduleRetry(f64),
    CancelRetry,
}

/// The macOS reader's policy, as a state machine any source with a "test, then
/// stream" shape can use.
///
/// Starting asks the adapter's own `test` first, because a MediaRemote that has
/// been closed reports exactly what an idle one does — nothing playing — and
/// the two must not look alike. A stream that ends on its own is tested again
/// before it is restarted, so a crash is not mistaken for a closed door. A test
/// that fails is tried again a minute later, and on waking: one failure — a
/// machine just woken, the media service restarting — must not close the Module
/// until it is switched off and on.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ReaderSupervisor {
    running: bool,
    unreadable: bool,
    streaming: bool,
}

impl ReaderSupervisor {
    pub const RETRY_AFTER: f64 = 60.0;

    pub fn new() -> Self {
        Self::default()
    }

    /// The Module is on.
    pub fn is_running(&self) -> bool {
        self.running
    }

    /// The system stopped telling the application what is playing.
    pub fn is_unreadable(&self) -> bool {
        self.unreadable
    }

    /// Controls work only while reading works.
    pub fn can_send(&self) -> bool {
        self.running && !self.unreadable
    }

    pub fn start(&mut self) -> Vec<ReaderAction> {
        if self.running {
            return vec![];
        }
        self.running = true;
        vec![ReaderAction::RunTest]
    }

    pub fn stop(&mut self) -> Vec<ReaderAction> {
        self.running = false;
        self.unreadable = false;
        let was_streaming = std::mem::take(&mut self.streaming);
        let mut actions = vec![ReaderAction::CancelRetry];
        if was_streaming {
            actions.push(ReaderAction::StopStream);
        }
        actions
    }

    /// The adapter could not be found at all: unreadable, and nothing to retry.
    pub fn missing(&mut self) {
        self.unreadable = true;
    }

    pub fn test_finished(&mut self, passed: bool) -> Vec<ReaderAction> {
        if !self.running {
            return vec![];
        }
        if passed {
            self.unreadable = false;
            self.streaming = true;
            vec![ReaderAction::StartStream]
        } else {
            self.unreadable = true;
            vec![ReaderAction::ScheduleRetry(Self::RETRY_AFTER)]
        }
    }

    /// The stream ended on its own: tested again rather than restarted blind.
    pub fn stream_ended(&mut self) -> Vec<ReaderAction> {
        if !self.running || !self.streaming {
            return vec![];
        }
        self.streaming = false;
        vec![ReaderAction::RunTest]
    }

    /// The retry timer fired, or the machine woke.
    pub fn retry_due(&mut self) -> Vec<ReaderAction> {
        if !self.running || !self.unreadable || self.streaming {
            return vec![];
        }
        vec![ReaderAction::CancelRetry, ReaderAction::RunTest]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ReaderAction::*;

    #[test]
    fn starting_tests_before_it_streams() {
        let mut r = ReaderSupervisor::new();
        assert_eq!(r.start(), [RunTest]);
        assert_eq!(r.start(), [], "starting twice does nothing");
        assert_eq!(r.test_finished(true), [StartStream]);
        assert!(r.can_send() && !r.is_unreadable());
    }

    #[test]
    fn a_failed_test_is_unreadable_and_tried_again_a_minute_later() {
        let mut r = ReaderSupervisor::new();
        r.start();
        assert_eq!(r.test_finished(false), [ScheduleRetry(60.0)]);
        assert!(r.is_unreadable() && !r.can_send(), "controls wait for reading");
        assert_eq!(r.retry_due(), [CancelRetry, RunTest]);
        assert_eq!(r.test_finished(true), [StartStream]);
        assert!(!r.is_unreadable(), "and it recovers on its own");
    }

    #[test]
    fn a_stream_that_ends_is_tested_again_not_restarted_blind() {
        let mut r = ReaderSupervisor::new();
        r.start();
        r.test_finished(true);
        assert_eq!(r.stream_ended(), [RunTest]);
        assert_eq!(r.stream_ended(), [], "once");
    }

    #[test]
    fn waking_retries_only_what_is_unreadable_and_not_streaming() {
        let mut r = ReaderSupervisor::new();
        r.start();
        r.test_finished(true);
        assert_eq!(r.retry_due(), [], "a working stream is left alone");
        let mut off = ReaderSupervisor::new();
        assert_eq!(off.retry_due(), [], "and a Module that is off");
    }

    #[test]
    fn stopping_ends_the_stream_and_ignores_late_answers() {
        let mut r = ReaderSupervisor::new();
        r.start();
        r.test_finished(true);
        assert_eq!(r.stop(), [CancelRetry, StopStream]);
        assert_eq!(r.test_finished(true), [], "a test that finishes after the Module went off changes nothing");
        assert_eq!(r.stream_ended(), []);
        assert!(!r.is_running());
    }

    #[test]
    fn a_missing_adapter_is_unreadable_without_a_retry() {
        let mut r = ReaderSupervisor::new();
        r.start();
        r.missing();
        assert!(r.is_unreadable());
        assert_eq!(r.stop(), [CancelRetry]);
    }

    #[test]
    fn events_cross_the_wire_as_tagged_json() {
        let e = MediaEvent::Unreadable { unreadable: true };
        let json = serde_json::to_string(&e).unwrap();
        assert_eq!(json, r#"{"event":"unreadable","unreadable":true}"#);
        assert_eq!(serde_json::from_str::<MediaEvent>(&json).unwrap(), e);
        let lost = serde_json::to_string(&MediaEvent::Lost).unwrap();
        assert_eq!(lost, r#"{"event":"lost"}"#);
    }
}
