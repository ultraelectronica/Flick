//! Lightweight stereo spatial and time FX for the realtime callback.
//!
//! The implementation is intentionally simple and deterministic:
//! - fixed-size delay buffers allocated outside the audio callback
//! - one-pole damping/filtering for the wet path
//! - stereo width and balance applied in place on interleaved buffers

use std::f32::consts::PI;

const MAX_DELAY_MS: f32 = 1600.0;
const MIN_DELAY_MS: f32 = 10.0;

#[derive(Debug, Clone, Copy)]
pub struct FxSettings {
    pub enabled: bool,
    pub balance: f32,
    pub tempo: f32,
    pub damp: f32,
    pub filter_hz: f32,
    pub delay_ms: f32,
    pub size: f32,
    pub mix: f32,
    pub feedback: f32,
    pub width: f32,
}

impl FxSettings {
    pub const fn disabled() -> Self {
        Self {
            enabled: false,
            balance: 0.0,
            tempo: 1.0,
            damp: 0.35,
            filter_hz: 6800.0,
            delay_ms: 240.0,
            size: 0.55,
            mix: 0.25,
            feedback: 0.35,
            width: 1.0,
        }
    }
}

pub struct SpatialFx {
    sample_rate: u32,
    settings: FxSettings,
    delay_l: Vec<f32>,
    delay_r: Vec<f32>,
    write_frame: usize,
    filter_l: f32,
    filter_r: f32,
}

impl SpatialFx {
    pub fn new(sample_rate: u32) -> Self {
        let delay_len = delay_capacity_frames(sample_rate);
        Self {
            sample_rate,
            settings: FxSettings::disabled(),
            delay_l: vec![0.0; delay_len],
            delay_r: vec![0.0; delay_len],
            write_frame: 0,
            filter_l: 0.0,
            filter_r: 0.0,
        }
    }

    pub fn reconfigure_sample_rate(&mut self, sample_rate: u32) {
        let settings = self.settings;
        *self = Self::new(sample_rate);
        self.settings = settings;
    }

    #[allow(clippy::too_many_arguments)]
    pub fn set(
        &mut self,
        enabled: bool,
        balance: f32,
        tempo: f32,
        damp: f32,
        filter_hz: f32,
        delay_ms: f32,
        size: f32,
        mix: f32,
        feedback: f32,
        width: f32,
    ) {
        self.settings = FxSettings {
            enabled,
            balance: balance.clamp(-1.0, 1.0),
            tempo: tempo.clamp(0.5, 2.0),
            damp: damp.clamp(0.0, 1.0),
            filter_hz: filter_hz.clamp(200.0, 18_000.0),
            delay_ms: delay_ms.clamp(MIN_DELAY_MS, MAX_DELAY_MS),
            size: size.clamp(0.0, 1.0),
            mix: mix.clamp(0.0, 1.0),
            feedback: feedback.clamp(0.0, 0.95),
            width: width.clamp(0.0, 2.0),
        };

        if !enabled {
            self.reset_state();
        }
    }

    pub fn process(&mut self, buf: &mut [f32], channels: usize) {
        if channels == 0 || !self.settings.enabled {
            return;
        }

        let stereo = channels > 1;
        let delay_len = self.delay_l.len();
        if delay_len < 2 {
            return;
        }

        let delay_frames = (((self.settings.delay_ms / self.settings.tempo) / 1000.0)
            * self.sample_rate as f32)
            .round()
            .clamp(1.0, (delay_len - 1) as f32) as usize;
        let spread_frames = ((delay_frames as f32 * (0.1 + self.settings.size * 0.35)).round()
            as usize)
            .clamp(1, delay_frames.max(1));
        let shorter_delay = delay_frames.saturating_sub(spread_frames).max(1);
        let filter_alpha = lowpass_alpha(self.settings.filter_hz, self.sample_rate);
        let crossfeed = 0.12 + (self.settings.size * 0.58);
        let feedback = self.settings.feedback * (1.0 - self.settings.damp * 0.25);

        for frame in buf.chunks_exact_mut(channels) {
            let dry_l = frame[0];
            let dry_r = if stereo { frame[1] } else { dry_l };

            let read_primary = wrap_sub(self.write_frame, delay_frames, delay_len);
            let read_secondary = wrap_sub(self.write_frame, shorter_delay, delay_len);

            let delayed_l = self.delay_l[read_primary];
            let delayed_r = self.delay_r[read_primary];
            let spread_l = self.delay_r[read_secondary];
            let spread_r = self.delay_l[read_secondary];

            let raw_wet_l = delayed_l + spread_l * crossfeed;
            let raw_wet_r = delayed_r + spread_r * crossfeed;

            self.filter_l += filter_alpha * (raw_wet_l - self.filter_l);
            self.filter_r += filter_alpha * (raw_wet_r - self.filter_r);

            let wet_l = raw_wet_l * (1.0 - self.settings.damp) + self.filter_l * self.settings.damp;
            let wet_r = raw_wet_r * (1.0 - self.settings.damp) + self.filter_r * self.settings.damp;

            self.delay_l[self.write_frame] =
                (dry_l + (wet_l + wet_r * crossfeed) * feedback).clamp(-1.5, 1.5);
            self.delay_r[self.write_frame] =
                (dry_r + (wet_r + wet_l * crossfeed) * feedback).clamp(-1.5, 1.5);
            self.write_frame += 1;
            if self.write_frame == delay_len {
                self.write_frame = 0;
            }

            let mut out_l = dry_l * (1.0 - self.settings.mix) + wet_l * self.settings.mix;
            let mut out_r = dry_r * (1.0 - self.settings.mix) + wet_r * self.settings.mix;

            if stereo {
                let mid = 0.5 * (out_l + out_r);
                let side = 0.5 * (out_l - out_r) * self.settings.width;
                out_l = mid + side;
                out_r = mid - side;
            }

            let (left_gain, right_gain) = balance_gains(self.settings.balance);
            out_l *= left_gain;
            out_r *= right_gain;

            frame[0] = out_l.clamp(-1.0, 1.0);
            if stereo {
                frame[1] = out_r.clamp(-1.0, 1.0);
            }
        }
    }

    fn reset_state(&mut self) {
        self.delay_l.fill(0.0);
        self.delay_r.fill(0.0);
        self.write_frame = 0;
        self.filter_l = 0.0;
        self.filter_r = 0.0;
    }
}

fn delay_capacity_frames(sample_rate: u32) -> usize {
    (((MAX_DELAY_MS / 1000.0) * sample_rate as f32).ceil() as usize).max(1) + 2
}

fn wrap_sub(index: usize, amount: usize, len: usize) -> usize {
    (index + len - (amount % len)) % len
}

fn lowpass_alpha(cutoff_hz: f32, sample_rate: u32) -> f32 {
    let cutoff = cutoff_hz.clamp(20.0, sample_rate as f32 * 0.45);
    let x = (-2.0 * PI * cutoff / sample_rate as f32).exp();
    1.0 - x
}

fn balance_gains(balance: f32) -> (f32, f32) {
    let clamped = balance.clamp(-1.0, 1.0);
    if clamped >= 0.0 {
        (1.0 - clamped, 1.0)
    } else {
        (1.0, 1.0 + clamped)
    }
}

#[cfg(test)]
mod tests {
    use super::SpatialFx;

    #[test]
    fn disabled_fx_leaves_buffer_unchanged() {
        let mut fx = SpatialFx::new(48_000);
        let mut buffer = [0.25f32, -0.25, 0.5, -0.5];
        let original = buffer;

        fx.process(&mut buffer, 2);

        assert_eq!(buffer, original);
    }

    #[test]
    fn enabled_fx_changes_stereo_signal() {
        let mut fx = SpatialFx::new(48_000);
        fx.set(true, 0.2, 1.0, 0.4, 5000.0, 30.0, 0.8, 0.7, 0.6, 1.5);

        let mut buffer = vec![0.0f32; 4096 * 2];
        buffer[0] = 1.0;

        fx.process(&mut buffer, 2);
        fx.process(&mut buffer, 2);

        assert!(buffer.iter().any(|sample| sample.abs() > 0.0001));
    }

    #[test]
    fn balance_reduces_left_channel_when_panned_right() {
        let mut fx = SpatialFx::new(48_000);
        fx.set(true, 1.0, 1.0, 0.0, 18_000.0, 10.0, 0.0, 0.0, 0.0, 1.0);

        let mut buffer = [0.8f32, 0.8f32];
        fx.process(&mut buffer, 2);

        assert!(buffer[0].abs() < 0.01);
        assert!(buffer[1] > 0.79);
    }
}
