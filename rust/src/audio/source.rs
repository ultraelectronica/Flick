//! Audio source abstraction for gapless playback.
//!
//! The source provider manages multiple audio sources and handles
//! seamless transitions between them.

use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::HeapRb;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

/// Size of the sample ring buffer per source (in samples, not frames)
/// 48000 samples/sec * 2 channels * 5 seconds = 480,000 samples
pub const SOURCE_BUFFER_SIZE: usize = 480_000;

/// Metadata about an audio source.
#[derive(Debug, Clone)]
pub struct SourceInfo {
    /// Path to the audio file
    pub path: PathBuf,
    /// Sample rate of the source (before resampling)
    pub original_sample_rate: u32,
    /// Output sample rate (after resampling)
    pub output_sample_rate: u32,
    /// Number of channels
    pub channels: usize,
    /// Total duration in samples (after resampling to output rate)
    pub total_samples: u64,
    /// Total duration in seconds
    pub duration_secs: f64,
}

/// State of an audio source.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceState {
    /// Source is being loaded/decoded
    Loading,
    /// Source is ready for playback
    Ready,
    /// Source is currently playing
    Playing,
    /// Source has finished (all samples consumed)
    Finished,
    /// Source encountered an error
    Error,
}

/// An audio source that provides samples from a ring buffer.
///
/// This is the consumer side - samples are produced by the decoder thread
/// and consumed by the audio callback.
pub struct AudioSource {
    /// Source metadata
    pub info: SourceInfo,
    /// Current state
    state: SourceState,
    /// Ring buffer consumer (receives samples from decoder)
    consumer: ringbuf::HeapCons<f32>,
    /// Flag indicating decoder has finished writing all samples
    decoder_finished: Arc<AtomicBool>,
    /// Current playback position in samples
    position: Arc<AtomicU64>,
    /// Flag to signal the decoder to stop
    stop_signal: Arc<AtomicBool>,
}

/// Handle given to the decoder thread to write samples.
pub struct SourceProducer {
    /// Ring buffer producer
    producer: ringbuf::HeapProd<f32>,
    /// Flag to set when decoding is complete
    decoder_finished: Arc<AtomicBool>,
    /// Position tracker (shared with consumer, for future seek support)
    #[allow(dead_code)]
    position: Arc<AtomicU64>,
    /// Stop signal from consumer
    stop_signal: Arc<AtomicBool>,
    /// Total samples written
    samples_written: u64,
}

impl AudioSource {
    /// Create a new audio source with its producer.
    ///
    /// Returns the source (for the audio thread) and producer (for the decoder thread).
    pub fn new(info: SourceInfo) -> (Self, SourceProducer) {
        let ring = HeapRb::<f32>::new(SOURCE_BUFFER_SIZE);
        let (producer, consumer) = ring.split();

        let decoder_finished = Arc::new(AtomicBool::new(false));
        let position = Arc::new(AtomicU64::new(0));
        let stop_signal = Arc::new(AtomicBool::new(false));

        let source = AudioSource {
            info,
            state: SourceState::Loading,
            consumer,
            decoder_finished: Arc::clone(&decoder_finished),
            position: Arc::clone(&position),
            stop_signal: Arc::clone(&stop_signal),
        };

        let producer = SourceProducer {
            producer,
            decoder_finished,
            position,
            stop_signal,
            samples_written: 0,
        };

        (source, producer)
    }

    /// Get the current state.
    #[inline]
    pub fn state(&self) -> SourceState {
        self.state
    }

    /// Set the state to ready (called when enough samples are buffered).
    pub fn set_ready(&mut self) {
        if self.state == SourceState::Loading {
            self.state = SourceState::Ready;
        }
    }

    /// Set the state to playing.
    pub fn set_playing(&mut self) {
        self.state = SourceState::Playing;
    }

    /// Check if the source has finished (all samples consumed and decoder done).
    pub fn is_finished(&self) -> bool {
        self.state == SourceState::Finished
            || (self.decoder_finished.load(Ordering::Acquire) && self.consumer.is_empty())
    }

    /// Get the current playback position in samples.
    #[inline]
    pub fn position_samples(&self) -> u64 {
        self.position.load(Ordering::Relaxed)
    }

    /// Get the current playback position in seconds.
    #[inline]
    pub fn position_secs(&self) -> f64 {
        // Position is in samples (interleaved) at the output sample rate, so divide by channels
        let samples = self.position_samples();
        let frames = samples / self.info.channels as u64;
        frames as f64 / self.info.output_sample_rate as f64
    }

    /// Get the buffer fill level (0.0 to 1.0).
    #[inline]
    pub fn buffer_level(&self) -> f32 {
        self.consumer.occupied_len() as f32 / SOURCE_BUFFER_SIZE as f32
    }

    /// Check if there are enough samples buffered for playback.
    #[inline]
    pub fn has_enough_buffer(&self) -> bool {
        // Need at least 0.5 seconds of audio buffered (at output sample rate)
        let min_samples = (self.info.output_sample_rate as usize / 2) * self.info.channels;
        self.consumer.occupied_len() >= min_samples || self.decoder_finished.load(Ordering::Acquire)
    }

    /// Read samples from the buffer into the output.
    ///
    /// This is the main function called by the audio callback.
    /// It's designed to be real-time safe (no allocations, no blocking).
    ///
    /// # Returns
    /// Number of samples actually read.
    #[inline]
    pub fn read(&mut self, output: &mut [f32]) -> usize {
        let read = self.consumer.pop_slice(output);
        
        if read > 0 {
            self.position.fetch_add(read as u64, Ordering::Relaxed);
        }

        // Check if we've finished
        if self.decoder_finished.load(Ordering::Acquire) && self.consumer.is_empty() {
            self.state = SourceState::Finished;
        }

        read
    }

    /// Signal the decoder to stop (used when skipping tracks).
    pub fn signal_stop(&self) {
        self.stop_signal.store(true, Ordering::Release);
    }

    /// Get remaining duration in seconds.
    pub fn remaining_secs(&self) -> f64 {
        let remaining_samples = self.info.total_samples.saturating_sub(self.position_samples());
        let remaining_frames = remaining_samples / self.info.channels as u64;
        remaining_frames as f64 / self.info.output_sample_rate as f64
    }
}

impl SourceProducer {
    /// Write samples to the ring buffer.
    ///
    /// # Returns
    /// Number of samples actually written (may be less than input if buffer is full).
    pub fn write(&mut self, samples: &[f32]) -> usize {
        let written = self.producer.push_slice(samples);
        self.samples_written += written as u64;
        written
    }

    /// Check if the stop signal has been set.
    #[inline]
    pub fn should_stop(&self) -> bool {
        self.stop_signal.load(Ordering::Acquire)
    }

    /// Get the available space in the ring buffer.
    #[inline]
    pub fn available_space(&self) -> usize {
        self.producer.vacant_len()
    }

    /// Check if there's enough space to write a chunk.
    #[inline]
    pub fn can_write(&self, size: usize) -> bool {
        self.producer.vacant_len() >= size
    }

    /// Mark the source as fully decoded.
    pub fn finish(&self) {
        self.decoder_finished.store(true, Ordering::Release);
    }

    /// Get total samples written so far.
    pub fn samples_written(&self) -> u64 {
        self.samples_written
    }

    /// Wait for space in the buffer (with timeout).
    ///
    /// This is NOT real-time safe and should only be used in the decoder thread.
    pub fn wait_for_space(&self, min_space: usize, timeout_ms: u64) -> bool {
        use std::thread::sleep;
        use std::time::{Duration, Instant};

        let start = Instant::now();
        let timeout = Duration::from_millis(timeout_ms);

        while self.producer.vacant_len() < min_space {
            if self.should_stop() {
                return false;
            }
            if start.elapsed() > timeout {
                return false;
            }
            sleep(Duration::from_millis(1));
        }
        true
    }
}

/// Source provider manages multiple sources for gapless playback.
pub struct SourceProvider {
    /// Currently playing source
    current: Option<AudioSource>,
    /// Next source queued for gapless playback
    next: Option<AudioSource>,
    /// Output sample rate (for future use in resampling validation)
    #[allow(dead_code)]
    output_sample_rate: u32,
    /// Number of output channels (for future use in channel validation)
    #[allow(dead_code)]
    output_channels: usize,
}

impl SourceProvider {
    /// Create a new source provider.
    pub fn new(output_sample_rate: u32, output_channels: usize) -> Self {
        Self {
            current: None,
            next: None,
            output_sample_rate,
            output_channels,
        }
    }

    /// Set the current source.
    pub fn set_current(&mut self, source: AudioSource) {
        // Stop the old source if any
        if let Some(ref old) = self.current {
            old.signal_stop();
        }
        self.current = Some(source);
    }

    /// Queue the next source for gapless playback.
    pub fn queue_next(&mut self, source: AudioSource) {
        // Stop any previously queued next source
        if let Some(ref old) = self.next {
            old.signal_stop();
        }
        self.next = Some(source);
    }

    /// Check if a next source is queued.
    pub fn has_next(&self) -> bool {
        self.next.is_some()
    }

    /// Get a reference to the current source.
    pub fn current(&self) -> Option<&AudioSource> {
        self.current.as_ref()
    }

    /// Get a mutable reference to the current source.
    pub fn current_mut(&mut self) -> Option<&mut AudioSource> {
        self.current.as_mut()
    }

    /// Get a mutable reference to the next source.
    pub fn next_mut(&mut self) -> Option<&mut AudioSource> {
        self.next.as_mut()
    }

    /// Transition to the next track (used for gapless playback).
    ///
    /// Returns the old source if there was one.
    pub fn advance_to_next(&mut self) -> Option<AudioSource> {
        let old = self.current.take();
        if let Some(ref old_source) = old {
            old_source.signal_stop();
        }
        self.current = self.next.take();
        old
    }

    /// Stop all playback.
    pub fn stop(&mut self) {
        if let Some(ref source) = self.current {
            source.signal_stop();
        }
        if let Some(ref source) = self.next {
            source.signal_stop();
        }
        self.current = None;
        self.next = None;
    }

    /// Read samples from the current source.
    ///
    /// Handles gapless transition if current source ends.
    ///
    /// # Returns
    /// * Number of samples read
    /// * Whether a track transition occurred
    #[inline]
    pub fn read(&mut self, output: &mut [f32]) -> (usize, Option<AudioSource>) {
        if self.current.is_none() {
            // No source - fill with silence
            output.fill(0.0);
            return (0, None);
        }

        // Borrow scope for playing current
        let (read, finished) = {
            let current = self.current.as_mut().unwrap();
            let read = current.read(output);
            (read, read < output.len() && current.is_finished())
        };

        // If we didn't get enough samples and source is finished, transition
        if finished {
            // Fill remaining with silence or next track
            if self.next.is_some() {
                // Gapless transition!
                // Swap current with next, keeping the old current to return
                let old_source = self.current.replace(self.next.take().unwrap());
                
                let remaining = &mut output[read..];
                // Read from new current (which was next)
                let next_read = self.current.as_mut().unwrap().read(remaining);
                
                return (read + next_read, old_source);
            } else {
                // No next track - fill with silence
                output[read..].fill(0.0);
            }
        }

        (read, None)
    }

    /// Check if the current track is near the end (for triggering look-ahead).
    pub fn should_load_next(&self, lookahead_secs: f64) -> bool {
        if self.next.is_some() {
            return false; // Already have next queued
        }
        
        if let Some(ref current) = self.current {
            current.remaining_secs() < lookahead_secs
        } else {
            false
        }
    }
}
