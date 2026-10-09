//! Reads OpenCode Go's Capacity: the key from OpenCode's file at each request
//! (ADR 0001, amended), the endpoint no more often than every five minutes
//! unless a person asks. A failure after a reading keeps it as Stale
//! Capacity, and nothing read is never drawn as zero.

use crate::{Clock, SnapshotSink};
use capa_core::opencode::{self, Month, USAGE_URL};
use capa_core::{CapacitySnapshot, CapacityStatusReason, ConnectionState, Provider};
use chrono::{DateTime, Utc};
use std::sync::Arc;
use std::time::Duration;

pub const MINIMUM_INTERVAL: chrono::Duration = chrono::Duration::minutes(5);

/// The usage endpoint could not be reached (or no key was there to ask with).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Unreachable;

/// Asks the usage endpoint once. Separate so tests answer without a network.
pub trait UsageClient: Send + Sync {
    /// `(status, body)`, or an error when the endpoint could not be reached.
    fn usage(&self, key: &str) -> Result<(u16, Vec<u8>), Unreachable>;
}

pub struct HttpClient;

impl UsageClient for HttpClient {
    fn usage(&self, key: &str) -> Result<(u16, Vec<u8>), Unreachable> {
        use std::io::Read;
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(20)))
            .http_status_as_error(false)
            .build()
            .into();
        let mut response = agent
            .get(USAGE_URL)
            .header("Authorization", &format!("Bearer {key}"))
            .header("Accept", "application/json")
            .call()
            .map_err(|_| Unreachable)?;
        let status = response.status().as_u16();
        let mut body = Vec::new();
        // Nothing of the answer is kept: it carries the person's plan.
        response.body_mut().as_reader().take(1 << 20).read_to_end(&mut body).map_err(|_| Unreachable)?;
        Ok((status, body))
    }
}

#[derive(Default)]
struct State {
    connected: bool,
    last_asked: Option<DateTime<Utc>>,
    last_successful: Option<CapacitySnapshot>,
}

#[derive(Clone)]
pub struct OpenCodeService {
    state: Arc<tokio::sync::Mutex<State>>,
    sink: SnapshotSink,
    now: Clock,
    read_key: Arc<dyn Fn() -> Option<String> + Send + Sync>,
    client: Arc<dyn UsageClient>,
}

impl OpenCodeService {
    pub fn new(
        sink: SnapshotSink,
        now: Clock,
        read_key: Arc<dyn Fn() -> Option<String> + Send + Sync>,
        client: Arc<dyn UsageClient>,
    ) -> Self {
        Self { state: Default::default(), sink, now, read_key, client }
    }

    pub fn with_http(sink: SnapshotSink, now: Clock) -> Self {
        let home = crate::codex::home_dir();
        Self::new(sink, now, Arc::new(move || opencode::read_key_anywhere(&home)), Arc::new(HttpClient))
    }

    pub async fn connect(&self) {
        {
            let mut state = self.state.lock().await;
            if state.connected {
                return;
            }
            state.connected = true;
        }
        self.refresh(true).await;
    }

    /// Asks the endpoint unless it was asked less than five minutes ago;
    /// `force` is a person asking, which is answered at once.
    pub async fn refresh(&self, force: bool) {
        {
            let mut state = self.state.lock().await;
            if !state.connected {
                return;
            }
            let now = (self.now)();
            if !force && state.last_asked.is_some_and(|at| now - at < MINIMUM_INTERVAL) {
                return;
            }
            state.last_asked = Some(now);
            // The key is read at each request and kept nowhere.
            if (self.read_key)().is_none() {
                self.hold_last_or_disconnect(&state, CapacityStatusReason::OpenCodeNotSignedIn);
                return;
            }
        }

        let (read_key, client) = (self.read_key.clone(), self.client.clone());
        let answer = tokio::task::spawn_blocking(move || {
            let key = read_key().ok_or(Unreachable)?;
            client.usage(&key)
        })
        .await
        .unwrap_or(Err(Unreachable));

        let mut state = self.state.lock().await;
        // Disconnected while asking: the switched-off card stands, not an
        // "unreachable" that arrived after it.
        if !state.connected {
            return;
        }
        let Ok((status, body)) = answer else {
            return self.hold_last_or_disconnect(&state, CapacityStatusReason::OpenCodeUnreachable);
        };

        match status {
            200 => {
                let Some(reading) = opencode::parse_usage(&body) else {
                    return self.hold_last_or_disconnect(&state, CapacityStatusReason::OpenCodeAnswerNotUnderstood);
                };
                let snapshot = CapacitySnapshot {
                    provider: Provider::OpenCode,
                    captured_at: (self.now)(),
                    windows: reading.windows,
                    connection_state: ConnectionState::Fresh,
                    status_reason: match reading.month {
                        Month::UsedUp { until } => Some(CapacityStatusReason::OpenCodeMonthlyLimitReached(until)),
                        Month::Available => None,
                    },
                };
                state.last_successful = Some(snapshot.clone());
                let _ = self.sink.send(snapshot);
            }
            401 | 403 => self.hold_last_or_disconnect(&state, CapacityStatusReason::OpenCodeKeyRefused),
            _ => self.hold_last_or_disconnect(&state, CapacityStatusReason::OpenCodeUnreachable),
        }
    }

    pub async fn disconnect(&self) {
        let mut state = self.state.lock().await;
        state.connected = false;
        state.last_successful = None;
        state.last_asked = None;
        let _ = self.sink.send(CapacitySnapshot::disconnected(
            Provider::OpenCode,
            (self.now)(),
            CapacityStatusReason::OpenCodeDisconnected,
        ));
    }

    fn hold_last_or_disconnect(&self, state: &State, reason: CapacityStatusReason) {
        let snapshot = match &state.last_successful {
            Some(last) => CapacitySnapshot {
                connection_state: ConnectionState::Stale,
                status_reason: Some(reason),
                ..last.clone()
            },
            None => CapacitySnapshot::disconnected(Provider::OpenCode, (self.now)(), reason),
        };
        let _ = self.sink.send(snapshot);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;
    use tokio::sync::mpsc;

    const OK: &str = r#"{"usage":{"rolling":{"status":"ok","percent":30},"weekly":{"status":"ok","percent":55}}}"#;

    type Answer = Result<(u16, Vec<u8>), Unreachable>;

    struct Answers {
        queue: Mutex<Vec<Answer>>,
        asked: AtomicUsize,
        keys: Mutex<Vec<String>>,
    }

    impl Answers {
        fn new(mut q: Vec<Answer>) -> Arc<Self> {
            q.reverse();
            Arc::new(Self { queue: Mutex::new(q), asked: AtomicUsize::new(0), keys: Default::default() })
        }
    }

    impl UsageClient for Answers {
        fn usage(&self, key: &str) -> Result<(u16, Vec<u8>), Unreachable> {
            self.asked.fetch_add(1, Ordering::SeqCst);
            self.keys.lock().unwrap().push(key.into());
            self.queue.lock().unwrap().pop().expect("an answer was scripted")
        }
    }

    struct Rig {
        service: OpenCodeService,
        rx: mpsc::UnboundedReceiver<CapacitySnapshot>,
        client: Arc<Answers>,
        clock: Arc<Mutex<DateTime<Utc>>>,
    }

    fn rig(key: Option<&'static str>, answers: Vec<Answer>) -> Rig {
        let (tx, rx) = mpsc::unbounded_channel();
        let client = Answers::new(answers);
        let clock = Arc::new(Mutex::new(Utc.timestamp_opt(1_700_000_000, 0).unwrap()));
        let c = clock.clone();
        let service = OpenCodeService::new(
            tx,
            Arc::new(move || *c.lock().unwrap()),
            Arc::new(move || key.map(str::to_owned)),
            client.clone(),
        );
        Rig { service, rx, client, clock }
    }

    #[tokio::test]
    async fn an_answer_becomes_fresh_capacity_and_the_key_is_sent() {
        let mut r = rig(Some("sk-go"), vec![Ok((200, OK.into()))]);
        r.service.connect().await;
        let s = r.rx.recv().await.unwrap();
        assert_eq!(s.connection_state, ConnectionState::Fresh);
        assert_eq!(s.windows.len(), 2);
        assert_eq!(*r.client.keys.lock().unwrap(), ["sk-go"]);
    }

    #[tokio::test]
    async fn no_key_means_not_signed_in_and_nothing_is_asked() {
        let mut r = rig(None, vec![]);
        r.service.connect().await;
        assert_eq!(r.rx.recv().await.unwrap().status_reason, Some(CapacityStatusReason::OpenCodeNotSignedIn));
        assert_eq!(r.client.asked.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn the_endpoint_is_asked_at_most_every_five_minutes_unless_forced() {
        let mut r = rig(Some("k"), vec![Ok((200, OK.into())), Ok((200, OK.into())), Ok((200, OK.into()))]);
        r.service.connect().await;
        r.service.refresh(false).await;
        assert_eq!(r.client.asked.load(Ordering::SeqCst), 1, "too soon");
        *r.clock.lock().unwrap() += chrono::Duration::minutes(6);
        r.service.refresh(false).await;
        assert_eq!(r.client.asked.load(Ordering::SeqCst), 2);
        r.service.refresh(true).await;
        assert_eq!(r.client.asked.load(Ordering::SeqCst), 3, "a person asking is answered at once");
        while r.rx.try_recv().is_ok() {}
    }

    #[tokio::test]
    async fn statuses_say_what_is_wrong() {
        for (status, expected) in [
            (401, CapacityStatusReason::OpenCodeKeyRefused),
            (403, CapacityStatusReason::OpenCodeKeyRefused),
            (500, CapacityStatusReason::OpenCodeUnreachable),
        ] {
            let mut r = rig(Some("k"), vec![Ok((status, vec![]))]);
            r.service.connect().await;
            assert_eq!(r.rx.recv().await.unwrap().status_reason, Some(expected), "{status}");
        }
        let mut r = rig(Some("k"), vec![Err(Unreachable)]);
        r.service.connect().await;
        assert_eq!(r.rx.recv().await.unwrap().status_reason, Some(CapacityStatusReason::OpenCodeUnreachable));
        let mut r = rig(Some("k"), vec![Ok((200, b"{}".to_vec()))]);
        r.service.connect().await;
        assert_eq!(r.rx.recv().await.unwrap().status_reason, Some(CapacityStatusReason::OpenCodeAnswerNotUnderstood));
    }

    #[tokio::test]
    async fn a_failure_after_a_reading_keeps_it_stale() {
        let mut r = rig(Some("k"), vec![Ok((200, OK.into())), Err(Unreachable)]);
        r.service.connect().await;
        r.rx.recv().await.unwrap();
        r.service.refresh(true).await;
        let s = r.rx.recv().await.unwrap();
        assert_eq!(s.connection_state, ConnectionState::Stale);
        assert_eq!(s.windows.len(), 2);
    }

    #[tokio::test]
    async fn a_used_up_month_is_said_on_a_fresh_reading() {
        let body = r#"{"usage":{"rolling":{"status":"ok","percent":1},"weekly":{"status":"ok","percent":1},"monthly":{"status":"rate-limited","percent":100}}}"#;
        let mut r = rig(Some("k"), vec![Ok((200, body.into()))]);
        r.service.connect().await;
        let s = r.rx.recv().await.unwrap();
        assert_eq!(s.connection_state, ConnectionState::Fresh);
        assert!(matches!(s.status_reason, Some(CapacityStatusReason::OpenCodeMonthlyLimitReached(_))));
    }

    #[tokio::test]
    async fn disconnecting_forgets_and_goes_quiet() {
        let mut r = rig(Some("k"), vec![Ok((200, OK.into()))]);
        r.service.connect().await;
        r.rx.recv().await.unwrap();
        r.service.disconnect().await;
        assert_eq!(r.rx.recv().await.unwrap().status_reason, Some(CapacityStatusReason::OpenCodeDisconnected));
        r.service.refresh(true).await;
        assert!(r.rx.try_recv().is_err());
    }
}
