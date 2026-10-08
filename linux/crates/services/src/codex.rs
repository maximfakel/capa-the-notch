//! Connects Codex and turns its App Server readings into Capacity Snapshots.
//!
//! The service owns exactly one App Server process at a time: it starts it on
//! connect, ends that same process on disconnect, and never touches a Codex
//! process it did not start.

use crate::{Clock, SnapshotSink};
use capa_core::codex::{
    self, method, AccountResponse, Inbound, RateLimitSnapshot, RateLimitsResponse, RateLimitsUpdated, RpcFailure,
};
use capa_core::{CapacitySnapshot, CapacityStatusReason, ConnectionState, Provider};
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

/// A duplex line channel to one App Server. `lines` ends when the App Server
/// goes away.
pub struct Transport {
    pub lines: mpsc::UnboundedReceiver<String>,
    pub send: SendLine,
    /// Ends only the App Server this transport started.
    pub terminate: Terminate,
}

/// Writes one line to the App Server.
pub type SendLine = Box<dyn Fn(&str) -> io::Result<()> + Send + Sync>;
/// Ends the App Server a transport started.
pub type Terminate = Box<dyn Fn() + Send + Sync>;

pub type TransportFactory = Arc<dyn Fn() -> Result<Option<Transport>, String> + Send + Sync>;

#[derive(Debug, Clone, PartialEq)]
pub enum RpcError {
    Failure(RpcFailure),
    Closed,
    /// The App Server answered in a shape this build cannot read.
    Undecodable,
    NotPermitted(String),
}

struct Notification {
    method: String,
    params: Value,
}

type Pending = Arc<Mutex<HashMap<i64, oneshot::Sender<Result<Value, RpcError>>>>>;

/// Request/response correlation over one transport.
struct Client {
    send: SendLine,
    terminate: Terminate,
    next_id: AtomicI64,
    pending: Pending,
    reader: JoinHandle<()>,
}

impl Client {
    fn start(transport: Transport) -> (Self, mpsc::UnboundedReceiver<Notification>) {
        let Transport { mut lines, send, terminate } = transport;
        let pending: Pending = Default::default();
        let (notify_tx, notify_rx) = mpsc::unbounded_channel();

        let table = pending.clone();
        let reader = tokio::spawn(async move {
            while let Some(line) = lines.recv().await {
                let Ok(Some(message)) = codex::parse_line(&line) else { continue };
                match message {
                    Inbound::Response { id, result } => {
                        if let Some(tx) = table.lock().unwrap().remove(&id) {
                            let _ = tx.send(Ok(result));
                        }
                    }
                    Inbound::Failure { id, error } => {
                        if let Some(tx) = table.lock().unwrap().remove(&id) {
                            let _ = tx.send(Err(RpcError::Failure(error)));
                        }
                    }
                    Inbound::Notification { method, params } => {
                        let _ = notify_tx.send(Notification { method, params });
                    }
                }
            }
            // The connection is gone: everyone waiting is told so.
            for (_, tx) in table.lock().unwrap().drain() {
                let _ = tx.send(Err(RpcError::Closed));
            }
            // `notify_tx` drops here, which ends the notification stream.
        });

        (Self { send, terminate, next_id: AtomicI64::new(0), pending, reader }, notify_rx)
    }

    fn guard(method: &str) -> Result<(), RpcError> {
        if method::PERMITTED_OUTBOUND.contains(&method) {
            Ok(())
        } else {
            Err(RpcError::NotPermitted(method.into()))
        }
    }

    async fn request(&self, method: &str, params: Option<Value>) -> Result<Value, RpcError> {
        Self::guard(method)?;
        let id = self.next_id.fetch_add(1, Ordering::SeqCst) + 1;
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        if (self.send)(&codex::request_line(id, method, params)).is_err() {
            self.pending.lock().unwrap().remove(&id);
            return Err(RpcError::Closed);
        }
        rx.await.unwrap_or(Err(RpcError::Closed))
    }

    async fn request_as<T: serde::de::DeserializeOwned>(&self, method: &str, params: Option<Value>) -> Result<T, RpcError> {
        serde_json::from_value(self.request(method, params).await?).map_err(|_| RpcError::Undecodable)
    }

    fn notify(&self, method: &str) -> Result<(), RpcError> {
        Self::guard(method)?;
        (self.send)(&codex::notification_line(method, None)).map_err(|_| RpcError::Closed)
    }

    fn stop(&self) {
        self.reader.abort();
        (self.terminate)();
        for (_, tx) in self.pending.lock().unwrap().drain() {
            let _ = tx.send(Err(RpcError::Closed));
        }
    }
}

#[derive(Default)]
struct Inner {
    client: Option<Arc<Client>>,
    /// Told apart so a loop belonging to a past connection cannot act on a new one.
    generation: u64,
    /// Past the handshake and the account: what a refresh may read from.
    ready: bool,
    notifications: Option<JoinHandle<()>>,
    last_rate_limits: Option<RateLimitSnapshot>,
    /// When `last_rate_limits` was read, which is what Stale Capacity reports.
    last_read_at: Option<DateTime<Utc>>,
}

#[derive(Clone)]
pub struct CodexService {
    inner: Arc<tokio::sync::Mutex<Inner>>,
    sink: SnapshotSink,
    now: Clock,
    make_transport: TransportFactory,
    client_name: String,
    client_version: String,
}

impl CodexService {
    pub fn new(
        sink: SnapshotSink,
        now: Clock,
        client_version: impl Into<String>,
        make_transport: TransportFactory,
    ) -> Self {
        Self {
            inner: Default::default(),
            sink,
            now,
            make_transport,
            client_name: "capacity_notch".into(),
            client_version: client_version.into(),
        }
    }

    /// The real thing: `codex app-server` found on this machine. `log` says,
    /// at the moment a connection is made, where the App Server's own output
    /// goes: the diagnostic log while the person keeps one, else nowhere
    /// (`CAPACITY_NOTCH_APP_SERVER_LOG` aside).
    pub fn with_process_transport(
        sink: SnapshotSink,
        now: Clock,
        client_version: impl Into<String>,
        log: Arc<dyn Fn() -> Option<std::path::PathBuf> + Send + Sync>,
    ) -> Self {
        Self::new(
            sink,
            now,
            client_version,
            Arc::new(move || {
                let home = home_dir();
                let Some(executable) = codex::locate(&home) else { return Ok(None) };
                // A process that could not be started is not a blip: it wants a person.
                process_transport(executable, log()).map(Some).map_err(|_| "the App Server did not start.".to_owned())
            }),
        )
    }

    pub async fn is_connected(&self) -> bool {
        self.inner.lock().await.client.is_some()
    }

    fn emit(&self, snapshot: CapacitySnapshot) {
        let _ = self.sink.send(snapshot);
    }

    fn emit_disconnected(&self, reason: CapacityStatusReason) {
        self.emit(CapacitySnapshot::disconnected(Provider::Codex, (self.now)(), reason));
    }

    /// Starts one App Server and publishes the Capacity it reports. Calling
    /// this while already connected does not start a second process.
    ///
    /// The lock is not held while the App Server is asked something: one that
    /// hangs must not keep a disconnect (switching Codex off, quitting) waiting.
    /// A disconnect meanwhile fails the question (`Client::stop`), and what
    /// comes back for a past connection is dropped (`current`).
    pub async fn connect(&self) {
        let (client, notifications, generation) = {
            let mut inner = self.inner.lock().await;
            if inner.client.is_some() {
                return;
            }

            let transport = match (self.make_transport)() {
                Ok(t) => t,
                Err(e) => return self.emit_disconnected(CapacityStatusReason::ProviderIncompatible(e)),
            };
            let Some(transport) = transport else {
                return self.emit_disconnected(CapacityStatusReason::ProviderNotInstalled);
            };

            let (client, notifications) = Client::start(transport);
            let client = Arc::new(client);
            inner.client = Some(client.clone());
            inner.generation += 1;
            (client, notifications, inner.generation)
        };

        let handshake = async {
            client
                .request(method::INITIALIZE, Some(codex::initialize_params(&self.client_name, &self.client_version)))
                .await?;
            client.notify(method::INITIALIZED)
        }
        .await;
        {
            let Some(mut inner) = self.current(generation).await else { return };
            match handshake {
                Ok(()) => {}
                Err(RpcError::Closed) => {
                    // It ended before answering: it could not start here, which is
                    // not the same as speaking another protocol.
                    Self::tear_down(&mut inner);
                    return self.emit_disconnected(CapacityStatusReason::ProviderUnavailable(
                        "it stopped before answering. Check that `codex app-server` runs in Terminal.".into(),
                    ));
                }
                Err(e) => {
                    Self::tear_down(&mut inner);
                    return self.emit_disconnected(CapacityStatusReason::ProviderIncompatible(handshake_detail(&e)));
                }
            }
        }

        // The App Server rejects `account/read` without a params object.
        let account = client.request_as::<AccountResponse>(method::READ_ACCOUNT, Some(serde_json::json!({}))).await;
        {
            let Some(mut inner) = self.current(generation).await else { return };
            match account {
                Ok(account) if account.is_authenticated() => {}
                Ok(_) => {
                    Self::tear_down(&mut inner);
                    return self.emit_disconnected(CapacityStatusReason::ProviderNotAuthenticated);
                }
                Err(RpcError::Undecodable) => {
                    Self::tear_down(&mut inner);
                    return self.emit_disconnected(CapacityStatusReason::ProviderAnswerNotUnderstood);
                }
                Err(e) => {
                    Self::tear_down(&mut inner);
                    return self.emit_disconnected(CapacityStatusReason::ProviderUnavailable(detail(&e)));
                }
            }
            inner.notifications = Some(self.observe(notifications, generation));
            inner.ready = true;
        }
        self.read_rate_limits(&client, generation).await;
    }

    /// Re-reads Capacity from the App Server already running. One still
    /// connecting is left to its own first read.
    pub async fn refresh(&self) {
        let (client, generation) = {
            let inner = self.inner.lock().await;
            match &inner.client {
                Some(client) if inner.ready => (client.clone(), inner.generation),
                _ => return,
            }
        };
        self.read_rate_limits(&client, generation).await;
    }

    /// The service's state, if `generation` is still the connection in force:
    /// an answer for one given up since is nobody's news.
    async fn current(&self, generation: u64) -> Option<tokio::sync::MutexGuard<'_, Inner>> {
        let inner = self.inner.lock().await;
        (inner.generation == generation && inner.client.is_some()).then_some(inner)
    }

    async fn read_rate_limits(&self, client: &Client, generation: u64) {
        let answer = client.request_as::<RateLimitsResponse>(method::READ_RATE_LIMITS, None).await;
        let Some(mut inner) = self.current(generation).await else { return };
        let inner = &mut *inner;

        match answer {
            Ok(response) => {
                let read_at = (self.now)();
                inner.last_rate_limits = Some(response.rate_limits);
                inner.last_read_at = Some(read_at);
                self.emit(codex::fresh_snapshot(&response.rate_limits, read_at));
            }
            // The App Server answered, so it is alive; it just could not reach
            // the backend. The last reading becomes Stale Capacity and the next
            // refresh tries again, rather than the Provider vanishing.
            Err(RpcError::Failure(failure)) => {
                self.hold_last_as_stale(inner, CapacityStatusReason::ProviderCouldNotRead(failure.message));
            }
            // Also alive, in a shape this build cannot read — a newer Codex.
            // Restarting it would get the same answer.
            Err(RpcError::Undecodable) => {
                self.hold_last_as_stale(inner, CapacityStatusReason::ProviderAnswerNotUnderstood);
            }
            Err(e) => {
                Self::tear_down(inner);
                self.emit_disconnected(CapacityStatusReason::ProviderUnavailable(detail(&e)));
            }
        }
    }

    /// Keeps the last observed Capacity on the surface, marked Stale and saying
    /// why. With nothing observed yet the Provider goes disconnected instead.
    fn hold_last_as_stale(&self, inner: &mut Inner, reason: CapacityStatusReason) {
        match inner.last_rate_limits {
            Some(last) => self.emit(codex::snapshot(
                &last,
                inner.last_read_at.unwrap_or_else(|| (self.now)()),
                ConnectionState::Stale,
                Some(reason),
            )),
            None => {
                Self::tear_down(inner);
                self.emit_disconnected(reason);
            }
        }
    }

    /// Ends the App Server this service started, and nothing else.
    pub async fn disconnect(&self) {
        Self::tear_down(&mut *self.inner.lock().await);
    }

    fn observe(&self, mut notifications: mpsc::UnboundedReceiver<Notification>, generation: u64) -> JoinHandle<()> {
        let this = self.clone();
        tokio::spawn(async move {
            while let Some(n) = notifications.recv().await {
                let mut inner = this.inner.lock().await;
                if inner.generation != generation {
                    return;
                }
                this.apply(&mut inner, n);
            }
            // The stream ended: the App Server went away.
            let mut inner = this.inner.lock().await;
            if inner.generation == generation && inner.client.is_some() {
                inner.notifications = None; // this very task: let it finish rather than abort itself
                Self::tear_down(&mut inner);
                this.emit_disconnected(CapacityStatusReason::ProviderUnavailable("the App Server stopped.".into()));
            }
        })
    }

    fn apply(&self, inner: &mut Inner, n: Notification) {
        if n.method != method::RATE_LIMITS_UPDATED {
            return;
        }
        let Ok(update) = serde_json::from_value::<RateLimitsUpdated>(n.params) else { return };
        let merged = match inner.last_rate_limits {
            Some(previous) => codex::merge(update.rate_limits, previous),
            None => update.rate_limits,
        };
        let read_at = (self.now)();
        inner.last_rate_limits = Some(merged);
        inner.last_read_at = Some(read_at);
        self.emit(codex::fresh_snapshot(&merged, read_at));
    }

    /// The connection is given up before the App Server is asked to stop, so
    /// the notification loop ending cannot end a second connection's process.
    fn tear_down(inner: &mut Inner) {
        if let Some(task) = inner.notifications.take() {
            task.abort();
        }
        inner.last_rate_limits = None;
        inner.last_read_at = None;
        inner.ready = false;
        inner.generation += 1;
        if let Some(client) = inner.client.take() {
            client.stop();
        }
    }
}

fn handshake_detail(error: &RpcError) -> String {
    match error {
        RpcError::Failure(f) => format!("the App Server rejected `initialize` ({}).", f.message),
        _ => "this Codex build does not speak the App Server protocol.".into(),
    }
}

fn detail(error: &RpcError) -> String {
    match error {
        RpcError::Failure(f) => f.message.clone(),
        _ => "the connection closed.".into(),
    }
}

pub(crate) fn home_dir() -> std::path::PathBuf {
    capa_core::dirs::home()
}

/// What Codex runs with: the application's own environment, with the places a
/// terminal would look for programs added to `PATH`. Started from a launcher,
/// a Codex installed with npm — a script that runs `node` — finds no Node.
pub fn environment_path() -> std::ffi::OsString {
    let mut path: Vec<_> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    let home = home_dir();
    let extras = [home.join(".local/bin"), "/usr/local/bin".into(), "/usr/bin".into()];
    for extra in extras {
        if !path.contains(&extra) {
            path.push(extra);
        }
    }
    std::env::join_paths(path).unwrap_or_default()
}

/// Runs `codex app-server` as a child process and speaks newline-delimited
/// JSON-RPC over its standard input and output. Codex logs to stderr, which
/// goes to `log` (the diagnostic log, while the person keeps one), else to the
/// file `CAPACITY_NOTCH_APP_SERVER_LOG` names, else nowhere. An error when the
/// process could not be started at all.
pub fn process_transport(executable: std::path::PathBuf, log: Option<std::path::PathBuf>) -> io::Result<Transport> {
    use std::process::Stdio;

    let (line_tx, lines) = mpsc::unbounded_channel();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<String>();
    let kill = Arc::new(tokio::sync::Notify::new());

    let stderr = log
        .map(std::ffi::OsString::from)
        .or_else(|| std::env::var_os("CAPACITY_NOTCH_APP_SERVER_LOG"))
        .filter(|p| !p.is_empty())
        .and_then(|p| std::fs::OpenOptions::new().create(true).append(true).open(p).ok())
        .map(Stdio::from)
        .unwrap_or_else(Stdio::null);

    let mut command = tokio::process::Command::new(&executable);
    command
        .arg("app-server")
        .env("PATH", environment_path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(stderr)
        .kill_on_drop(true);
    let mut child = command.spawn()?;
    {
        let mut stdin = child.stdin.take().expect("piped");
        let stdout = child.stdout.take().expect("piped");
        let stop = kill.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout).lines();
            loop {
                tokio::select! {
                    line = reader.next_line() => match line {
                        Ok(Some(line)) => { let _ = line_tx.send(line); }
                        _ => break,
                    },
                    out = out_rx.recv() => match out {
                        Some(line) => {
                            if stdin.write_all(format!("{line}\n").as_bytes()).await.is_err() { break; }
                            let _ = stdin.flush().await;
                        }
                        None => break,
                    },
                    _ = stop.notified() => break,
                }
            }
            let _ = child.kill().await;
            // `line_tx` drops here: the line stream ends with the process.
        });
    }

    let stopper = kill.clone();
    Ok(Transport {
        lines,
        send: Box::new(move |line| {
            out_tx
                .send(line.to_owned())
                .map_err(|_| io::Error::new(io::ErrorKind::NotConnected, "App Server is not running"))
        }),
        terminate: Box::new(move || stopper.notify_one()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::ConnectionState;
    use chrono::TimeZone;
    use std::sync::atomic::AtomicUsize;

    fn fixed_now() -> Clock {
        Arc::new(|| Utc.timestamp_opt(1_700_000_000, 0).unwrap())
    }

    /// Scripted App Server: answers each request with the lines `script`
    /// returns for (method, id).
    struct Fake {
        starts: Arc<AtomicUsize>,
        terminated: Arc<AtomicUsize>,
        /// Lets a test push lines as the App Server, or end it.
        server: Arc<Mutex<Option<mpsc::UnboundedSender<String>>>>,
        sent: Arc<Mutex<Vec<String>>>,
    }

    fn fake(script: impl Fn(&str, i64) -> Vec<String> + Send + Sync + 'static) -> (TransportFactory, Fake) {
        let f = Fake {
            starts: Default::default(),
            terminated: Default::default(),
            server: Default::default(),
            sent: Default::default(),
        };
        let (starts, terminated, server, sent) = (f.starts.clone(), f.terminated.clone(), f.server.clone(), f.sent.clone());
        let script = Arc::new(script);
        let factory: TransportFactory = Arc::new(move || {
            starts.fetch_add(1, Ordering::SeqCst);
            let (tx, rx) = mpsc::unbounded_channel();
            // The registry holds the only sender, so removing it is the App Server exiting.
            *server.lock().unwrap() = Some(tx);
            let (script, sent, terminated, server_end) = (script.clone(), sent.clone(), terminated.clone(), server.clone());
            let replies = server.clone();
            Ok(Some(Transport {
                lines: rx,
                send: Box::new(move |line| {
                    sent.lock().unwrap().push(line.to_owned());
                    let v: Value = serde_json::from_str(line).unwrap();
                    if let (Some(m), Some(id)) = (v["method"].as_str(), v["id"].as_i64()) {
                        for reply in script(m, id) {
                            if let Some(tx) = replies.lock().unwrap().as_ref() {
                                let _ = tx.send(reply);
                            }
                        }
                    }
                    Ok(())
                }),
                terminate: Box::new(move || {
                    terminated.fetch_add(1, Ordering::SeqCst);
                    server_end.lock().unwrap().take();
                }),
            }))
        });
        (factory, f)
    }

    fn connected_script(used: i64) -> impl Fn(&str, i64) -> Vec<String> + Send + Sync + 'static {
        move |m, id| match m {
            "initialize" => vec![format!(r#"{{"id":{id},"result":{{"userAgent":"codex"}}}}"#)],
            "account/read" => vec![format!(r#"{{"id":{id},"result":{{"account":{{"type":"chatgpt"}},"requiresOpenaiAuth":true}}}}"#)],
            "account/rateLimits/read" => vec![format!(
                r#"{{"id":{id},"result":{{"rateLimits":{{"primary":{{"usedPercent":{used},"windowDurationMins":300,"resetsAt":1700003600}},"secondary":{{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1700600000}}}}}}}}"#
            )],
            _ => vec![],
        }
    }

    fn service(factory: TransportFactory) -> (CodexService, mpsc::UnboundedReceiver<CapacitySnapshot>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (CodexService::new(tx, fixed_now(), "0.1.0", factory), rx)
    }

    #[tokio::test]
    async fn connecting_publishes_fresh_capacity() {
        let (factory, fake) = fake(connected_script(70));
        let (service, mut rx) = service(factory);
        service.connect().await;
        let s = rx.recv().await.unwrap();
        assert_eq!(s.connection_state, ConnectionState::Fresh);
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].remaining_percentage(), 30.0);
        assert_eq!(fake.starts.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn connecting_twice_starts_one_app_server() {
        let (factory, fake) = fake(connected_script(70));
        let (service, _rx) = service(factory);
        service.connect().await;
        service.connect().await;
        assert_eq!(fake.starts.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn rolling_updates_reach_the_surface_without_reconnecting() {
        let (factory, fake) = fake(connected_script(70));
        let (service, mut rx) = service(factory);
        service.connect().await;
        rx.recv().await.unwrap();

        let server = fake.server.lock().unwrap().clone().unwrap();
        server
            .send(r#"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":95,"windowDurationMins":300,"resetsAt":1700003600}}}}"#.into())
            .unwrap();
        let s = rx.recv().await.unwrap();
        assert_eq!(s.windows[0].remaining_percentage(), 5.0);
        assert_eq!(s.windows.len(), 2, "the window the update omits keeps its last value");
        assert_eq!(fake.starts.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn only_reading_methods_ever_reach_the_wire() {
        let (factory, fake) = fake(connected_script(70));
        let (service, _rx) = service(factory);
        service.connect().await;
        let methods: Vec<String> = fake
            .sent
            .lock()
            .unwrap()
            .iter()
            .map(|l| serde_json::from_str::<Value>(l).unwrap()["method"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(methods, ["initialize", "initialized", "account/read", "account/rateLimits/read"]);
    }

    #[tokio::test]
    async fn an_app_server_that_cannot_be_started_wants_a_person() {
        let missing = std::env::temp_dir().join(format!("capa-no-codex-{}", std::process::id()));
        assert!(process_transport(missing, None).is_err());
        let factory: TransportFactory = Arc::new(|| Err("the App Server did not start.".into()));
        let (service, mut rx) = service(factory);
        service.connect().await;
        let s = rx.recv().await.unwrap();
        assert_eq!(s.status_reason, Some(CapacityStatusReason::ProviderIncompatible("the App Server did not start.".into())));
        assert!(!s.status_reason.unwrap().is_transient());
    }

    #[tokio::test]
    async fn no_codex_installed_says_so() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let service = CodexService::new(tx, fixed_now(), "0.1.0", Arc::new(|| Ok(None)));
        service.connect().await;
        let s = rx.recv().await.unwrap();
        assert_eq!(s.status_reason, Some(CapacityStatusReason::ProviderNotInstalled));
        assert!(s.windows.is_empty());
    }

    #[tokio::test]
    async fn a_signed_out_codex_is_not_authenticated_and_is_ended() {
        let (factory, fake) = fake(|m, id| match m {
            "initialize" => vec![format!(r#"{{"id":{id},"result":{{}}}}"#)],
            "account/read" => vec![format!(r#"{{"id":{id},"result":{{"account":null,"requiresOpenaiAuth":true}}}}"#)],
            _ => vec![],
        });
        let (service, mut rx) = service(factory);
        service.connect().await;
        assert_eq!(rx.recv().await.unwrap().status_reason, Some(CapacityStatusReason::ProviderNotAuthenticated));
        assert!(!service.is_connected().await);
        assert_eq!(fake.terminated.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn an_account_answer_without_the_required_field_is_not_understood() {
        let (factory, _fake) = fake(|m, id| match m {
            "initialize" => vec![format!(r#"{{"id":{id},"result":{{}}}}"#)],
            "account/read" => vec![format!(r#"{{"id":{id},"result":{{"account":null}}}}"#)],
            _ => vec![],
        });
        let (service, mut rx) = service(factory);
        service.connect().await;
        assert_eq!(rx.recv().await.unwrap().status_reason, Some(CapacityStatusReason::ProviderAnswerNotUnderstood));
    }

    #[tokio::test]
    async fn a_rejected_handshake_is_an_incompatible_codex() {
        let (factory, _fake) = fake(|m, id| match m {
            "initialize" => vec![format!(r#"{{"id":{id},"error":{{"code":-32600,"message":"bad"}}}}"#)],
            _ => vec![],
        });
        let (service, mut rx) = service(factory);
        service.connect().await;
        let reason = rx.recv().await.unwrap().status_reason.unwrap();
        assert!(matches!(reason, CapacityStatusReason::ProviderIncompatible(d) if d.contains("bad")));
    }

    #[tokio::test]
    async fn a_failed_read_keeps_the_last_reading_as_stale() {
        let fail = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = fail.clone();
        let ok = connected_script(70);
        let (factory, _fake) = fake(move |m, id| {
            if m == "account/rateLimits/read" && flag.load(Ordering::SeqCst) {
                return vec![format!(r#"{{"id":{id},"error":{{"code":1,"message":"backend down"}}}}"#)];
            }
            ok(m, id)
        });
        let (service, mut rx) = service(factory);
        service.connect().await;
        rx.recv().await.unwrap();

        fail.store(true, Ordering::SeqCst);
        service.refresh().await;
        let s = rx.recv().await.unwrap();
        assert_eq!(s.connection_state, ConnectionState::Stale);
        assert_eq!(s.windows[0].remaining_percentage(), 30.0, "the last reading stays");
        assert!(matches!(s.status_reason, Some(CapacityStatusReason::ProviderCouldNotRead(d)) if d == "backend down"));
        assert!(service.is_connected().await, "an App Server that answered is alive");
    }

    #[tokio::test]
    async fn a_first_read_that_fails_disconnects() {
        let (factory, _fake) = fake(|m, id| match m {
            "initialize" => vec![format!(r#"{{"id":{id},"result":{{}}}}"#)],
            "account/read" => vec![format!(r#"{{"id":{id},"result":{{"account":{{}},"requiresOpenaiAuth":false}}}}"#)],
            "account/rateLimits/read" => vec![format!(r#"{{"id":{id},"error":{{"code":1,"message":"nope"}}}}"#)],
            _ => vec![],
        });
        let (service, mut rx) = service(factory);
        service.connect().await;
        let s = rx.recv().await.unwrap();
        assert!(matches!(s.connection_state, ConnectionState::Disconnected(_)));
        assert!(!service.is_connected().await);
    }

    #[tokio::test]
    async fn an_app_server_that_goes_away_is_reported() {
        let (factory, fake) = fake(connected_script(70));
        let (service, mut rx) = service(factory);
        service.connect().await;
        rx.recv().await.unwrap();

        fake.server.lock().unwrap().take(); // the App Server exits
        let s = rx.recv().await.unwrap();
        assert!(matches!(s.status_reason, Some(CapacityStatusReason::ProviderUnavailable(d)) if d.contains("stopped")));
        assert!(!service.is_connected().await);
    }

    #[tokio::test]
    async fn a_hung_app_server_does_not_keep_a_disconnect_waiting() {
        // It never answers `initialize`.
        let (factory, fake) = fake(|_, _| vec![]);
        let (service, mut rx) = service(factory);
        let connecting = tokio::spawn({
            let service = service.clone();
            async move { service.connect().await }
        });
        while fake.sent.lock().unwrap().is_empty() {
            tokio::task::yield_now().await;
        }
        tokio::time::timeout(std::time::Duration::from_secs(1), service.disconnect())
            .await
            .expect("the disconnect does not wait on the App Server");
        assert_eq!(fake.terminated.load(Ordering::SeqCst), 1);
        tokio::time::timeout(std::time::Duration::from_secs(1), connecting)
            .await
            .expect("the question is failed, so connecting ends")
            .unwrap();
        assert!(!service.is_connected().await);
        assert!(rx.try_recv().is_err(), "a connection given up says nothing more");
    }

    #[tokio::test]
    async fn a_hung_read_does_not_keep_a_disconnect_waiting() {
        let hang = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = hang.clone();
        let ok = connected_script(70);
        let (factory, fake) = fake(move |m, id| {
            if m == "account/rateLimits/read" && flag.load(Ordering::SeqCst) {
                return vec![];
            }
            ok(m, id)
        });
        let (service, mut rx) = service(factory);
        service.connect().await;
        rx.recv().await.unwrap();

        hang.store(true, Ordering::SeqCst);
        let reading = tokio::spawn({
            let service = service.clone();
            async move { service.refresh().await }
        });
        while fake.sent.lock().unwrap().len() < 5 {
            tokio::task::yield_now().await;
        }
        tokio::time::timeout(std::time::Duration::from_secs(1), service.disconnect())
            .await
            .expect("the disconnect does not wait on the App Server");
        tokio::time::timeout(std::time::Duration::from_secs(1), reading).await.unwrap().unwrap();
        assert!(rx.try_recv().is_err(), "the failed read of a connection given up is not news");
    }

    #[tokio::test]
    async fn a_refresh_while_connecting_leaves_the_first_read_to_the_connect() {
        // It answers the handshake, then keeps the account question waiting.
        let (factory, fake) = fake(|m, id| match m {
            "initialize" => vec![format!(r#"{{"id":{id},"result":{{}}}}"#)],
            _ => vec![],
        });
        let (service, _rx) = service(factory);
        let connecting = tokio::spawn({
            let service = service.clone();
            async move { service.connect().await }
        });
        while fake.sent.lock().unwrap().len() < 3 {
            tokio::task::yield_now().await;
        }
        assert!(service.is_connected().await);
        service.refresh().await;
        assert_eq!(fake.sent.lock().unwrap().len(), 3, "nothing is read before the account is known");
        service.disconnect().await;
        connecting.await.unwrap();
    }

    #[tokio::test]
    async fn disconnecting_ends_the_process_it_started_and_reconnecting_starts_another() {
        let (factory, fake) = fake(connected_script(70));
        let (service, mut rx) = service(factory);
        service.connect().await;
        rx.recv().await.unwrap();
        service.disconnect().await;
        assert_eq!(fake.terminated.load(Ordering::SeqCst), 1);
        assert!(!service.is_connected().await);

        service.connect().await;
        assert_eq!(fake.starts.load(Ordering::SeqCst), 2);
        assert_eq!(rx.recv().await.unwrap().connection_state, ConnectionState::Fresh);
    }
}
