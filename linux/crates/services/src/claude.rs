//! Reads Claude Capacity through Claude Code itself: its own `/usage`, and the
//! status-line bridge where one runs. This service has no credential or
//! network boundary of its own.

use crate::{Clock, SnapshotSink};
use capa_core::claude::{self, ClaudeCapacityReading, SourceError, UsageCommandError, ARGUMENTS, FRESH_FOR};
use capa_core::claude_bridge::{self, BridgeError};
use capa_core::{CapacitySnapshot, CapacityStatusReason, ConnectionState, Provider};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub trait CapacitySource: Send + Sync {
    fn read(&self) -> Result<ClaudeCapacityReading, SourceError>;
}

impl<T: CapacitySource + ?Sized> CapacitySource for Arc<T> {
    fn read(&self) -> Result<ClaudeCapacityReading, SourceError> {
        (**self).read()
    }
}

/// Long enough for a cold start on a busy machine, short enough that a wedged
/// process cannot hold a refresh open.
pub const TIMEOUT: Duration = Duration::from_secs(20);

/// How long the output is waited for once Claude Code has gone.
const DRAIN_GRACE: Duration = Duration::from_secs(1);

pub fn search_paths(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(".claude/local/claude"),
        home.join(".local/bin/claude"),
        home.join(".npm-global/bin/claude"),
        "/usr/local/bin/claude".into(),
        "/usr/bin/claude".into(),
    ]
}

pub fn locate(home: &Path) -> Option<PathBuf> {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .map(|d| d.join("claude"))
        .chain(search_paths(home))
        .find(|p| capa_core::codex::is_executable(p))
}

/// Somewhere of its own for Claude Code to be run from. Without one the child
/// inherits the daemon's directory, and Claude Code reaches around whatever
/// directory it starts in; one fixed directory also means it keys at most one
/// project folder on it.
fn scratch_directory(home: &Path) -> PathBuf {
    let dir = capa_core::dirs::state(home).join("claude-usage");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Asks Claude Code for its own usage. `/usage` is a local command: it sends
/// no prompt to the model.
pub struct UsageCommandSource {
    home: PathBuf,
    timeout: Duration,
    now: Clock,
}

impl UsageCommandSource {
    pub fn new(home: PathBuf, now: Clock) -> Self {
        Self { home, timeout: TIMEOUT, now }
    }

    fn run(&self) -> Result<String, UsageCommandError> {
        let executable = locate(&self.home).ok_or(UsageCommandError::ClaudeCodeNotInstalled)?;
        let mut command = Command::new(executable);
        command
            .args(ARGUMENTS)
            .current_dir(scratch_directory(&self.home))
            .env("PATH", crate::codex::environment_path())
            .stdin(Stdio::null()) // print mode reads stdin; an empty one ends it at once
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = command.spawn().map_err(|_| UsageCommandError::CommandFailed)?;

        // Drained alongside the wait, never ahead of it: reading to the end
        // waits for a process that may never close the pipe, and a process
        // whose output fills the pipe cannot exit until someone reads it.
        let mut stdout = child.stdout.take().ok_or(UsageCommandError::CommandFailed)?;
        let (drained, collected) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut text = Vec::new();
            let _ = stdout.read_to_end(&mut text);
            let _ = drained.send(text);
        });

        let deadline = Instant::now() + self.timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(40)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(UsageCommandError::CommandFailed);
                }
            }
        };
        // Gone, so what it wrote is at most a moment behind — unless something
        // it started still holds the pipe, which is not worth waiting on.
        let bytes = collected.recv_timeout(DRAIN_GRACE).map_err(|_| UsageCommandError::CommandFailed)?;
        if !status.success() {
            return Err(UsageCommandError::CommandFailed);
        }
        String::from_utf8(bytes).map_err(|_| UsageCommandError::CommandFailed)
    }
}

impl CapacitySource for UsageCommandSource {
    fn read(&self) -> Result<ClaudeCapacityReading, SourceError> {
        let text = self.run()?;
        Ok(claude::reading(&text, (self.now)()).ok_or(UsageCommandError::OutputNotUnderstood)?)
    }
}

/// The file Claude Code's status-line bridge writes (`ClaudeFileCapacitySource`).
pub struct FileSource {
    pub path: PathBuf,
}

impl FileSource {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

impl CapacitySource for FileSource {
    fn read(&self) -> Result<ClaudeCapacityReading, SourceError> {
        Ok(claude_bridge::read_file(&self.path)?)
    }
}

/// Takes whichever source has the newer reading (`NewestClaudeCapacity`).
///
/// The status-line bridge and `/usage` describe the same windows, so the
/// question is never which source to believe but which one saw them last.
///
/// When none has a reading, the failure passed on is the one that says what
/// to fix: `/usage`'s first, since it is the source that works wherever the
/// person is, then anything else, and last a bridge that has published
/// nothing — usually a bridge nobody set up, the normal case outside a terminal.
///
/// Nor does an old reading stand in for a source that just failed: a bridge
/// last run yesterday still has yesterday's file, and handing that on would
/// roll the surface back a day and bury the failure that says what to fix.
pub struct NewestSource {
    sources: Vec<Box<dyn CapacitySource>>,
    stale_after: chrono::Duration,
    now: Clock,
}

impl NewestSource {
    pub fn new(sources: Vec<Box<dyn CapacitySource>>, now: Clock) -> Self {
        let stale_after = chrono::Duration::from_std(FRESH_FOR).unwrap_or_else(|_| chrono::Duration::minutes(5));
        Self { sources, stale_after, now }
    }
}

impl CapacitySource for NewestSource {
    fn read(&self) -> Result<ClaudeCapacityReading, SourceError> {
        let mut readings: Vec<ClaudeCapacityReading> = Vec::new();
        let mut failures: Vec<SourceError> = Vec::new();
        for source in &self.sources {
            match source.read() {
                Ok(reading) => readings.push(reading),
                Err(error) => failures.push(error),
            }
        }

        let telling = failures
            .iter()
            .find(|e| matches!(e, SourceError::Usage(_)))
            .or_else(|| failures.iter().find(|e| **e != SourceError::Bridge(BridgeError::MissingSnapshot)))
            .copied();
        // Of two equally new, the first, as Swift's `max(by:)` keeps it.
        let Some(newest) = readings.into_iter().reduce(|a, b| if b.captured_at > a.captured_at { b } else { a }) else {
            return Err(telling.or_else(|| failures.first().copied()).unwrap_or(SourceError::Bridge(BridgeError::MissingSnapshot)));
        };
        if let Some(telling) = telling {
            if (self.now)() - newest.captured_at > self.stale_after {
                return Err(telling);
            }
        }
        Ok(newest)
    }
}

/// Holds a source's last answer for a while. `/usage` costs a subprocess and
/// a couple of seconds; running Claude Code every minute to learn a
/// percentage that moves slowly would be rude to the machine.
pub struct ThrottledSource<S> {
    source: S,
    interval: Duration,
    failure_interval: Duration,
    now: Arc<dyn Fn() -> Instant + Send + Sync>,
    last: Mutex<Option<(Instant, Result<ClaudeCapacityReading, SourceError>)>>,
}

impl<S: CapacitySource> ThrottledSource<S> {
    /// An answer is held for `interval`; a failure only for `failure_interval`,
    /// since holding a failure as long as an answer kept Claude unread for
    /// minutes after an update.
    pub fn new(source: S, interval: Duration, failure_interval: Duration) -> Self {
        Self::with_clock(source, interval, failure_interval, Arc::new(Instant::now))
    }

    pub fn with_clock(
        source: S,
        interval: Duration,
        failure_interval: Duration,
        now: Arc<dyn Fn() -> Instant + Send + Sync>,
    ) -> Self {
        Self { source, interval, failure_interval: failure_interval.min(interval), now, last: Mutex::new(None) }
    }
}

impl<S: CapacitySource> CapacitySource for ThrottledSource<S> {
    fn read(&self) -> Result<ClaudeCapacityReading, SourceError> {
        let mut last = self.last.lock().unwrap();
        if let Some((at, held)) = &*last {
            let holds_for = if held.is_ok() { self.interval } else { self.failure_interval };
            if (self.now)().saturating_duration_since(*at) < holds_for {
                return held.clone();
            }
        }
        let result = self.source.read();
        *last = Some(((self.now)(), result.clone()));
        result
    }
}

#[derive(Default)]
struct State {
    connected: bool,
    last_successful: Option<CapacitySnapshot>,
}

#[derive(Clone)]
pub struct ClaudeService {
    state: Arc<tokio::sync::Mutex<State>>,
    source: Arc<dyn CapacitySource>,
    sink: SnapshotSink,
    now: Clock,
    stale_after: chrono::Duration,
}

impl ClaudeService {
    pub fn new(sink: SnapshotSink, now: Clock, source: Arc<dyn CapacitySource>) -> Self {
        Self {
            state: Default::default(),
            source,
            sink,
            now,
            stale_after: chrono::Duration::from_std(FRESH_FOR).unwrap_or_else(|_| chrono::Duration::minutes(5)),
        }
    }

    pub fn with_stale_after(mut self, stale_after: chrono::Duration) -> Self {
        self.stale_after = stale_after;
        self
    }

    pub async fn connect(&self) {
        {
            let mut state = self.state.lock().await;
            if state.connected {
                return;
            }
            state.connected = true;
        }
        self.refresh().await;
    }

    pub async fn refresh(&self) {
        if !self.state.lock().await.connected {
            return;
        }
        let source = self.source.clone();
        // A subprocess and a wait: kept off the async threads.
        let read = tokio::task::spawn_blocking(move || source.read())
            .await
            .unwrap_or(Err(SourceError::Usage(UsageCommandError::CommandFailed)));

        let mut state = self.state.lock().await;
        if !state.connected {
            return; // switched off while asking: the switched-off card stands
        }
        match read {
            Ok(reading) => {
                let stale = (self.now)() - reading.captured_at > self.stale_after;
                let snapshot = CapacitySnapshot {
                    provider: Provider::ClaudeCode,
                    captured_at: reading.captured_at,
                    windows: reading.windows,
                    connection_state: if stale { ConnectionState::Stale } else { ConnectionState::Fresh },
                    status_reason: stale.then_some(CapacityStatusReason::ClaudeStatusLineStale),
                };
                state.last_successful = Some(snapshot.clone());
                let _ = self.sink.send(snapshot);
            }
            Err(error) => self.hold_last_or_disconnect(&state, reason(error)),
        }
    }

    pub async fn disconnect(&self) {
        let mut state = self.state.lock().await;
        state.connected = false;
        state.last_successful = None;
        let _ = self.sink.send(CapacitySnapshot::disconnected(
            Provider::ClaudeCode,
            (self.now)(),
            CapacityStatusReason::ClaudeDisconnected,
        ));
    }

    fn hold_last_or_disconnect(&self, state: &State, reason: CapacityStatusReason) {
        let snapshot = match &state.last_successful {
            Some(last) => CapacitySnapshot {
                connection_state: ConnectionState::Stale,
                status_reason: Some(reason),
                ..last.clone()
            },
            None => CapacitySnapshot::disconnected(Provider::ClaudeCode, (self.now)(), reason),
        };
        let _ = self.sink.send(snapshot);
    }
}

/// The failure said as the one thing that would fix it. `/usage` fails in
/// three different ways and each wants a different hand; anything else came
/// from the status-line bridge.
fn reason(error: SourceError) -> CapacityStatusReason {
    match error {
        SourceError::Usage(UsageCommandError::ClaudeCodeNotInstalled) => CapacityStatusReason::ClaudeCodeNotInstalled,
        SourceError::Usage(UsageCommandError::CommandFailed) => CapacityStatusReason::ClaudeUsageFailed,
        SourceError::Usage(UsageCommandError::OutputNotUnderstood) => CapacityStatusReason::ClaudeUsageNotUnderstood,
        SourceError::Bridge(_) => CapacityStatusReason::ClaudeStatusLineUnavailable,
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::QuotaWindow;
    use chrono::{TimeZone, Utc};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::mpsc;

    fn t0() -> chrono::DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    fn reading(at: chrono::DateTime<Utc>) -> ClaudeCapacityReading {
        ClaudeCapacityReading { captured_at: at, windows: vec![QuotaWindow::new("claude-five-hour", "5 hour", Some(300), 0.24, None)] }
    }

    struct Scripted(Mutex<Vec<Result<ClaudeCapacityReading, SourceError>>>, AtomicUsize);

    impl Scripted {
        fn new(answers: Vec<Result<ClaudeCapacityReading, UsageCommandError>>) -> Arc<Self> {
            Self::answering(answers.into_iter().map(|a| a.map_err(SourceError::Usage)).collect())
        }

        fn answering(mut answers: Vec<Result<ClaudeCapacityReading, SourceError>>) -> Arc<Self> {
            answers.reverse();
            Arc::new(Self(Mutex::new(answers), AtomicUsize::new(0)))
        }
    }

    impl CapacitySource for Scripted {
        fn read(&self) -> Result<ClaudeCapacityReading, SourceError> {
            self.1.fetch_add(1, Ordering::SeqCst);
            self.0.lock().unwrap().pop().expect("an answer was scripted")
        }
    }

    fn newest(sources: Vec<Arc<Scripted>>) -> NewestSource {
        NewestSource::new(sources.into_iter().map(|s| Box::new(s) as Box<dyn CapacitySource>).collect(), Arc::new(t0))
    }

    const MISSING: SourceError = SourceError::Bridge(BridgeError::MissingSnapshot);
    const FAILED: SourceError = SourceError::Usage(UsageCommandError::CommandFailed);

    #[test]
    fn the_newer_reading_wins_whichever_source_it_came_from() {
        let bridge = Scripted::answering(vec![Ok(reading(t0() - chrono::Duration::seconds(10)))]);
        let usage = Scripted::answering(vec![Ok(reading(t0() - chrono::Duration::seconds(100)))]);
        assert_eq!(newest(vec![bridge, usage]).read().unwrap().captured_at, t0() - chrono::Duration::seconds(10));
    }

    #[test]
    fn a_failure_is_told_only_when_the_newest_reading_is_old() {
        // A fresh bridge reading stands over a `/usage` that failed.
        let fresh = Scripted::answering(vec![Ok(reading(t0() - chrono::Duration::seconds(60)))]);
        assert!(newest(vec![fresh, Scripted::answering(vec![Err(FAILED)])]).read().is_ok());
        // Yesterday's file does not bury the failure that says what to fix.
        let old = Scripted::answering(vec![Ok(reading(t0() - chrono::Duration::seconds(301)))]);
        assert_eq!(newest(vec![old, Scripted::answering(vec![Err(FAILED)])]).read(), Err(FAILED));
        // A bridge nobody set up is not worth telling while it is the only failure.
        let old = Scripted::answering(vec![Ok(reading(t0() - chrono::Duration::hours(1)))]);
        assert!(newest(vec![Scripted::answering(vec![Err(MISSING)]), old]).read().is_ok());
    }

    #[test]
    fn with_nothing_read_usage_says_what_to_fix_before_the_bridge() {
        let unknown = SourceError::Bridge(BridgeError::UnsupportedSchema);
        let both = newest(vec![Scripted::answering(vec![Err(unknown)]), Scripted::answering(vec![Err(FAILED)])]);
        assert_eq!(both.read(), Err(FAILED));
        let bridge_only = newest(vec![Scripted::answering(vec![Err(MISSING)]), Scripted::answering(vec![Err(unknown)])]);
        assert_eq!(bridge_only.read(), Err(unknown));
        assert_eq!(newest(vec![Scripted::answering(vec![Err(MISSING)])]).read(), Err(MISSING));
    }

    #[tokio::test]
    async fn a_bridge_failure_asks_for_the_status_line() {
        let (service, mut rx) = service(Scripted::answering(vec![Err(SourceError::Bridge(BridgeError::MalformedInput))]));
        service.connect().await;
        assert_eq!(rx.recv().await.unwrap().status_reason, Some(CapacityStatusReason::ClaudeStatusLineUnavailable));
    }

    #[cfg(unix)]
    #[test]
    fn a_grandchild_holding_the_pipe_does_not_hold_the_reading() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("capa-claude-drain-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let bin = home.join(".local/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let claude = bin.join("claude");
        // Prints a report, leaves a sleeper holding stdout, and exits at once.
        std::fs::write(&claude, "#!/bin/sh\necho 'Current session: 24% used'\n(sleep 30) &\nexit 0\n").unwrap();
        std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
        let source = UsageCommandSource { home: home.clone(), timeout: Duration::from_secs(10), now: Arc::new(t0) };
        // Only this test's `claude`: what is on the machine's PATH is not looked at.
        let started = Instant::now();
        let read = with_path_of(&bin, || source.run());
        assert!(started.elapsed() < Duration::from_secs(5), "waited {:?}", started.elapsed());
        assert_eq!(read, Err(UsageCommandError::CommandFailed), "the output is not waited for past a second");
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Runs `body` with only `dir` on `PATH`, one test at a time.
    #[cfg(unix)]
    fn with_path_of<R>(dir: &Path, body: impl FnOnce() -> R) -> R {
        static LOCK: Mutex<()> = Mutex::new(());
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let before = std::env::var_os("PATH");
        std::env::set_var("PATH", std::env::join_paths([dir, Path::new("/usr/bin"), Path::new("/bin")]).unwrap());
        let result = body();
        match before {
            Some(path) => std::env::set_var("PATH", path),
            None => std::env::remove_var("PATH"),
        }
        result
    }

    fn service(source: Arc<dyn CapacitySource>) -> (ClaudeService, mpsc::UnboundedReceiver<CapacitySnapshot>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (ClaudeService::new(tx, Arc::new(t0), source), rx)
    }

    #[tokio::test]
    async fn a_reading_becomes_fresh_capacity() {
        let (service, mut rx) = service(Scripted::new(vec![Ok(reading(t0()))]));
        service.connect().await;
        let s = rx.recv().await.unwrap();
        assert_eq!(s.connection_state, ConnectionState::Fresh);
        assert_eq!(s.provider, Provider::ClaudeCode);
        assert_eq!(s.windows[0].remaining_percentage(), 76.0);
    }

    #[tokio::test]
    async fn an_old_reading_is_stale() {
        let (service, mut rx) = service(Scripted::new(vec![Ok(reading(t0() - chrono::Duration::minutes(10)))]));
        service.connect().await;
        let s = rx.recv().await.unwrap();
        assert_eq!(s.connection_state, ConnectionState::Stale);
        assert_eq!(s.status_reason, Some(CapacityStatusReason::ClaudeStatusLineStale));
    }

    #[tokio::test]
    async fn each_failure_says_the_one_thing_that_fixes_it() {
        for (error, expected) in [
            (UsageCommandError::ClaudeCodeNotInstalled, CapacityStatusReason::ClaudeCodeNotInstalled),
            (UsageCommandError::CommandFailed, CapacityStatusReason::ClaudeUsageFailed),
            (UsageCommandError::OutputNotUnderstood, CapacityStatusReason::ClaudeUsageNotUnderstood),
        ] {
            let (service, mut rx) = service(Scripted::new(vec![Err(error)]));
            service.connect().await;
            let s = rx.recv().await.unwrap();
            assert_eq!(s.status_reason, Some(expected));
            assert!(s.windows.is_empty(), "nothing read is never zero");
        }
    }

    #[tokio::test]
    async fn a_failure_after_a_reading_keeps_it_as_stale() {
        let (service, mut rx) = service(Scripted::new(vec![Ok(reading(t0())), Err(UsageCommandError::CommandFailed)]));
        service.connect().await;
        rx.recv().await.unwrap();
        service.refresh().await;
        let s = rx.recv().await.unwrap();
        assert_eq!(s.connection_state, ConnectionState::Stale);
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.status_reason, Some(CapacityStatusReason::ClaudeUsageFailed));
    }

    #[tokio::test]
    async fn disconnecting_says_it_was_switched_off_and_refresh_then_does_nothing() {
        let source = Scripted::new(vec![Ok(reading(t0()))]);
        let (service, mut rx) = service(source.clone());
        service.connect().await;
        rx.recv().await.unwrap();
        service.disconnect().await;
        assert_eq!(rx.recv().await.unwrap().status_reason, Some(CapacityStatusReason::ClaudeDisconnected));
        service.refresh().await;
        assert!(rx.try_recv().is_err());
        assert_eq!(source.1.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_throttled_source_holds_an_answer_and_a_failure_for_different_times() {
        let clock = Arc::new(Mutex::new(Instant::now()));
        let tick = clock.clone();
        let now: Arc<dyn Fn() -> Instant + Send + Sync> = Arc::new(move || *tick.lock().unwrap());
        let advance = |s: u64| *clock.lock().unwrap() += Duration::from_secs(s);

        let inner = Scripted::new(vec![Err(UsageCommandError::CommandFailed), Ok(reading(t0())), Ok(reading(t0()))]);
        let throttled = ThrottledSource::with_clock(inner.clone(), Duration::from_secs(300), Duration::from_secs(30), now);

        assert!(throttled.read().is_err());
        advance(10);
        assert!(throttled.read().is_err(), "a failure is held briefly");
        assert_eq!(inner.1.load(Ordering::SeqCst), 1);
        advance(25);
        assert!(throttled.read().is_ok(), "then asked again");
        advance(200);
        assert!(throttled.read().is_ok());
        assert_eq!(inner.1.load(Ordering::SeqCst), 2, "an answer is held for the long interval");
        advance(101);
        assert!(throttled.read().is_ok());
        assert_eq!(inner.1.load(Ordering::SeqCst), 3);
    }
}
