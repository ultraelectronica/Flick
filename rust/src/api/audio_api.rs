//! Flutter Rust Bridge API for audio engine control.
//!
//! This module provides the interface between Dart and the Rust audio engine.
//! Now available on all platforms including Android (using CPAL with Oboe backend).

use crate::audio::commands::{AudioEvent, PlaybackState};
use crate::audio::crossfeed::CrossfeedLevel;
use crate::audio::decoder::{probe_file, probe_http, DecoderThread};
use crate::audio::decoder_handle::{detect_file_type, DecoderHandle};
#[cfg(target_os = "android")]
use crate::audio::device::current_device_profile;
use crate::audio::dsd_engine::dsd::{resolve_dsd_pcm_sample_rate, DsdOutputMode, DsdRate};
use crate::audio::dsd_engine::format::open_dsd_decoder;
use crate::audio::dsd_engine::DsdDecoderThread;
use crate::audio::engine::AudioApiPreference;
use crate::audio::equalizer::EqBandSpec;
use crate::audio::manager::{AudioCapability, AudioCapabilitySnapshot, AudioEngine, EngineManager};
use crate::audio::strategy::OutputStrategy;
use crate::audio::wavpack_thread::WavpackDecoderThread;
use log::{info as log_info, warn as log_warn};
use once_cell::sync::Lazy;
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicU8, Ordering};
use std::sync::Mutex;

static ENGINE_MANAGER: Lazy<EngineManager> = Lazy::new(EngineManager::new);

// Default Auto, not PcmDecimation: FRB runs calls on a worker pool, so the
// Dart-side sync can race the first audio_play. Never decimate DSD to PCM.
static DSD_OUTPUT_MODE: AtomicU8 = AtomicU8::new(3);
static CURRENT_DSD_TRACK_RATE: AtomicU32 = AtomicU32::new(0);
static PENDING_VOLUME: AtomicU32 = AtomicU32::new(0);

const PENDING_VOLUME_NONE: u32 = 0xFFFF_FFFF;

// ponytail: mirror of the last volume the app pushed. PENDING_VOLUME is
// one-shot and gets consumed on the first engine recreate, so reopening the
// stream on a sample-rate change (e.g. a 96k track) would otherwise drop the
// new engine to the CallbackData default of 1.0 = full-scale blast. This is
// the fallback for that case.
static LAST_VOLUME: AtomicU32 = AtomicU32::new(1.0f32.to_bits());

static PENDING_XF_ENABLED: AtomicU8 = AtomicU8::new(u8::MAX);
static PENDING_XF_DURATION: AtomicU32 = AtomicU32::new(0xFFFF_FFFF);
static PENDING_XF_CURVE: AtomicU8 = AtomicU8::new(u8::MAX);

// ponytail: pending EQ so it survives engine recreation. A USB DAC rebuilds
// the engine on a sample-rate change between tracks; volume and crossfade are
// already re-applied on the fresh handle, but EQ was dropped — so it worked
// on the first track and silently vanished on the next (issue #211). EqBandSpec
// is Copy but the band list is a Vec, so this needs a Mutex, not atomics.
static PENDING_EQ: Lazy<Mutex<Option<(bool, Vec<EqBandSpec>)>>> = Lazy::new(|| Mutex::new(None));

// ponytail: pending crossfeed level (0..3, u32::MAX = none) so it survives
// engine recreation like EQ — a USB DAC rebuilds the engine on a sample-rate
// change between tracks and would otherwise drop it.
static PENDING_CROSSFEED: AtomicU32 = AtomicU32::new(u32::MAX);

pub fn current_dsd_output_mode() -> DsdOutputMode {
    match DSD_OUTPUT_MODE.load(Ordering::Relaxed) {
        1 => DsdOutputMode::Dop,
        2 => DsdOutputMode::Native,
        3 => DsdOutputMode::Auto,
        _ => DsdOutputMode::PcmDecimation,
    }
}

pub fn effective_dsd_output_mode(requested: DsdOutputMode) -> DsdOutputMode {
    let dsd_rate = current_dsd_track_rate().and_then(DsdRate::from_sample_rate);
    effective_dsd_output_mode_for_rate(requested, dsd_rate)
}

pub fn effective_dsd_output_mode_for_rate(
    requested: DsdOutputMode,
    dsd_rate: Option<DsdRate>,
) -> DsdOutputMode {
    let is_dsd256_plus = dsd_rate.is_some_and(|r| matches!(r, DsdRate::Dsd256 | DsdRate::Dsd512));

    // Capability of the registered UAC2 DAC, from its discovered alt settings.
    // These are populated at registration (before the stream starts), so this
    // avoids the chicken-and-egg with create_audio_engine (which only starts the
    // stream AFTER the output mode is decided). This mirrors the capability
    // checks in engine.rs so the DSD-engine output mode and the chosen USB
    // transport always agree — preventing DSD-as-PCM corruption.
    #[cfg(all(feature = "uac2", target_os = "android"))]
    let (usb_native_capable, usb_dop_capable) = {
        let debug = crate::uac2::android_direct_debug_state();
        let carrier = dsd_rate.map(|r| r.dop_carrier_rate()).unwrap_or(0);
        let native = debug.registered
            && debug.available_alt_settings.iter().any(|alt| {
                alt.format_tag == "DSD"
                    && alt.subslot_size > 0
                    && dsd_rate.is_some_and(|r| {
                        let wire = r.sample_rate() / (8 * u32::from(alt.subslot_size));
                        alt.sample_rates.is_empty()
                            || wire <= alt.sample_rates.iter().copied().max().unwrap_or(0)
                            || alt.sample_rates.iter().any(|&sr| sr == wire)
                    })
            });
        let dop = debug.registered
            && debug.available_alt_settings.iter().any(|alt| {
                alt.format_tag == "PCM"
                    && alt.bit_resolution >= 24
                    && alt.sample_rates.iter().any(|&sr| sr == carrier)
            });
        (native, dop)
    };
    #[cfg(not(all(feature = "uac2", target_os = "android")))]
    let (_usb_native_capable, usb_dop_capable) = (false, false);

    match requested {
        DsdOutputMode::PcmDecimation => return DsdOutputMode::PcmDecimation,
        DsdOutputMode::Dop => {
            if is_dsd256_plus && !usb_dop_capable {
                log_info!(
                    "[AUDIO] DoP requested for DSD256+ but no UAC2 DoP-capable alt at carrier; \
                     falling back to PCM decimation"
                );
                return DsdOutputMode::PcmDecimation;
            }
            return DsdOutputMode::Dop;
        }
        DsdOutputMode::Native | DsdOutputMode::Auto => {}
    }

    // Native/Auto DSD delivery routes:
    // 1. UAC2 direct USB native DSD (raw DSD bitstream via isochronous transfers)
    // 2. Android AudioTrack with ENCODING_DSD (direct to internal DAC)
    // 3. DoP fallback

    #[cfg(all(feature = "uac2", target_os = "android"))]
    if usb_native_capable {
        log_info!(
            "[AUDIO] {:?} DSD: registered UAC2 DAC exposes a native-DSD alt; using native USB",
            requested
        );
        return DsdOutputMode::Native;
    }

    #[cfg(target_os = "android")]
    {
        let profile = crate::audio::device::current_device_profile();
        let supports_dsd = profile.as_ref().is_some_and(|p| p.supports_native_dsd);
        if supports_dsd {
            log_info!(
                "[AUDIO] {:?} DSD requested; device supports ENCODING_DSD, \
                 using Android DSD AudioTrack",
                requested
            );
            return DsdOutputMode::Native;
        }
    }

    // DSD256+ without any native or UAC2 DoP path: go straight to PCM
    if is_dsd256_plus && !usb_dop_capable {
        log_info!(
            "[AUDIO] DSD256+ with no native DSD or UAC2 DoP path; falling back to PCM decimation"
        );
        return DsdOutputMode::PcmDecimation;
    }

    // Auto: prefer DoP over PCM decimation when a DoP-capable UAC2 alt exists
    if requested == DsdOutputMode::Auto {
        #[cfg(target_os = "android")]
        {
            let profile = crate::audio::device::current_device_profile();
            let is_dap = profile.as_ref().is_some_and(|p| p.is_dap());
            if is_dap {
                log_info!(
                    "[AUDIO] Auto DSD: device is DAP but native DSD unavailable; \
                     falling back to DoP"
                );
                return DsdOutputMode::Dop;
            }
        }

        #[cfg(all(feature = "uac2", target_os = "android"))]
        if usb_dop_capable {
            log_info!(
                "[AUDIO] Auto DSD: registered UAC2 DAC exposes a DoP-capable PCM alt; using DoP"
            );
            return DsdOutputMode::Dop;
        }

        log_info!(
            "[AUDIO] Auto DSD: no native DSD or DoP path available; \
             falling back to PCM decimation"
        );
        return DsdOutputMode::PcmDecimation;
    }

    log_info!(
        "[AUDIO] Native DSD requested but no direct DSD path available; \
         falling back to DoP (bit-perfect DSD over PCM carrier)"
    );
    DsdOutputMode::Dop
}

pub fn set_dsd_track_rate(rate: u32) {
    CURRENT_DSD_TRACK_RATE.store(rate, Ordering::Relaxed);
}

// Why the last native-DSD attempt fell back (SAS offload / ALSA reasons), so
// diagnostics can say more than "native unavailable".
static LAST_DSD_NATIVE_FAILURE: Lazy<Mutex<Option<String>>> =
    Lazy::new(|| Mutex::new(None));

pub fn last_dsd_native_failure() -> Option<String> {
    LAST_DSD_NATIVE_FAILURE
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
}

pub fn clear_dsd_native_failure() {
    if let Ok(mut guard) = LAST_DSD_NATIVE_FAILURE.lock() {
        *guard = None;
    }
}

fn record_dsd_native_failure(error: &str) {
    let reason = error
        .strip_prefix("DSD_NATIVE_FALLBACK:")
        .unwrap_or(error)
        .to_string();
    if let Ok(mut guard) = LAST_DSD_NATIVE_FAILURE.lock() {
        *guard = Some(reason);
    }
}

pub fn clear_dsd_track_rate() {
    CURRENT_DSD_TRACK_RATE.store(0, Ordering::Relaxed);
}

pub fn current_dsd_track_rate() -> Option<u32> {
    let rate = CURRENT_DSD_TRACK_RATE.load(Ordering::Relaxed);
    if rate > 0 {
        Some(rate)
    } else {
        None
    }
}

pub fn set_pending_volume(volume: f32) {
    PENDING_VOLUME.store(volume.to_bits(), Ordering::Relaxed);
    LAST_VOLUME.store(volume.to_bits(), Ordering::Relaxed);
}

pub fn take_pending_volume() -> Option<f32> {
    let bits = PENDING_VOLUME.load(Ordering::Relaxed);
    if bits == PENDING_VOLUME_NONE {
        return None;
    }
    PENDING_VOLUME.store(PENDING_VOLUME_NONE, Ordering::Relaxed);
    Some(f32::from_bits(bits))
}

pub fn last_volume() -> f32 {
    f32::from_bits(LAST_VOLUME.load(Ordering::Relaxed))
}

pub fn set_pending_crossfade(enabled: bool, duration_secs: f32) {
    PENDING_XF_ENABLED.store(if enabled { 1 } else { 0 }, Ordering::Relaxed);
    PENDING_XF_DURATION.store(duration_secs.to_bits(), Ordering::Relaxed);
}

pub fn set_pending_crossfade_curve(curve: crate::audio::crossfader::CrossfadeCurve) {
    let raw = match curve {
        crate::audio::crossfader::CrossfadeCurve::EqualPower => 0,
        crate::audio::crossfader::CrossfadeCurve::Linear => 1,
        crate::audio::crossfader::CrossfadeCurve::SquareRoot => 2,
        crate::audio::crossfader::CrossfadeCurve::SCurve => 3,
    };
    PENDING_XF_CURVE.store(raw, Ordering::Relaxed);
}

pub fn take_pending_crossfade() -> Option<(bool, f32, crate::audio::crossfader::CrossfadeCurve)> {
    let enabled_raw = PENDING_XF_ENABLED.swap(u8::MAX, Ordering::Relaxed);
    if enabled_raw == u8::MAX {
        return None;
    }
    let enabled = enabled_raw == 1;
    let dur_bits = PENDING_XF_DURATION.swap(0xFFFF_FFFF, Ordering::Relaxed);
    let duration_secs = if dur_bits == 0xFFFF_FFFF {
        3.0
    } else {
        f32::from_bits(dur_bits)
    };
    let curve_raw = PENDING_XF_CURVE.swap(u8::MAX, Ordering::Relaxed);
    let curve = match curve_raw {
        1 => crate::audio::crossfader::CrossfadeCurve::Linear,
        2 => crate::audio::crossfader::CrossfadeCurve::SquareRoot,
        3 => crate::audio::crossfader::CrossfadeCurve::SCurve,
        _ => crate::audio::crossfader::CrossfadeCurve::EqualPower,
    };
    Some((enabled, duration_secs, curve))
}

pub fn set_pending_equalizer(enabled: bool, specs: Vec<EqBandSpec>) {
    *PENDING_EQ.lock().expect("pending eq poisoned") = Some((enabled, specs));
}

pub fn take_pending_equalizer() -> Option<(bool, Vec<EqBandSpec>)> {
    PENDING_EQ.lock().expect("pending eq poisoned").take()
}

pub fn set_pending_crossfeed(level: u8) {
    PENDING_CROSSFEED.store(level as u32, Ordering::Relaxed);
}

pub fn take_pending_crossfeed() -> Option<u8> {
    let raw = PENDING_CROSSFEED.swap(u32::MAX, Ordering::Relaxed);
    if raw == u32::MAX {
        None
    } else {
        Some(raw as u8)
    }
}

fn with_audio_engine<T>(
    f: impl FnOnce(&crate::audio::engine::AudioEngineHandle) -> Result<T, String>,
) -> Result<T, String> {
    ENGINE_MANAGER.with_rust_handle(f)
}

fn read_audio_engine<T>(
    f: impl FnOnce(&crate::audio::engine::AudioEngineHandle) -> T,
) -> Option<T> {
    ENGINE_MANAGER.read_rust_handle(f)
}

fn ensure_audio_engine(preferred_sample_rate: Option<u32>) -> Result<(), String> {
    ENGINE_MANAGER.ensure_rust_engine(preferred_sample_rate, vec![])
}

fn ensure_audio_engine_excluded(
    preferred_sample_rate: Option<u32>,
    excluded: Vec<OutputStrategy>,
) -> Result<(), String> {
    ENGINE_MANAGER.ensure_rust_engine(preferred_sample_rate, excluded)
}

fn resolve_requested_output_sample_rate(
    preferred_sample_rate: Option<u32>,
) -> Result<Option<u32>, String> {
    #[cfg(all(feature = "uac2", target_os = "android"))]
    {
        return crate::uac2::negotiate_android_direct_output_sample_rate(preferred_sample_rate);
    }

    #[allow(unreachable_code)]
    Ok(preferred_sample_rate)
}

fn resolve_track_playback_output_sample_rate(
    preferred_sample_rate: Option<u32>,
) -> Result<Option<u32>, String> {
    // Lying container headers (1 Hz ALAC stsd) must not become output configs.
    let preferred_sample_rate =
        preferred_sample_rate.filter(|rate| crate::audio::decoder::plausible_sample_rate(*rate));

    #[cfg(target_os = "android")]
    {
        let route_type = ENGINE_MANAGER.capability_route_type();
        #[cfg(feature = "uac2")]
        let usb_direct_active = crate::uac2::android_direct_usb_enabled();
        #[cfg(not(feature = "uac2"))]
        let usb_direct_active = false;
        let should_preserve_existing_rate = !ENGINE_MANAGER.is_high_res_mode_enabled()
            && !ENGINE_MANAGER.get_dap_bit_perfect_enabled()
            && matches!(route_type.as_str(), "unknown" | "internal" | "wired")
            && current_device_profile().is_some_and(|profile| profile.is_dap())
            && !usb_direct_active;
        if let Some(existing_rate) = should_preserve_existing_rate
            .then(|| read_audio_engine(|handle| handle.sample_rate()))
            .flatten()
            .filter(|rate| crate::audio::decoder::plausible_sample_rate(*rate))
        {
            return Ok(Some(existing_rate));
        }
    }

    resolve_requested_output_sample_rate(preferred_sample_rate)
}

fn resolve_dsd_engine_sample_rate(
    path: &PathBuf,
    output_mode: DsdOutputMode,
) -> Result<Option<u32>, String> {
    let effective_mode = effective_dsd_output_mode(output_mode);
    if effective_mode == DsdOutputMode::Dop {
        let decoder = open_dsd_decoder(path)
            .map_err(|e| format!("Failed to probe DSD rate for {}: {}", path.display(), e))?;
        let dsd_rate = DsdRate::from_sample_rate(decoder.sample_rate())
            .ok_or_else(|| format!("Unsupported DSD sample rate: {}", decoder.sample_rate()))?;
        let carrier = dsd_rate.dop_carrier_rate();
        log_info!(
            "[AUDIO] DSD DoP: dsd_rate={} Hz -> carrier={} Hz",
            dsd_rate.sample_rate(),
            carrier
        );
        return resolve_requested_output_sample_rate(Some(carrier));
    }
    let decoder = open_dsd_decoder(path)
        .map_err(|e| format!("Failed to probe DSD rate for {}: {}", path.display(), e))?;
    let dsd_rate = DsdRate::from_sample_rate(decoder.sample_rate())
        .ok_or_else(|| format!("Unsupported DSD sample rate: {}", decoder.sample_rate()))?;
    if effective_mode == DsdOutputMode::Native {
        #[cfg(target_os = "android")]
        {
            let use_audio_track = current_device_profile()
                .as_ref()
                .is_some_and(|p| p.supports_native_dsd)
                && !{
                    #[cfg(feature = "uac2")]
                    {
                        crate::uac2::is_usb_session_active()
                    }
                    #[cfg(not(feature = "uac2"))]
                    {
                        false
                    }
                };
            let frame_rate = dsd_rate.byte_rate();
            if use_audio_track {
                log_info!(
                    "[AUDIO] DSD Native AudioTrack: dsd_rate={} Hz -> frame_rate={} Hz",
                    dsd_rate.sample_rate(),
                    frame_rate
                );
                return resolve_requested_output_sample_rate(Some(frame_rate));
            }
            #[cfg(feature = "uac2")]
            {
                if crate::uac2::is_usb_session_active() {
                    log_info!(
                        "[AUDIO] DSD Native USB: dsd_rate={} Hz -> frame_rate={} Hz",
                        dsd_rate.sample_rate(),
                        frame_rate
                    );
                    return resolve_requested_output_sample_rate(Some(frame_rate));
                }
            }
        }

        #[cfg(not(target_os = "android"))]
        {
            return resolve_requested_output_sample_rate(Some(dsd_rate.byte_rate()));
        }

        #[cfg(target_os = "android")]
        {
            return resolve_requested_output_sample_rate(Some(dsd_rate.byte_rate()));
        }
    }
    let existing_rate = read_audio_engine(|handle| handle.sample_rate()).unwrap_or(0);
    let target = resolve_dsd_pcm_sample_rate(dsd_rate, existing_rate);
    log_info!(
        "[AUDIO] DSD PCM decimation: dsd_rate={} Hz, existing_engine={} Hz -> target={} Hz",
        dsd_rate.sample_rate(),
        existing_rate,
        target
    );
    resolve_requested_output_sample_rate(Some(target))
}

fn verify_dsd_engine_rate(
    path: &PathBuf,
    mode: DsdOutputMode,
    engine_rate: u32,
) -> Result<(), String> {
    if !matches!(mode, DsdOutputMode::Native | DsdOutputMode::Dop) {
        return Ok(());
    }
    let decoder = open_dsd_decoder(path)
        .map_err(|e| format!("Failed to probe DSD rate for {}: {}", path.display(), e))?;
    let dsd_rate = DsdRate::from_sample_rate(decoder.sample_rate())
        .ok_or_else(|| format!("Unsupported DSD sample rate: {}", decoder.sample_rate()))?;
    let required_rate = match mode {
        DsdOutputMode::Native => dsd_rate.byte_rate(),
        DsdOutputMode::Dop => dsd_rate.dop_carrier_rate(),
        _ => return Ok(()),
    };
    if engine_rate != required_rate {
        return Err(format!(
            "DSD {:?} playback requires the output to run at exactly {} Hz, \
             but the engine is running at {} Hz. The current audio backend \
             does not support this DSD mode. Switch to PCM Decimation or \
             connect a DSD-capable DAC and enable direct USB mode.",
            mode, required_rate, engine_rate
        ));
    }
    Ok(())
}

fn verify_dop_passthrough(engine_rate: u32) -> Result<(), String> {
    let signature = read_audio_engine(|handle| handle.output_signature().to_string());
    let passthrough = read_audio_engine(|handle| {
        let rt = handle.output_runtime();
        rt.passthrough_allowed
    });

    let sig = signature.as_deref().unwrap_or("");
    let sig_matches_dop = sig.contains("dsd-dop:") || sig.contains("dsd-native:");
    let rate_matches = if let Some(rate_str) = sig.rsplit(':').next() {
        rate_str.parse::<u32>().ok() == Some(engine_rate)
    } else {
        false
    };

    if sig_matches_dop && rate_matches && passthrough.unwrap_or(false) {
        log::info!(
            "[AUDIO] DoP pre-flight OK: wire_rate={} signature={}",
            engine_rate,
            sig
        );
        return Ok(());
    }

    log::warn!(
        "[AUDIO] DoP pre-flight FAILED: Android may have resampled the carrier. \
         engine_rate={} signature={} passthrough={:?}. Degrading to PCM decimation.",
        engine_rate,
        sig,
        passthrough
    );

    Err(format!(
        "DoP passthrough verification failed: the output path did not confirm \
         bit-perfect DoP delivery at {} Hz (signature={}, passthrough={:?}). \
         Android likely resampled the carrier. Degrading to PCM decimation.",
        engine_rate, sig, passthrough
    ))
}

fn prepare_decoder_source(
    path: &PathBuf,
    output_sample_rate: u32,
    output_channels: usize,
) -> Result<(crate::audio::source::AudioSource, DecoderHandle), String> {
    match detect_file_type(path) {
        crate::audio::decoder_handle::FileType::Dsd => {
            let effective_mode = effective_dsd_output_mode(current_dsd_output_mode());
            verify_dsd_engine_rate(path, effective_mode, output_sample_rate)?;
            let (source, thread) = DsdDecoderThread::spawn(
                path.clone(),
                effective_mode,
                output_sample_rate,
                output_channels,
            )
            .map_err(|e| format!("Failed to decode DSD {}: {}", path.display(), e))?;
            Ok((source, DecoderHandle::Dsd(thread)))
        }
        crate::audio::decoder_handle::FileType::WavPack => {
            let (source, handle) =
                WavpackDecoderThread::spawn(path.clone(), output_sample_rate, output_channels)
                    .map_err(|e| format!("Failed to decode WavPack {}: {}", path.display(), e))?;
            Ok((source, handle))
        }
        crate::audio::decoder_handle::FileType::Standard => {
            let probe_result = probe_file(path.as_path())
                .map_err(|error| format!("Failed to probe {}: {}", path.display(), error))?;
            let file_rate = probe_result.source_info.original_sample_rate;
            if output_sample_rate != file_rate {
                log_warn!(
                    "[AUDIO] engine_sample_rate_hz={} decoded_file_sample_rate_hz={} — decoder resampling active",
                    output_sample_rate,
                    file_rate
                );
            } else {
                log_info!(
                    "[AUDIO] engine_sample_rate_hz matches decoded_file_sample_rate_hz ({} Hz); decoder resampling off",
                    file_rate
                );
            }

            let (source, thread) = DecoderThread::spawn_from_probe_result(
                probe_result,
                output_sample_rate,
                output_channels,
                None,
            )
            .map_err(|error| format!("Failed to decode {}: {}", path.display(), error))?;
            Ok((source, DecoderHandle::Symphonia(thread)))
        }
    }
}

// ============================================================================
// SHARED TYPES (available on all platforms)
// ============================================================================

/// Progress information returned to Dart.
#[derive(Debug, Clone)]
pub struct AudioProgress {
    /// Current position in seconds
    pub position_secs: f64,
    /// Total duration in seconds (if known)
    pub duration_secs: Option<f64>,
    /// Buffer fill level (0.0 to 1.0)
    pub buffer_level: f32,
}

/// Audio event types for Dart.
#[derive(Debug, Clone)]
pub enum AudioEventType {
    StateChanged {
        state: String,
    },
    Progress {
        position_secs: f64,
        duration_secs: Option<f64>,
        buffer_level: f32,
    },
    TrackEnded {
        path: String,
    },
    CrossfadeStarted {
        from_path: String,
        to_path: String,
    },
    Error {
        message: String,
    },
    NextTrackReady {
        path: String,
    },
}

/// Crossfade curve type for Dart.
#[derive(Debug, Clone, Copy)]
pub enum CrossfadeCurveType {
    EqualPower,
    Linear,
    SquareRoot,
    SCurve,
}

/// The currently available output capability classes for engine selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioCapabilityType {
    UsbDac,
    HiResInternal,
    Standard,
}

impl From<AudioCapability> for AudioCapabilityType {
    fn from(value: AudioCapability) -> Self {
        match value {
            AudioCapability::UsbDac => Self::UsbDac,
            AudioCapability::HiResInternal => Self::HiResInternal,
            AudioCapability::Standard => Self::Standard,
        }
    }
}

impl From<AudioCapabilityType> for AudioCapability {
    fn from(value: AudioCapabilityType) -> Self {
        match value {
            AudioCapabilityType::UsbDac => Self::UsbDac,
            AudioCapabilityType::HiResInternal => Self::HiResInternal,
            AudioCapabilityType::Standard => Self::Standard,
        }
    }
}

#[derive(Debug, Clone)]
pub struct AudioCapabilityInfo {
    pub capabilities: Vec<AudioCapabilityType>,
    pub route_type: String,
    pub route_label: Option<String>,
    pub max_sample_rate: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AudioRuntimeDebugState {
    pub manager_engine: String,
    pub rust_initialized: bool,
    pub output_signature: Option<String>,
    pub sample_rate: Option<u32>,
    pub channels: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AudioRuntimeDebugJsonState {
    pub manager_engine: String,
    pub rust_initialized: bool,
    pub output_signature: Option<String>,
    pub sample_rate: Option<u32>,
    pub channels: Option<usize>,
    pub output_strategy: Option<String>,
    pub requested_sample_rate: Option<u32>,
    pub actual_sample_rate: Option<u32>,
    pub resampler_active: Option<bool>,
    pub passthrough_allowed: Option<bool>,
    pub verification_reason: Option<String>,
    pub direct_usb_active: Option<bool>,
    pub direct_usb_verified: Option<bool>,
    pub dsd_source_rate: Option<u32>,
    pub dsd_effective_mode: Option<String>,
    pub dsd_wire_rate: Option<u32>,
    pub dsd_transport: Option<String>,
    pub active_audio_api: Option<String>,
}

impl From<AudioCapabilitySnapshot> for AudioCapabilityInfo {
    fn from(value: AudioCapabilitySnapshot) -> Self {
        Self {
            capabilities: value.capabilities.into_iter().map(Into::into).collect(),
            route_type: value.route_type,
            route_label: value.route_label,
            max_sample_rate: value.max_sample_rate,
        }
    }
}

impl From<AudioCapabilityInfo> for AudioCapabilitySnapshot {
    fn from(value: AudioCapabilityInfo) -> Self {
        AudioCapabilitySnapshot {
            capabilities: value.capabilities.into_iter().map(Into::into).collect(),
            route_type: value.route_type,
            route_label: value.route_label,
            max_sample_rate: value.max_sample_rate,
        }
        .normalize()
    }
}

// ============================================================================
// API FUNCTIONS
// ============================================================================

/// Check if native audio is available on this platform.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_is_native_available() -> bool {
    // Native audio is now available on all platforms including Android
    true
}

/// Initialize the audio engine.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_init() -> Result<(), String> {
    crate::assert_android_debug_logging();
    ENGINE_MANAGER.init();
    Ok(())
}

/// Check if the audio engine is initialized.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_is_initialized() -> bool {
    ENGINE_MANAGER.is_rust_initialized()
}

/// Enable or disable high-res mode. When enabled, the Rust engine is allowed
/// to initialize even if a DAC is not currently detected.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_high_res_mode(enabled: bool) {
    ENGINE_MANAGER.set_high_res_mode(enabled);
    #[cfg(all(feature = "uac2", target_os = "android"))]
    crate::uac2::set_android_direct_usb_enabled(!enabled);
}

/// Sync the Bit-perfect (DAP Internal) preference from Dart so the Rust engine manager
/// can factor it into engine selection and reuse decisions.
/// When toggled at runtime, the running engine's pipeline mode is switched
/// between Passthrough (bit-perfect) and Dsp (full processing) on DAP devices.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_dap_bit_perfect_enabled(enabled: bool) {
    ENGINE_MANAGER.set_dap_bit_perfect_enabled(enabled);

    #[cfg(target_os = "android")]
    {
        let is_dap = current_device_profile()
            .as_ref()
            .is_some_and(|p| p.is_dap());
        if is_dap {
            if let Err(e) =
                with_audio_engine(|handle| handle.set_pipeline_mode_passthrough(enabled))
            {
                log::warn!(
                    "audio_set_dap_bit_perfect_enabled({}): runtime pipeline switch skipped — {}",
                    enabled,
                    e
                );
            }
        }
    }
    #[cfg(not(target_os = "android"))]
    let _ = enabled;
}

/// Set the running Rust callback's base pipeline mode.
///
/// This is separate from the DAP preference because direct USB playback can
/// leave the engine in passthrough after bit-perfect is disabled.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_pipeline_mode_passthrough(enabled: bool) -> Result<(), String> {
    with_audio_engine(|handle| handle.set_pipeline_mode_passthrough(enabled))
}

/// Sync the preferred Android audio API (AAudio / OpenSL ES / Auto) from Dart.
/// The change is staged on the engine manager and applied on the next engine
/// (re)initialization — the live stream is reopened when the preference no
/// longer matches the value the running engine was built with. On non-Android
/// targets this is a no-op (cpal has no AudioApi selection).
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_audio_api(preference: AudioApiPreference) {
    ENGINE_MANAGER.set_audio_api_preference(preference);
}

/// Read the currently-staged Android audio-API preference. Returns the string
/// key ("auto" / "aaudio" / "opensles") so Dart can mirror UI selection without
/// importing the generated enum mirror.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_audio_api() -> String {
    ENGINE_MANAGER.get_audio_api_preference().as_str().to_string()
}

/// Toggle experimental 432 Hz tuning. When enabled the engine leaves bit-perfect
/// passthrough, runs the DSP path, and pins playback speed at 432/440.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_432hz_tuning_enabled(enabled: bool) {
    ENGINE_MANAGER.set_432hz_tuning_enabled(enabled);
}

/// Set the DSD output mode from Dart. 0 = PCM decimation, 1 = DoP, 2 = Native, 3 = Auto.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_dsd_output_mode(mode: u8) {
    DSD_OUTPUT_MODE.store(mode.min(3), Ordering::Relaxed);
}

/// Toggle DSD bit-reverse override. When on, inverts the bit-order normalization
/// so that MSB-first sources get reversed and LSB-first sources pass through.
/// Use this to diagnose white-noise from wrong bit order.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_dsd_bit_reverse_override(enabled: bool) {
    crate::audio::dsd_engine::output::set_dsd_bit_reverse_override(enabled);
}

/// Wire-packing variant for the DAP-internal native-DSD shim transport:
/// 0 = Auto/BE-MSB, 1 = LE-MSB, 2 = BE-LSB, 3 = LE-LSB. Wrong = hiss.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_sas_wire_variant(variant: u8) {
    crate::audio::dsd_sas_shim::set_wire_variant(variant.min(3));
}

/// Wire byte grouping (subslot width) for the DAP-internal native-DSD shim:
/// 0 = U32 (legacy), 1 = U16, 2 = U8 (byte-interleaved). Wrong = hiss.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_sas_wire_grouping(grouping: u8) {
    crate::audio::dsd_sas_shim::set_wire_grouping(grouping);
}

/// Force the native-DSD wire byte order on the USB direct transport (DSD_U32
/// packing). Pass `None` to defer to the device quirk (auto). Use to diagnose
/// channel-swapped or noisy DSD from a wrong byte-order assumption.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_dsd_big_endian_override(value: Option<bool>) {
    crate::audio::dsd_engine::output::set_dsd_big_endian_override(value);
}

/// Force the native-DSD subslot size (1=DSD_U8, 2=DSD_U16, 4=DSD_U32) on the
/// USB direct transport. Pass `None` to defer to the descriptor / device quirk.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_dsd_subslot_override(value: Option<u8>) {
    crate::audio::dsd_engine::output::set_dsd_subslot_override(value);
}

/// Update the current platform capability snapshot used for engine selection.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_capability_info(info: AudioCapabilityInfo) {
    ENGINE_MANAGER.set_capability_snapshot(info.into());
}

/// Inspect the current capability snapshot after native detection and platform hints are merged.
pub fn audio_get_capability_info(
    preferred_sample_rate: Option<u32>,
) -> Result<AudioCapabilityInfo, String> {
    ENGINE_MANAGER
        .capability_snapshot(preferred_sample_rate)
        .map(Into::into)
}

/// Return the currently selected engine.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_active_engine() -> String {
    match ENGINE_MANAGER.current_engine() {
        Some(AudioEngine::Default) => "default".to_string(),
        Some(AudioEngine::Rust) => "rust".to_string(),
        None => "uninitialized".to_string(),
    }
}

pub fn audio_get_runtime_debug_state() -> AudioRuntimeDebugState {
    let manager_engine = audio_get_active_engine();
    let rust_initialized = audio_is_initialized();
    let handle_state = read_audio_engine(|handle| {
        (
            handle.output_signature().to_string(),
            handle.sample_rate(),
            handle.channels(),
        )
    });

    AudioRuntimeDebugState {
        manager_engine,
        rust_initialized,
        output_signature: handle_state
            .as_ref()
            .map(|(signature, _, _)| signature.clone()),
        sample_rate: handle_state
            .as_ref()
            .map(|(_, sample_rate, _)| *sample_rate),
        channels: handle_state.as_ref().map(|(_, _, channels)| *channels),
    }
}

pub fn audio_get_runtime_debug_json_state() -> AudioRuntimeDebugJsonState {
    let base = audio_get_runtime_debug_state();
    let output_runtime = read_audio_engine(|handle| handle.output_runtime().clone());

    AudioRuntimeDebugJsonState {
        manager_engine: base.manager_engine,
        rust_initialized: base.rust_initialized,
        output_signature: base.output_signature,
        sample_rate: base.sample_rate,
        channels: base.channels,
        output_strategy: output_runtime.as_ref().map(|state| state.strategy.clone()),
        requested_sample_rate: output_runtime
            .as_ref()
            .map(|state| state.requested_sample_rate),
        actual_sample_rate: output_runtime
            .as_ref()
            .map(|state| state.actual_sample_rate),
        resampler_active: output_runtime.as_ref().map(|state| state.resampler_active),
        passthrough_allowed: output_runtime
            .as_ref()
            .map(|state| state.passthrough_allowed),
        verification_reason: output_runtime
            .as_ref()
            .and_then(|state| state.verification_reason.clone()),
        direct_usb_active: output_runtime.as_ref().map(|state| state.direct_usb_active),
        direct_usb_verified: output_runtime
            .as_ref()
            .map(|state| state.direct_usb_verified),
        dsd_source_rate: output_runtime
            .as_ref()
            .and_then(|state| state.dsd_source_rate),
        dsd_effective_mode: output_runtime
            .as_ref()
            .and_then(|state| state.dsd_effective_mode.clone()),
        dsd_wire_rate: output_runtime
            .as_ref()
            .and_then(|state| state.dsd_wire_rate),
        dsd_transport: output_runtime
            .as_ref()
            .and_then(|state| state.dsd_transport.clone()),
        active_audio_api: output_runtime
            .as_ref()
            .and_then(|state| state.active_audio_api.clone()),
    }
}

/// Detect whether a DAC is present before attempting Rust engine initialization.
pub fn audio_is_dac_available(preferred_sample_rate: Option<u32>) -> Result<bool, String> {
    ENGINE_MANAGER.is_dac_available(preferred_sample_rate)
}

/// Prepare the Rust audio engine for the requested output rate before playback starts.
pub fn audio_prepare_engine(preferred_sample_rate: Option<u32>) -> Result<(), String> {
    ensure_audio_engine(resolve_requested_output_sample_rate(preferred_sample_rate)?)
}

/// discover the actual sample rate before the USB engine is configured. Used by
/// Dart when song metadata lacks sampleRate/bitDepth, to avoid falling back to
/// just_audio and to avoid configuring the USB DAC clock at the wrong rate.
pub struct AudioProbeFormat {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: Option<u32>,
}

pub fn audio_probe_format(path: String) -> Result<AudioProbeFormat, String> {
    use symphonia::core::codecs::CODEC_TYPE_NULL;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;
    use std::fs::File;
    use std::path::Path;

    let path_obj = Path::new(&path);
    let file = File::open(path_obj).map_err(|e| format!("Failed to open file: {}", e))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path_obj.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| format!("Failed to probe format: {}", e))?;
    let track = probed
        .format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or("No audio track found".to_string())?;
    let cp = &track.codec_params;
    Ok(AudioProbeFormat {
        sample_rate: cp.sample_rate.unwrap_or(44100),
        channels: cp.channels.map(|c| c.count() as u16).unwrap_or(2),
        bits_per_sample: cp.bits_per_sample,
    })
}

/// Play an audio file.
pub fn audio_play(path: String) -> Result<(), String> {
    crate::assert_android_debug_logging();
    let path = PathBuf::from(&path);
    match detect_file_type(&path) {
        crate::audio::decoder_handle::FileType::Dsd => {
            let requested_mode = current_dsd_output_mode();
            let dsd_sample_rate = {
                let decoder = open_dsd_decoder(&path)
                    .map_err(|e| format!("Failed to probe DSD rate: {}", e))?;
                decoder.sample_rate()
            };
            let dsd_rate_enum = DsdRate::from_sample_rate(dsd_sample_rate);
            set_dsd_track_rate(dsd_sample_rate);
            clear_dsd_native_failure();
            let mut effective_mode =
                effective_dsd_output_mode_for_rate(requested_mode, dsd_rate_enum);
            log_info!(
                "[AUDIO] DSD play: requested={:?} dsd_rate={} effective={:?}",
                requested_mode,
                dsd_sample_rate,
                effective_mode
            );
            if matches!(effective_mode, DsdOutputMode::Native | DsdOutputMode::Auto) {
                crate::audio::dsd_native_jni::dsd_track_preload_class();
            }
            if let Err(e) =
                ensure_audio_engine(resolve_dsd_engine_sample_rate(&path, effective_mode)?)
            {
                if e.starts_with("DSD_NATIVE_FALLBACK:") {
                    record_dsd_native_failure(&e);
                    log::info!(
                        "[AUDIO] DSD Native unavailable ({}), falling back to DoP",
                        e
                    );
                    effective_mode = DsdOutputMode::Dop;
                    ensure_audio_engine_excluded(
                        resolve_dsd_engine_sample_rate(&path, effective_mode)?,
                        vec![OutputStrategy::DsdNative],
                    )?;
                } else {
                    return Err(e);
                }
            }
            let (mut output_sample_rate, mut output_channels) =
                with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
            verify_dsd_engine_rate(&path, effective_mode, output_sample_rate)?;
            if effective_mode == DsdOutputMode::Dop {
                if let Err(dop_err) = verify_dop_passthrough(output_sample_rate) {
                    log::info!(
                        "[AUDIO] DoP pre-flight failed ({}), degrading to PCM decimation",
                        dop_err
                    );
                    effective_mode = DsdOutputMode::PcmDecimation;
                    let pcm_rate = {
                        let decoder = open_dsd_decoder(&path)
                            .map_err(|e| format!("Failed to probe DSD rate: {}", e))?;
                        let dsd_rate = DsdRate::from_sample_rate(decoder.sample_rate())
                            .ok_or_else(|| format!("Unsupported DSD rate"))?;
                        resolve_dsd_pcm_sample_rate(dsd_rate, 0)
                    };
                    ensure_audio_engine_excluded(
                        resolve_requested_output_sample_rate(Some(pcm_rate))?,
                        vec![OutputStrategy::DsdNative],
                    )?;
                    output_sample_rate = with_audio_engine(|handle| Ok(handle.sample_rate()))?;
                    output_channels = with_audio_engine(|handle| Ok(handle.channels()))?;
                }
            }
            let (source, thread) =
                DsdDecoderThread::spawn(path, effective_mode, output_sample_rate, output_channels)
                    .map_err(|e| format!("Failed to decode DSD: {}", e))?;
            let is_raw = matches!(effective_mode, DsdOutputMode::Dop | DsdOutputMode::Native);
            with_audio_engine(|handle| {
                handle.set_dop_override(is_raw)?;
                handle.play_prepared(source, DecoderHandle::Dsd(thread))
            })
        }
        crate::audio::decoder_handle::FileType::WavPack => {
            clear_dsd_track_rate();
            ensure_audio_engine(resolve_requested_output_sample_rate(None)?)?;
            let (output_sample_rate, output_channels) =
                with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
            let (source, handle) =
                WavpackDecoderThread::spawn(path, output_sample_rate, output_channels)
                    .map_err(|e| format!("Failed to decode WavPack: {}", e))?;
            with_audio_engine(|engine| {
                engine.set_dop_override(false)?;
                engine.play_prepared(source, handle)
            })
        }
        crate::audio::decoder_handle::FileType::Standard => {
            let probe_result = probe_file(path.as_path())
                .map_err(|error| format!("Failed to probe {}: {}", path.display(), error))?;
            ensure_audio_engine(resolve_track_playback_output_sample_rate(Some(
                probe_result.source_info.original_sample_rate,
            ))?)?;
            let (output_sample_rate, output_channels) =
                with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
            let file_rate = probe_result.source_info.original_sample_rate;
            if output_sample_rate != file_rate {
                log_warn!(
                    "[AUDIO] engine_sample_rate_hz={} decoded_file_sample_rate_hz={} — decoder resampling active",
                    output_sample_rate,
                    file_rate
                );
            } else {
                log_info!(
                    "[AUDIO] engine_sample_rate_hz matches decoded_file_sample_rate_hz ({} Hz); decoder resampling off",
                    file_rate
                );
            }
            let (source, decoder_thread) = DecoderThread::spawn_from_probe_result(
                probe_result,
                output_sample_rate,
                output_channels,
                None,
            )
            .map_err(|error| format!("Failed to decode {}: {}", path.display(), error))?;
            with_audio_engine(|handle| {
                handle.set_dop_override(false)?;
                handle.play_prepared(source, DecoderHandle::Symphonia(decoder_thread))
            })
        }
    }
}

/// Queue the next track for gapless playback.
pub fn audio_queue_next(path: String) -> Result<(), String> {
    crate::assert_android_debug_logging();
    let path = PathBuf::from(path);
    if !audio_is_initialized() {
        match detect_file_type(&path) {
            crate::audio::decoder_handle::FileType::Dsd => {
                let requested_mode = current_dsd_output_mode();
                let dsd_sample_rate = {
                    let decoder = open_dsd_decoder(&path)
                        .map_err(|e| format!("Failed to probe DSD rate: {}", e))?;
                    decoder.sample_rate()
                };
                let dsd_rate_enum = DsdRate::from_sample_rate(dsd_sample_rate);
                set_dsd_track_rate(dsd_sample_rate);
                clear_dsd_native_failure();
                let mut effective_mode =
                    effective_dsd_output_mode_for_rate(requested_mode, dsd_rate_enum);
                log_info!(
                    "[AUDIO] DSD queue_next: requested={:?} dsd_rate={} effective={:?}",
                    requested_mode,
                    dsd_sample_rate,
                    effective_mode
                );
                if matches!(effective_mode, DsdOutputMode::Native | DsdOutputMode::Auto) {
                    crate::audio::dsd_native_jni::dsd_track_preload_class();
                }
                if let Err(e) =
                    ensure_audio_engine(resolve_dsd_engine_sample_rate(&path, effective_mode)?)
                {
                    if e.starts_with("DSD_NATIVE_FALLBACK:") {
                        record_dsd_native_failure(&e);
                        log::info!(
                            "[AUDIO] DSD Native unavailable ({}), falling back to DoP",
                            e
                        );
                        effective_mode = DsdOutputMode::Dop;
                        ensure_audio_engine_excluded(
                            resolve_dsd_engine_sample_rate(&path, effective_mode)?,
                            vec![OutputStrategy::DsdNative],
                        )?;
                    } else {
                        return Err(e);
                    }
                }
                let (mut output_sample_rate, mut output_channels) =
                    with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
                verify_dsd_engine_rate(&path, effective_mode, output_sample_rate)?;
                if effective_mode == DsdOutputMode::Dop {
                    if let Err(dop_err) = verify_dop_passthrough(output_sample_rate) {
                        log::info!(
                            "[AUDIO] DoP pre-flight failed ({}), degrading to PCM decimation",
                            dop_err
                        );
                        effective_mode = DsdOutputMode::PcmDecimation;
                        let pcm_rate = {
                            let decoder = open_dsd_decoder(&path)
                                .map_err(|e| format!("Failed to probe DSD rate: {}", e))?;
                            let dsd_rate = DsdRate::from_sample_rate(decoder.sample_rate())
                                .ok_or_else(|| format!("Unsupported DSD rate"))?;
                            resolve_dsd_pcm_sample_rate(dsd_rate, 0)
                        };
                        ensure_audio_engine_excluded(
                            resolve_requested_output_sample_rate(Some(pcm_rate))?,
                            vec![OutputStrategy::DsdNative],
                        )?;
                        output_sample_rate = with_audio_engine(|handle| Ok(handle.sample_rate()))?;
                        output_channels = with_audio_engine(|handle| Ok(handle.channels()))?;
                    }
                }
                let (source, thread) = DsdDecoderThread::spawn(
                    path,
                    effective_mode,
                    output_sample_rate,
                    output_channels,
                )
                .map_err(|e| format!("Failed to decode DSD: {}", e))?;
                let is_raw = matches!(effective_mode, DsdOutputMode::Dop | DsdOutputMode::Native);
                return with_audio_engine(|handle| {
                    handle.set_dop_override(is_raw)?;
                    handle.queue_next_prepared(source, DecoderHandle::Dsd(thread))
                });
            }
            crate::audio::decoder_handle::FileType::WavPack => {
                ensure_audio_engine(resolve_requested_output_sample_rate(None)?)?;
                let (output_sample_rate, output_channels) =
                    with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
                let (source, wh) =
                    WavpackDecoderThread::spawn(path, output_sample_rate, output_channels)
                        .map_err(|e| format!("Failed to decode WavPack: {}", e))?;
                return with_audio_engine(|engine| {
                    engine.set_dop_override(false)?;
                    engine.queue_next_prepared(source, wh)
                });
            }
            crate::audio::decoder_handle::FileType::Standard => {
                clear_dsd_track_rate();
                let probe_result = probe_file(path.as_path())
                    .map_err(|error| format!("Failed to probe {}: {}", path.display(), error))?;
                ensure_audio_engine(resolve_track_playback_output_sample_rate(Some(
                    probe_result.source_info.original_sample_rate,
                ))?)?;
                let (output_sample_rate, output_channels) =
                    with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
                let file_rate = probe_result.source_info.original_sample_rate;
                if output_sample_rate != file_rate {
                    log_warn!(
                        "[AUDIO] engine_sample_rate_hz={} decoded_file_sample_rate_hz={} — decoder resampling active",
                        output_sample_rate,
                        file_rate
                    );
                } else {
                    log_info!(
                        "[AUDIO] engine_sample_rate_hz matches decoded_file_sample_rate_hz ({} Hz); decoder resampling off",
                        file_rate
                    );
                }
                let (source, decoder_thread) = DecoderThread::spawn_from_probe_result(
                    probe_result,
                    output_sample_rate,
                    output_channels,
                    None,
                )
                .map_err(|error| format!("Failed to decode {}: {}", path.display(), error))?;
                return with_audio_engine(|handle| {
                    handle.set_dop_override(false)?;
                    handle.queue_next_prepared(source, DecoderHandle::Symphonia(decoder_thread))
                });
            }
        }
    }

    let (output_sample_rate, output_channels) =
        with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
    let (source, handle) = prepare_decoder_source(&path, output_sample_rate, output_channels)?;
    let effective_mode = effective_dsd_output_mode(current_dsd_output_mode());
    let is_raw = matches!(effective_mode, DsdOutputMode::Dop | DsdOutputMode::Native);
    with_audio_engine(|engine| {
        engine.set_dop_override(is_raw)?;
        engine.queue_next_prepared(source, handle)
    })
}

/// Play a remote audio stream over HTTP. Range-support is assumed (caller
/// verifies `Accept-Ranges: bytes`); PCM only, no DSD/WavPack over HTTP.
/// Auth is carried via `headers` (e.g. WebDAV Basic) — Subsonic/Jellyfin embed
/// credentials in the URL query and pass an empty header map.
pub fn audio_play_from_http(url: String, headers: HashMap<String, String>) -> Result<(), String> {
    let probe_result = probe_http(&url, headers)
        .map_err(|e| format!("Failed to probe HTTP stream: {}", e))?;
    let file_rate = probe_result.source_info.original_sample_rate;
    ensure_audio_engine(resolve_track_playback_output_sample_rate(Some(file_rate))?)?;
    let (output_sample_rate, output_channels) =
        with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
    if output_sample_rate != file_rate {
        log_warn!(
            "[AUDIO] http: engine_sample_rate_hz={} stream_sample_rate_hz={} — decoder resampling active",
            output_sample_rate,
            file_rate
        );
    }
    let (source, decoder_thread) = DecoderThread::spawn_from_probe_result(
        probe_result,
        output_sample_rate,
        output_channels,
        None,
    )
    .map_err(|e| format!("Failed to decode HTTP stream: {}", e))?;
    with_audio_engine(|handle| {
        handle.set_dop_override(false)?;
        handle.play_prepared(source, DecoderHandle::Symphonia(decoder_thread))
    })
}

/// Queue a remote HTTP stream as the next track for gapless playback.
pub fn audio_queue_next_from_http(
    url: String,
    headers: HashMap<String, String>,
) -> Result<(), String> {
    if !audio_is_initialized() {
        let probe_result = probe_http(&url, headers)
            .map_err(|e| format!("Failed to probe HTTP stream: {}", e))?;
        let file_rate = probe_result.source_info.original_sample_rate;
        ensure_audio_engine(resolve_track_playback_output_sample_rate(Some(file_rate))?)?;
        let (output_sample_rate, output_channels) =
            with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
        let (source, decoder_thread) = DecoderThread::spawn_from_probe_result(
            probe_result,
            output_sample_rate,
            output_channels,
            None,
        )
        .map_err(|e| format!("Failed to decode HTTP stream: {}", e))?;
        return with_audio_engine(|handle| {
            handle.set_dop_override(false)?;
            handle.queue_next_prepared(source, DecoderHandle::Symphonia(decoder_thread))
        });
    }

    // Engine already live at a fixed rate: probe + queue without rate negotiation.
    let probe_result = probe_http(&url, headers)
        .map_err(|e| format!("Failed to probe HTTP stream: {}", e))?;
    let (output_sample_rate, output_channels) =
        with_audio_engine(|handle| Ok((handle.sample_rate(), handle.channels())))?;
    let (source, decoder_thread) = DecoderThread::spawn_from_probe_result(
        probe_result,
        output_sample_rate,
        output_channels,
        None,
    )
    .map_err(|e| format!("Failed to decode HTTP stream: {}", e))?;
    with_audio_engine(|handle| {
        handle.set_dop_override(false)?;
        handle.queue_next_prepared(source, DecoderHandle::Symphonia(decoder_thread))
    })
}

/// Pause playback.
pub fn audio_pause() -> Result<(), String> {
    with_audio_engine(|handle| handle.pause())
}

/// Resume playback after pause.
pub fn audio_resume() -> Result<(), String> {
    with_audio_engine(|handle| handle.resume())
}

/// Stop playback completely.
pub fn audio_stop() -> Result<(), String> {
    clear_dsd_track_rate();
    with_audio_engine(|handle| handle.stop())
}

/// Seek to a position in the current track.
pub fn audio_seek(position_secs: f64) -> Result<(), String> {
    with_audio_engine(|handle| handle.seek(position_secs))
}

/// Set the playback volume.
pub fn audio_set_volume(volume: f32) -> Result<(), String> {
    let clamped = volume.clamp(0.0, crate::audio::engine::MAX_VOLUME);
    set_pending_volume(clamped);
    let _ = with_audio_engine(|handle| handle.set_volume(clamped));
    Ok(())
}

/// Set the effective ReplayGain (dB) for the current track and as the default
/// for subsequently spawned sources (next track, seek re-spawn). 0.0 = off.
///
/// Callers compute the final value — mode gain (track/album) + preamp +
/// clipping-prevention reduction — before calling. The engine applies it as a
/// per-source linear gain; a non-zero value forces the DSP path.
pub fn audio_set_replaygain(gain_db: f32) -> Result<(), String> {
    let clamped = gain_db.clamp(-60.0, 30.0);
    with_audio_engine(|handle| handle.set_replaygain(clamped))
}

/// Set only the spawn-time default ReplayGain (dB): the running source keeps
/// its own gain while currently-playing. Used when pre-queueing the next
/// gapless track, whose gain is stamped on the newly spawned source.
pub fn audio_set_replaygain_default(gain_db: f32) -> Result<(), String> {
    let clamped = gain_db.clamp(-60.0, 30.0);
    with_audio_engine(|handle| handle.set_replaygain_default(clamped))
}

/// Set EQ: enabled and a variable list of band specs (real per-type biquads,
/// up to 31 bands). Graphic mode is expressed as 10 peaking specs.
pub fn audio_set_equalizer(enabled: bool, specs: Vec<EqBandSpec>) -> Result<(), String> {
    set_pending_equalizer(enabled, specs.clone());
    with_audio_engine(|handle| handle.set_equalizer(enabled, specs))
}

/// Set BS2B crossfeed level for the native audio engine.
/// 0 = Off, 1 = Default (BS2B middle preset), 2 = Crossfeed (high),
/// 3 = Crossfeed easy (gentle). 0 fully bypasses processing.
pub fn audio_set_crossfeed(level: u8) -> Result<(), String> {
    set_pending_crossfeed(level);
    with_audio_engine(|handle| handle.set_crossfeed(CrossfeedLevel::from_u8(level)))
}

/// Set pitch shift in semitones for the native audio engine (tempo preserved).
/// 0 = bypass. Range is clamped internally to ±12 semitones.
pub fn audio_set_pitch_shift_semitones(semitones: f32) -> Result<(), String> {
    log::info!("[PITCH] FFI audio_set_pitch_shift_semitones({semitones})");
    with_audio_engine(|handle| handle.set_pitch_shift(semitones))
}

/// Configure compressor settings for the native audio engine.
pub fn audio_set_compressor(
    enabled: bool,
    threshold_db: f32,
    ratio: f32,
    attack_ms: f32,
    release_ms: f32,
    makeup_gain_db: f32,
) -> Result<(), String> {
    with_audio_engine(|handle| {
        handle.set_compressor(
            enabled,
            threshold_db,
            ratio,
            attack_ms,
            release_ms,
            makeup_gain_db,
        )
    })
}

/// Configure limiter settings for the native audio engine.
pub fn audio_set_limiter(
    enabled: bool,
    input_gain_db: f32,
    ceiling_db: f32,
    release_ms: f32,
) -> Result<(), String> {
    with_audio_engine(|handle| handle.set_limiter(enabled, input_gain_db, ceiling_db, release_ms))
}

/// Configure spatial/time FX settings for the native audio engine.
#[allow(clippy::too_many_arguments)]
pub fn audio_set_fx(
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
) -> Result<(), String> {
    with_audio_engine(|handle| {
        handle.set_fx(
            enabled, balance, tempo, damp, filter_hz, delay_ms, size, mix, feedback, width,
        )
    })
}

/// Enable/disable the impulse-response convolver and set its wet/dry mix
/// (0.0 = dry, 1.0 = full IR).
pub fn audio_set_convolver(enabled: bool, mix: f32) -> Result<(), String> {
    with_audio_engine(|handle| handle.set_convolver(enabled, mix))
}

/// Decode an impulse-response file, resample it to the engine rate and load it
/// into the convolver. Decoding runs on this thread (not the audio callback);
/// a failure leaves the previously-loaded IR untouched.
pub fn audio_load_ir(path: String) -> Result<(), String> {
    let rate = with_audio_engine(|handle| Ok(handle.sample_rate()))?;
    let coeffs = crate::audio::ir_loader::load_ir(std::path::Path::new(&path), rate)?;
    with_audio_engine(|handle| handle.set_convolver_ir(coeffs))
}

/// Drop any loaded IR and disable the convolver.
pub fn audio_clear_ir() -> Result<(), String> {
    with_audio_engine(|handle| handle.send_command(crate::audio::commands::AudioCommand::ClearConvolverIr))
}

/// Configure crossfade settings.
///
/// The engine's own `is_crossfade_allowed()` trigger gate (plus the Dart-side
/// processing policy) authoritatively decide whether crossfade runs; the old
/// passthrough guard here was redundant and self-defeating — it blocked the
/// very `crossfade_forces_dsp` flip that lets crossfade escape passthrough.
pub fn audio_set_crossfade(enabled: bool, duration_secs: f32) -> Result<(), String> {
    set_pending_crossfade(enabled, duration_secs);
    with_audio_engine(|handle| handle.set_crossfade(enabled, duration_secs))
}

/// Skip to the next queued track.
pub fn audio_skip_to_next() -> Result<(), String> {
    with_audio_engine(|handle| handle.skip_to_next())
}

/// Set the playback speed.
pub fn audio_set_playback_speed(speed: f32) -> Result<(), String> {
    with_audio_engine(|handle| handle.set_playback_speed(speed))
}

/// Get the current playback speed.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_playback_speed() -> Option<f32> {
    read_audio_engine(|handle| handle.get_playback_speed())
}

/// Get the current playback state.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_state() -> String {
    let Some(handle_state) = read_audio_engine(|handle| handle.state()) else {
        return "uninitialized".to_string();
    };
    match handle_state {
        PlaybackState::Idle => "idle".to_string(),
        PlaybackState::Playing => "playing".to_string(),
        PlaybackState::Paused => "paused".to_string(),
        PlaybackState::Buffering => "buffering".to_string(),
        PlaybackState::Crossfading => "crossfading".to_string(),
        PlaybackState::Stopped => "stopped".to_string(),
    }
}

/// Get the current playback progress.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_progress() -> Option<AudioProgress> {
    read_audio_engine(|handle| handle.get_progress())
        .flatten()
        .map(|p| AudioProgress {
            position_secs: p.position_secs,
            duration_secs: p.duration_secs,
            buffer_level: p.buffer_level,
        })
}

/// Poll for audio events (non-blocking).
#[flutter_rust_bridge::frb(sync)]
pub fn audio_poll_event() -> Option<AudioEventType> {
    let event = read_audio_engine(|handle| handle.try_recv_event()).flatten()?;
    Some(match event {
        AudioEvent::StateChanged(state) => AudioEventType::StateChanged {
            state: match state {
                PlaybackState::Idle => "idle".to_string(),
                PlaybackState::Playing => "playing".to_string(),
                PlaybackState::Paused => "paused".to_string(),
                PlaybackState::Buffering => "buffering".to_string(),
                PlaybackState::Crossfading => "crossfading".to_string(),
                PlaybackState::Stopped => "stopped".to_string(),
            },
        },
        AudioEvent::Progress(p) => AudioEventType::Progress {
            position_secs: p.position_secs,
            duration_secs: p.duration_secs,
            buffer_level: p.buffer_level,
        },
        AudioEvent::TrackEnded { path } => AudioEventType::TrackEnded { path },
        AudioEvent::CrossfadeStarted { from_path, to_path } => {
            AudioEventType::CrossfadeStarted { from_path, to_path }
        }
        AudioEvent::Error { message } => AudioEventType::Error { message },
        AudioEvent::NextTrackReady { path } => AudioEventType::NextTrackReady { path },
    })
}

/// Set the crossfade curve type.
pub fn audio_set_crossfade_curve(curve: CrossfadeCurveType) -> Result<(), String> {
    let curve = match curve {
        CrossfadeCurveType::EqualPower => crate::audio::crossfader::CrossfadeCurve::EqualPower,
        CrossfadeCurveType::Linear => crate::audio::crossfader::CrossfadeCurve::Linear,
        CrossfadeCurveType::SquareRoot => crate::audio::crossfader::CrossfadeCurve::SquareRoot,
        CrossfadeCurveType::SCurve => crate::audio::crossfader::CrossfadeCurve::SCurve,
    };
    set_pending_crossfade_curve(curve);
    with_audio_engine(|handle| handle.set_crossfade_curve(curve))
}

/// Get the audio engine's sample rate.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_sample_rate() -> Option<u32> {
    read_audio_engine(|handle| handle.sample_rate())
}

/// Get the current track path.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_current_path() -> Option<String> {
    read_audio_engine(|handle| handle.get_current_path())
        .flatten()
        .map(|p| p.to_string_lossy().to_string())
}

/// Get the number of audio channels.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_channels() -> Option<usize> {
    read_audio_engine(|handle| handle.channels())
}

/// Shutdown the audio engine.
pub fn audio_shutdown() -> Result<(), String> {
    ENGINE_MANAGER.shutdown()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::crossfader::CrossfadeCurve;

    #[test]
    fn pending_crossfade_round_trip() {
        let _ = take_pending_crossfade();

        set_pending_crossfade(true, 5.0);
        set_pending_crossfade_curve(CrossfadeCurve::Linear);
        let (enabled, dur, curve) = take_pending_crossfade().expect("pending set");
        assert!(enabled);
        assert!((dur - 5.0).abs() < 1e-6);
        assert_eq!(curve, CrossfadeCurve::Linear);
        assert!(take_pending_crossfade().is_none(), "take must clear");

        set_pending_crossfade(false, 12.5);
        let (enabled, dur, _) = take_pending_crossfade().unwrap();
        assert!(!enabled, "disabled state must round-trip");
        assert!((dur - 12.5).abs() < 1e-6);
    }

    #[test]
    fn pending_crossfade_all_curves() {
        for (curve, expect) in [
            (CrossfadeCurve::EqualPower, CrossfadeCurve::EqualPower),
            (CrossfadeCurve::Linear, CrossfadeCurve::Linear),
            (CrossfadeCurve::SquareRoot, CrossfadeCurve::SquareRoot),
            (CrossfadeCurve::SCurve, CrossfadeCurve::SCurve),
        ] {
            let _ = take_pending_crossfade();
            set_pending_crossfade(true, 3.0);
            set_pending_crossfade_curve(curve);
            let (_, _, got) = take_pending_crossfade().unwrap();
            assert_eq!(got, expect, "curve {:?} did not round-trip", curve);
        }
    }

    #[test]
    fn pending_equalizer_round_trip() {
        let _ = take_pending_equalizer();

        let specs = vec![EqBandSpec {
            band_type: crate::audio::equalizer::EqBandType::Peaking,
            freq_hz: 1000.0,
            gain_db: 4.5,
            q: 1.2,
        }];
        set_pending_equalizer(true, specs.clone());
        let (enabled, got) = take_pending_equalizer().expect("pending set");
        assert!(enabled);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].freq_hz, 1000.0);
        assert_eq!(got[0].gain_db, 4.5);
        assert!(take_pending_equalizer().is_none(), "take must clear");

        set_pending_equalizer(false, Vec::new());
        let (enabled, got) = take_pending_equalizer().unwrap();
        assert!(!enabled, "disabled state must round-trip");
        assert!(got.is_empty());
    }
}
