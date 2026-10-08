//! Claude Code's status-line bridge (`CapacityNotchClaudeBridge/main.swift`).
//!
//! Claude Code runs a status-line command with its own JSON on stdin. Set as
//! that command — `"statusLine": {"type": "command", "command":
//! "capa-claude-bridge"}` in `~/.claude/settings.json` — this keeps only the
//! rate limits in `claude-capacity.json` in CapaTheNotch's data folder, where
//! the Claude service reads them beside `/usage`. With `-- command args…` it
//! then runs the person's own status line with the same stdin, and exits with
//! its status, so the status line keeps working through it.

use capa_core::claude_bridge::{self, BridgeError, PublishError};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

fn main() {
    let mut input = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut input);

    let destination = claude_bridge::default_snapshot_path(&capa_core::dirs::home());
    match claude_bridge::publish(&input, now(), &destination) {
        Ok(()) => {}
        // Claude Code omits rate_limits before the first API response. The last
        // useful snapshot is kept and the status line goes on working.
        Err(PublishError::Bridge(BridgeError::MissingRateLimits)) => {
            claude_bridge::record_unreadable(&destination, BridgeError::MissingRateLimits.name(), &input, now());
        }
        Err(error) => {
            claude_bridge::record_unreadable(&destination, &error.to_string(), &input, now());
            eprintln!("CapaTheNotch bridge: {error}");
        }
    }

    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.first().map(String::as_str) == Some("--") && arguments.len() > 1 {
        std::process::exit(forward(&arguments[1], &arguments[2..], &input));
    }
}

/// Runs the person's own status line with the same input. The program is a
/// path, as `URL(fileURLWithPath:)` takes it: relative to the working
/// directory, never looked up on `PATH`.
fn forward(program: &str, arguments: &[String], input: &[u8]) -> i32 {
    let mut path = PathBuf::from(program);
    if path.is_relative() {
        if let Ok(dir) = std::env::current_dir() {
            path = dir.join(path);
        }
    }
    let run = || -> std::io::Result<i32> {
        let mut child = Command::new(&path).args(arguments).stdin(Stdio::piped()).spawn()?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(input)?;
        } // closed here: the child sees the end of its input
        let status = child.wait()?;
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt;
            if let Some(signal) = status.signal() {
                return Ok(signal);
            }
        }
        Ok(status.code().unwrap_or(1))
    };
    match run() {
        Ok(code) => code,
        Err(error) => {
            eprintln!("CapaTheNotch passthrough: {error}");
            1
        }
    }
}
