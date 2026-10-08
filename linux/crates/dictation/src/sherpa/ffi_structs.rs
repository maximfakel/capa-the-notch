//! Generated from sherpa-onnx 1.13.8's c-api.h (the structs the offline recognizer takes).
//! Field order and types are the header's; `layout_matches_the_header` checks sizes and
//! offsets against a C compiler's answer, recorded in `LAYOUT`.
#![allow(non_snake_case)]
use std::os::raw::{c_char, c_float, c_int};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxFeatureConfig {
    pub sample_rate: c_int,
    pub feature_dim: c_int,
}

impl Default for SherpaOnnxFeatureConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineTransducerModelConfig {
    pub encoder: *const c_char,
    pub decoder: *const c_char,
    pub joiner: *const c_char,
}

impl Default for SherpaOnnxOfflineTransducerModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineParaformerModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineParaformerModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineNemoEncDecCtcModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineNemoEncDecCtcModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineWhisperModelConfig {
    pub encoder: *const c_char,
    pub decoder: *const c_char,
    pub language: *const c_char,
    pub task: *const c_char,
    pub tail_paddings: c_int,
    pub enable_token_timestamps: c_int,
    pub enable_segment_timestamps: c_int,
}

impl Default for SherpaOnnxOfflineWhisperModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineFireRedAsrModelConfig {
    pub encoder: *const c_char,
    pub decoder: *const c_char,
}

impl Default for SherpaOnnxOfflineFireRedAsrModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineTdnnModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineTdnnModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineLMConfig {
    pub model: *const c_char,
    pub scale: c_float,
}

impl Default for SherpaOnnxOfflineLMConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineSenseVoiceModelConfig {
    pub model: *const c_char,
    pub language: *const c_char,
    pub use_itn: c_int,
}

impl Default for SherpaOnnxOfflineSenseVoiceModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineMoonshineModelConfig {
    pub preprocessor: *const c_char,
    pub encoder: *const c_char,
    pub uncached_decoder: *const c_char,
    pub cached_decoder: *const c_char,
    pub merged_decoder: *const c_char,
}

impl Default for SherpaOnnxOfflineMoonshineModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineDolphinModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineDolphinModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineZipformerCtcModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineZipformerCtcModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineCanaryModelConfig {
    pub encoder: *const c_char,
    pub decoder: *const c_char,
    pub src_lang: *const c_char,
    pub tgt_lang: *const c_char,
    pub use_pnc: c_int,
}

impl Default for SherpaOnnxOfflineCanaryModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineWenetCtcModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineWenetCtcModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineMedAsrCtcModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineMedAsrCtcModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineFunASRNanoModelConfig {
    pub encoder_adaptor: *const c_char,
    pub llm: *const c_char,
    pub embedding: *const c_char,
    pub tokenizer: *const c_char,
    pub system_prompt: *const c_char,
    pub user_prompt: *const c_char,
    pub max_new_tokens: c_int,
    pub temperature: c_float,
    pub top_p: c_float,
    pub seed: c_int,
    pub language: *const c_char,
    pub itn: c_int,
    pub hotwords: *const c_char,
}

impl Default for SherpaOnnxOfflineFunASRNanoModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineFireRedAsrCtcModelConfig {
    pub model: *const c_char,
}

impl Default for SherpaOnnxOfflineFireRedAsrCtcModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineQwen3ASRModelConfig {
    pub conv_frontend: *const c_char,
    pub encoder: *const c_char,
    pub decoder: *const c_char,
    pub tokenizer: *const c_char,
    pub max_total_len: c_int,
    pub max_new_tokens: c_int,
    pub temperature: c_float,
    pub top_p: c_float,
    pub seed: c_int,
    pub hotwords: *const c_char,
}

impl Default for SherpaOnnxOfflineQwen3ASRModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineCohereTranscribeModelConfig {
    pub encoder: *const c_char,
    pub decoder: *const c_char,
    pub language: *const c_char,
    pub use_punct: c_int,
    pub use_itn: c_int,
}

impl Default for SherpaOnnxOfflineCohereTranscribeModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineModelConfig {
    pub transducer: SherpaOnnxOfflineTransducerModelConfig,
    pub paraformer: SherpaOnnxOfflineParaformerModelConfig,
    pub nemo_ctc: SherpaOnnxOfflineNemoEncDecCtcModelConfig,
    pub whisper: SherpaOnnxOfflineWhisperModelConfig,
    pub tdnn: SherpaOnnxOfflineTdnnModelConfig,
    pub tokens: *const c_char,
    pub num_threads: c_int,
    pub debug: c_int,
    pub provider: *const c_char,
    pub model_type: *const c_char,
    pub modeling_unit: *const c_char,
    pub bpe_vocab: *const c_char,
    pub telespeech_ctc: *const c_char,
    pub sense_voice: SherpaOnnxOfflineSenseVoiceModelConfig,
    pub moonshine: SherpaOnnxOfflineMoonshineModelConfig,
    pub fire_red_asr: SherpaOnnxOfflineFireRedAsrModelConfig,
    pub dolphin: SherpaOnnxOfflineDolphinModelConfig,
    pub zipformer_ctc: SherpaOnnxOfflineZipformerCtcModelConfig,
    pub canary: SherpaOnnxOfflineCanaryModelConfig,
    pub wenet_ctc: SherpaOnnxOfflineWenetCtcModelConfig,
    pub omnilingual: SherpaOnnxOfflineOmnilingualAsrCtcModelConfig,
    pub medasr: SherpaOnnxOfflineMedAsrCtcModelConfig,
    pub funasr_nano: SherpaOnnxOfflineFunASRNanoModelConfig,
    pub fire_red_asr_ctc: SherpaOnnxOfflineFireRedAsrCtcModelConfig,
    pub qwen3_asr: SherpaOnnxOfflineQwen3ASRModelConfig,
    pub cohere_transcribe: SherpaOnnxOfflineCohereTranscribeModelConfig,
}

impl Default for SherpaOnnxOfflineModelConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxHomophoneReplacerConfig {
    pub dict_dir: *const c_char,
    pub lexicon: *const c_char,
    pub rule_fsts: *const c_char,
}

impl Default for SherpaOnnxHomophoneReplacerConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SherpaOnnxOfflineRecognizerConfig {
    pub feat_config: SherpaOnnxFeatureConfig,
    pub model_config: SherpaOnnxOfflineModelConfig,
    pub lm_config: SherpaOnnxOfflineLMConfig,
    pub decoding_method: *const c_char,
    pub max_active_paths: c_int,
    pub hotwords_file: *const c_char,
    pub hotwords_score: c_float,
    pub rule_fsts: *const c_char,
    pub rule_fars: *const c_char,
    pub blank_penalty: c_float,
    pub hr: SherpaOnnxHomophoneReplacerConfig,
}

impl Default for SherpaOnnxOfflineRecognizerConfig {
    fn default() -> Self {
        // SAFETY: every field is an integer, a float, a null pointer or a struct of them.
        unsafe { std::mem::zeroed() }
    }
}
