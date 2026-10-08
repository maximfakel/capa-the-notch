//! A held key owns one recording. The generation remains valid only until
//! cancellation or completion; inference may finish after either.

use serde::{Deserialize, Serialize};

/// Which recording a result belongs to. Numbers rather than UUIDs, counted up
/// by the session that hands them out, so no one else can make one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SessionId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Recording(SessionId),
    Recognizing(SessionId),
}

#[derive(Debug, Clone)]
pub struct DictationSession {
    phase: Phase,
    made: u64,
}

impl Default for DictationSession {
    fn default() -> Self {
        Self::new()
    }
}

impl DictationSession {
    /// A recording is cut off after this many seconds.
    pub const MAXIMUM_DURATION_SECONDS: u32 = 60;
    /// The most audio a recording keeps: sixty seconds at 16 kHz.
    pub const LIMIT_SAMPLES: usize = 960_000;

    pub fn new() -> Self {
        Self { phase: Phase::Idle, made: 0 }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn begin(&mut self) -> Option<SessionId> {
        if self.phase != Phase::Idle {
            return None;
        }
        self.made += 1;
        let id = SessionId(self.made);
        self.phase = Phase::Recording(id);
        Some(id)
    }

    pub fn stop(&mut self) -> Option<SessionId> {
        match self.phase {
            Phase::Recording(id) => {
                self.phase = Phase::Recognizing(id);
                Some(id)
            }
            _ => None,
        }
    }

    pub fn cancel(&mut self) {
        self.phase = Phase::Idle;
    }

    pub fn complete(&mut self, id: SessionId) -> bool {
        if self.phase != Phase::Recognizing(id) {
            return false;
        }
        self.phase = Phase::Idle;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dictation_stops_once_and_rejects_cancelled_results() {
        let mut session = DictationSession::new();
        let id = session.begin().unwrap();
        assert!(session.begin().is_none(), "A repeated key down must not start another recording");
        assert_eq!(session.stop(), Some(id), "The limit stops the current recording");
        assert_eq!(session.stop(), None, "Key release after the limit must not decode twice");
        session.cancel();
        assert!(!session.complete(id), "A cancelled decode must never deliver");
        let next = session.begin().unwrap();
        session.stop();
        assert!(!session.complete(id), "An old result cannot complete a new recording");
        assert!(session.complete(next), "The current result can complete once");
        assert!(!session.complete(next), "A duplicate completion cannot deliver twice");
    }

    #[test]
    fn a_recording_in_progress_refuses_a_second_and_a_recognition_in_progress_does_too() {
        let mut session = DictationSession::new();
        session.begin().unwrap();
        session.stop();
        assert!(session.begin().is_none(), "recognising owns the session until it completes or is cancelled");
        assert!(matches!(session.phase(), Phase::Recognizing(_)));
    }

    #[test]
    fn ids_are_never_reused() {
        let mut session = DictationSession::new();
        let a = session.begin().unwrap();
        session.cancel();
        let b = session.begin().unwrap();
        assert_ne!(a, b);
    }
}
