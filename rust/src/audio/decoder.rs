//! Background audio decoder using symphonia.
//!
//! Decoding happens in a separate thread to avoid blocking the audio callback.
//! Decoded samples are written to a ring buffer for consumption by the audio thread.

use crate::audio::resampler::{AudioResampler, DEFAULT_OUTPUT_SAMPLE_RATE};
use crate::audio::source::{AudioSource, SourceInfo, SourceProducer};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

use symphonia::core::audio::{AudioBufferRef, Signal};
use symphonia::core::codecs::{Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::core::units::Time;

/// Default chunk size for decoding (in frames)
const DECODE_CHUNK_SIZE: usize = 4096;

/// Errors that can occur during decoding.
#[derive(Debug)]
pub enum DecoderError {
    IoError(std::io::Error),
    UnsupportedFormat(String),
    NoAudioTrack,
    DecodingFailed(String),
    ResamplingFailed(String),
}

impl std::fmt::Display for DecoderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IoError(e) => write!(f, "I/O error: {}", e),
            Self::UnsupportedFormat(s) => write!(f, "Unsupported format: {}", s),
            Self::NoAudioTrack => write!(f, "No audio track found"),
            Self::DecodingFailed(s) => write!(f, "Decoding failed: {}", s),
            Self::ResamplingFailed(s) => write!(f, "Resampling failed: {}", s),
        }
    }
}

impl From<std::io::Error> for DecoderError {
    fn from(e: std::io::Error) -> Self {
        Self::IoError(e)
    }
}

/// Result of probing an audio file.
pub struct ProbeResult {
    pub source_info: SourceInfo,
    pub format: Box<dyn FormatReader>,
    pub decoder: Box<dyn Decoder>,
    pub track_id: u32,
}

/// Probe an audio file to get its metadata and prepare for decoding.
pub fn probe_file(path: &Path) -> Result<ProbeResult, DecoderError> {
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let format_opts = FormatOptions {
        enable_gapless: true,
        ..Default::default()
    };
    let metadata_opts = MetadataOptions::default();

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &format_opts, &metadata_opts)
        .map_err(|e| DecoderError::UnsupportedFormat(e.to_string()))?;

    let format = probed.format;

    // Find the first audio track
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or(DecoderError::NoAudioTrack)?;

    let track_id = track.id;
    let codec_params = &track.codec_params;

    let sample_rate = codec_params.sample_rate.unwrap_or(44100);
    let channels = codec_params
        .channels
        .map(|c| c.count())
        .unwrap_or(2);

    // Calculate duration
    let duration_secs = if let Some(n_frames) = codec_params.n_frames {
        n_frames as f64 / sample_rate as f64
    } else if let Some(time_base) = codec_params.time_base {
        if let Some(dur) = codec_params.n_frames {
            time_base.calc_time(dur).seconds as f64
        } else {
            0.0
        }
    } else {
        0.0
    };

    // Total samples at output sample rate
    let total_samples = (duration_secs * DEFAULT_OUTPUT_SAMPLE_RATE as f64 * channels as f64) as u64;

    let decoder_opts = DecoderOptions::default();
    let decoder = symphonia::default::get_codecs()
        .make(&codec_params, &decoder_opts)
        .map_err(|e| DecoderError::UnsupportedFormat(e.to_string()))?;

    let source_info = SourceInfo {
        path: path.to_path_buf(),
        original_sample_rate: sample_rate,
        output_sample_rate: DEFAULT_OUTPUT_SAMPLE_RATE,
        channels,
        total_samples,
        duration_secs,
    };

    Ok(ProbeResult {
        source_info,
        format,
        decoder,
        track_id,
    })
}

/// Decoder thread handle.
pub struct DecoderThread {
    handle: Option<JoinHandle<Result<(), DecoderError>>>,
    stop_signal: Arc<AtomicBool>,
}

impl DecoderThread {
    /// Spawn a new decoder thread for the given file.
    ///
    /// Returns the audio source (for the audio thread) and the decoder thread handle.
    pub fn spawn(path: PathBuf, output_sample_rate: u32) -> Result<(AudioSource, Self), DecoderError> {
        // Probe the file first (on the calling thread)
        let probe_result = probe_file(&path)?;
        let source_info = probe_result.source_info.clone();

        // Create the source and producer
        let (source, producer) = AudioSource::new(source_info);
        let stop_signal = Arc::new(AtomicBool::new(false));
        let stop_signal_clone = Arc::clone(&stop_signal);

        // Spawn the decoder thread
        let handle = thread::Builder::new()
            .name(format!("decoder-{}", path.display()))
            .spawn(move || {
                decode_thread(probe_result, producer, output_sample_rate, stop_signal_clone)
            })
            .map_err(|e| DecoderError::IoError(e.into()))?;

        Ok((
            source,
            Self {
                handle: Some(handle),
                stop_signal,
            },
        ))
    }

    /// Signal the decoder to stop.
    pub fn stop(&self) {
        self.stop_signal.store(true, Ordering::Release);
    }

    /// Wait for the decoder thread to finish.
    pub fn join(mut self) -> Result<(), DecoderError> {
        if let Some(handle) = self.handle.take() {
            handle
                .join()
                .map_err(|_| DecoderError::DecodingFailed("Thread panicked".to_string()))?
        } else {
            Ok(())
        }
    }

    /// Check if the decoder is still running.
    pub fn is_running(&self) -> bool {
        self.handle
            .as_ref()
            .map(|h| !h.is_finished())
            .unwrap_or(false)
    }
}

impl Drop for DecoderThread {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The main decoder loop running in a background thread.
fn decode_thread(
    probe_result: ProbeResult,
    mut producer: SourceProducer,
    output_sample_rate: u32,
    stop_signal: Arc<AtomicBool>,
) -> Result<(), DecoderError> {
    let ProbeResult {
        source_info,
        mut format,
        mut decoder,
        track_id,
    } = probe_result;

    // Create resampler if needed
    let needs_resampling = source_info.original_sample_rate != output_sample_rate;
    let mut resampler = if needs_resampling {
        Some(
            AudioResampler::new(
                source_info.original_sample_rate,
                output_sample_rate,
                source_info.channels,
                DECODE_CHUNK_SIZE,
            )
            .map_err(DecoderError::ResamplingFailed)?,
        )
    } else {
        None
    };

    // Pre-allocated buffers (avoid allocations in the loop)
    let mut decode_buffer: Vec<f32> = Vec::with_capacity(DECODE_CHUNK_SIZE * source_info.channels * 2);
    let mut resample_buffer: Vec<f32> = Vec::with_capacity(
        (DECODE_CHUNK_SIZE as f64 * output_sample_rate as f64 / source_info.original_sample_rate as f64 * 1.2) as usize
            * source_info.channels
            + 256,
    );

    // Decode loop
    loop {
        // Check stop signal
        if stop_signal.load(Ordering::Acquire) || producer.should_stop() {
            break;
        }

        // Get the next packet
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(ref e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                // End of stream
                break;
            }
            Err(SymphoniaError::ResetRequired) => {
                // Reset decoder for gapless playback
                decoder.reset();
                continue;
            }
            Err(e) => {
                return Err(DecoderError::DecodingFailed(e.to_string()));
            }
        };

        // Skip packets from other tracks
        if packet.track_id() != track_id {
            continue;
        }

        // Decode the packet
        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(SymphoniaError::DecodeError(e)) => {
                // Skip corrupted frames
                eprintln!("Decode error (skipping frame): {}", e);
                continue;
            }
            Err(e) => {
                return Err(DecoderError::DecodingFailed(e.to_string()));
            }
        };

        // Convert to interleaved f32
        decode_buffer.clear();
        convert_to_interleaved_f32(&decoded, &mut decode_buffer);

        // Resample if needed
        let output_samples = if let Some(ref mut resampler) = resampler {
            resample_buffer.clear();
            resample_buffer.resize(
                (decode_buffer.len() as f64 * output_sample_rate as f64 / source_info.original_sample_rate as f64 * 1.2) as usize + 256,
                0.0,
            );

            let written = resampler
                .process_interleaved(&decode_buffer, &mut resample_buffer)
                .map_err(DecoderError::ResamplingFailed)?;

            &resample_buffer[..written]
        } else {
            &decode_buffer[..]
        };

        // Write to ring buffer, waiting if necessary
        let mut offset = 0;
        while offset < output_samples.len() {
            if stop_signal.load(Ordering::Acquire) || producer.should_stop() {
                break;
            }

            let chunk = &output_samples[offset..];
            let written = producer.write(chunk);
            offset += written;

            if written == 0 {
                // Buffer full - wait a bit
                if !producer.wait_for_space(chunk.len().min(1024), 100) {
                    // Timeout or stop signal
                    break;
                }
            }
        }
    }

    // Mark decoding as complete
    producer.finish();

    Ok(())
}

/// Convert an AudioBufferRef to interleaved f32 samples.
fn convert_to_interleaved_f32(buffer: &AudioBufferRef, output: &mut Vec<f32>) {
    match buffer {
        AudioBufferRef::F32(buf) => {
            let channels = buf.spec().channels.count();
            let frames = buf.frames();
            output.reserve(frames * channels);

            for frame in 0..frames {
                for ch in 0..channels {
                    output.push(buf.chan(ch)[frame]);
                }
            }
        }
        AudioBufferRef::S16(buf) => {
            let channels = buf.spec().channels.count();
            let frames = buf.frames();
            output.reserve(frames * channels);

            for frame in 0..frames {
                for ch in 0..channels {
                    // Convert i16 to f32 (-1.0 to 1.0)
                    output.push(buf.chan(ch)[frame] as f32 / 32768.0);
                }
            }
        }
        AudioBufferRef::S24(buf) => {
            let channels = buf.spec().channels.count();
            let frames = buf.frames();
            output.reserve(frames * channels);

            for frame in 0..frames {
                for ch in 0..channels {
                    // Convert i24 to f32
                    let sample = buf.chan(ch)[frame].inner();
                    output.push(sample as f32 / 8388608.0);
                }
            }
        }
        AudioBufferRef::S32(buf) => {
            let channels = buf.spec().channels.count();
            let frames = buf.frames();
            output.reserve(frames * channels);

            for frame in 0..frames {
                for ch in 0..channels {
                    output.push(buf.chan(ch)[frame] as f32 / 2147483648.0);
                }
            }
        }
        AudioBufferRef::U8(buf) => {
            let channels = buf.spec().channels.count();
            let frames = buf.frames();
            output.reserve(frames * channels);

            for frame in 0..frames {
                for ch in 0..channels {
                    // Convert u8 to f32 (-1.0 to 1.0)
                    output.push((buf.chan(ch)[frame] as f32 - 128.0) / 128.0);
                }
            }
        }
        _ => {
            // Unsupported format - output silence
            eprintln!("Unsupported audio buffer format");
        }
    }
}

/// Seek context for handling seek requests.
pub struct SeekContext {
    pub format: Box<dyn FormatReader>,
    pub decoder: Box<dyn Decoder>,
    pub track_id: u32,
}

impl SeekContext {
    /// Seek to a position in seconds.
    pub fn seek(&mut self, position_secs: f64) -> Result<(), DecoderError> {
        let seek_to = SeekTo::Time {
            time: Time::new(position_secs as u64, position_secs.fract()),
            track_id: Some(self.track_id),
        };

        self.format
            .seek(SeekMode::Coarse, seek_to)
            .map_err(|e| DecoderError::DecodingFailed(format!("Seek failed: {}", e)))?;

        // Reset decoder after seek
        self.decoder.reset();

        Ok(())
    }
}
