//! A rendered sound as a mono 16-bit WAV in memory, cut as procedural-sounds
//! cuts its exports (lib/audio/export/wav.ts): the silence before and after
//! trimmed, and both new edges faded so the cut cannot click.

pub fn wav(samples: &[f32]) -> Vec<u8> {
    wav_at(samples, 44100)
}

pub fn wav_at(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let trimmed = trim_and_fade(samples, sample_rate as f64);
    let bytes = (trimmed.len() * 2) as u32;
    let mut data = Vec::with_capacity(44 + trimmed.len() * 2);
    data.extend_from_slice(b"RIFF");
    data.extend_from_slice(&(36 + bytes).to_le_bytes());
    data.extend_from_slice(b"WAVE");
    data.extend_from_slice(b"fmt ");
    data.extend_from_slice(&16u32.to_le_bytes());
    data.extend_from_slice(&1u16.to_le_bytes()); // PCM
    data.extend_from_slice(&1u16.to_le_bytes()); // mono
    data.extend_from_slice(&sample_rate.to_le_bytes());
    data.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    data.extend_from_slice(&2u16.to_le_bytes());
    data.extend_from_slice(&16u16.to_le_bytes());
    data.extend_from_slice(b"data");
    data.extend_from_slice(&bytes.to_le_bytes());
    for sample in trimmed {
        let clamped = sample.clamp(-1.0, 1.0);
        let scaled = if clamped < 0.0 { clamped * 32768.0 } else { clamped * 32767.0 };
        data.extend_from_slice(&(scaled.round() as i16).to_le_bytes());
    }
    data
}

/// The samples as 16-bit PCM, cut and faded as the WAV is, for a player that
/// wants buffers rather than files.
pub fn pcm16(samples: &[f32], sample_rate: u32) -> Vec<i16> {
    trim_and_fade(samples, sample_rate as f64)
        .into_iter()
        .map(|sample| {
            let clamped = sample.clamp(-1.0, 1.0);
            (if clamped < 0.0 { clamped * 32768.0 } else { clamped * 32767.0 }).round() as i16
        })
        .collect()
}

pub fn trim_and_fade(samples: &[f32], sample_rate: f64) -> Vec<f32> {
    let silence = 0.0001f32;
    let peak = samples.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
    if peak <= silence {
        let keep = (sample_rate * 0.01).ceil() as usize;
        return samples.iter().take(keep).copied().collect();
    }
    let mut start = 0;
    while start < samples.len() && samples[start].abs() < silence {
        start += 1;
    }
    let mut end = samples.len();
    while end > start && samples[end - 1].abs() < silence {
        end -= 1;
    }
    let mut out: Vec<f32> = samples[start..end].to_vec();
    let n = out.len();
    if n == 0 {
        return out;
    }
    let mut onset = 0;
    while onset < n && out[onset].abs() < peak * 0.01 {
        onset += 1;
    }
    let fade_in = ((sample_rate * 0.002).round() as usize).min(onset);
    let fade_out = ((sample_rate * 0.006).round() as usize).min(n / 4);
    for (i, sample) in out.iter_mut().enumerate().take(fade_in) {
        *sample *= i as f32 / fade_in as f32;
    }
    for i in 0..fade_out {
        out[n - 1 - i] *= i as f32 / fade_out as f32;
    }
    out
}
