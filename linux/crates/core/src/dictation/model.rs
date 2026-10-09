//! The speech model: GigaAM v3 (Russian, with punctuation) in the sherpa-onnx
//! packaging. One download, then recognition works offline.
//!
//! Everything about it that is not touching a disk or a network is here: what
//! it is called, where it comes from, which files and which hashes make it
//! whole, how it is checked, and how a download's progress is told.

use super::messages::{DictationFailure, MODEL_MISSING_OR_DAMAGED};
use super::sha256;
use std::io::Read;
use std::path::{Path, PathBuf};

pub const NAME: &str = "sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16";

/// A `.tar.bz2` of the model's folder.
pub fn source_url() -> String {
    format!("https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{NAME}.tar.bz2")
}

/// What Settings says about its size: "GigaAM v3 · 170 MB download · 232 MB on disk".
pub const DOWNLOAD_MEGABYTES: u32 = 170;
pub const DISK_MEGABYTES: u32 = 232;
pub const LICENCE_FILE: &str = "LICENSE";

/// The four files and the SHA-256 each must have, in the order checked.
pub const FILES: [(&str, &str); 4] = [
    ("encoder.int8.onnx", "369f35a71bf288d3b8e0391fabd8dba5f2314088d440bca474056b7b4b6e66bf"),
    ("decoder.onnx", "38fc7475443ea2a26f63211ca350f73ac50fff824ab7a3876ee2bd610c53bbc4"),
    ("joiner.onnx", "602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c"),
    ("tokens.txt", "39abae20e692998290c574e606f11a9edef2902a1995463fcff63d1490cf22b7"),
];

/// The audio the recogniser is fed: 16 kHz mono, 64 mel features.
pub const SAMPLE_RATE: u32 = 16_000;
pub const FEATURE_DIM: u32 = 64;
/// The sherpa-onnx configuration the Swift engine builds, for the Rust one to
/// reproduce exactly.
pub mod engine {
    pub const THREADS: u32 = 4;
    pub const PROVIDER: &str = "cpu";
    pub const MODEL_TYPE: &str = "nemo_transducer";
    pub const MODELING_UNIT: &str = "cjkchar";
    pub const DECODING_METHOD: &str = "greedy_search";
    pub const MAX_ACTIVE_PATHS: u32 = 4;
    /// A loaded model is let go after this many seconds without a recognition.
    pub const UNLOAD_AFTER_SECONDS: u64 = 300;
}

/// Where the model lives: `<data directory>/Dictation/<name>`. The data
/// directory is `dirs::state`'s sibling the platform picks for large files
/// (Application Support on a Mac, `$XDG_DATA_HOME` on Linux).
pub fn directory(data_directory: &Path) -> PathBuf {
    data_directory.join("Dictation").join(NAME)
}

/// What must be taken out of the archive: each file and the licence, as
/// `<name>/<file>` members.
pub fn archive_members() -> Vec<String> {
    FILES.iter().map(|(file, _)| *file).chain([LICENCE_FILE]).map(|f| format!("{NAME}/{f}")).collect()
}

/// Whether a member of a downloaded archive may be unpacked: a path inside the
/// archive's own folder, never one that climbs out of it (`..`) or starts at
/// the root.
pub fn safe_member(path: &Path) -> bool {
    use std::path::Component;
    path.components().all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
}

/// The folder as the model's files see it: just enough to ask of any disk.
pub trait ModelFolder {
    fn exists(&self, file: &str) -> bool;
    fn open(&self, file: &str) -> Option<Box<dyn Read + '_>>;
}

/// A real folder.
pub struct DiskFolder(pub PathBuf);

impl ModelFolder for DiskFolder {
    fn exists(&self, file: &str) -> bool {
        self.0.join(file).is_file()
    }
    fn open(&self, file: &str) -> Option<Box<dyn Read + '_>> {
        std::fs::File::open(self.0.join(file)).ok().map(|f| Box::new(f) as Box<dyn Read>)
    }
}

/// Whether every file is there. Cheap: nothing is read.
pub fn exists(folder: &dyn ModelFolder) -> bool {
    FILES.iter().all(|(file, _)| folder.exists(file))
}

/// Checks every file's hash. `cancelled` is asked before each file, so a
/// long check can be given up; a cancelled check is `Ok(false)`.
pub fn validate(folder: &dyn ModelFolder, cancelled: &dyn Fn() -> bool) -> Result<bool, DictationFailure> {
    for (file, hash) in FILES {
        if cancelled() {
            return Ok(false);
        }
        let damaged = || DictationFailure::new(MODEL_MISSING_OR_DAMAGED);
        let reader = folder.open(file).ok_or_else(damaged)?;
        let found = sha256::hex_of(reader).map_err(|_| damaged())?;
        if found != hash {
            return Err(damaged());
        }
    }
    Ok(true)
}

/// A download told in numbers: fractions that arrive, and the log hearing a
/// quarter at a time, so one that stalls shows where.
#[derive(Debug, Clone, Default)]
pub struct DownloadProgress {
    fraction: Option<f64>,
    logged_quarter: u32,
}

impl DownloadProgress {
    pub fn started() -> Self {
        Self { fraction: Some(0.0), logged_quarter: 0 }
    }

    pub fn fraction(&self) -> Option<f64> {
        self.fraction
    }

    /// What Settings writes under the bar: "Checking the model…" once all of
    /// it is here, a percentage until then.
    pub fn label(&self) -> Option<ProgressLabel> {
        self.fraction.map(|f| if f >= 1.0 { ProgressLabel::Checking } else { ProgressLabel::Downloading((f * 100.0) as u32) })
    }

    /// Takes a fraction; returns the quarter (25, 50, 75) to log, if it is a
    /// new one. Never 100: finishing is logged by its own event.
    pub fn advance(&mut self, fraction: f64) -> Option<u32> {
        self.fraction?;
        let fraction = fraction.clamp(0.0, 1.0);
        self.fraction = Some(fraction);
        let quarter = (fraction * 4.0) as u32 * 25;
        if quarter > self.logged_quarter && quarter < 100 {
            self.logged_quarter = quarter;
            Some(quarter)
        } else {
            None
        }
    }

    pub fn finished(&mut self) {
        self.fraction = None;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressLabel {
    /// "Downloading · %d%%"
    Downloading(u32),
    /// "Checking the model…"
    Checking,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    struct Memory(HashMap<&'static str, Vec<u8>>);

    impl ModelFolder for Memory {
        fn exists(&self, file: &str) -> bool {
            self.0.contains_key(file)
        }
        fn open(&self, file: &str) -> Option<Box<dyn Read + '_>> {
            self.0.get(file).map(|d| Box::new(std::io::Cursor::new(d.clone())) as Box<dyn Read>)
        }
    }

    #[test]
    fn a_member_climbing_out_of_the_archive_is_refused() {
        assert!(safe_member(Path::new(&format!("{NAME}/tokens.txt"))));
        assert!(safe_member(Path::new("./lib/libonnxruntime.so")));
        assert!(!safe_member(Path::new(&format!("{NAME}/../../.bashrc"))));
        assert!(!safe_member(Path::new("../tokens.txt")));
        assert!(!safe_member(Path::new("/etc/passwd")));
    }

    #[test]
    fn the_model_is_a_named_download_with_four_hashed_files() {
        assert!(source_url().ends_with(&format!("/asr-models/{NAME}.tar.bz2")));
        assert!(source_url().starts_with("https://github.com/k2-fsa/sherpa-onnx/releases/download/"));
        assert_eq!(FILES.len(), 4);
        for (_, hash) in FILES {
            assert_eq!(hash.len(), 64);
            assert!(hash.chars().all(|c| c.is_ascii_hexdigit()));
        }
        assert_eq!(directory(Path::new("/data")), Path::new("/data/Dictation").join(NAME));
        let members = archive_members();
        assert_eq!(members.len(), 5, "the four files and the licence");
        assert!(members.iter().all(|m| m.starts_with(&format!("{NAME}/"))));
        assert!(members.last().unwrap().ends_with("/LICENSE"));
    }

    #[test]
    fn a_folder_with_every_file_exists_and_one_short_does_not() {
        let mut files: HashMap<&'static str, Vec<u8>> = FILES.iter().map(|(f, _)| (*f, vec![1])).collect();
        assert!(exists(&Memory(files.clone())));
        files.remove("joiner.onnx");
        assert!(!exists(&Memory(files)));
    }

    #[test]
    fn a_file_that_is_not_the_one_shipped_is_damaged_and_so_is_a_missing_one() {
        let files: HashMap<&'static str, Vec<u8>> = FILES.iter().map(|(f, _)| (*f, b"not the model".to_vec())).collect();
        let error = validate(&Memory(files), &|| false).unwrap_err();
        assert_eq!(error.message(), MODEL_MISSING_OR_DAMAGED);
        let none = Memory(HashMap::new());
        assert_eq!(validate(&none, &|| false).unwrap_err().message(), MODEL_MISSING_OR_DAMAGED);
    }

    #[test]
    fn a_cancelled_check_is_neither_good_nor_damaged() {
        let none = Memory(HashMap::new());
        assert_eq!(validate(&none, &|| true), Ok(false));
    }

    #[test]
    fn progress_logs_a_quarter_at_a_time_and_never_the_end() {
        let mut p = DownloadProgress::started();
        assert_eq!(p.label(), Some(ProgressLabel::Downloading(0)));
        assert_eq!(p.advance(0.10), None);
        assert_eq!(p.advance(0.26), Some(25));
        assert_eq!(p.advance(0.30), None, "the same quarter is logged once");
        assert_eq!(p.advance(0.80), Some(75), "a jump logs where it landed");
        assert_eq!(p.advance(1.0), None, "100 has its own event");
        assert_eq!(p.label(), Some(ProgressLabel::Checking));
        p.finished();
        assert_eq!(p.fraction(), None);
        assert_eq!(p.advance(0.5), None, "a finished download takes no more progress");
        assert_eq!(DownloadProgress::default().label(), None);
    }
}
