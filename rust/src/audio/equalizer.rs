//! Graphic EQ: 10 peaking biquad bands at fixed frequencies.
//! Single responsibility: apply band gains to interleaved f32 samples.

use std::f32::consts::PI;
use std::sync::atomic::{AtomicU8, Ordering};

/// Fixed center frequencies (Hz) matching Dart EqualizerState.defaultGraphicFrequenciesHz.
pub const BAND_FREQS_HZ: [f32; 10] =
    [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

const Q: f32 = 1.0;
const NUM_BANDS: usize = 10;
const COEFFS_PER_BAND: usize = 5;

/// Biquad coeffs per band: b0, b1, b2, a1, a2 (a0 normalized to 1).
#[derive(Clone, Copy)]
pub struct EqParams {
    pub enabled: bool,
    pub coeffs: [[f32; COEFFS_PER_BAND]; NUM_BANDS],
}

impl EqParams {
    pub fn disabled() -> Self {
        Self {
            enabled: false,
            coeffs: [[1.0, 0.0, 0.0, 0.0, 0.0]; NUM_BANDS],
        }
    }

    /// Build from band gains in dB and sample rate.
    pub fn from_gains_db(gains_db: &[f32; NUM_BANDS], sample_rate: u32) -> Self {
        let fs = sample_rate as f32;
        let mut coeffs = [[0.0f32; COEFFS_PER_BAND]; NUM_BANDS];
        for (i, &gain_db) in gains_db.iter().enumerate() {
            let f0 = BAND_FREQS_HZ[i];
            let (b0, b1, b2, a1, a2) = peaking_coeffs(f0, gain_db, Q, fs);
            coeffs[i] = [b0, b1, b2, a1, a2];
        }
        Self { enabled: true, coeffs }
    }
}

/// Peaking EQ: A = 10^(dBgain/40), w0 = 2*pi*f0/Fs, alpha = sin(w0)/(2*Q).
fn peaking_coeffs(f0: f32, gain_db: f32, q: f32, fs: f32) -> (f32, f32, f32, f32, f32) {
    let a = 10.0f32.powf(gain_db / 40.0);
    let w0 = 2.0 * PI * f0 / fs;
    let cos_w0 = w0.cos();
    let sin_w0 = w0.sin();
    let alpha = sin_w0 / (2.0 * q);
    let b0 = 1.0 + alpha * a;
    let b1 = -2.0 * cos_w0;
    let b2 = 1.0 - alpha * a;
    let a0 = 1.0 + alpha / a;
    let a1 = -2.0 * cos_w0;
    let a2 = 1.0 - alpha / a;
    (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
}

/// Per-channel, per-band biquad state: x1, x2, y1, y2.
type BandState = [f32; 4];
type ChannelState = [BandState; NUM_BANDS];

/// Double-buffered params for lock-free updates from command thread.
pub struct Equalizer {
    params: [EqParams; 2],
    index: AtomicU8,
    state: [ChannelState; 2],
}

impl Equalizer {
    pub fn new() -> Self {
        Self {
            params: [EqParams::disabled(), EqParams::disabled()],
            index: AtomicU8::new(0),
            state: [[[0.0; 4]; NUM_BANDS]; 2],
        }
    }

    /// Called from command thread. sample_rate must match engine.
    pub fn set(&mut self, enabled: bool, gains_db: &[f32; NUM_BANDS], sample_rate: u32) {
        let next = if enabled {
            EqParams::from_gains_db(gains_db, sample_rate)
        } else {
            EqParams::disabled()
        };
        let idx = self.index.load(Ordering::Relaxed);
        self.params[1 - idx as usize] = next;
        self.index.store(1 - idx, Ordering::Release);
    }

    #[inline]
    fn current_params(&self) -> EqParams {
        self.params[self.index.load(Ordering::Acquire) as usize]
    }

    /// Process interleaved buffer in place. channels = 2.
    pub fn process(&mut self, buf: &mut [f32], channels: usize) {
        let p = self.current_params();
        if !p.enabled {
            return;
        }
        let frames = buf.len() / channels;
        for f in 0..frames {
            for ch in 0..channels {
                let idx = f * channels + ch;
                let x0 = buf[idx];
                buf[idx] = process_sample_chain(x0, &p.coeffs, &mut self.state[ch]);
            }
        }
    }
}

fn process_sample_chain(
    x0: f32,
    coeffs: &[[f32; COEFFS_PER_BAND]; NUM_BANDS],
    state: &mut ChannelState,
) -> f32 {
    let mut x = x0;
    for (b, s) in coeffs.iter().zip(state.iter_mut()) {
        let (b0, b1, b2, a1, a2) = (b[0], b[1], b[2], b[3], b[4]);
        let (x1, x2, y1, y2) = (s[0], s[1], s[2], s[3]);
        let y0 = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        s[0] = x;
        s[1] = x1;
        s[2] = y0;
        s[3] = y1;
        x = y0;
    }
    x
}

