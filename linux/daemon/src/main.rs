use capa_core::Provider;
use capa_hub::{Event, Hub};
use std::sync::Arc;
use zbus::{interface, object_server::SignalEmitter, Connection};

pub const BUS_NAME: &str = "tech.capathenotch.Daemon";
pub const OBJECT_PATH: &str = "/tech/capathenotch/Daemon";

struct Daemon {
    hub: Arc<Hub>,
}

fn parse_provider(name: &str) -> Option<Provider> {
    serde_json::from_value(serde_json::Value::String(name.to_owned())).ok()
}

#[interface(name = "tech.capathenotch.Daemon1")]
impl Daemon {
    /// The whole state as JSON: what a surface draws.
    async fn get_state(&self) -> String {
        self.hub.state_json()
    }

    /// Quit CapaTheNotch: the daemon ends cleanly — the archive written, the
    /// Modules and the Providers' processes stopped. A moment's grace so the
    /// answer to this call is sent first.
    async fn quit(&self) {
        let hub = self.hub.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            quit(&hub).await;
        });
    }

    /// Refresh Now: every connected Provider read at once. One Provider is
    /// refreshed with `Call("hub", "refresh", {"provider": ...})`.
    async fn refresh(&self) {
        self.hub.refresh_now();
    }

    /// The surface opened or closed, which sets how often Providers are read.
    async fn set_expanded(&self, expanded: bool) {
        self.hub.set_expanded(expanded);
    }

    /// Turns a Provider (`codex`, `claudeCode`, `openCode`) on or off.
    /// Returns false when the choice was refused: two at most.
    async fn set_provider_enabled(&self, provider: &str, enabled: bool) -> bool {
        match parse_provider(provider) {
            Some(p) => self.hub.set_provider_enabled(p, enabled).await,
            None => false,
        }
    }

    /// A command for a Module: `args` is a JSON value, the answer a JSON
    /// object `{"ok": value}` or `{"error": text}`.
    async fn call(&self, module: &str, method: &str, args: &str) -> String {
        let args = serde_json::from_str(args).unwrap_or(serde_json::Value::Null);
        match self.hub.call(module, method, args).await {
            Ok(value) => serde_json::json!({ "ok": value }).to_string(),
            Err(error) => serde_json::json!({ "error": error }).to_string(),
        }
    }

    /// A sound by name (`surfacePinned`, `kapaTapped`, `kapaHello`, ...), when sounds are on.
    async fn play_sound(&self, cue: &str) -> bool {
        self.hub.play_named(cue)
    }

    /// The surface host says which displays there are: a JSON array of
    /// `{id, name, isBuiltIn}`.
    async fn set_displays(&self, displays: &str) {
        if let Ok(displays) = serde_json::from_str(displays) {
            self.hub.set_displays(displays);
        }
    }

    /// The display the person prefers; a negative id clears the choice.
    async fn set_preferred_display(&self, id: i64) {
        self.hub.set_preferred_display(u32::try_from(id).ok());
    }

    /// The text of a bug report: versions, Providers' states, notes. Nothing a person wrote or said.
    async fn diagnostic_report(&self) -> String {
        self.hub.diagnostic_report()
    }

    /// `system`, `english` or `russian`.
    async fn set_language(&self, language: &str) {
        if let Ok(language) = serde_json::from_value(serde_json::Value::String(language.to_owned())) {
            self.hub.set_language(language);
        }
    }

    /// `fiveHour`, `weekly` or `leastLeft`: which window the closed strip shows.
    async fn set_compact_window(&self, choice: &str) {
        if let Ok(choice) = serde_json::from_value(serde_json::Value::String(choice.to_owned())) {
            self.hub.set_compact_window(choice);
        }
    }

    async fn set_alerts_enabled(&self, enabled: bool) {
        self.hub.set_alerts_enabled(enabled);
    }

    async fn set_alerts_enabled_for(&self, provider: &str, enabled: bool) {
        if let Some(p) = parse_provider(provider) {
            self.hub.set_alerts_for(p, enabled);
        }
    }

    #[zbus(signal)]
    async fn state_changed(emitter: &SignalEmitter<'_>, state: &str) -> zbus::Result<()>;

    /// Something a Module wants surfaces to know that is not state.
    #[zbus(signal)]
    async fn module_event(emitter: &SignalEmitter<'_>, module: &str, name: &str, data: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn alert(emitter: &SignalEmitter<'_>, alert: &str) -> zbus::Result<()>;
}

/// Stops everything the hub started, then the process.
async fn quit(hub: &Hub) -> ! {
    hub.shutdown().await;
    std::process::exit(0);
}

const USAGE: &str = "capa-daemon — CapaTheNotch's hub on the session bus (tech.capathenotch.Daemon).
Started by the GNOME Shell extension through D-Bus activation; it is not meant to be run by hand.

  --help       this text
  --version    the version
  --once       read what is switched on for 25 seconds, print the state, and leave (no bus name)
";

#[tokio::main]
async fn main() -> zbus::Result<()> {
    // Asked about itself, it answers and leaves before anything is read or written.
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        print!("{USAGE}");
        return Ok(());
    }
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("capa-daemon {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if let Some(unknown) = args.iter().find(|a| *a != "--once") {
        eprintln!("capa-daemon: unknown argument {unknown}\n\n{USAGE}");
        std::process::exit(2);
    }
    let once = args.iter().any(|a| a == "--once");

    // One hub a session: while another holds the name, this one starts nothing —
    // no Provider read, no preference written — and leaves.
    if !once {
        let bus = Connection::session().await?;
        let names = zbus::fdo::DBusProxy::new(&bus).await?;
        if names.name_has_owner(BUS_NAME.try_into()?).await? {
            eprintln!("capa-daemon: {BUS_NAME} is already running");
            return Ok(());
        }
    }

    let hub = capa_hub::start_default();

    // SIGTERM — what `pkill` and the session's end send — quits properly, so
    // the Providers' processes are stopped rather than orphaned.
    #[cfg(unix)]
    {
        let hub = hub.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let (Ok(mut term), Ok(mut interrupt)) = (signal(SignalKind::terminate()), signal(SignalKind::interrupt())) else {
                return;
            };
            tokio::select! {
                _ = term.recv() => {}
                _ = interrupt.recv() => {}
            }
            quit(&hub).await;
        });
    }

    if once {
        // For looking at what is read: connect what is on, print, leave.
        tokio::time::sleep(std::time::Duration::from_secs(25)).await;
        println!("{}", hub.state_json());
        hub.shutdown().await;
        return Ok(());
    }

    let connection = match zbus::connection::Builder::session()
        .and_then(|b| b.name(BUS_NAME))
        .and_then(|b| b.serve_at(OBJECT_PATH, Daemon { hub: hub.clone() }))
    {
        Ok(builder) => match builder.build().await {
            Ok(connection) => connection,
            Err(e) => {
                eprintln!("capa-daemon: no session bus: {e}");
                quit(&hub).await;
            }
        },
        Err(e) => {
            eprintln!("capa-daemon: {e}");
            quit(&hub).await;
        }
    };
    // The name is asked for without a place in a queue behind another owner: one
    // that started a moment after the check above is not this one's to wait for.
    let names = zbus::fdo::DBusProxy::new(&connection).await?;
    let owner = names.get_name_owner(BUS_NAME.try_into()?).await.ok();
    if owner.as_ref().map(|o| o.as_str()) != connection.unique_name().map(|u| u.as_str()) {
        eprintln!("capa-daemon: {BUS_NAME} was taken by another; leaving");
        quit(&hub).await;
    }

    // The name lost — replaced, or the bus gone — is the end of this hub: a daemon
    // that cannot be reached must not go on reading and writing behind the session's back.
    {
        let hub = hub.clone();
        let mut lost = names.receive_name_lost().await?;
        tokio::spawn(async move {
            use futures_util::StreamExt;
            while let Some(signal) = lost.next().await {
                if signal.args().map(|a| a.name.as_str() == BUS_NAME).unwrap_or(false) {
                    eprintln!("capa-daemon: lost {BUS_NAME}; leaving");
                    quit(&hub).await;
                }
            }
        });
    }

    let iface = connection.object_server().interface::<_, Daemon>(OBJECT_PATH).await?;
    let mut events = hub.subscribe();
    loop {
        // A signal that cannot be sent is said and passed over; it never ends the hub,
        // which would drop the name and leave the process behind it.
        let sent = match events.recv().await {
            Ok(Event::State(json)) => Daemon::state_changed(iface.signal_emitter(), &json).await,
            Ok(Event::Alert(json)) => Daemon::alert(iface.signal_emitter(), &json).await,
            Ok(Event::Module(module, name, data)) => Daemon::module_event(iface.signal_emitter(), &module, &name, &data).await,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                // Missed some: the latest state says it all.
                Daemon::state_changed(iface.signal_emitter(), &hub.state_json()).await
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        };
        if let Err(e) = sent {
            eprintln!("capa-daemon: a signal could not be sent: {e}");
        }
    }
    quit(&hub).await
}
