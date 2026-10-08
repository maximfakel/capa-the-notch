//! The sherpa-onnx shared library: where it lives, and fetching it.

use capa_core::dictation::{model, sha256::Sha256};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// The pinned release: the one `ffi_structs` was generated from.
pub const VERSION: &str = "1.13.8";

pub const LIBRARY_FILE: &str = "libsherpa-onnx-c-api.so";

/// The SHA-256 of the release's tarball, as GitHub lists it for the asset. A
/// download that is anything else is thrown away unopened: the library in it
/// is loaded into the daemon.
pub const ARCHIVE_SHA256: &str = "3892d184be41027e18165e67f549cd4e4cdd8dcd73ac5579e97afd55e14e30b6";

/// What the release's tarball is called.
pub fn archive_url() -> String {
    let name = format!("sherpa-onnx-v{VERSION}-linux-x64-shared-lib.tar.bz2");
    format!("https://github.com/k2-fsa/sherpa-onnx/releases/download/v{VERSION}/{name}")
}

/// Files of the archive worth keeping, by name: the C API and onnxruntime.
fn wanted(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    (lower.contains("sherpa-onnx-c-api") || lower.contains("onnxruntime")) && lower.contains(".so")
}

/// `$data/Dictation/runtime`.
pub fn directory(data: &Path) -> PathBuf {
    data.join("Dictation").join("runtime")
}

/// The library to load: `CAPA_SHERPA_LIB` if set (for a system install or a
/// build of one's own), else the one downloaded beside the model.
pub fn library_path(data: &Path) -> PathBuf {
    std::env::var_os("CAPA_SHERPA_LIB").map(PathBuf::from).unwrap_or_else(|| directory(data).join(LIBRARY_FILE))
}

pub fn is_installed(data: &Path) -> bool {
    library_path(data).is_file()
}

/// Downloads the library, checks the archive's hash, and only then unpacks it
/// into `directory(data)`. `cancelled` is looked at between chunks.
pub fn install(data: &Path, cancelled: &dyn Fn() -> bool) -> Result<(), String> {
    let target = directory(data);
    std::fs::create_dir_all(&target).map_err(|e| e.to_string())?;
    let response = ureq::get(&archive_url()).call().map_err(|e| e.to_string())?;
    let mut reader = response.into_body().into_reader();
    let archive = target.join("download.tar.bz2");
    let mut hasher = Sha256::new();
    {
        let mut file = std::fs::File::create(&archive).map_err(|e| e.to_string())?;
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            if cancelled() {
                let _ = std::fs::remove_file(&archive);
                return Err("cancelled".into());
            }
            let n = reader.read(&mut buffer).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            hasher.update(&buffer[..n]);
            file.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
        }
    }
    let found = hasher.hex();
    if found != ARCHIVE_SHA256 {
        let _ = std::fs::remove_file(&archive);
        return Err(format!("the sherpa-onnx archive is not the released one (SHA-256 {found})"));
    }
    let result = unpack(&archive, &target);
    let _ = std::fs::remove_file(&archive);
    result?;
    if is_installed(data) { Ok(()) } else { Err("the archive held no sherpa-onnx library".into()) }
}

fn unpack(archive: &Path, target: &Path) -> Result<(), String> {
    let decoder = bzip2::read::BzDecoder::new(std::fs::File::open(archive).map_err(|e| e.to_string())?);
    let mut tar = tar::Archive::new(decoder);
    for entry in tar.entries().map_err(|e| e.to_string())? {
        let mut entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path().map_err(|e| e.to_string())?.into_owned();
        if !model::safe_member(&path) {
            return Err(format!("the sherpa-onnx archive has a path outside it: {}", path.display()));
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()).map(str::to_owned) else { continue };
        if entry.header().entry_type().is_file() && wanted(&name) {
            entry.unpack(target.join(&name)).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pinned_library_is_named_and_only_the_c_api_and_onnxruntime_are_kept() {
        assert!(archive_url().contains(VERSION));
        assert!(wanted("libsherpa-onnx-c-api.so"));
        assert!(wanted("libonnxruntime.so"));
        assert!(!wanted("libsherpa-onnx-cxx-api.so"));
        assert!(!wanted("LICENSE"));
        assert_eq!(ARCHIVE_SHA256.len(), 64);
        assert!(ARCHIVE_SHA256.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }
}
