//! sherpa-onnx, loaded at run time.
//!
//! The macOS app links sherpa-onnx's static frameworks. Here the C API is
//! `dlopen`ed from a shared library instead, so the application builds and
//! runs without the runtime present, and a person who never turns Dictation
//! on never downloads it. `RuntimeLibrary` says where the library is and
//! downloads it (pinned, hashed by size and checked by loading) with the model.
//!
//! The struct layouts in `ffi_structs` are the header's, for exactly the
//! version pinned in `VERSION`.

#![allow(non_snake_case)]

pub mod ffi_structs;
pub mod runtime;

use capa_core::dictation::{
    model, DictationFailure, RecognitionError, Recogniser, MODEL_COULD_NOT_LOAD, MODEL_MISSING_OR_DAMAGED,
    NO_SPEECH_RECORDED, RECOGNITION_COULD_NOT_START, RECOGNITION_FAILED,
};
use ffi_structs::SherpaOnnxOfflineRecognizerConfig;
use libloading::Library;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::{Path, PathBuf};

type Handle = *const c_void;

/// The result's first field, the text: all this module reads. The C struct goes on
/// (tokens, timestamps, JSON); a pointer to it is only ever read through this prefix.
#[repr(C)]
pub struct SherpaOnnxOfflineRecognizerResult {
    pub text: *const c_char,
}

struct Api {
    create_recognizer: unsafe extern "C" fn(*const SherpaOnnxOfflineRecognizerConfig) -> Handle,
    destroy_recognizer: unsafe extern "C" fn(Handle),
    create_stream: unsafe extern "C" fn(Handle) -> Handle,
    destroy_stream: unsafe extern "C" fn(Handle),
    accept_waveform: unsafe extern "C" fn(Handle, i32, *const f32, i32),
    decode: unsafe extern "C" fn(Handle, Handle),
    get_result: unsafe extern "C" fn(Handle) -> *const SherpaOnnxOfflineRecognizerResult,
    destroy_result: unsafe extern "C" fn(*const SherpaOnnxOfflineRecognizerResult),
    // Keeps the library mapped for as long as the function pointers live.
    _library: Library,
}

impl Api {
    fn load(path: &Path) -> Result<Self, DictationFailure> {
        // SAFETY: loading a shared library runs its initialisers; it is the
        // pinned sherpa-onnx build, or what `CAPA_SHERPA_LIB` names.
        let library = unsafe { Library::new(path) }.map_err(|_| DictationFailure::new(MODEL_COULD_NOT_LOAD))?;
        macro_rules! symbol {
            ($name:literal) => {
                // SAFETY: the signature is the header's for this symbol.
                *unsafe { library.get($name) }.map_err(|_| DictationFailure::new(MODEL_COULD_NOT_LOAD))?
            };
        }
        Ok(Self {
            create_recognizer: symbol!(b"SherpaOnnxCreateOfflineRecognizer\0"),
            destroy_recognizer: symbol!(b"SherpaOnnxDestroyOfflineRecognizer\0"),
            create_stream: symbol!(b"SherpaOnnxCreateOfflineStream\0"),
            destroy_stream: symbol!(b"SherpaOnnxDestroyOfflineStream\0"),
            accept_waveform: symbol!(b"SherpaOnnxAcceptWaveformOffline\0"),
            decode: symbol!(b"SherpaOnnxDecodeOfflineStream\0"),
            get_result: symbol!(b"SherpaOnnxGetOfflineStreamResult\0"),
            destroy_result: symbol!(b"SherpaOnnxDestroyOfflineRecognizerResult\0"),
            _library: library,
        })
    }
}

/// The loaded model: the C handle, and the API that owns it.
struct Loaded {
    api: Api,
    handle: Handle,
}

// SAFETY: the handle is used from one thread at a time (`SherpaRecogniser` is
// behind `&mut self`), and sherpa-onnx's offline recogniser has no thread affinity.
unsafe impl Send for Loaded {}

impl Drop for Loaded {
    fn drop(&mut self) {
        // SAFETY: `handle` came from `create_recognizer` and is destroyed once.
        unsafe { (self.api.destroy_recognizer)(self.handle) }
    }
}

/// Speech to text with the model in `model.rs`, configured as the Swift app does.
pub struct SherpaRecogniser {
    library: PathBuf,
    folder: PathBuf,
    loaded: Option<Loaded>,
}

impl SherpaRecogniser {
    pub fn new(library: PathBuf, folder: PathBuf) -> Self {
        Self { library, folder, loaded: None }
    }

    /// Whether a model is loaded now, for the 300 s unload.
    pub fn is_loaded(&self) -> bool {
        self.loaded.is_some()
    }

    fn load(&mut self, cancelled: &dyn Fn() -> bool) -> Result<(), RecognitionError> {
        if self.loaded.is_some() {
            return Ok(());
        }
        let disk = model::DiskFolder(self.folder.clone());
        match model::validate(&disk, cancelled) {
            Ok(true) => {}
            Ok(false) => return Err(RecognitionError::Other("cancelled".into())),
            Err(_) => return Err(RecognitionError::Dictation(DictationFailure::new(MODEL_MISSING_OR_DAMAGED))),
        }
        let api = Api::load(&self.library).map_err(RecognitionError::Dictation)?;

        let path = |name: &str| CString::new(self.folder.join(name).to_string_lossy().into_owned()).unwrap();
        let text = |value: &str| CString::new(value).unwrap();
        let (encoder, decoder, joiner, tokens) =
            (path("encoder.int8.onnx"), path("decoder.onnx"), path("joiner.onnx"), path("tokens.txt"));
        let (provider, model_type, unit, method) =
            (text(model::engine::PROVIDER), text(model::engine::MODEL_TYPE), text(model::engine::MODELING_UNIT), text(model::engine::DECODING_METHOD));

        let mut config = SherpaOnnxOfflineRecognizerConfig::default();
        config.feat_config.sample_rate = model::SAMPLE_RATE as i32;
        config.feat_config.feature_dim = model::FEATURE_DIM as i32;
        config.model_config.transducer.encoder = encoder.as_ptr();
        config.model_config.transducer.decoder = decoder.as_ptr();
        config.model_config.transducer.joiner = joiner.as_ptr();
        config.model_config.tokens = tokens.as_ptr();
        config.model_config.num_threads = model::engine::THREADS as i32;
        config.model_config.provider = provider.as_ptr();
        config.model_config.model_type = model_type.as_ptr();
        config.model_config.modeling_unit = unit.as_ptr();
        config.decoding_method = method.as_ptr();
        config.max_active_paths = model::engine::MAX_ACTIVE_PATHS as i32;

        // SAFETY: `config` and the C strings it points at outlive the call.
        let handle = unsafe { (api.create_recognizer)(&config) };
        if handle.is_null() {
            return Err(RecognitionError::Dictation(DictationFailure::new(MODEL_COULD_NOT_LOAD)));
        }
        self.loaded = Some(Loaded { api, handle });
        Ok(())
    }
}

impl Recogniser for SherpaRecogniser {
    fn recognise(&mut self, samples: &[f32], cancelled: &dyn Fn() -> bool) -> Result<String, RecognitionError> {
        if cancelled() {
            return Err(RecognitionError::Other("cancelled".into()));
        }
        if samples.is_empty() {
            return Err(RecognitionError::Dictation(DictationFailure::new(NO_SPEECH_RECORDED)));
        }
        self.load(cancelled)?;
        if cancelled() {
            return Err(RecognitionError::Other("cancelled".into()));
        }
        let loaded = self.loaded.as_ref().expect("loaded above");
        let api = &loaded.api;
        // SAFETY: each call is the header's, on handles this function owns, and
        // the result is read before it is destroyed.
        unsafe {
            let stream = (api.create_stream)(loaded.handle);
            if stream.is_null() {
                return Err(RecognitionError::Dictation(DictationFailure::new(RECOGNITION_COULD_NOT_START)));
            }
            (api.accept_waveform)(stream, model::SAMPLE_RATE as i32, samples.as_ptr(), samples.len() as i32);
            (api.decode)(loaded.handle, stream);
            let result = (api.get_result)(stream);
            let text = if result.is_null() {
                None
            } else {
                let text_ptr: *const c_char = (*result).text;
                let text = (!text_ptr.is_null()).then(|| CStr::from_ptr(text_ptr).to_string_lossy().trim().to_owned());
                (api.destroy_result)(result);
                text
            };
            (api.destroy_stream)(stream);
            text.ok_or_else(|| RecognitionError::Dictation(DictationFailure::new(RECOGNITION_FAILED)))
        }
    }

    fn unload(&mut self) {
        self.loaded = None;
    }
}

#[cfg(test)]
mod tests {
    use super::ffi_structs::*;
    use std::mem::{offset_of, size_of};

    /// What a C compiler says about sherpa-onnx 1.13.8's `c-api.h` on a 64-bit
    /// system (gcc, `offsetof`/`sizeof`), for the fields this module sets.
    #[test]
    fn layout_matches_the_header() {
        assert_eq!(size_of::<SherpaOnnxOfflineModelConfig>(), 504);
        assert_eq!(size_of::<SherpaOnnxOfflineRecognizerConfig>(), 608);
        assert_eq!(offset_of!(SherpaOnnxOfflineModelConfig, tokens), 96);
        assert_eq!(offset_of!(SherpaOnnxOfflineModelConfig, num_threads), 104);
        assert_eq!(offset_of!(SherpaOnnxOfflineModelConfig, provider), 112);
        assert_eq!(offset_of!(SherpaOnnxOfflineModelConfig, model_type), 120);
        assert_eq!(offset_of!(SherpaOnnxOfflineModelConfig, modeling_unit), 128);
        assert_eq!(offset_of!(SherpaOnnxOfflineRecognizerConfig, model_config), 8);
        assert_eq!(offset_of!(SherpaOnnxOfflineRecognizerConfig, decoding_method), 528);
        assert_eq!(offset_of!(SherpaOnnxOfflineRecognizerConfig, max_active_paths), 536);
        assert_eq!(offset_of!(SherpaOnnxOfflineRecognizerConfig, hr), 584);
    }
}
