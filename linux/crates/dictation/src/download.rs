//! "Set up": the speech model, downloaded once, unpacked and checked.
//! `DictationModelFiles.install` and `DictationDownloader` in Swift.

use capa_core::dictation::{model, DictationFailure, DOWNLOAD_FAILED, UNPACK_FAILED};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// Why a download ended without a model.
#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    Cancelled,
    /// The server could not be reached or answered something else than 200.
    Download,
    /// Here, but not usable: could not be unpacked, or the files are not the ones shipped.
    Install,
}

impl Failure {
    pub fn sentence(&self) -> &'static str {
        match self {
            Failure::Cancelled => "",
            Failure::Download => DOWNLOAD_FAILED,
            Failure::Install => UNPACK_FAILED,
        }
    }
}

/// What the machine is told along the way.
pub trait Reporter {
    fn progress(&self, fraction: f64);
    fn answered(&self, status: u16, bytes: u64);
}

/// Downloads `url` to a temporary file, reporting a fraction as bytes arrive.
pub fn fetch(url: &str, reporter: &dyn Reporter, cancelled: &dyn Fn() -> bool) -> Result<PathBuf, Failure> {
    let agent: ureq::Agent = ureq::Agent::config_builder().http_status_as_error(false).build().into();
    let response = agent.get(url).call().map_err(|_| Failure::Download)?;
    let status = response.status().as_u16();
    let total = response.headers().get("content-length").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok());
    reporter.answered(status, total.unwrap_or(0));
    if status != 200 {
        return Err(Failure::Download);
    }
    let path = std::env::temp_dir().join(format!("dictation-{}.tar.bz2", std::process::id()));
    let mut file = std::fs::File::create(&path).map_err(|_| Failure::Download)?;
    let mut reader = response.into_body().into_reader();
    let (mut done, mut buffer) = (0u64, vec![0u8; 64 * 1024]);
    loop {
        if cancelled() {
            let _ = std::fs::remove_file(&path);
            return Err(Failure::Cancelled);
        }
        let n = match reader.read(&mut buffer) {
            Ok(n) => n,
            Err(_) => {
                let _ = std::fs::remove_file(&path);
                return Err(Failure::Download);
            }
        };
        if n == 0 {
            break;
        }
        if file.write_all(&buffer[..n]).is_err() {
            let _ = std::fs::remove_file(&path);
            return Err(Failure::Download);
        }
        done += n as u64;
        if let Some(total) = total.filter(|t| *t > 0) {
            reporter.progress(done as f64 / total as f64);
        }
    }
    Ok(path)
}

/// Unpacks the four files and the licence into a staging folder beside
/// `directory`, checks every file's hash, then moves the folder into place.
pub fn install(archive: &Path, directory: &Path, cancelled: &dyn Fn() -> bool) -> Result<(), Failure> {
    let parent = directory.parent().ok_or(Failure::Install)?;
    std::fs::create_dir_all(parent).map_err(|_| Failure::Install)?;
    let staging = parent.join(format!("install-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).map_err(|_| Failure::Install)?;
    let result = (|| {
        let wanted = model::archive_members();
        let decoder = bzip2::read::BzDecoder::new(std::fs::File::open(archive).map_err(|_| Failure::Install)?);
        let mut tar = tar::Archive::new(decoder);
        for entry in tar.entries().map_err(|_| Failure::Install)? {
            if cancelled() {
                return Err(Failure::Cancelled);
            }
            let mut entry = entry.map_err(|_| Failure::Install)?;
            let path = entry.path().map_err(|_| Failure::Install)?.into_owned();
            if !model::safe_member(&path) {
                return Err(Failure::Install);
            }
            let path = path.to_string_lossy().into_owned();
            if wanted.contains(&path) {
                let name = path.rsplit('/').next().unwrap_or(&path).to_owned();
                entry.unpack(staging.join(name)).map_err(|_| Failure::Install)?;
            }
        }
        match model::validate(&model::DiskFolder(staging.clone()), cancelled) {
            Ok(true) => {}
            Ok(false) => return Err(Failure::Cancelled),
            Err(DictationFailure { .. }) => return Err(Failure::Install),
        }
        if cancelled() {
            return Err(Failure::Cancelled);
        }
        let _ = std::fs::remove_dir_all(directory);
        std::fs::rename(&staging, directory).map_err(|_| Failure::Install)
    })();
    let _ = std::fs::remove_dir_all(&staging);
    result
}
