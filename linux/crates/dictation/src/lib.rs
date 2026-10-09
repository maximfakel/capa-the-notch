//! The Dictation Module: hold the shortcut, speak, let go — the text appears at
//! the cursor. Recognised entirely on this machine (sherpa-onnx with GigaAM).
//!
//! The logic is `capa_core::dictation`, ported with its tests. This crate is
//! what talks to the machine:
//!
//! * `microphone` — `cpal` capture, 16 kHz mono, across a change of input
//! * `sherpa` — the recogniser, the C API `dlopen`ed from a library fetched with the model
//! * `download` — the model: fetched, unpacked, hashed
//! * `bridge` — the shortcut, the application in front, the clipboard and the
//!   paste, which belong to the desktop and are done by the surface's host
//! * `driver` — the one task that feeds the machine events and carries out what it asks
//! * `sleep` — logind's notice that the system is going to sleep, which ends a session
//!
//! Nothing here runs while the Module is off: the shortcut is not registered,
//! the microphone is not opened and the model is not in memory.

pub mod bridge;
pub mod download;
pub mod driver;
pub mod microphone;
pub mod sherpa;
pub mod sleep;
mod view;

#[cfg(test)]
mod tests;

use bridge::Bridge;
use capa_core::dictation::model;
use capa_core::module::{BoxFuture, ModuleContext, SurfaceModule};
use driver::{Context, Downloader, Driver, Event, Platform};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::{mpsc, oneshot};

/// Opens a folder in the file manager (`xdg-open`).
pub fn open_in_file_manager(folder: &std::path::Path) {
    let mut command = std::process::Command::new("xdg-open");
    command.arg(folder).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    let _ = command.spawn();
}

/// Where the model and the runtime library are kept: `$XDG_DATA_HOME/capa-the-notch`
/// (`~/.local/share/capa-the-notch`).
pub fn data_directory() -> PathBuf {
    let home = capa_core::dirs::home();
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".local/share"))
        .join("capa-the-notch")
}

/// The model and its runtime, on disk.
pub struct DiskDownloader {
    pub data: PathBuf,
}

impl Downloader for DiskDownloader {
    fn is_ready(&self) -> bool {
        model::exists(&model::DiskFolder(model::directory(&self.data))) && sherpa::runtime::is_installed(&self.data)
    }

    fn install(&self, reporter: &dyn download::Reporter, cancelled: &dyn Fn() -> bool) -> Result<(), download::Failure> {
        use download::Failure;
        if !sherpa::runtime::is_installed(&self.data) {
            // A few megabytes, ahead of the model's own progress.
            sherpa::runtime::install(&self.data, cancelled).map_err(|e| if e == "cancelled" { Failure::Cancelled } else { Failure::Download })?;
        }
        // The model is always fetched and put in place of what is there, as
        // the Swift `startDownload` does: "Download again" is how a damaged
        // or outdated model is replaced, so it must not be skipped because
        // files are present. Only the runtime above is kept when installed.
        let directory = model::directory(&self.data);
        let archive = download::fetch(&model::source_url(), reporter, cancelled)?;
        let result = download::install(&archive, &directory, cancelled);
        let _ = std::fs::remove_file(&archive);
        result
    }
}

pub struct DictationModule {
    tx: mpsc::UnboundedSender<Event>,
    published: Arc<Mutex<Value>>,
    /// What the log hears at launch: Dictation as it starts, before anything is asked of it.
    launched: capa_core::dictation::DictationObservation,
}

/// The Module with the platform's real parts.
pub fn module(context: ModuleContext) -> Arc<dyn SurfaceModule> {
    let data = data_directory();
    let emit = context.emit.clone();
    let bridge = Bridge::new(Arc::new(move |name, data| emit("dictation", name, data)));
    let platform = Platform {
        microphone: Box::new(microphone::CpalMicrophone::new()),
        recogniser: Arc::new(Mutex::new(Box::new(sherpa::SherpaRecogniser::new(
            sherpa::runtime::library_path(&data),
            model::directory(&data),
        )))),
        inserter: Arc::new(Mutex::new(Box::new(bridge.clone()))),
        clipboard: Box::new(bridge.clone()),
        hotkey: Box::new(bridge::HostHotKey::new(bridge.clone())),
        downloader: Arc::new(DiskDownloader { data }),
        sleep: Some(Box::new(sleep::Logind)),
    };
    with_platform(context, platform, bridge)
}

/// The Module over any platform: the real one above, and a fake in the tests.
pub fn with_platform(context: ModuleContext, platform: Platform, bridge: Bridge) -> Arc<dyn SurfaceModule> {
    let (tx, rx) = mpsc::unbounded_channel();
    let published = Arc::new(Mutex::new(Value::Null));
    let driver = Driver::new(
        platform,
        bridge,
        Context { prefs: context.prefs.clone(), clock: context.clock.clone(), notify: context.notify.clone(), sound: context.sound.clone() },
        tx.clone(),
        published.clone(),
    );
    let launched = driver.observation();
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => {
            handle.spawn(driver.run(rx));
        }
        // No runtime yet (a test building the hub): the Module simply does nothing.
        Err(_) => drop((driver, rx)),
    }
    Arc::new(DictationModule { tx, published, launched })
}

impl SurfaceModule for DictationModule {
    fn id(&self) -> &'static str {
        "dictation"
    }

    fn state(&self) -> Value {
        self.published.lock().unwrap().clone()
    }

    fn call(&self, method: &str, args: Value) -> BoxFuture<Result<Value, String>> {
        let (reply, answer) = oneshot::channel();
        let sent = self.tx.send(Event::Command { method: method.to_owned(), args, reply });
        Box::pin(async move {
            sent.map_err(|_| "dictation is not running".to_owned())?;
            answer.await.map_err(|_| "dictation stopped".to_owned())?
        })
    }

    fn preferences_changed(&self) {
        let _ = self.tx.send(Event::Resync);
    }

    /// What a bug report notes: `DictationObservation.observations` — states,
    /// never words, each `dictation-` and a code, as the Swift writes them.
    fn observations(&self) -> Vec<String> {
        self.published.lock().unwrap()["observation"]
            .as_array()
            .map(|codes| codes.iter().filter_map(|c| c.as_str().map(|c| format!("dictation-{c}"))).collect())
            .unwrap_or_default()
    }

    /// `DiagnosticLog.record(.dictation(dictation.observation))`, after `launched`.
    fn launch_events(&self) -> Vec<capa_core::diagnostics::DiagnosticEvent> {
        vec![capa_core::diagnostics::DiagnosticEvent::Dictation(self.launched.diagnostic())]
    }
}
