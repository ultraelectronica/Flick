//! Core audio engine with cpal output and lock-free architecture.
//!
//! The engine manages the audio output stream, handles commands from Dart,
//! and coordinates decoding, resampling, and crossfading.

use crate::audio::commands::{AudioCommand, AudioEvent, PlaybackProgress, PlaybackState};
use crate::audio::crossfader::Crossfader;
use crate::audio::decoder::DecoderThread;
use crate::audio::resampler::DEFAULT_OUTPUT_SAMPLE_RATE;
use crate::audio::source::{AudioSource, SourceProvider};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleRate, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender};
use parking_lot::Mutex;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::Arc;
use std::thread;

/// Audio callback data shared between engine and audio thread.
///
/// This struct contains only lock-free or atomic data to ensure
/// the audio callback never blocks.
pub struct AudioCallbackData {
    /// Volume level (0.0 to 1.0)
    volume: std::sync::atomic::AtomicU32, // Using AtomicU32 for f32 bit pattern
    /// Playback speed (0.5 to 2.0)
    playback_speed: std::sync::atomic::AtomicU32, // Using AtomicU32 for f32 bit pattern
    /// Pause state
    paused: AtomicBool,
    /// Output channel count
    channels: usize,
    /// Crossfader state
    crossfader: Mutex<Crossfader>,
    /// Source provider (provides samples from current/next track)
    sources: Mutex<SourceProvider>,
    /// Pre-allocated mix buffer for crossfading
    mix_buffer_a: Mutex<Vec<f32>>,
    mix_buffer_b: Mutex<Vec<f32>>,
    /// Pre-allocated speed processing buffer
    speed_buffer: Mutex<Vec<f32>>,
    /// Fractional sample position for speed interpolation
    speed_frac_pos: Mutex<f64>,
    /// Channel for sending finished tracks to command thread
    finished_tracks: Sender<AudioSource>,
}

impl AudioCallbackData {
    pub fn new(sample_rate: u32, channels: usize, finished_tracks: Sender<AudioSource>) -> Self {
        // Pre-allocate mix buffers (enough for ~100ms of audio)
        let buffer_size = (sample_rate as usize / 10) * channels;
        // Speed buffer needs to be larger to handle 2x speed (need 2x input for 1x output)
        let speed_buffer_size = buffer_size * 3;

        Self {
            volume: std::sync::atomic::AtomicU32::new(1.0f32.to_bits()),
            playback_speed: std::sync::atomic::AtomicU32::new(1.0f32.to_bits()),
            paused: AtomicBool::new(false),
            channels,
            crossfader: Mutex::new(Crossfader::disabled(sample_rate)),
            sources: Mutex::new(SourceProvider::new(sample_rate, channels)),
            mix_buffer_a: Mutex::new(vec![0.0; buffer_size]),
            mix_buffer_b: Mutex::new(vec![0.0; buffer_size]),
            speed_buffer: Mutex::new(vec![0.0; speed_buffer_size]),
            speed_frac_pos: Mutex::new(0.0),
            finished_tracks,
        }
    }

    #[inline]
    pub fn channels(&self) -> usize {
        self.channels
    }

    #[inline]
    pub fn get_volume(&self) -> f32 {
        f32::from_bits(self.volume.load(Ordering::Relaxed))
    }

    #[inline]
    pub fn set_volume(&self, volume: f32) {
        self.volume.store(volume.to_bits(), Ordering::Relaxed);
    }

    #[inline]
    pub fn get_playback_speed(&self) -> f32 {
        f32::from_bits(self.playback_speed.load(Ordering::Relaxed))
    }

    #[inline]
    pub fn set_playback_speed(&self, speed: f32) {
        self.playback_speed.store(speed.clamp(0.5, 2.0).to_bits(), Ordering::Relaxed);
    }

    #[inline]
    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn set_paused(&self, paused: bool) {
        self.paused.store(paused, Ordering::Relaxed);
    }
}

/// Handle for controlling the audio engine from any thread.
/// 
/// This is the Send + Sync part that can be stored in a static.
pub struct AudioEngineHandle {
    /// Shared callback data
    callback_data: Arc<AudioCallbackData>,
    /// Command sender (to audio thread)
    command_tx: Sender<AudioCommand>,
    /// Event receiver (from audio processing)
    event_rx: Receiver<AudioEvent>,
    /// Current playback state
    state: Arc<AtomicU8>,
    /// Sample rate
    sample_rate: u32,
    /// Number of channels
    channels: usize,
    /// Active decoder threads (kept alive for the duration of playback)
    #[allow(dead_code)]
    decoders: Arc<Mutex<Vec<DecoderThread>>>,
    /// Shutdown flag
    shutdown: Arc<AtomicBool>,
}

// AudioEngineHandle is Send + Sync because it only contains Arc, channels, and atomics
unsafe impl Send for AudioEngineHandle {}
unsafe impl Sync for AudioEngineHandle {}

impl AudioEngineHandle {
    /// Send a command to the audio engine.
    pub fn send_command(&self, command: AudioCommand) -> Result<(), String> {
        self.command_tx
            .try_send(command)
            .map_err(|e| format!("Failed to send command: {}", e))
    }

    /// Play a track.
    pub fn play(&self, path: PathBuf) -> Result<(), String> {
        self.send_command(AudioCommand::Play { path })
    }

    /// Queue the next track for gapless playback.
    pub fn queue_next(&self, path: PathBuf) -> Result<(), String> {
        self.send_command(AudioCommand::QueueNext { path })
    }

    /// Pause playback.
    pub fn pause(&self) -> Result<(), String> {
        self.send_command(AudioCommand::Pause)
    }

    /// Resume playback.
    pub fn resume(&self) -> Result<(), String> {
        self.send_command(AudioCommand::Resume)
    }

    /// Stop playback.
    pub fn stop(&self) -> Result<(), String> {
        self.send_command(AudioCommand::Stop)
    }

    /// Seek to a position.
    pub fn seek(&self, position_secs: f64) -> Result<(), String> {
        self.send_command(AudioCommand::Seek { position_secs })
    }

    /// Set volume.
    pub fn set_volume(&self, volume: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetVolume { volume })
    }

    /// Configure crossfade.
    pub fn set_crossfade(&self, enabled: bool, duration_secs: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetCrossfade {
            enabled,
            duration_secs,
        })
    }

    /// Skip to next track with crossfade.
    pub fn skip_to_next(&self) -> Result<(), String> {
        self.send_command(AudioCommand::SkipToNext)
    }

    /// Set playback speed (0.5 to 2.0).
    pub fn set_playback_speed(&self, speed: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetPlaybackSpeed { speed })
    }

    /// Get the current playback speed.
    pub fn get_playback_speed(&self) -> f32 {
        self.callback_data.get_playback_speed()
    }

    /// Get the current playback state.
    pub fn state(&self) -> PlaybackState {
        match self.state.load(Ordering::Relaxed) {
            0 => PlaybackState::Idle,
            1 => PlaybackState::Playing,
            2 => PlaybackState::Paused,
            3 => PlaybackState::Buffering,
            4 => PlaybackState::Crossfading,
            5 => PlaybackState::Stopped,
            _ => PlaybackState::Idle,
        }
    }

    /// Get current progress.
    pub fn get_progress(&self) -> Option<PlaybackProgress> {
        let sources = self.callback_data.sources.lock();
        sources.current().map(|source| PlaybackProgress {
            position_secs: source.position_secs(),
            duration_secs: Some(source.info.duration_secs),
            buffer_level: source.buffer_level(),
        })
    }

    /// Get the current track path.
    pub fn get_current_path(&self) -> Option<PathBuf> {
        let sources = self.callback_data.sources.lock();
        sources.current().map(|source| source.info.path.clone())
    }

    /// Try to receive an event (non-blocking).
    pub fn try_recv_event(&self) -> Option<AudioEvent> {
        self.event_rx.try_recv().ok()
    }

    /// Get sample rate.
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Get number of channels.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Shutdown the engine.
    pub fn shutdown(&self) -> Result<(), String> {
        self.shutdown.store(true, Ordering::Release);
        self.send_command(AudioCommand::Shutdown)
    }
}

/// Initialize the audio engine and return a handle.
/// 
/// The actual cpal stream runs in a dedicated thread.
pub fn create_audio_engine() -> Result<AudioEngineHandle, String> {
    // Get the default audio device
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or("No default output device")?;

    // Get default config
    let default_config = device
        .default_output_config()
        .map_err(|e| format!("Failed to get default config: {}", e))?;

    let sample_rate = default_config.sample_rate().0;
    let channels = default_config.channels() as usize;

    // Prefer our default sample rate if supported
    let target_sample_rate = if sample_rate == DEFAULT_OUTPUT_SAMPLE_RATE {
        sample_rate
    } else {
        DEFAULT_OUTPUT_SAMPLE_RATE
    };

    let config = StreamConfig {
        channels: channels as u16,
        sample_rate: SampleRate(target_sample_rate),
        buffer_size: cpal::BufferSize::Default,
    };

    // Create finished tracks channel (from audio callback to command thread)
    let (finished_tx, finished_rx) = bounded::<AudioSource>(32);

    // Create shared data
    let callback_data = Arc::new(AudioCallbackData::new(target_sample_rate, channels, finished_tx));
    let callback_data_clone = Arc::clone(&callback_data);

    // Create event channel
    let (event_tx, event_rx) = bounded::<AudioEvent>(256);
    let event_tx_clone = event_tx.clone();

    // Create command channel
    let (command_tx, command_rx) = bounded::<AudioCommand>(64);

    // State
    let state = Arc::new(AtomicU8::new(PlaybackState::Idle as u8));
    let state_clone = Arc::clone(&state);

    // Decoders
    let decoders = Arc::new(Mutex::new(Vec::<DecoderThread>::new()));
    let decoders_clone = Arc::clone(&decoders);

    // Shutdown flag
    let shutdown = Arc::new(AtomicBool::new(false));
    let shutdown_clone = Arc::clone(&shutdown);

    // Callback data for command thread
    let callback_data_for_thread = Arc::clone(&callback_data);

    // Spawn the audio thread (which owns the cpal stream)
    thread::Builder::new()
        .name("audio-engine".to_string())
        .spawn(move || {
            // Build the stream in this thread
            let stream = match device.build_output_stream(
                &config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    audio_callback(data, &callback_data_clone, &event_tx_clone);
                },
                |err| {
                    eprintln!("Audio stream error: {}", err);
                },
                None,
            ) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("Failed to build audio stream: {}", e);
                    return;
                }
            };

            // Start the stream
            if let Err(e) = stream.play() {
                eprintln!("Failed to start audio stream: {}", e);
                return;
            }

            // Run command processing loop
            command_processing_loop(
                command_rx,
                finished_rx,
                event_tx,
                callback_data_for_thread,
                state_clone,
                decoders_clone,
                target_sample_rate,
                shutdown_clone,
            );

            // Stream will be dropped here when the loop exits
        })
        .map_err(|e| format!("Failed to spawn audio thread: {}", e))?;

    Ok(AudioEngineHandle {
        callback_data,
        command_tx,
        event_rx,
        state,
        sample_rate: target_sample_rate,
        channels,
        decoders,
        shutdown,
    })
}

/// The real-time audio callback.
///
/// This function MUST NOT:
/// - Allocate memory
/// - Block on mutexes (we use try_lock where possible)
/// - Perform I/O
#[inline]
fn audio_callback(
    output: &mut [f32],
    data: &AudioCallbackData,
    _event_tx: &Sender<AudioEvent>,
) {
    // Check if paused
    if data.is_paused() {
        output.fill(0.0);
        return;
    }

    // Get volume and speed
    let volume = data.get_volume();
    let speed = data.get_playback_speed();
    let channels = data.channels();

    // Try to lock sources (non-blocking)
    let mut sources = match data.sources.try_lock() {
        Some(s) => s,
        None => {
            output.fill(0.0);
            return;
        }
    };

    // Try to lock crossfader
    let mut crossfader = match data.crossfader.try_lock() {
        Some(c) => c,
        None => {
            // Couldn't get lock - just read from current source without speed processing
            let (read, old_source) = sources.read(output);
            
            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }
            
            if read < output.len() {
                output[read..].fill(0.0);
            }
            for sample in output.iter_mut() {
                *sample *= volume;
            }
            return;
        }
    };

    // Handle crossfading
    if crossfader.is_active() && sources.next_mut().is_some() {
        // Get mix buffers
        let mut buf_a = match data.mix_buffer_a.try_lock() {
            Some(b) => b,
            None => {
                output.fill(0.0);
                return;
            }
        };
        let mut buf_b = match data.mix_buffer_b.try_lock() {
            Some(b) => b,
            None => {
                output.fill(0.0);
                return;
            }
        };

        let needed = output.len();
        if buf_a.len() < needed {
            output.fill(0.0);
            return;
        }

        // Read from both sources
        let read_a = sources.current_mut().map(|s| s.read(&mut buf_a[..needed])).unwrap_or(0);
        let read_b = sources.next_mut().map(|s| s.read(&mut buf_b[..needed])).unwrap_or(0);

        if read_a < needed {
            buf_a[read_a..needed].fill(0.0);
        }
        if read_b < needed {
            buf_b[read_b..needed].fill(0.0);
        }

        // Mix with crossfade
        let _ = crossfader.mix(&buf_a[..needed], &buf_b[..needed], output, channels);

        if !crossfader.is_active() {
            drop(crossfader);
            if let Some(source) = sources.advance_to_next() {
                let _ = data.finished_tracks.try_send(source);
            }
        }
    } else {
        // Normal playback - apply speed processing if needed
        if (speed - 1.0).abs() < 0.001 {
            // Speed is 1.0 - direct read
            let (read, old_source) = sources.read(output);
            
            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }

            if read < output.len() {
                output[read..].fill(0.0);
            }
        } else {
            // Speed processing with linear interpolation
            let mut speed_buf = match data.speed_buffer.try_lock() {
                Some(b) => b,
                None => {
                    output.fill(0.0);
                    return;
                }
            };
            let mut frac_pos = match data.speed_frac_pos.try_lock() {
                Some(p) => p,
                None => {
                    output.fill(0.0);
                    return;
                }
            };

            let output_frames = output.len() / channels;
            // Calculate how many input samples we need
            let input_samples_needed = ((output_frames as f64 * speed as f64) + 2.0) as usize * channels;
            
            if speed_buf.len() < input_samples_needed {
                output.fill(0.0);
                return;
            }

            // Read source samples
            let (read, old_source) = sources.read(&mut speed_buf[..input_samples_needed]);
            
            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }

            if read < channels {
                output.fill(0.0);
                return;
            }

            let input_frames = read / channels;

            // Linear interpolation for speed change
            for out_frame in 0..output_frames {
                let in_pos = *frac_pos;
                let in_frame = in_pos as usize;
                let frac = (in_pos - in_frame as f64) as f32;

                if in_frame + 1 >= input_frames {
                    // Not enough input - fill with silence
                    for ch in 0..channels {
                        output[out_frame * channels + ch] = 0.0;
                    }
                } else {
                    // Linear interpolation between frames
                    for ch in 0..channels {
                        let s0 = speed_buf[in_frame * channels + ch];
                        let s1 = speed_buf[(in_frame + 1) * channels + ch];
                        output[out_frame * channels + ch] = s0 + (s1 - s0) * frac;
                    }
                }

                *frac_pos += speed as f64;
            }

            // Keep fractional part for next callback
            let consumed_frames = (*frac_pos) as usize;
            *frac_pos -= consumed_frames as f64;
        }
    }

    // Apply volume
    for sample in output.iter_mut() {
        *sample *= volume;
    }
}

/// Command processing loop running in the audio thread.
fn command_processing_loop(
    command_rx: Receiver<AudioCommand>,
    finished_rx: Receiver<AudioSource>,
    event_tx: Sender<AudioEvent>,
    callback_data: Arc<AudioCallbackData>,
    state: Arc<AtomicU8>,
    decoders: Arc<Mutex<Vec<DecoderThread>>>,
    sample_rate: u32,
    shutdown: Arc<AtomicBool>,
) {
    loop {
        // Check shutdown flag
        if shutdown.load(Ordering::Acquire) {
            break;
        }

        // Check for finished tracks
        while let Ok(source) = finished_rx.try_recv() {
            let path = source.info.path.to_string_lossy().to_string();
            let _ = event_tx.try_send(AudioEvent::TrackEnded { path });
        }

        match command_rx.recv_timeout(std::time::Duration::from_millis(50)) {
            Ok(command) => {
                match command {
                    AudioCommand::Play { path } => {
                        handle_play(
                            path,
                            &callback_data,
                            &state,
                            &decoders,
                            &event_tx,
                            sample_rate,
                        );
                    }
                    AudioCommand::QueueNext { path } => {
                        handle_queue_next(
                            path,
                            &callback_data,
                            &decoders,
                            &event_tx,
                            sample_rate,
                        );
                    }
                    AudioCommand::Pause => {
                        callback_data.set_paused(true);
                        state.store(PlaybackState::Paused as u8, Ordering::Relaxed);
                        let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Paused));
                    }
                    AudioCommand::Resume => {
                        callback_data.set_paused(false);
                        state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
                        let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Playing));
                    }
                    AudioCommand::Stop => {
                        callback_data.sources.lock().stop();
                        callback_data.crossfader.lock().reset();
                        state.store(PlaybackState::Stopped as u8, Ordering::Relaxed);
                        let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Stopped));
                    }
                    AudioCommand::Seek { position_secs: _ } => {
                        // Seeking requires restarting the decoder - complex to implement
                        let _ = event_tx.try_send(AudioEvent::Error {
                            message: "Seek not yet implemented".to_string(),
                        });
                    }
                    AudioCommand::SetVolume { volume } => {
                        callback_data.set_volume(volume.clamp(0.0, 1.0));
                    }
                    AudioCommand::SetCrossfade { enabled, duration_secs } => {
                        let mut crossfader = callback_data.crossfader.lock();
                        crossfader.set_enabled(enabled);
                        crossfader.set_duration(duration_secs);
                    }
                    AudioCommand::SetPlaybackSpeed { speed } => {
                        callback_data.set_playback_speed(speed);
                        // Reset fractional position when speed changes
                        *callback_data.speed_frac_pos.lock() = 0.0;
                    }
                    AudioCommand::CrossfadeToNext | AudioCommand::SkipToNext => {
                        handle_skip_to_next(&callback_data, &state, &event_tx);
                    }
                    AudioCommand::Shutdown => {
                        // Stop everything and exit
                        callback_data.sources.lock().stop();
                        for decoder in decoders.lock().drain(..) {
                            decoder.stop();
                        }
                        break;
                    }
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                // No command - continue loop
            }
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                // Channel closed - exit
                break;
            }
        }

        // Clean up finished decoders
        decoders.lock().retain(|d| d.is_running());
    }
}

fn handle_play(
    path: PathBuf,
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    decoders: &Arc<Mutex<Vec<DecoderThread>>>,
    event_tx: &Sender<AudioEvent>,
    sample_rate: u32,
) {
    // Set buffering state
    state.store(PlaybackState::Buffering as u8, Ordering::Relaxed);
    let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Buffering));

    // Stop current playback
    callback_data.sources.lock().stop();
    callback_data.crossfader.lock().reset();

    // Spawn decoder
    match DecoderThread::spawn(path.clone(), sample_rate) {
        Ok((mut source, decoder_thread)) => {
            // Wait for initial buffering
            let mut attempts = 0;
            while !source.has_enough_buffer() && attempts < 100 {
                std::thread::sleep(std::time::Duration::from_millis(10));
                attempts += 1;
            }

            source.set_ready();
            source.set_playing();

            // Set the source
            callback_data.sources.lock().set_current(source);
            callback_data.set_paused(false);

            // Store decoder
            decoders.lock().push(decoder_thread);

            // Update state
            state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
            let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Playing));
        }
        Err(e) => {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Failed to decode {}: {}", path.display(), e),
            });
            state.store(PlaybackState::Idle as u8, Ordering::Relaxed);
        }
    }
}

fn handle_queue_next(
    path: PathBuf,
    callback_data: &AudioCallbackData,
    decoders: &Arc<Mutex<Vec<DecoderThread>>>,
    event_tx: &Sender<AudioEvent>,
    sample_rate: u32,
) {
    // Spawn decoder for next track
    match DecoderThread::spawn(path.clone(), sample_rate) {
        Ok((mut source, decoder_thread)) => {
            // Wait for initial buffering
            let mut attempts = 0;
            while !source.has_enough_buffer() && attempts < 100 {
                std::thread::sleep(std::time::Duration::from_millis(10));
                attempts += 1;
            }

            source.set_ready();

            // Queue the source
            callback_data.sources.lock().queue_next(source);

            // Store decoder
            decoders.lock().push(decoder_thread);

            let _ = event_tx.try_send(AudioEvent::NextTrackReady {
                path: path.to_string_lossy().to_string(),
            });
        }
        Err(e) => {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Failed to decode next track {}: {}", path.display(), e),
            });
        }
    }
}

fn handle_skip_to_next(
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    event_tx: &Sender<AudioEvent>,
) {
    let mut sources = callback_data.sources.lock();
    let mut crossfader = callback_data.crossfader.lock();

    if sources.has_next() {
        if crossfader.is_enabled() {
            // Start crossfade
            crossfader.start();
            state.store(PlaybackState::Crossfading as u8, Ordering::Relaxed);
            let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Crossfading));
        } else {
            // Immediate transition
            sources.advance_to_next();
            state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
        }
    }
}
