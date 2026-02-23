//! Real-time sample rate conversion using rubato.
//!
//! All tracks are resampled to the system output sample rate (typically 48kHz)
//! to ensure seamless gapless playback between tracks with different rates.

use rubato::{FastFixedIn, PolynomialDegree, Resampler as RubatoResampler};

/// Default system output sample rate (48kHz is standard for modern audio)
pub const DEFAULT_OUTPUT_SAMPLE_RATE: u32 = 48000;

/// Wrapper around rubato's resampler for real-time audio conversion.
pub struct AudioResampler {
    resampler: FastFixedIn<f32>,
    input_rate: u32,
    output_rate: u32,
    channels: usize,
    /// Pre-allocated input buffers (one per channel)
    input_buffers: Vec<Vec<f32>>,
    /// Pre-allocated output buffers (one per channel)
    output_buffers: Vec<Vec<f32>>,
    /// Maximum frames we can process in one call
    max_input_frames: usize,
}

impl AudioResampler {
    /// Create a new resampler.
    ///
    /// # Arguments
    /// * `input_rate` - Sample rate of the input audio
    /// * `output_rate` - Desired output sample rate
    /// * `channels` - Number of audio channels
    /// * `chunk_size` - Processing chunk size (typically matches decoder output)
    pub fn new(
        input_rate: u32,
        output_rate: u32,
        channels: usize,
        chunk_size: usize,
    ) -> Result<Self, String> {
        if input_rate == output_rate {
            // No resampling needed - create a passthrough
            return Ok(Self {
                resampler: FastFixedIn::new(
                    1.0,
                    1.0,
                    PolynomialDegree::Linear,
                    chunk_size,
                    channels,
                )
                .map_err(|e| format!("Failed to create passthrough resampler: {}", e))?,
                input_rate,
                output_rate,
                channels,
                input_buffers: vec![vec![0.0; chunk_size]; channels],
                output_buffers: vec![vec![0.0; chunk_size]; channels],
                max_input_frames: chunk_size,
            });
        }

        let resample_ratio = output_rate as f64 / input_rate as f64;
        
        // Calculate output size based on ratio
        let max_output_frames = (chunk_size as f64 * resample_ratio * 1.1) as usize + 10;

        let resampler = FastFixedIn::new(
            resample_ratio,
            1.0, // No additional ratio adjustment
            PolynomialDegree::Septic, // High quality interpolation
            chunk_size,
            channels,
        )
        .map_err(|e| format!("Failed to create resampler: {}", e))?;

        Ok(Self {
            resampler,
            input_rate,
            output_rate,
            channels,
            input_buffers: vec![vec![0.0; chunk_size]; channels],
            output_buffers: vec![vec![0.0; max_output_frames]; channels],
            max_input_frames: chunk_size,
        })
    }

    /// Check if resampling is actually needed.
    #[inline]
    pub fn needs_resampling(&self) -> bool {
        self.input_rate != self.output_rate
    }

    /// Get the input sample rate.
    #[inline]
    pub fn input_rate(&self) -> u32 {
        self.input_rate
    }

    /// Get the output sample rate.
    #[inline]
    pub fn output_rate(&self) -> u32 {
        self.output_rate
    }

    /// Get the number of channels.
    #[inline]
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Process a chunk of interleaved audio samples.
    ///
    /// # Arguments
    /// * `input` - Interleaved input samples (e.g., [L, R, L, R, ...])
    /// * `output` - Pre-allocated output buffer for interleaved samples
    ///
    /// # Returns
    /// Number of output samples written (interleaved, so divide by channels for frames)
    pub fn process_interleaved(
        &mut self,
        input: &[f32],
        output: &mut [f32],
    ) -> Result<usize, String> {
        if !self.needs_resampling() {
            // Passthrough - just copy
            let copy_len = input.len().min(output.len());
            output[..copy_len].copy_from_slice(&input[..copy_len]);
            return Ok(copy_len);
        }

        let input_frames = input.len() / self.channels;
        
        if input_frames == 0 {
            return Ok(0);
        }

        // Deinterleave input into channel buffers
        for (frame_idx, chunk) in input.chunks_exact(self.channels).enumerate() {
            for (ch, &sample) in chunk.iter().enumerate() {
                if frame_idx < self.input_buffers[ch].len() {
                    self.input_buffers[ch][frame_idx] = sample;
                }
            }
        }

        // Truncate input buffers to actual size
        let input_refs: Vec<&[f32]> = self
            .input_buffers
            .iter()
            .map(|b| &b[..input_frames.min(self.max_input_frames)])
            .collect();

        // Perform resampling
        let (_, output_frames) = self
            .resampler
            .process_into_buffer(&input_refs, &mut self.output_buffers, None)
            .map_err(|e| format!("Resampling error: {}", e))?;

        // Interleave output
        let output_samples = output_frames * self.channels;
        if output_samples > output.len() {
            return Err(format!(
                "Output buffer too small: need {}, have {}",
                output_samples,
                output.len()
            ));
        }

        for frame_idx in 0..output_frames {
            for ch in 0..self.channels {
                output[frame_idx * self.channels + ch] = self.output_buffers[ch][frame_idx];
            }
        }

        Ok(output_samples)
    }

    /// Reset the resampler state (call between tracks).
    pub fn reset(&mut self) {
        self.resampler.reset();
    }

    /// Get the latency introduced by resampling in samples.
    pub fn latency_frames(&self) -> usize {
        if self.needs_resampling() {
            self.resampler.output_delay()
        } else {
            0
        }
    }
}

/// Helper to create a resampler that converts to the default output rate.
pub fn create_resampler_to_default(
    input_rate: u32,
    channels: usize,
    chunk_size: usize,
) -> Result<AudioResampler, String> {
    AudioResampler::new(input_rate, DEFAULT_OUTPUT_SAMPLE_RATE, channels, chunk_size)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_passthrough() {
        let mut resampler = AudioResampler::new(48000, 48000, 2, 1024).unwrap();
        assert!(!resampler.needs_resampling());

        let input: Vec<f32> = (0..200).map(|i| i as f32 / 200.0).collect();
        let mut output = vec![0.0; 200];

        let written = resampler.process_interleaved(&input, &mut output).unwrap();
        assert_eq!(written, 200);
        assert_eq!(input, output);
    }

    #[test]
    fn test_upsampling() {
        let resampler = AudioResampler::new(44100, 48000, 2, 1024).unwrap();
        assert!(resampler.needs_resampling());
    }
}
