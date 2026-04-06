use crate::audio::commands::AudioEvent;
use crate::audio::engine::{audio_callback, AudioCallbackData};
use crate::uac2::DescriptorIter;
use crossbeam_channel::Sender;
use libusb1_sys::{
    constants::{
        LIBUSB_TRANSFER_CANCELLED, LIBUSB_TRANSFER_COMPLETED, LIBUSB_TRANSFER_ERROR,
        LIBUSB_TRANSFER_NO_DEVICE, LIBUSB_TRANSFER_OVERFLOW, LIBUSB_TRANSFER_STALL,
        LIBUSB_TRANSFER_TIMED_OUT,
    },
    libusb_alloc_transfer, libusb_fill_iso_transfer, libusb_free_transfer, libusb_submit_transfer,
    libusb_transfer, libusb_transfer_cb_fn,
};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use rusb::{
    disable_device_discovery, supports_detach_kernel_driver, Context, Device, DeviceHandle,
    Direction, Error as UsbError, Speed, SyncType, TransferType, UsageType, UsbContext,
};
use serde::Serialize;
use std::ffi::c_void;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex as StdMutex, Once};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const USB_CLASS_AUDIO: u8 = 0x01;
const USB_SUBCLASS_AUDIOCONTROL: u8 = 0x01;
const USB_SUBCLASS_AUDIOSTREAMING: u8 = 0x02;
const USB_DT_CS_INTERFACE: u8 = 0x24;
const USB_DIR_IN: u8 = 0x80;
const USB_DIR_OUT: u8 = 0x00;
const USB_TYPE_CLASS: u8 = 0x20;
const USB_RECIP_INTERFACE: u8 = 0x01;
const UAC2_CLOCK_SOURCE: u8 = 0x0a;
const UAC2_AS_GENERAL: u8 = 0x01;
const UAC2_FORMAT_TYPE: u8 = 0x02;
const UAC2_FORMAT_TYPE_I: u8 = 0x01;
const UAC2_REQUEST_SET_CUR: u8 = 0x01;
const UAC2_REQUEST_GET_CUR: u8 = 0x81;
const UAC2_REQUEST_GET_RANGE: u8 = 0x82;
const UAC2_CLOCK_SOURCE_SAM_FREQ_CONTROL: u16 = 0x0100;
const FORMAT_TAG_PCM: u16 = 0x0001;
const FORMAT_TAG_PCM8: u16 = 0x0002;
const FORMAT_TAG_IEEE_FLOAT: u16 = 0x0003;
const ISO_TRANSFER_TIMEOUT_MS: u32 = 1000;
const ANDROID_USB_BUFFER_CAPACITY_MS: usize = 200;
const ANDROID_USB_BUFFER_TARGET_MS: usize = 100;
const ANDROID_USB_RENDER_CHUNK_MS: usize = 10;
const ANDROID_USB_RENDER_POLL_MS: u64 = 2;
const ANDROID_USB_STABLE_TRANSFER_THRESHOLD: usize = 64;
const ANDROID_USB_REQUIRE_VERIFIED_RATE_DEFAULT: bool = false;
const ANDROID_USB_CLOCK_SETTLE_DELAY_MS_DEFAULT: u64 = 20;
const ANDROID_USB_FEEDBACK_TIMEOUT_MS: u32 = 50;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DacClockPolicy {
    AllowUnverified,
    RequireVerifiedRate,
    Force48kHzOnly,
}

struct DacQuirk {
    vendor_id: u16,
    product_id: u16,
    product_name_contains: &'static str,
    clock_policy: DacClockPolicy,
    settle_delay_ms: u64,
}

const KNOWN_DAC_QUIRKS: &[DacQuirk] = &[DacQuirk {
    vendor_id: 12230,
    product_id: 61546,
    product_name_contains: "MOONDROP Dawn Pro",
    clock_policy: DacClockPolicy::AllowUnverified,
    settle_delay_ms: 50,
}];

fn lookup_dac_quirk(
    vendor_id: u16,
    product_id: u16,
    product_name: &str,
) -> Option<&'static DacQuirk> {
    for quirk in KNOWN_DAC_QUIRKS {
        if quirk.vendor_id == vendor_id
            && quirk.product_id == product_id
            && product_name.contains(quirk.product_name_contains)
        {
            return Some(quirk);
        }
    }
    None
}

#[derive(Debug, Clone)]
pub struct AndroidDirectUsbDevice {
    pub fd: RawFd,
    pub vendor_id: u16,
    pub product_id: u16,
    pub product_name: String,
    pub manufacturer: String,
    pub serial: Option<String>,
    pub device_name: Option<String>,
}

#[derive(Debug, Clone, Copy)]
pub struct AndroidDirectUsbPlaybackFormat {
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub channels: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DacMode {
    FullControl,
    FixedClock,
    AdaptiveStreaming,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AndroidDirectUsbEngineState {
    Idle,
    UsbInit,
    UsbReady,
    Streaming,
    Error,
    Fallback,
}

#[derive(Debug, Clone)]
struct AndroidDirectUsbLifecycleState {
    engine_state: AndroidDirectUsbEngineState,
    reason: Option<String>,
}

impl Default for AndroidDirectUsbLifecycleState {
    fn default() -> Self {
        Self {
            engine_state: AndroidDirectUsbEngineState::Idle,
            reason: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct AndroidDirectUsbDebugState {
    pub registered: bool,
    pub engine_state: Option<String>,
    pub engine_state_reason: Option<String>,
    pub requested_playback_sample_rate: Option<u32>,
    pub requested_playback_bit_depth: Option<u8>,
    pub requested_playback_channels: Option<u16>,
    pub device_name: Option<String>,
    pub product_name: Option<String>,
    pub playback_format_sample_rate: Option<u32>,
    pub playback_format_bit_depth: Option<u8>,
    pub playback_format_channels: Option<u16>,
    pub lock_requested: bool,
    pub stream_active: bool,
    pub idle_lock_held: bool,
    pub active_interface_number: Option<u8>,
    pub active_alt_setting: Option<u8>,
    pub active_endpoint_address: Option<u8>,
    pub active_endpoint_interval: Option<u8>,
    pub active_service_interval_us: Option<u32>,
    pub active_max_packet_bytes: Option<usize>,
    pub transport_format: Option<String>,
    pub transport_channels: Option<u16>,
    pub transport_subslot_size: Option<u8>,
    pub transport_bit_resolution: Option<u8>,
    pub advertised_sample_rates: Vec<u32>,
    pub active_sync_type: Option<String>,
    pub active_usage_type: Option<String>,
    pub active_refresh: Option<u8>,
    pub active_synch_address: Option<u8>,
    pub clock_interface_number: Option<u8>,
    pub clock_id: Option<u8>,
    pub clock_requested_sample_rate: Option<u32>,
    pub clock_reported_sample_rate: Option<u32>,
    pub clock_control_attempted: bool,
    pub clock_control_succeeded: bool,
    pub clock_verification_passed: bool,
    pub require_verified_rate: bool,
    pub dac_clock_policy: Option<String>,
    pub dac_mode: Option<String>,
    pub resampling_active: bool,
    pub last_error: Option<String>,
    pub direct_mode_refusal_reason: Option<String>,
    pub usb_stream_stable: bool,
    pub bit_perfect_verified: bool,
    pub software_volume_active: bool,
    pub feedback_endpoint_present: bool,
    pub feedback_endpoint_address: Option<u8>,
    pub feedback_transfer_type: Option<String>,
    pub packet_schedule_frames_preview: Vec<u32>,
    pub supported_sample_rates: Vec<u32>,
    pub supported_bit_depths: Vec<u8>,
    pub supported_channels: Vec<u16>,
    pub available_alt_settings: Vec<AndroidDirectUsbAltCapability>,
    pub buffer_fill_ms: Option<u32>,
    pub buffer_capacity_ms: Option<u32>,
    pub buffer_target_ms: Option<u32>,
    pub frames_per_packet: Option<u32>,
    pub underrun_count: Option<u64>,
    pub producer_frames: Option<u64>,
    pub consumer_frames: Option<u64>,
    pub drift_ms_from_target: Option<i32>,
}

#[derive(Debug, Clone)]
struct AndroidDirectUsbState {
    device: AndroidDirectUsbDevice,
    requested_playback_format: Option<AndroidDirectUsbPlaybackFormat>,
    playback_format: Option<AndroidDirectUsbPlaybackFormat>,
    lock_requested: bool,
    stream_active: bool,
    active_transport: Option<AndroidDirectUsbActiveTransport>,
    capability_model: Option<AndroidDirectUsbCapabilityModel>,
    clock_status: Option<AndroidDirectUsbClockStatus>,
    clock_control_attempted: bool,
    clock_control_succeeded: bool,
    clock_verification_passed: bool,
    require_verified_rate: bool,
    dac_clock_policy: DacClockPolicy,
    dac_mode: DacMode,
    last_error: Option<String>,
    direct_mode_refusal_reason: Option<String>,
    usb_stream_stable: bool,
    bit_perfect_verified: bool,
    software_volume_active: bool,
    packet_schedule_frames_preview: Vec<u32>,
    runtime_stats: Option<Arc<AndroidDirectUsbRuntimeStats>>,
}

#[derive(Debug, Clone)]
struct AndroidDirectUsbActiveTransport {
    interface_number: u8,
    alt_setting: u8,
    endpoint_address: u8,
    endpoint_interval: u8,
    service_interval_us: u32,
    max_packet_bytes: usize,
    format_tag: String,
    channels: u16,
    subslot_size: u8,
    bit_resolution: u8,
    sample_rates: Vec<u32>,
    sync_type: String,
    usage_type: String,
    refresh: u8,
    synch_address: u8,
    feedback_endpoint_address: Option<u8>,
    feedback_transfer_type: Option<String>,
}

#[derive(Debug, Clone)]
struct AndroidDirectUsbClockStatus {
    interface_number: u8,
    clock_id: u8,
    requested_sample_rate: u32,
    reported_sample_rate: Option<u32>,
}

#[derive(Debug, Clone)]
struct AndroidDirectUsbClockApplyOutcome {
    clock_ok: bool,
    rate_verified: bool,
    reported_sample_rate: Option<u32>,
    known_mismatch: bool,
    message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Default)]
struct AndroidDirectUsbCapabilityModel {
    supported_sample_rates: Vec<u32>,
    supported_bit_depths: Vec<u8>,
    supported_channels: Vec<u16>,
    alt_settings: Vec<AndroidDirectUsbAltCapability>,
}

#[derive(Debug, Clone, Serialize)]
struct AndroidDirectUsbAltCapability {
    interface_number: u8,
    alt_setting: u8,
    endpoint_address: u8,
    endpoint_interval: u8,
    service_interval_us: u32,
    max_packet_bytes: usize,
    format_tag: String,
    channels: u16,
    subslot_size: u8,
    bit_resolution: u8,
    sample_rates: Vec<u32>,
    sync_type: String,
    usage_type: String,
    refresh: u8,
    synch_address: u8,
}

#[derive(Debug)]
struct AndroidDirectUsbRuntimeStats {
    sample_rate: u32,
    channels: usize,
    buffer_capacity_samples: usize,
    buffer_target_samples: usize,
    frames_per_packet: AtomicUsize,
    buffered_samples: AtomicUsize,
    underrun_count: AtomicU64,
    producer_frames: AtomicU64,
    consumer_frames: AtomicU64,
}

#[derive(Debug)]
struct AndroidDirectUsbPcmRingBuffer {
    samples: Vec<i32>,
    capacity_samples: usize,
    read_index: usize,
    write_index: usize,
    len_samples: usize,
    last_frame: Vec<i32>,
}

struct AndroidDirectUsbLock {
    device_fd: RawFd,
    context: Context,
    handle: DeviceHandle<Context>,
    claimed_interfaces: Vec<u8>,
}

struct AndroidDirectUsbClaimedHandle {
    device_fd: RawFd,
    context: Context,
    handle: DeviceHandle<Context>,
    claimed_interfaces: Vec<u8>,
}

#[derive(Debug)]
struct AndroidIsoStreamCandidate {
    interface_number: u8,
    alt_setting: u8,
    endpoint_address: u8,
    endpoint_interval: u8,
    service_interval_us: u32,
    max_packet_bytes: usize,
    sync_type: SyncType,
    usage_type: UsageType,
    format_tag: u16,
    channels: u16,
    subslot_size: u8,
    bit_resolution: u8,
    sample_rates: Vec<u32>,
    refresh: u8,
    synch_address: u8,
    feedback_endpoint: Option<AndroidUsbFeedbackEndpoint>,
}

#[derive(Debug, Clone, Copy)]
struct AndroidUsbFeedbackEndpoint {
    address: u8,
    transfer_type: TransferType,
    interval: u8,
    service_interval_us: u32,
    max_packet_bytes: usize,
}

#[derive(Debug, Clone, Copy)]
struct AudioControlClock {
    interface_number: u8,
    clock_id: u8,
}

#[derive(Debug, Clone, Copy)]
struct SamplingFrequencySubrange {
    min: u32,
    max: u32,
    res: u32,
}

#[derive(Debug)]
struct IsoPacketScheduler {
    sample_rate: u32,
    service_interval_us: u32,
    nominal_remainder: u64,
    bytes_per_frame: usize,
    packets_per_transfer: usize,
    feedback_frames_per_packet: Option<f64>,
    feedback_remainder: f64,
}

#[derive(Debug, Clone)]
struct AndroidStreamingInterfaceFormat {
    format_tag: u16,
    channels: u16,
    subslot_size: u8,
    bit_resolution: u8,
    sample_rates: Vec<u32>,
}

#[derive(Debug)]
struct IsoTransferCompletion {
    status: StdMutex<Option<i32>>,
    condvar: Condvar,
}

#[derive(Debug)]
struct IsoTransferUserData {
    completion: Arc<IsoTransferCompletion>,
    buffer: Vec<u8>,
}

impl AndroidDirectUsbRuntimeStats {
    fn new(sample_rate: u32, channels: usize, capacity_ms: usize, target_ms: usize) -> Self {
        let frames_per_ms = sample_rate as usize / 1_000;
        let capacity_frames = frames_per_ms.saturating_mul(capacity_ms);
        let target_frames = frames_per_ms.saturating_mul(target_ms);
        let capacity_samples = capacity_frames.saturating_mul(channels);
        let target_samples = target_frames.saturating_mul(channels);

        Self {
            sample_rate,
            channels,
            buffer_capacity_samples: capacity_samples,
            buffer_target_samples: target_samples,
            frames_per_packet: AtomicUsize::new(0),
            buffered_samples: AtomicUsize::new(0),
            underrun_count: AtomicU64::new(0),
            producer_frames: AtomicU64::new(0),
            consumer_frames: AtomicU64::new(0),
        }
    }

    fn buffer_fill_ms(&self) -> u32 {
        samples_to_millis(
            self.buffered_samples.load(Ordering::Relaxed),
            self.sample_rate,
            self.channels,
        )
    }

    fn buffer_capacity_ms(&self) -> u32 {
        samples_to_millis(
            self.buffer_capacity_samples,
            self.sample_rate,
            self.channels,
        )
    }

    fn buffer_target_ms(&self) -> u32 {
        samples_to_millis(self.buffer_target_samples, self.sample_rate, self.channels)
    }

    fn drift_ms_from_target(&self) -> i32 {
        let buffered_samples = self.buffered_samples.load(Ordering::Relaxed) as i64;
        let target_samples = self.buffer_target_samples as i64;
        let sample_delta = buffered_samples - target_samples;
        if self.sample_rate == 0 || self.channels == 0 {
            return 0;
        }
        ((sample_delta * 1_000) / (self.sample_rate as i64 * self.channels as i64)) as i32
    }
}

impl AndroidDirectUsbPcmRingBuffer {
    fn new(capacity_samples: usize, channels: usize) -> Self {
        let min_capacity = channels.max(1) * 4;
        Self {
            samples: vec![0; capacity_samples.max(min_capacity)],
            capacity_samples: capacity_samples.max(min_capacity),
            read_index: 0,
            write_index: 0,
            len_samples: 0,
            last_frame: vec![0; channels.max(1)],
        }
    }

    fn len_samples(&self) -> usize {
        self.len_samples
    }

    fn push_samples(&mut self, input: &[i32]) -> usize {
        if input.is_empty() || self.capacity_samples == 0 {
            return 0;
        }

        let writable = input
            .len()
            .min(self.capacity_samples.saturating_sub(self.len_samples));
        for sample in input.iter().take(writable) {
            self.samples[self.write_index] = *sample;
            self.write_index = (self.write_index + 1) % self.capacity_samples;
        }
        self.len_samples += writable;
        writable
    }

    fn pop_into_or_pad(&mut self, output: &mut [i32], channels: usize) -> bool {
        if output.is_empty() {
            return false;
        }

        let readable = output.len().min(self.len_samples);
        for destination in output.iter_mut().take(readable) {
            *destination = self.samples[self.read_index];
            self.read_index = (self.read_index + 1) % self.capacity_samples;
        }
        self.len_samples -= readable;

        if readable >= channels && self.last_frame.len() == channels {
            let frame_start = readable - channels;
            self.last_frame
                .copy_from_slice(&output[frame_start..readable]);
        }

        let underrun = readable < output.len();
        if underrun {
            let mut index = readable;
            while index < output.len() {
                for channel in 0..channels {
                    if index >= output.len() {
                        break;
                    }
                    output[index] = *self.last_frame.get(channel).unwrap_or(&0);
                    index += 1;
                }
            }
        }

        underrun
    }
}

fn samples_to_millis(samples: usize, sample_rate: u32, channels: usize) -> u32 {
    if sample_rate == 0 || channels == 0 {
        return 0;
    }
    ((samples as u64 * 1_000) / (sample_rate as u64 * channels as u64)) as u32
}

pub struct AndroidDirectUsbBackend {
    stop: Arc<AtomicBool>,
    producer_thread_handle: Option<JoinHandle<()>>,
    usb_thread_handle: Option<JoinHandle<()>>,
}

static DIRECT_USB_STATE: Lazy<Mutex<Option<AndroidDirectUsbState>>> =
    Lazy::new(|| Mutex::new(None));
static DIRECT_USB_LOCK: Lazy<Mutex<Option<AndroidDirectUsbLock>>> = Lazy::new(|| Mutex::new(None));
static DIRECT_USB_LIFECYCLE_STATE: Lazy<Mutex<AndroidDirectUsbLifecycleState>> =
    Lazy::new(|| Mutex::new(AndroidDirectUsbLifecycleState::default()));
static DIRECT_USB_DISCOVERY_DISABLED: Once = Once::new();
static ANDROID_DIRECT_USB_ENABLED: AtomicBool = AtomicBool::new(true);

pub fn set_android_direct_usb_enabled(enabled: bool) {
    ANDROID_DIRECT_USB_ENABLED.store(enabled, Ordering::Release);
}

fn android_direct_usb_enabled() -> bool {
    ANDROID_DIRECT_USB_ENABLED.load(Ordering::Acquire)
}

pub fn register_android_usb_device(device: AndroidDirectUsbDevice) -> Result<(), String> {
    let existing_format = DIRECT_USB_STATE
        .lock()
        .as_ref()
        .and_then(|state| state.playback_format);
    let existing_lock_requested = DIRECT_USB_STATE
        .lock()
        .as_ref()
        .map(|state| state.lock_requested)
        .unwrap_or(false);

    let capability_model = inspect_android_usb_capabilities(&device).ok();
    let dac_clock_policy =
        lookup_dac_quirk(device.vendor_id, device.product_id, &device.product_name)
            .map(|quirk| quirk.clock_policy)
            .unwrap_or(DacClockPolicy::AllowUnverified);

    let require_verified_rate = match dac_clock_policy {
        DacClockPolicy::RequireVerifiedRate => true,
        DacClockPolicy::Force48kHzOnly | DacClockPolicy::AllowUnverified => {
            ANDROID_USB_REQUIRE_VERIFIED_RATE_DEFAULT
        }
    };

    release_idle_lock();
    set_android_usb_engine_state(AndroidDirectUsbEngineState::Idle, None);
    *DIRECT_USB_STATE.lock() = Some(AndroidDirectUsbState {
        device,
        requested_playback_format: existing_format,
        playback_format: existing_format,
        lock_requested: existing_lock_requested,
        stream_active: false,
        active_transport: None,
        capability_model,
        clock_status: None,
        clock_control_attempted: false,
        clock_control_succeeded: false,
        clock_verification_passed: false,
        require_verified_rate,
        dac_clock_policy,
        dac_mode: DacMode::FullControl,
        last_error: None,
        direct_mode_refusal_reason: None,
        usb_stream_stable: false,
        bit_perfect_verified: false,
        software_volume_active: false,
        packet_schedule_frames_preview: Vec::new(),
        runtime_stats: None,
    });
    if existing_lock_requested {
        ensure_android_usb_idle_lock()?;
    }
    Ok(())
}

pub fn set_android_usb_playback_format(
    playback_format: Option<AndroidDirectUsbPlaybackFormat>,
) -> Result<(), String> {
    let mut guard = DIRECT_USB_STATE.lock();
    let Some(state) = guard.as_mut() else {
        return if playback_format.is_some() {
            Err("No Android direct USB DAC is registered".to_string())
        } else {
            Ok(())
        };
    };

    let sanitized = playback_format.map(|format| {
        let mut format = sanitize_android_usb_playback_format(format);
        match state.dac_clock_policy {
            DacClockPolicy::Force48kHzOnly => {}
            DacClockPolicy::RequireVerifiedRate | DacClockPolicy::AllowUnverified => {}
        }
        format
    });

    state.playback_format = sanitized;
    state.requested_playback_format = sanitized;
    state.clock_status = None;
    state.clock_control_attempted = false;
    state.clock_control_succeeded = false;
    state.clock_verification_passed = false;
    state.dac_mode = DacMode::FullControl;
    state.usb_stream_stable = false;
    state.bit_perfect_verified = false;
    state.software_volume_active = false;
    state.packet_schedule_frames_preview.clear();
    state.direct_mode_refusal_reason = None;
    state.runtime_stats = None;
    set_android_usb_engine_state(AndroidDirectUsbEngineState::Idle, None);
    Ok(())
}

pub fn set_android_usb_lock_enabled(enabled: bool) -> Result<(), String> {
    let stream_active = {
        let mut guard = DIRECT_USB_STATE.lock();
        let Some(state) = guard.as_mut() else {
            if enabled {
                return Err("No Android direct USB DAC is registered".to_string());
            }
            release_idle_lock();
            return Ok(());
        };

        state.lock_requested = enabled;
        state.stream_active
    };

    if enabled {
        if !stream_active {
            ensure_android_usb_idle_lock()?;
        }
    } else {
        release_idle_lock();
    }

    Ok(())
}

pub fn clear_android_usb_device() {
    release_idle_lock();
    if DIRECT_USB_LIFECYCLE_STATE.lock().engine_state != AndroidDirectUsbEngineState::Fallback {
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Idle, None);
    }
    *DIRECT_USB_STATE.lock() = None;
}

pub fn android_direct_output_signature(preferred_sample_rate: Option<u32>) -> Option<String> {
    if !android_direct_usb_enabled() {
        return None;
    }

    let guard = DIRECT_USB_STATE.lock();
    let state = guard.as_ref()?;
    let playback_format = state.playback_format?;

    if preferred_sample_rate != Some(playback_format.sample_rate) {
        return None;
    }

    Some(format!(
        "android-uac2:{}:{}:{}:{}:{}",
        state.device.fd,
        playback_format.sample_rate,
        playback_format.bit_depth,
        playback_format.channels,
        state.device.device_name.as_deref().unwrap_or("usb"),
    ))
}

pub fn validate_android_direct_request(preferred_sample_rate: Option<u32>) -> Result<(), String> {
    if !android_direct_usb_enabled() {
        return Ok(());
    }

    let guard = DIRECT_USB_STATE.lock();
    let Some(state) = guard.as_ref() else {
        return Ok(());
    };
    let Some(playback_format) = state.playback_format else {
        return Ok(());
    };

    if preferred_sample_rate == Some(playback_format.sample_rate) {
        return Ok(());
    }

    Err(format!(
        "Android direct USB DAC '{}' is prepared for {} Hz, but the track requires {:?} Hz",
        state.device.product_name, playback_format.sample_rate, preferred_sample_rate
    ))
}

pub fn android_direct_debug_state() -> AndroidDirectUsbDebugState {
    let state = DIRECT_USB_STATE.lock().clone();
    let idle_lock_held = DIRECT_USB_LOCK.lock().is_some();
    let lifecycle_state = DIRECT_USB_LIFECYCLE_STATE.lock().clone();

    let Some(state) = state else {
        return AndroidDirectUsbDebugState {
            idle_lock_held,
            engine_state: Some(android_direct_usb_engine_state_label(
                lifecycle_state.engine_state,
            )
            .to_string()),
            engine_state_reason: lifecycle_state.reason,
            ..Default::default()
        };
    };

    let active_transport = state.active_transport.as_ref();
    let clock_status = state.clock_status.as_ref();
    let runtime_stats = state.runtime_stats.as_ref();
    let capability_model = state.capability_model.as_ref();

    AndroidDirectUsbDebugState {
        registered: true,
        engine_state: Some(android_direct_usb_engine_state_label(
            lifecycle_state.engine_state,
        )
        .to_string()),
        engine_state_reason: lifecycle_state.reason,
        requested_playback_sample_rate: state
            .requested_playback_format
            .map(|format| format.sample_rate),
        requested_playback_bit_depth: state
            .requested_playback_format
            .map(|format| format.bit_depth),
        requested_playback_channels: state
            .requested_playback_format
            .map(|format| format.channels),
        device_name: state.device.device_name,
        product_name: Some(state.device.product_name),
        playback_format_sample_rate: state.playback_format.map(|format| format.sample_rate),
        playback_format_bit_depth: state.playback_format.map(|format| format.bit_depth),
        playback_format_channels: state.playback_format.map(|format| format.channels),
        lock_requested: state.lock_requested,
        stream_active: state.stream_active,
        idle_lock_held,
        active_interface_number: active_transport.map(|transport| transport.interface_number),
        active_alt_setting: active_transport.map(|transport| transport.alt_setting),
        active_endpoint_address: active_transport.map(|transport| transport.endpoint_address),
        active_endpoint_interval: active_transport.map(|transport| transport.endpoint_interval),
        active_service_interval_us: active_transport.map(|transport| transport.service_interval_us),
        active_max_packet_bytes: active_transport.map(|transport| transport.max_packet_bytes),
        transport_format: active_transport.map(|transport| transport.format_tag.clone()),
        transport_channels: active_transport.map(|transport| transport.channels),
        transport_subslot_size: active_transport.map(|transport| transport.subslot_size),
        transport_bit_resolution: active_transport.map(|transport| transport.bit_resolution),
        advertised_sample_rates: active_transport
            .map(|transport| transport.sample_rates.clone())
            .unwrap_or_default(),
        active_sync_type: active_transport.map(|transport| transport.sync_type.clone()),
        active_usage_type: active_transport.map(|transport| transport.usage_type.clone()),
        active_refresh: active_transport.map(|transport| transport.refresh),
        active_synch_address: active_transport.map(|transport| transport.synch_address),
        clock_interface_number: clock_status.map(|clock| clock.interface_number),
        clock_id: clock_status.map(|clock| clock.clock_id),
        clock_requested_sample_rate: clock_status.map(|clock| clock.requested_sample_rate),
        clock_reported_sample_rate: clock_status.and_then(|clock| clock.reported_sample_rate),
        clock_control_attempted: state.clock_control_attempted,
        clock_control_succeeded: state.clock_control_succeeded,
        clock_verification_passed: state.clock_verification_passed,
        require_verified_rate: state.require_verified_rate,
        dac_clock_policy: Some(match state.dac_clock_policy {
            DacClockPolicy::AllowUnverified => "allowUnverified".to_string(),
            DacClockPolicy::RequireVerifiedRate => "requireVerifiedRate".to_string(),
            DacClockPolicy::Force48kHzOnly => "force48kHzOnly".to_string(),
        }),
        dac_mode: Some(match state.dac_mode {
            DacMode::FullControl => "fullControl".to_string(),
            DacMode::FixedClock => "fixedClock".to_string(),
            DacMode::AdaptiveStreaming => "adaptiveStreaming".to_string(),
        }),
        resampling_active: state
            .requested_playback_format
            .zip(state.playback_format)
            .is_some_and(|(requested, effective)| requested.sample_rate != effective.sample_rate),
        last_error: state.last_error,
        direct_mode_refusal_reason: state.direct_mode_refusal_reason,
        usb_stream_stable: state.usb_stream_stable,
        bit_perfect_verified: state.bit_perfect_verified,
        software_volume_active: state.software_volume_active,
        feedback_endpoint_present: active_transport
            .map(|transport| transport.feedback_endpoint_address.is_some())
            .unwrap_or(false),
        feedback_endpoint_address: active_transport
            .and_then(|transport| transport.feedback_endpoint_address),
        feedback_transfer_type: active_transport
            .and_then(|transport| transport.feedback_transfer_type.clone()),
        packet_schedule_frames_preview: state.packet_schedule_frames_preview,
        supported_sample_rates: capability_model
            .map(|capabilities| capabilities.supported_sample_rates.clone())
            .unwrap_or_default(),
        supported_bit_depths: capability_model
            .map(|capabilities| capabilities.supported_bit_depths.clone())
            .unwrap_or_default(),
        supported_channels: capability_model
            .map(|capabilities| capabilities.supported_channels.clone())
            .unwrap_or_default(),
        available_alt_settings: capability_model
            .map(|capabilities| capabilities.alt_settings.clone())
            .unwrap_or_default(),
        buffer_fill_ms: runtime_stats.map(|stats| stats.buffer_fill_ms()),
        buffer_capacity_ms: runtime_stats.map(|stats| stats.buffer_capacity_ms()),
        buffer_target_ms: runtime_stats.map(|stats| stats.buffer_target_ms()),
        frames_per_packet: runtime_stats
            .map(|stats| stats.frames_per_packet.load(Ordering::Relaxed) as u32)
            .filter(|frames| *frames > 0),
        underrun_count: runtime_stats.map(|stats| stats.underrun_count.load(Ordering::Relaxed)),
        producer_frames: runtime_stats.map(|stats| stats.producer_frames.load(Ordering::Relaxed)),
        consumer_frames: runtime_stats.map(|stats| stats.consumer_frames.load(Ordering::Relaxed)),
        drift_ms_from_target: runtime_stats.map(|stats| stats.drift_ms_from_target()),
    }
}

pub fn android_direct_preferred_sample_rate(preferred_sample_rate: Option<u32>) -> Option<u32> {
    DIRECT_USB_STATE
        .lock()
        .as_ref()
        .and_then(|state| state.playback_format.map(|format| format.sample_rate))
        .or(preferred_sample_rate)
}

pub fn negotiate_android_direct_output_sample_rate(
    preferred_sample_rate: Option<u32>,
) -> Result<Option<u32>, String> {
    if !android_direct_usb_enabled() {
        return Ok(None);
    }

    let requested_format = {
        let mut guard = DIRECT_USB_STATE.lock();
        let Some(state) = guard.as_mut() else {
            return Ok(preferred_sample_rate);
        };
        let Some(mut requested_format) = state.requested_playback_format.or(state.playback_format)
        else {
            return Ok(preferred_sample_rate);
        };
        if let Some(rate) = preferred_sample_rate {
            requested_format.sample_rate = rate.max(8_000);
        }
        state.requested_playback_format = Some(requested_format);
        state.playback_format = Some(requested_format);
        state.clock_status = None;
        state.clock_control_attempted = false;
        state.clock_control_succeeded = false;
        state.clock_verification_passed = false;
        state.dac_mode = DacMode::FullControl;
        state.direct_mode_refusal_reason = None;
        requested_format
    };

    negotiate_android_direct_playback_format(requested_format)
        .map(|format| Some(format.sample_rate))
}

fn negotiate_android_direct_playback_format(
    requested_format: AndroidDirectUsbPlaybackFormat,
) -> Result<AndroidDirectUsbPlaybackFormat, String> {
    let device = {
        let guard = DIRECT_USB_STATE.lock();
        let Some(state) = guard.as_ref() else {
            return Ok(requested_format);
        };
        state.device.clone()
    };

    let mut claimed_handle = open_claimed_usb_handle(&device)?;
    let lock_requested = current_lock_requested_for_fd(device.fd);
    let mut cleanup_interface: Option<u8> = None;
    let negotiated = (|| {
        let usb_device = claimed_handle.handle.device();
        let speed = usb_device.speed();
        let capability_model = build_android_usb_capability_model(&usb_device, speed).ok();
        set_capability_model(capability_model.clone());
        let clock = find_audio_control_clock(&usb_device);

        let candidate = match select_stream_candidate(&usb_device, requested_format, speed) {
            Ok(c) => c,
            Err(error) => {
                set_last_error(Some(error.clone()));
                set_direct_mode_refusal_reason(Some(error.clone()));
                return Err(error);
            }
        };

        if let Err(error) = claimed_handle.ensure_interface_claimed(candidate.interface_number) {
            set_last_error(Some(error.clone()));
            set_direct_mode_refusal_reason(Some(error.clone()));
            return Err(error);
        }

        if let Err(error) = claimed_handle
            .handle
            .set_alternate_setting(candidate.interface_number, 0)
        {
            let msg = format!(
                "Failed to reset USB interface {} to alt 0 before negotiation: {}",
                candidate.interface_number, error
            );
            set_last_error(Some(msg.clone()));
            set_direct_mode_refusal_reason(Some(msg.clone()));
            return Err(msg);
        }
        cleanup_interface = Some(candidate.interface_number);
        thread::sleep(Duration::from_millis(100));

        let mut effective_format = requested_format;
        let mut dac_mode = DacMode::FullControl;
        let mut clock_attempted = false;
        let mut clock_succeeded = false;
        let mut rate_verified = false;
        let mut reported_rate = None;
        let mut last_message = None;

        if let Some(clock) = clock {
            set_clock_status(Some(AndroidDirectUsbClockStatus {
                interface_number: clock.interface_number,
                clock_id: clock.clock_id,
                requested_sample_rate: requested_format.sample_rate,
                reported_sample_rate: None,
            }));
            let current_rate = get_sampling_frequency(
                &claimed_handle.handle,
                clock.interface_number,
                clock.clock_id,
            )
            .ok();
            let supported_ranges = get_sampling_frequency_ranges(
                &claimed_handle.handle,
                clock.interface_number,
                clock.clock_id,
            )
            .ok();

            if supported_ranges.as_ref().is_some_and(|ranges| {
                sampling_frequency_ranges_support_rate(ranges, requested_format.sample_rate)
            }) || supported_ranges.is_none()
            {
                eprintln!(
                    "Android USB direct [NEGOTIATION] engineType=USB_DAC_EXPERIMENTAL, usbClaimed={}, altSetting={}, endpointAddress=0x{:02x}, sampleRateSent={} Hz",
                    claimed_handle.claimed_interfaces.contains(&candidate.interface_number),
                    candidate.alt_setting,
                    candidate.endpoint_address,
                    requested_format.sample_rate,
                );
                let clock_outcome = apply_sampling_frequency(
                    &claimed_handle.handle,
                    clock.interface_number,
                    clock.clock_id,
                    requested_format.sample_rate,
                    ANDROID_USB_CLOCK_SETTLE_DELAY_MS_DEFAULT,
                );
                clock_attempted = true;
                clock_succeeded = clock_outcome.clock_ok;
                rate_verified = clock_outcome.rate_verified;
                reported_rate = clock_outcome.reported_sample_rate.or(current_rate);
                last_message = clock_outcome.message.clone();
                eprintln!(
                    "Android USB direct [CLOCK] sampleRateConfirmed={} Hz, clockOk={}, rateVerified={}, clockId={}, interfaceNumber={}",
                    clock_outcome.reported_sample_rate.unwrap_or(0),
                    clock_outcome.clock_ok,
                    clock_outcome.rate_verified,
                    clock.clock_id,
                    clock.interface_number,
                );
                if clock_outcome.rate_verified
                    && clock_outcome.reported_sample_rate == Some(requested_format.sample_rate)
                {
                    dac_mode = DacMode::FullControl;
                    set_effective_playback_format(requested_format);
                    set_dac_mode(dac_mode);
                    set_clock_verification(
                        clock_attempted,
                        clock_succeeded,
                        rate_verified,
                        reported_rate,
                    );
                    if let Some(message) = last_message {
                        eprintln!("Android USB direct: {}", message);
                    }
                    return Ok(requested_format);
                }
            } else {
                last_message = supported_ranges.as_ref().map(|ranges| {
                    format!(
                        "Requested {} Hz is not supported by clock {} on interface {}; supported rates: {}",
                        requested_format.sample_rate,
                        clock.clock_id,
                        clock.interface_number,
                        format_sampling_frequency_ranges(ranges),
                    )
                });
            }

            if let Some(actual_rate) = choose_adaptive_sample_rate(
                requested_format.sample_rate,
                current_rate,
                supported_ranges.as_deref(),
                capability_model.as_ref(),
                &usb_device,
                speed,
                requested_format,
            )? {
                effective_format.sample_rate = actual_rate;
                dac_mode = if actual_rate == requested_format.sample_rate {
                    DacMode::FixedClock
                } else {
                    DacMode::AdaptiveStreaming
                };
                reported_rate = reported_rate.or(current_rate).or(Some(actual_rate));
                rate_verified =
                    current_rate == Some(actual_rate) || reported_rate == Some(actual_rate);
            } else {
                let message = last_message.unwrap_or_else(|| {
                    format!(
                        "Unable to verify DAC rate for requested {} Hz during negotiation; continuing with direct USB at the requested stream rate",
                        requested_format.sample_rate
                    )
                });
                reported_rate = reported_rate.or(current_rate).or(Some(requested_format.sample_rate));
                last_message = Some(message);
            }
        } else if let Some(actual_rate) = choose_adaptive_sample_rate(
            requested_format.sample_rate,
            None,
            None,
            capability_model.as_ref(),
            &usb_device,
            speed,
            requested_format,
        )? {
            effective_format.sample_rate = actual_rate;
            dac_mode = if actual_rate == requested_format.sample_rate {
                DacMode::FixedClock
            } else {
                DacMode::AdaptiveStreaming
            };
            let inferred_message = if actual_rate == requested_format.sample_rate {
                format!(
                    "Android USB direct: no clock control entity; using fixed clock {} Hz",
                    actual_rate
                )
            } else {
                format!(
                    "Android USB direct: SET_CUR unavailable or unsupported; using adaptive mode at {} Hz for requested {} Hz",
                    actual_rate, requested_format.sample_rate
                )
            };
            eprintln!("{}", inferred_message);
            last_message = Some(inferred_message);
        } else {
            let message = format!(
                "Unable to determine a usable fixed clock rate for requested {} Hz during negotiation; continuing direct USB with assumed stream rate",
                requested_format.sample_rate
            );
            reported_rate = Some(requested_format.sample_rate);
            last_message = Some(message);
        }

        reported_rate = reported_rate.or(Some(effective_format.sample_rate));
        set_effective_playback_format(effective_format);
        set_dac_mode(dac_mode);
        set_clock_verification(
            clock_attempted,
            clock_succeeded,
            rate_verified,
            reported_rate,
        );
        if let Some(message) = last_message {
            eprintln!("Android USB direct: {}", message);
        }
        Ok(effective_format)
    })();

    cleanup_claimed_handle(claimed_handle, cleanup_interface, lock_requested);
    negotiated
}

fn choose_adaptive_sample_rate(
    requested_sample_rate: u32,
    current_rate: Option<u32>,
    supported_ranges: Option<&[SamplingFrequencySubrange]>,
    capability_model: Option<&AndroidDirectUsbCapabilityModel>,
    device: &Device<Context>,
    speed: Speed,
    requested_format: AndroidDirectUsbPlaybackFormat,
) -> Result<Option<u32>, String> {
    let has_rate_evidence = current_rate.is_some()
        || supported_ranges.is_some_and(|ranges| !ranges.is_empty())
        || capability_model
            .is_some_and(|capabilities| !capabilities.supported_sample_rates.is_empty());

    if !has_rate_evidence {
        return Ok(None);
    }

    let mut candidates = Vec::new();
    if let Some(current_rate) = current_rate {
        candidates.push(current_rate);
    }
    if let Some(ranges) = supported_ranges {
        candidates.extend(candidate_rates_from_supported_ranges(
            ranges,
            requested_sample_rate,
        ));
    }
    if let Some(capability_model) = capability_model {
        candidates.extend(capability_model.supported_sample_rates.iter().copied());
    }
    candidates.sort_unstable();
    candidates.dedup();

    let mut ordered_candidates = Vec::new();
    if let Some(current_rate) = current_rate {
        ordered_candidates.push(current_rate);
    }
    ordered_candidates.extend(preferred_adaptive_sample_rates(requested_sample_rate));
    if let Some(ranges) = supported_ranges {
        ordered_candidates.extend(candidate_rates_from_supported_ranges(
            ranges,
            requested_sample_rate,
        ));
    }
    ordered_candidates.extend(candidates);
    ordered_candidates.sort_unstable();
    ordered_candidates.dedup();

    for candidate_rate in ordered_candidates {
        let candidate_format = AndroidDirectUsbPlaybackFormat {
            sample_rate: candidate_rate,
            ..requested_format
        };
        if select_stream_candidate(device, candidate_format, speed).is_ok() {
            return Ok(Some(candidate_rate));
        }
    }

    Ok(None)
}

fn preferred_adaptive_sample_rates(requested_sample_rate: u32) -> Vec<u32> {
    let mut preferred = Vec::new();
    for rate in [
        requested_sample_rate,
        48_000,
        96_000,
        192_000,
        384_000,
        44_100,
        88_200,
        176_400,
        352_800,
    ] {
        if !preferred.contains(&rate) {
            preferred.push(rate);
        }
    }
    preferred
}

fn candidate_rates_from_supported_ranges(
    ranges: &[SamplingFrequencySubrange],
    requested_sample_rate: u32,
) -> Vec<u32> {
    let mut candidates = Vec::new();
    let preferred = preferred_adaptive_sample_rates(requested_sample_rate);

    for range in ranges {
        if range.res == 0 || range.min == range.max {
            candidates.push(range.min);
            continue;
        }

        for rate in preferred.iter().copied() {
            if sampling_frequency_ranges_support_rate(std::slice::from_ref(range), rate) {
                candidates.push(rate);
            }
        }

        candidates.push(range.min);
        if range.max != range.min {
            candidates.push(range.max);
        }
    }

    candidates.sort_unstable();
    candidates.dedup();
    candidates
}

fn sanitize_android_usb_playback_format(
    playback_format: AndroidDirectUsbPlaybackFormat,
) -> AndroidDirectUsbPlaybackFormat {
    AndroidDirectUsbPlaybackFormat {
        sample_rate: playback_format.sample_rate.max(8_000),
        bit_depth: match playback_format.bit_depth {
            16 | 24 | 32 => playback_format.bit_depth,
            _ => 16,
        },
        channels: playback_format.channels.max(1),
    }
}

fn prepare_direct_usb_libusb() {
    DIRECT_USB_DISCOVERY_DISABLED.call_once(|| {
        if let Err(error) = disable_device_discovery() {
            eprintln!(
                "Android USB direct: failed to disable libusb device discovery: {}",
                error
            );
        }
    });
}

fn current_lock_requested_for_fd(device_fd: RawFd) -> bool {
    DIRECT_USB_STATE
        .lock()
        .as_ref()
        .map(|state| state.lock_requested && state.device.fd == device_fd)
        .unwrap_or(false)
}

fn set_last_error(error: Option<String>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.last_error = error;
    }
}

fn set_direct_mode_refusal_reason(reason: Option<String>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.direct_mode_refusal_reason = reason;
    }
}

fn set_usb_stream_stable(stable: bool) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.usb_stream_stable = stable;
    }
}

fn set_software_volume_active(active: bool) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.software_volume_active = active;
        state.bit_perfect_verified = direct_path_is_bit_perfect(state);
    }
}

fn set_runtime_stats(runtime_stats: Option<Arc<AndroidDirectUsbRuntimeStats>>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.runtime_stats = runtime_stats;
    }
}

fn set_capability_model(capability_model: Option<AndroidDirectUsbCapabilityModel>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.capability_model = capability_model;
    }
}

fn set_active_transport(candidate: Option<&AndroidIsoStreamCandidate>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.active_transport = candidate.map(|candidate| AndroidDirectUsbActiveTransport {
            interface_number: candidate.interface_number,
            alt_setting: candidate.alt_setting,
            endpoint_address: candidate.endpoint_address,
            endpoint_interval: candidate.endpoint_interval,
            service_interval_us: candidate.service_interval_us,
            max_packet_bytes: candidate.max_packet_bytes,
            format_tag: format_tag_label(candidate.format_tag).to_string(),
            channels: candidate.channels,
            subslot_size: candidate.subslot_size,
            bit_resolution: candidate.bit_resolution,
            sample_rates: candidate.sample_rates.clone(),
            sync_type: sync_type_label(candidate.sync_type).to_string(),
            usage_type: usage_type_label(candidate.usage_type).to_string(),
            refresh: candidate.refresh,
            synch_address: candidate.synch_address,
            feedback_endpoint_address: candidate.feedback_endpoint.map(|feedback| feedback.address),
            feedback_transfer_type: candidate
                .feedback_endpoint
                .map(|feedback| transfer_type_label(feedback.transfer_type).to_string()),
        });
    }
}

fn android_direct_usb_engine_state_label(state: AndroidDirectUsbEngineState) -> &'static str {
    match state {
        AndroidDirectUsbEngineState::Idle => "idle",
        AndroidDirectUsbEngineState::UsbInit => "usbInit",
        AndroidDirectUsbEngineState::UsbReady => "usbReady",
        AndroidDirectUsbEngineState::Streaming => "streaming",
        AndroidDirectUsbEngineState::Error => "error",
        AndroidDirectUsbEngineState::Fallback => "fallback",
    }
}

fn set_android_usb_engine_state(state: AndroidDirectUsbEngineState, reason: Option<String>) {
    let mut lifecycle_state = DIRECT_USB_LIFECYCLE_STATE.lock();
    lifecycle_state.engine_state = state;
    lifecycle_state.reason = reason;
    eprintln!(
        "[USB][STATE] {}{}",
        android_direct_usb_engine_state_label(state),
        lifecycle_state
            .reason
            .as_ref()
            .map(|reason| format!(" ({})", reason))
            .unwrap_or_default()
    );
}

pub fn mark_android_usb_fallback(reason: Option<String>) {
    set_android_usb_engine_state(AndroidDirectUsbEngineState::Fallback, reason);
}

fn set_clock_status(clock_status: Option<AndroidDirectUsbClockStatus>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.clock_status = clock_status;
    }
}

fn set_clock_verification(
    attempted: bool,
    succeeded: bool,
    passed: bool,
    reported_sample_rate: Option<u32>,
) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.clock_control_attempted = attempted;
        state.clock_control_succeeded = succeeded;
        state.clock_verification_passed = passed;
        if let Some(clock_status) = state.clock_status.as_mut() {
            clock_status.reported_sample_rate = reported_sample_rate;
        }
        state.bit_perfect_verified = direct_path_is_bit_perfect(state);
    }
}

fn direct_path_is_bit_perfect(state: &AndroidDirectUsbState) -> bool {
    if !state.clock_verification_passed || state.software_volume_active {
        return false;
    }

    let Some(requested) = state.requested_playback_format else {
        return false;
    };
    let Some(effective) = state.playback_format else {
        return false;
    };

    requested.sample_rate == effective.sample_rate
        && requested.bit_depth == effective.bit_depth
        && requested.channels == effective.channels
}

fn set_effective_playback_format(playback_format: AndroidDirectUsbPlaybackFormat) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.playback_format = Some(playback_format);
    }
}

fn set_dac_mode(mode: DacMode) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.dac_mode = mode;
    }
}

fn stream_descriptor_verifies_rate(
    candidate: &AndroidIsoStreamCandidate,
    sample_rate: u32,
) -> bool {
    !candidate.sample_rates.is_empty() && candidate.sample_rates.contains(&sample_rate)
}

fn set_packet_schedule_preview(packet_schedule_frames_preview: Vec<u32>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.packet_schedule_frames_preview = packet_schedule_frames_preview;
    }
}

fn set_stream_active(active: bool) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.stream_active = active;
    }
}

fn release_idle_lock() {
    if let Some(lock) = DIRECT_USB_LOCK.lock().take() {
        release_claimed_interfaces(&lock.handle, &lock.claimed_interfaces);
    }
}

fn release_claimed_interfaces(handle: &DeviceHandle<Context>, interfaces: &[u8]) {
    let mut released = interfaces.to_vec();
    released.sort_unstable();
    released.dedup();
    released.reverse();

    for interface_number in released {
        let _ = handle.set_alternate_setting(interface_number, 0);
        let _ = handle.release_interface(interface_number);
    }
}

impl From<AndroidDirectUsbLock> for AndroidDirectUsbClaimedHandle {
    fn from(value: AndroidDirectUsbLock) -> Self {
        Self {
            device_fd: value.device_fd,
            context: value.context,
            handle: value.handle,
            claimed_interfaces: value.claimed_interfaces,
        }
    }
}

impl AndroidDirectUsbClaimedHandle {
    fn into_idle_lock(self) -> AndroidDirectUsbLock {
        AndroidDirectUsbLock {
            device_fd: self.device_fd,
            context: self.context,
            handle: self.handle,
            claimed_interfaces: self.claimed_interfaces,
        }
    }

    fn ensure_interface_claimed(&mut self, interface_number: u8) -> Result<(), String> {
        if self.claimed_interfaces.contains(&interface_number) {
            return Ok(());
        }

        claim_interface_with_recovery(&self.handle, interface_number)?;
        self.claimed_interfaces.push(interface_number);
        self.claimed_interfaces.sort_unstable();
        self.claimed_interfaces.dedup();
        Ok(())
    }
}

fn configure_kernel_driver_detach(handle: &DeviceHandle<Context>) {
    if !supports_detach_kernel_driver() {
        eprintln!(
            "Android USB direct: libusb kernel-driver detach is not supported on this platform"
        );
        return;
    }

    match handle.set_auto_detach_kernel_driver(true) {
        Ok(()) => {
            eprintln!("Android USB direct: enabled libusb auto-detach for claimed interfaces");
        }
        Err(UsbError::NotSupported) => {
            eprintln!(
                "Android USB direct: libusb auto-detach is not supported for this device handle"
            );
        }
        Err(error) => {
            eprintln!(
                "Android USB direct: failed to enable libusb auto-detach: {}",
                error
            );
        }
    }
}

fn claim_interface_with_recovery(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
) -> Result<(), String> {
    match handle.claim_interface(interface_number) {
        Ok(()) => return Ok(()),
        Err(initial_error) => {
            let mut details = vec![format!("initial claim failed: {}", initial_error)];

            if !supports_detach_kernel_driver() {
                return Err(format!(
                    "Failed to claim USB interface {}: {}",
                    interface_number,
                    details.join("; ")
                ));
            }

            match handle.kernel_driver_active(interface_number) {
                Ok(true) => {
                    details.push("kernel driver is active".to_string());
                    match handle.detach_kernel_driver(interface_number) {
                        Ok(()) => {
                            details.push("detached kernel driver".to_string());
                        }
                        Err(error) => {
                            details.push(format!("kernel-driver detach failed: {}", error));
                        }
                    }
                }
                Ok(false) => {
                    details.push("kernel driver is not active".to_string());
                }
                Err(error) => {
                    details.push(format!("kernel_driver_active failed: {}", error));
                }
            }

            match handle.claim_interface(interface_number) {
                Ok(()) => {
                    eprintln!(
                        "Android USB direct claimed interface {} after kernel-driver recovery",
                        interface_number
                    );
                    return Ok(());
                }
                Err(retry_error) => {
                    details.push(format!("retry claim failed: {}", retry_error));
                    return Err(format!(
                        "Failed to claim USB interface {}: {}",
                        interface_number,
                        details.join("; ")
                    ));
                }
            }
        }
    }
}

fn open_claimed_usb_handle(
    device: &AndroidDirectUsbDevice,
) -> Result<AndroidDirectUsbClaimedHandle, String> {
    if let Some(lock) = DIRECT_USB_LOCK.lock().take() {
        if lock.device_fd == device.fd {
            return Ok(lock.into());
        }

        release_claimed_interfaces(&lock.handle, &lock.claimed_interfaces);
    }

    prepare_direct_usb_libusb();

    let context =
        Context::new().map_err(|error| format!("Failed to create libusb context: {}", error))?;
    let handle = unsafe { context.open_device_with_fd(device.fd) }
        .map_err(|error| format!("Failed to wrap Android USB file descriptor: {}", error))?;
    configure_kernel_driver_detach(&handle);

    Ok(AndroidDirectUsbClaimedHandle {
        device_fd: device.fd,
        context,
        handle,
        claimed_interfaces: Vec::new(),
    })
}

fn inspect_android_usb_capabilities(
    device: &AndroidDirectUsbDevice,
) -> Result<AndroidDirectUsbCapabilityModel, String> {
    prepare_direct_usb_libusb();
    let context =
        Context::new().map_err(|error| format!("Failed to create libusb context: {}", error))?;
    let handle = unsafe { context.open_device_with_fd(device.fd) }
        .map_err(|error| format!("Failed to wrap Android USB file descriptor: {}", error))?;
    let inspected_device = handle.device();
    build_android_usb_capability_model(&inspected_device, inspected_device.speed())
}

fn build_android_usb_capability_model(
    device: &Device<Context>,
    speed: Speed,
) -> Result<AndroidDirectUsbCapabilityModel, String> {
    let config_descriptor = device
        .active_config_descriptor()
        .map_err(|error| format!("Failed to read active USB config descriptor: {}", error))?;

    let mut alt_settings = Vec::new();
    let mut supported_sample_rates = Vec::new();
    let mut supported_bit_depths = Vec::new();
    let mut supported_channels = Vec::new();

    for interface in config_descriptor.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() != USB_CLASS_AUDIO
                || descriptor.sub_class_code() != USB_SUBCLASS_AUDIOSTREAMING
            {
                continue;
            }

            let Some(stream_format) = parse_android_streaming_interface_format(&descriptor) else {
                continue;
            };

            for endpoint in descriptor.endpoint_descriptors() {
                if endpoint.direction() != Direction::Out
                    || endpoint.transfer_type() != TransferType::Isochronous
                {
                    continue;
                }

                let service_interval_us = service_interval_micros(speed, endpoint.interval());
                let max_packet_bytes =
                    effective_iso_packet_bytes(endpoint.max_packet_size(), speed);

                supported_bit_depths.push(stream_format.bit_resolution);
                supported_channels.push(stream_format.channels);
                supported_sample_rates.extend(stream_format.sample_rates.iter().copied());
                alt_settings.push(AndroidDirectUsbAltCapability {
                    interface_number: descriptor.interface_number(),
                    alt_setting: descriptor.setting_number(),
                    endpoint_address: endpoint.address(),
                    endpoint_interval: endpoint.interval(),
                    service_interval_us,
                    max_packet_bytes,
                    format_tag: format_tag_label(stream_format.format_tag).to_string(),
                    channels: stream_format.channels,
                    subslot_size: stream_format.subslot_size,
                    bit_resolution: stream_format.bit_resolution,
                    sample_rates: stream_format.sample_rates.clone(),
                    sync_type: sync_type_label(endpoint.sync_type()).to_string(),
                    usage_type: usage_type_label(endpoint.usage_type()).to_string(),
                    refresh: endpoint.refresh(),
                    synch_address: endpoint.synch_address(),
                });
            }
        }
    }

    supported_sample_rates.sort_unstable();
    supported_sample_rates.dedup();
    supported_bit_depths.sort_unstable();
    supported_bit_depths.dedup();
    supported_channels.sort_unstable();
    supported_channels.dedup();
    alt_settings.sort_by_key(|alt| {
        (
            alt.interface_number,
            alt.alt_setting,
            alt.endpoint_address,
            alt.bit_resolution,
            alt.max_packet_bytes,
        )
    });

    Ok(AndroidDirectUsbCapabilityModel {
        supported_sample_rates,
        supported_bit_depths,
        supported_channels,
        alt_settings,
    })
}

fn cleanup_claimed_handle(
    mut claimed_handle: AndroidDirectUsbClaimedHandle,
    active_interface: Option<u8>,
    keep_locked: bool,
) {
    if let Some(interface_number) = active_interface {
        let _ = claimed_handle
            .handle
            .set_alternate_setting(interface_number, 0);
    }

    if keep_locked {
        if let Ok(interfaces) = discover_audio_streaming_interfaces(&claimed_handle.handle.device())
        {
            for interface_number in interfaces {
                let _ = claimed_handle.ensure_interface_claimed(interface_number);
            }
        }

        *DIRECT_USB_LOCK.lock() = Some(claimed_handle.into_idle_lock());
        return;
    }

    release_claimed_interfaces(&claimed_handle.handle, &claimed_handle.claimed_interfaces);
}

fn ensure_android_usb_idle_lock() -> Result<(), String> {
    if DIRECT_USB_LOCK.lock().is_some() {
        return Ok(());
    }

    let state = DIRECT_USB_STATE
        .lock()
        .as_ref()
        .cloned()
        .ok_or_else(|| "No Android direct USB DAC is registered".to_string())?;
    let mut claimed_handle = open_claimed_usb_handle(&state.device).map_err(|error| {
        set_last_error(Some(error.clone()));
        set_direct_mode_refusal_reason(Some(error.clone()));
        set_android_usb_engine_state(
            AndroidDirectUsbEngineState::Error,
            Some(error.clone()),
        );
        error
    })?;

    let interfaces = discover_audio_streaming_interfaces(&claimed_handle.handle.device())?;
    for interface_number in interfaces {
        claimed_handle.ensure_interface_claimed(interface_number)?;
    }

    eprintln!(
        "Android USB direct idle lock claimed '{}' interfaces {:?}",
        state.device.product_name, claimed_handle.claimed_interfaces
    );

    *DIRECT_USB_LOCK.lock() = Some(claimed_handle.into_idle_lock());
    Ok(())
}

pub fn create_android_usb_backend(
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    preferred_sample_rate: u32,
) -> Result<Option<AndroidDirectUsbBackend>, String> {
    let (state, playback_format, use_requested_playback_format) = {
        let guard = DIRECT_USB_STATE.lock();
        let Some(state) = guard.as_ref() else {
            eprintln!(
                "Android USB direct backend skipped: no registered DAC state for preferred {} Hz",
                preferred_sample_rate
            );
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some("No registered Android USB DAC state was available".to_string()),
            );
            return Ok(None);
        };
        let Some(effective_playback_format) = state.playback_format else {
            eprintln!(
                "Android USB direct backend skipped: no effective playback format is configured for '{}' (preferred {} Hz, requested {:?})",
                state.device.product_name,
                preferred_sample_rate,
                state.requested_playback_format.map(|format| format.sample_rate),
            );
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some("No effective Android USB playback format was configured".to_string()),
            );
            return Ok(None);
        };
        let requested_playback_format =
            state.requested_playback_format.unwrap_or(effective_playback_format);
        let (playback_format, use_requested_playback_format) =
            if effective_playback_format.sample_rate == preferred_sample_rate {
                (effective_playback_format, false)
            } else if requested_playback_format.sample_rate == preferred_sample_rate {
                eprintln!(
                    "Android USB direct backend: preferred {} Hz matched requested playback format for '{}' while effective playback format was {} Hz; using requested format",
                    preferred_sample_rate,
                    state.device.product_name,
                    effective_playback_format.sample_rate,
                );
                (requested_playback_format, true)
            } else {
                eprintln!(
                    "Android USB direct backend skipped: preferred {} Hz did not match effective {} Hz or requested {} Hz for '{}'",
                    preferred_sample_rate,
                    effective_playback_format.sample_rate,
                    requested_playback_format.sample_rate,
                    state.device.product_name,
                );
                set_android_usb_engine_state(
                    AndroidDirectUsbEngineState::Error,
                    Some(format!(
                        "Prepared playback rate did not match requested startup rate {} Hz",
                        preferred_sample_rate
                    )),
                );
                return Ok(None);
            };
        debug_assert_eq!(playback_format.sample_rate, preferred_sample_rate);
        (
            state.clone(),
            playback_format,
            use_requested_playback_format,
        )
    };
    if use_requested_playback_format {
        set_effective_playback_format(playback_format);
    }
    set_android_usb_engine_state(AndroidDirectUsbEngineState::UsbInit, None);
    let clock_settle_delay_ms = lookup_dac_quirk(
        state.device.vendor_id,
        state.device.product_id,
        &state.device.product_name,
    )
    .map(|quirk| quirk.settle_delay_ms)
    .unwrap_or(ANDROID_USB_CLOCK_SETTLE_DELAY_MS_DEFAULT);

    let mut claimed_handle = open_claimed_usb_handle(&state.device).map_err(|error| {
        set_last_error(Some(error.clone()));
        set_direct_mode_refusal_reason(Some(error.clone()));
        set_android_usb_engine_state(
            AndroidDirectUsbEngineState::Error,
            Some(error.clone()),
        );
        error
    })?;
    let requested_playback_format = state.requested_playback_format.unwrap_or(playback_format);
    let device = claimed_handle.handle.device();
    let speed = device.speed();
    let lock_requested = current_lock_requested_for_fd(state.device.fd);
    set_capability_model(build_android_usb_capability_model(&device, speed).ok());
    let candidate = match select_stream_candidate(&device, playback_format, speed) {
        Ok(candidate) => candidate,
        Err(error) => {
            set_last_error(Some(error.clone()));
            set_direct_mode_refusal_reason(Some(error.clone()));
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some(error.clone()),
            );
            cleanup_claimed_handle(claimed_handle, None, lock_requested);
            return Err(error);
        }
    };
    let clock = find_audio_control_clock(&device);

    set_last_error(None);
    set_direct_mode_refusal_reason(None);
    set_usb_stream_stable(false);
    set_active_transport(Some(&candidate));
    set_clock_status(clock.map(|clock| {
        AndroidDirectUsbClockStatus {
            interface_number: clock.interface_number,
            clock_id: clock.clock_id,
            requested_sample_rate: playback_format.sample_rate,
            reported_sample_rate: state
                .clock_status
                .as_ref()
                .and_then(|status| status.reported_sample_rate),
        }
    }));
    set_clock_verification(
        state.clock_control_attempted,
        state.clock_control_succeeded,
        state.clock_verification_passed,
        state
            .clock_status
            .as_ref()
            .and_then(|status| status.reported_sample_rate),
    );

    eprintln!(
        "[USB] Candidate device='{}' mode={:?} requested={}Hz effective={}Hz resampling={} endpoint=0x{:02x} interface={} alt={} clock={} feedbackEndpoint={} sync={:?} usage={:?} service={}us maxPacket={} speed={:?} fmt={} channels={} subslot={} bitResolution={} sampleRates={:?}",
        state.device.product_name,
        state.dac_mode,
        requested_playback_format.sample_rate,
        playback_format.sample_rate,
        requested_playback_format.sample_rate != playback_format.sample_rate,
        candidate.endpoint_address,
        candidate.interface_number,
        candidate.alt_setting,
        clock.map(|clock| clock.clock_id).unwrap_or_default(),
        candidate
            .feedback_endpoint
            .map(|feedback| format!(
                "0x{:02x}/{}",
                feedback.address,
                transfer_type_label(feedback.transfer_type)
            ))
            .unwrap_or_else(|| "none".to_string()),
        candidate.sync_type,
        candidate.usage_type,
        candidate.service_interval_us,
        candidate.max_packet_bytes,
        speed,
        format_tag_label(candidate.format_tag),
        candidate.channels,
        candidate.subslot_size,
        candidate.bit_resolution,
        candidate.sample_rates,
    );

    eprintln!(
        "[USB] Interface={} alt={} endpoint=0x{:02x} syncAddress=0x{:02x} interval={} serviceIntervalUs={} refresh={}",
        candidate.interface_number,
        candidate.alt_setting,
        candidate.endpoint_address,
        candidate.synch_address,
        candidate.endpoint_interval,
        candidate.service_interval_us,
        candidate.refresh,
    );

    if let Err(error) = claimed_handle.ensure_interface_claimed(candidate.interface_number) {
        set_last_error(Some(error.clone()));
        set_direct_mode_refusal_reason(Some(error.clone()));
        set_android_usb_engine_state(
            AndroidDirectUsbEngineState::Error,
            Some(error.clone()),
        );
        cleanup_claimed_handle(claimed_handle, None, lock_requested);
        return Err(error);
    }

    if supports_detach_kernel_driver() {
        if claimed_handle
            .handle
            .kernel_driver_active(candidate.interface_number)
            .unwrap_or(false)
        {
            let _ = claimed_handle
                .handle
                .detach_kernel_driver(candidate.interface_number);
            thread::sleep(Duration::from_millis(100));
        }
    }

    if let Err(error) = claimed_handle.ensure_interface_claimed(candidate.interface_number) {
        set_last_error(Some(error.clone()));
        set_direct_mode_refusal_reason(Some(error.clone()));
        set_android_usb_engine_state(
            AndroidDirectUsbEngineState::Error,
            Some(error.clone()),
        );
        cleanup_claimed_handle(claimed_handle, None, lock_requested);
        return Err(error);
    }

    claimed_handle
        .handle
        .set_alternate_setting(candidate.interface_number, 0)
        .ok();
    thread::sleep(Duration::from_millis(100));

    let mut clock_control_attempted = state.clock_control_attempted;
    let mut clock_control_succeeded = state.clock_control_succeeded;
    let mut clock_verification_passed = state.clock_verification_passed;
    let mut reported_sample_rate = state
        .clock_status
        .as_ref()
        .and_then(|status| status.reported_sample_rate);

    if let Some(clock) = clock {
        match state.dac_mode {
            DacMode::FullControl => {
                let clock_already_verified = state.clock_verification_passed
                    && state.clock_status.as_ref().is_some_and(|status| {
                        status.interface_number == clock.interface_number
                            && status.clock_id == clock.clock_id
                            && status.reported_sample_rate == Some(playback_format.sample_rate)
                    });

                if clock_already_verified {
                    eprintln!(
                        "Android USB direct: reusing verified USB clock {} on interface {} at {} Hz; skipping redundant SET_CUR before alt {}",
                        clock.clock_id,
                        clock.interface_number,
                        playback_format.sample_rate,
                        candidate.alt_setting,
                    );
                } else {
                    let clock_outcome = apply_sampling_frequency(
                        &claimed_handle.handle,
                        clock.interface_number,
                        clock.clock_id,
                        playback_format.sample_rate,
                        clock_settle_delay_ms,
                    );
                    clock_control_attempted = true;
                    clock_control_succeeded = clock_outcome.clock_ok;
                    reported_sample_rate = clock_outcome.reported_sample_rate;
                    clock_verification_passed = clock_outcome.rate_verified
                        && clock_outcome.reported_sample_rate == Some(playback_format.sample_rate);
                    set_clock_verification(
                        clock_control_attempted,
                        clock_control_succeeded,
                        clock_verification_passed,
                        reported_sample_rate,
                    );

                    eprintln!(
                        "Android USB direct [CLOCK] sampleRateConfirmed={} Hz, clockOk={}, rateVerified={}, clockId={}, interfaceNumber={}",
                        clock_outcome.reported_sample_rate.unwrap_or(0),
                        clock_outcome.clock_ok,
                        clock_outcome.rate_verified,
                        clock.clock_id,
                        clock.interface_number,
                    );

                    if let Some(message) = clock_outcome.message.as_ref() {
                        eprintln!("Android USB direct: {}", message);
                    }
                    if !clock_outcome.clock_ok {
                        eprintln!(
                            "[USB] SET_CUR {}Hz -> FAILED (continuing direct USB, reported={}Hz, verified={})",
                            playback_format.sample_rate,
                            clock_outcome
                                .reported_sample_rate
                                .unwrap_or(playback_format.sample_rate),
                            clock_verification_passed,
                        );
                    }

                    if clock_outcome.known_mismatch {
                        eprintln!(
                            "[USB] SET_CUR {}Hz -> MISMATCH (continuing direct USB, DAC reports {}Hz, verified={})",
                            playback_format.sample_rate,
                            clock_outcome
                                .reported_sample_rate
                                .unwrap_or_default(),
                            clock_verification_passed,
                        );
                    }

                    if state.require_verified_rate && !clock_verification_passed {
                        eprintln!(
                            "[USB] DAC verification is unavailable for {}Hz on clock {} / interface {}; continuing direct USB with unverified rate",
                            playback_format.sample_rate,
                            clock.clock_id,
                            clock.interface_number,
                        );
                    }
                }

                if let Err(error) = claimed_handle
                    .handle
                    .set_alternate_setting(candidate.interface_number, candidate.alt_setting)
                {
                    let msg = format!(
                        "Failed to set USB alt setting {} on interface {}: {}",
                        candidate.alt_setting, candidate.interface_number, error
                    );
                    set_last_error(Some(msg.clone()));
                    set_direct_mode_refusal_reason(Some(msg.clone()));
                    set_android_usb_engine_state(
                        AndroidDirectUsbEngineState::Error,
                        Some(msg.clone()),
                    );
                    cleanup_claimed_handle(claimed_handle, None, lock_requested);
                    return Err(msg);
                }
                thread::sleep(Duration::from_millis(50));

                eprintln!(
                    "Android USB direct [VALIDATION] engineType=USB_DAC_EXPERIMENTAL, usbClaimed={}, altSetting={}, endpointAddress=0x{:02x}, sampleRateSent={} Hz",
                    claimed_handle.claimed_interfaces.contains(&candidate.interface_number),
                    candidate.alt_setting,
                    candidate.endpoint_address,
                    playback_format.sample_rate,
                );
            }
            DacMode::FixedClock | DacMode::AdaptiveStreaming => {
                reported_sample_rate = get_sampling_frequency(
                    &claimed_handle.handle,
                    clock.interface_number,
                    clock.clock_id,
                )
                .ok()
                .or(reported_sample_rate);

                if let Some(actual_rate) = reported_sample_rate {
                    if actual_rate != playback_format.sample_rate {
                        let message = format!(
                            "Android USB direct: DAC reports {} Hz while stream is configured for {} Hz; continuing direct USB with unverified clock",
                            actual_rate, playback_format.sample_rate
                        );
                        set_clock_verification(
                            clock_control_attempted,
                            clock_control_succeeded,
                            false,
                            Some(actual_rate),
                        );
                        eprintln!("{}", message);
                        eprintln!(
                            "[USB] Actual sample rate={}Hz verified=false (reported by DAC, requested {}Hz)",
                            actual_rate,
                            playback_format.sample_rate,
                        );
                        clock_verification_passed = false;
                    } else {
                        clock_verification_passed = true;
                    }
                } else if stream_descriptor_verifies_rate(&candidate, playback_format.sample_rate) {
                    reported_sample_rate = Some(playback_format.sample_rate);
                    clock_verification_passed = true;
                    eprintln!(
                        "Android USB direct: using descriptor-advertised fixed clock {} Hz on alt setting {} without SET_CUR",
                        playback_format.sample_rate, candidate.alt_setting
                    );
                } else {
                    let message = format!(
                        "Android USB direct could not verify fixed clock {} Hz for alt setting {}; continuing with assumed stream rate",
                        playback_format.sample_rate, candidate.alt_setting
                    );
                    reported_sample_rate = Some(playback_format.sample_rate);
                    set_clock_verification(
                        clock_control_attempted,
                        clock_control_succeeded,
                        false,
                        reported_sample_rate,
                    );
                    eprintln!("{}", message);
                }

                set_clock_verification(
                    clock_control_attempted,
                    clock_control_succeeded,
                    clock_verification_passed,
                    reported_sample_rate,
                );
            }
        }
    } else if stream_descriptor_verifies_rate(&candidate, playback_format.sample_rate) {
        clock_verification_passed = true;
        reported_sample_rate = Some(playback_format.sample_rate);
        set_clock_verification(
            clock_control_attempted,
            clock_control_succeeded,
            true,
            reported_sample_rate,
        );
        eprintln!(
            "Android USB direct: no clock entity; using descriptor-advertised fixed rate {} Hz on alt setting {}",
            playback_format.sample_rate, candidate.alt_setting
        );
    } else {
        let message = format!(
            "Android USB direct cannot verify {} Hz: no usable clock entity and alt setting {} does not advertise that rate; continuing with assumed stream rate",
            playback_format.sample_rate, candidate.alt_setting
        );
        reported_sample_rate = Some(playback_format.sample_rate);
        set_clock_verification(
            clock_control_attempted,
            clock_control_succeeded,
            false,
            reported_sample_rate,
        );
        eprintln!("{}", message);
    }

    if !claimed_handle
        .claimed_interfaces
        .contains(&candidate.interface_number)
    {
        let refusal = format!(
            "Android USB direct refused: interface {} not claimed (endpoint=0x{:02x}, alt={})",
            candidate.interface_number, candidate.endpoint_address, candidate.alt_setting
        );
        set_last_error(Some(refusal.clone()));
        set_direct_mode_refusal_reason(Some(refusal.clone()));
        set_android_usb_engine_state(
            AndroidDirectUsbEngineState::Error,
            Some(refusal.clone()),
        );
        cleanup_claimed_handle(
            claimed_handle,
            Some(candidate.interface_number),
            lock_requested,
        );
        return Err(refusal);
    }

    if candidate.alt_setting == 0 {
        let refusal = format!(
            "Android USB direct refused: invalid alt setting 0 on interface {} (endpoint=0x{:02x})",
            candidate.interface_number, candidate.endpoint_address
        );
        set_last_error(Some(refusal.clone()));
        set_direct_mode_refusal_reason(Some(refusal.clone()));
        set_android_usb_engine_state(
            AndroidDirectUsbEngineState::Error,
            Some(refusal.clone()),
        );
        cleanup_claimed_handle(
            claimed_handle,
            Some(candidate.interface_number),
            lock_requested,
        );
        return Err(refusal);
    }

    if candidate.endpoint_address == 0 {
        let refusal =
            "Android USB direct refused: no valid isochronous OUT endpoint found".to_string();
        set_last_error(Some(refusal.clone()));
        set_direct_mode_refusal_reason(Some(refusal.clone()));
        cleanup_claimed_handle(
            claimed_handle,
            Some(candidate.interface_number),
            lock_requested,
        );
        return Err(refusal);
    }

    eprintln!(
        "Android USB direct output opened '{}' requested {} Hz / {}-bit / {} ch, transport {} / {} ch / {}-byte subslot on endpoint 0x{:02x} (interface {}, alt {}, speed {:?})",
        state.device.product_name,
        playback_format.sample_rate,
        playback_format.bit_depth,
        playback_format.channels,
        format_tag_label(candidate.format_tag),
        candidate.channels,
        candidate.subslot_size,
        candidate.endpoint_address,
        candidate.interface_number,
        candidate.alt_setting,
        speed,
    );

    if !clock_verification_passed {
        reported_sample_rate = reported_sample_rate.or(Some(playback_format.sample_rate));
        set_clock_verification(
            clock_control_attempted,
            clock_control_succeeded,
            false,
            reported_sample_rate,
        );
        eprintln!(
            "[USB] Actual sample rate is unverified for {}Hz playback; continuing direct USB with assumed/reported rate {}Hz",
            playback_format.sample_rate,
            reported_sample_rate.unwrap_or(playback_format.sample_rate),
        );
    }

    set_last_error(None);
    set_direct_mode_refusal_reason(None);
    set_stream_active(true);
    set_android_usb_engine_state(AndroidDirectUsbEngineState::UsbReady, None);
    set_software_volume_active((callback_data.get_volume() - 1.0).abs() > 0.000_1);
    let runtime_stats = Arc::new(AndroidDirectUsbRuntimeStats::new(
        playback_format.sample_rate,
        playback_format.channels as usize,
        ANDROID_USB_BUFFER_CAPACITY_MS,
        ANDROID_USB_BUFFER_TARGET_MS,
    ));
    set_runtime_stats(Some(Arc::clone(&runtime_stats)));
    let mut preview_scheduler = IsoPacketScheduler::new(
        playback_format.sample_rate,
        candidate.subslot_size as usize * candidate.channels as usize,
        candidate.service_interval_us,
    );
    let packet_schedule_preview = preview_scheduler
        .next_transfer_packet_bytes()
        .into_iter()
        .map(|packet_bytes| {
            (packet_bytes / (candidate.subslot_size as usize * candidate.channels as usize)) as u32
        })
        .collect::<Vec<_>>();
    set_packet_schedule_preview(packet_schedule_preview);
    let pcm_buffer = Arc::new(Mutex::new(AndroidDirectUsbPcmRingBuffer::new(
        runtime_stats.buffer_capacity_samples,
        playback_format.channels as usize,
    )));
    let stop = Arc::new(AtomicBool::new(false));
    let producer_stop = Arc::clone(&stop);
    let producer_buffer = Arc::clone(&pcm_buffer);
    let producer_stats = Arc::clone(&runtime_stats);
    let producer_callback_data = Arc::clone(&callback_data);
    let producer_event_tx = event_tx.clone();
    let producer_thread_handle = match thread::Builder::new()
        .name("android-usb-direct-render".to_string())
        .spawn(move || {
            run_usb_render_loop(
                producer_callback_data,
                producer_event_tx,
                producer_buffer,
                producer_stats,
                playback_format,
                producer_stop,
            );
        }) {
        Ok(handle) => handle,
        Err(error) => {
            set_stream_active(false);
            set_runtime_stats(None);
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some(format!(
                    "Failed to spawn Android USB direct render thread: {}",
                    error
                )),
            );
            cleanup_claimed_handle(
                claimed_handle,
                Some(candidate.interface_number),
                lock_requested,
            );
            return Err(format!(
                "Failed to spawn Android USB direct render thread: {}",
                error
            ));
        }
    };

    let usb_stop = Arc::clone(&stop);
    let usb_buffer = Arc::clone(&pcm_buffer);
    let usb_stats = Arc::clone(&runtime_stats);
    let backend_product_name = state.device.product_name.clone();
    let backend_endpoint_address = candidate.endpoint_address;
    let backend_interface_number = candidate.interface_number;
    let backend_alt_setting = candidate.alt_setting;
    let thread_handle = match thread::Builder::new()
        .name("android-usb-direct-output".to_string())
        .spawn(move || {
            run_usb_output_loop(
                claimed_handle,
                candidate,
                state,
                event_tx,
                usb_buffer,
                usb_stats,
                usb_stop,
            );
        }) {
        Ok(handle) => handle,
        Err(error) => {
            set_stream_active(false);
            set_runtime_stats(None);
            stop.store(true, Ordering::Release);
            let _ = producer_thread_handle.join();
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some(format!(
                    "Failed to spawn Android USB direct output thread: {}",
                    error
                )),
            );
            return Err(format!(
                "Failed to spawn Android USB direct output thread: {}",
                error
            ));
        }
    };

    eprintln!(
        "[USB] Streaming started device='{}' preferred={}Hz effective={}Hz requested={}Hz endpoint=0x{:02x} interface={} alt={}",
        backend_product_name,
        preferred_sample_rate,
        playback_format.sample_rate,
        requested_playback_format.sample_rate,
        backend_endpoint_address,
        backend_interface_number,
        backend_alt_setting,
    );
    set_android_usb_engine_state(AndroidDirectUsbEngineState::Streaming, None);
    Ok(Some(AndroidDirectUsbBackend {
        stop,
        producer_thread_handle: Some(producer_thread_handle),
        usb_thread_handle: Some(thread_handle),
    }))
}

impl AndroidDirectUsbBackend {
    pub fn stop(&mut self) -> Result<(), String> {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.producer_thread_handle.take() {
            handle
                .join()
                .map_err(|_| "Android USB direct render thread panicked".to_string())?;
        }
        if let Some(handle) = self.usb_thread_handle.take() {
            handle
                .join()
                .map_err(|_| "Android USB direct output thread panicked".to_string())?;
        }
        Ok(())
    }
}

impl Drop for AndroidDirectUsbBackend {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

impl IsoPacketScheduler {
    fn new(sample_rate: u32, bytes_per_frame: usize, service_interval_us: u32) -> Self {
        let packets_per_transfer = if service_interval_us >= 1_000 {
            16usize
        } else {
            (4_000u32 / service_interval_us).clamp(16, 32) as usize
        };

        Self {
            sample_rate,
            service_interval_us,
            nominal_remainder: 0,
            bytes_per_frame,
            packets_per_transfer,
            feedback_frames_per_packet: None,
            feedback_remainder: 0.0,
        }
    }

    fn next_transfer_packet_bytes(&mut self) -> Vec<usize> {
        (0..self.packets_per_transfer)
            .map(|_| self.next_packet_bytes())
            .collect()
    }

    fn nominal_frames_per_packet(&self) -> f64 {
        self.sample_rate as f64 * self.service_interval_us as f64 / 1_000_000.0
    }

    fn update_feedback_frames_per_packet(&mut self, frames_per_packet: f64) {
        if !frames_per_packet.is_finite() || frames_per_packet <= 0.0 {
            return;
        }

        let nominal = self.nominal_frames_per_packet().max(0.001);
        let clamped = frames_per_packet.clamp(nominal * 0.5, nominal * 1.5);
        self.feedback_frames_per_packet = Some(match self.feedback_frames_per_packet {
            Some(previous) => previous * 0.8 + clamped * 0.2,
            None => clamped,
        });
    }

    fn next_packet_bytes(&mut self) -> usize {
        let frames = if let Some(feedback_frames_per_packet) = self.feedback_frames_per_packet {
            self.feedback_remainder += feedback_frames_per_packet;
            let frames = self.feedback_remainder.floor() as usize;
            self.feedback_remainder -= frames as f64;
            frames
        } else {
            let total = self.nominal_remainder
                + (self.sample_rate as u64 * self.service_interval_us as u64);
            let frames = (total / 1_000_000) as usize;
            self.nominal_remainder = total % 1_000_000;
            frames
        };
        frames.saturating_mul(self.bytes_per_frame)
    }
}

fn run_usb_render_loop(
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    pcm_buffer: Arc<Mutex<AndroidDirectUsbPcmRingBuffer>>,
    runtime_stats: Arc<AndroidDirectUsbRuntimeStats>,
    playback_format: AndroidDirectUsbPlaybackFormat,
    stop: Arc<AtomicBool>,
) {
    let channels = playback_format.channels as usize;
    let chunk_frames =
        ((playback_format.sample_rate as usize * ANDROID_USB_RENDER_CHUNK_MS) / 1_000).max(1);
    let chunk_samples = chunk_frames.saturating_mul(channels);
    let target_samples = runtime_stats.buffer_target_samples;
    let mut render_buffer = vec![0.0f32; chunk_samples];
    let mut pcm_samples = vec![0i32; chunk_samples];
    let mut warned_no_frames = false;

    while !stop.load(Ordering::Acquire) {
        let buffered_samples = {
            let guard = pcm_buffer.lock();
            guard.len_samples()
        };
        runtime_stats
            .buffered_samples
            .store(buffered_samples, Ordering::Relaxed);

        if buffered_samples >= target_samples {
            thread::sleep(Duration::from_millis(ANDROID_USB_RENDER_POLL_MS));
            continue;
        }

        audio_callback(&mut render_buffer, &callback_data, &event_tx);
        set_software_volume_active((callback_data.get_volume() - 1.0).abs() > 0.000_1);
        if render_buffer.is_empty() {
            if !warned_no_frames {
                let message = "USB stream active but no PCM frames received".to_string();
                eprintln!("Android USB direct: {}", message);
                set_last_error(Some(message));
                warned_no_frames = true;
            }
            thread::sleep(Duration::from_millis(ANDROID_USB_RENDER_POLL_MS));
            continue;
        }

        if let Err(error) =
            convert_f32_to_pcm_samples(&render_buffer, &mut pcm_samples, playback_format.bit_depth)
        {
            let message = format!("Android USB direct PCM render conversion failed: {}", error);
            eprintln!("{}", message);
            set_last_error(Some(message.clone()));
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some(message.clone()),
            );
            let _ = event_tx.try_send(AudioEvent::Error { message });
            break;
        }

        let written_samples = {
            let mut guard = pcm_buffer.lock();
            let written = guard.push_samples(&pcm_samples);
            runtime_stats
                .buffered_samples
                .store(guard.len_samples(), Ordering::Relaxed);
            written
        };
        runtime_stats
            .producer_frames
            .fetch_add((written_samples / channels) as u64, Ordering::Relaxed);

        if written_samples > 0 && warned_no_frames {
            let should_clear_warning = DIRECT_USB_STATE
                .lock()
                .as_ref()
                .and_then(|state| state.last_error.as_ref())
                .is_some_and(|error| error == "USB stream active but no PCM frames received");
            if should_clear_warning {
                set_last_error(None);
            }
            warned_no_frames = false;
        }

        if written_samples == 0 {
            thread::sleep(Duration::from_millis(ANDROID_USB_RENDER_POLL_MS));
        }
    }
}

fn run_usb_output_loop(
    claimed_handle: AndroidDirectUsbClaimedHandle,
    candidate: AndroidIsoStreamCandidate,
    state: AndroidDirectUsbState,
    event_tx: Sender<AudioEvent>,
    pcm_buffer: Arc<Mutex<AndroidDirectUsbPcmRingBuffer>>,
    runtime_stats: Arc<AndroidDirectUsbRuntimeStats>,
    stop: Arc<AtomicBool>,
) {
    let AndroidDirectUsbClaimedHandle {
        device_fd,
        context,
        handle,
        claimed_interfaces,
    } = claimed_handle;
    let playback_format = state.playback_format.unwrap();
    let slot_bytes = candidate.subslot_size as usize;
    if slot_bytes == 0 {
        let message = "Android USB direct selected an invalid zero-byte subslot".to_string();
        set_last_error(Some(message.clone()));
        set_android_usb_engine_state(
            AndroidDirectUsbEngineState::Error,
            Some(message.clone()),
        );
        let _ = event_tx.try_send(AudioEvent::Error { message });
        cleanup_claimed_handle(
            AndroidDirectUsbClaimedHandle {
                device_fd,
                context,
                handle,
                claimed_interfaces,
            },
            Some(candidate.interface_number),
            current_lock_requested_for_fd(device_fd),
        );
        set_stream_active(false);
        return;
    }

    if let Err(error) = validate_transport_against_playback_format(&candidate, playback_format) {
        set_last_error(Some(error.clone()));
        set_android_usb_engine_state(
            AndroidDirectUsbEngineState::Error,
            Some(error.clone()),
        );
        let _ = event_tx.try_send(AudioEvent::Error { message: error });
        cleanup_claimed_handle(
            AndroidDirectUsbClaimedHandle {
                device_fd,
                context,
                handle,
                claimed_interfaces,
            },
            Some(candidate.interface_number),
            current_lock_requested_for_fd(device_fd),
        );
        set_stream_active(false);
        return;
    }

    let channels = candidate.channels as usize;
    let bytes_per_frame = slot_bytes.saturating_mul(channels);
    let mut scheduler = IsoPacketScheduler::new(
        playback_format.sample_rate,
        bytes_per_frame,
        candidate.service_interval_us,
    );
    let mut logged_transfer_preview = false;
    let mut clean_transfers = 0usize;
    let mut underrun_count = 0u64;
    let mut feedback_report_count = 0usize;

    while !stop.load(Ordering::Acquire) {
        let packet_bytes = scheduler.next_transfer_packet_bytes();
        let total_bytes: usize = packet_bytes.iter().sum();
        if total_bytes == 0 {
            thread::sleep(Duration::from_millis(1));
            continue;
        }

        if packet_bytes
            .iter()
            .any(|packet_size| *packet_size > candidate.max_packet_bytes)
        {
            let error = format!(
                "Android USB direct packet exceeds endpoint max packet size: packets={:?}, endpoint_max={}",
                packet_bytes, candidate.max_packet_bytes
            );
            set_last_error(Some(error.clone()));
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some(error.clone()),
            );
            let _ = event_tx.try_send(AudioEvent::Error { message: error });
            break;
        }

        if packet_bytes
            .iter()
            .any(|packet_size| packet_size % bytes_per_frame != 0)
        {
            let error = format!(
                "Android USB direct packet is not aligned to {}-byte transport frames: {:?}",
                bytes_per_frame, packet_bytes
            );
            set_last_error(Some(error.clone()));
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some(error.clone()),
            );
            let _ = event_tx.try_send(AudioEvent::Error { message: error });
            break;
        }

        let total_samples = total_bytes / slot_bytes;
        let mut packet_samples = vec![0i32; total_samples];
        let underrun = {
            let mut guard = pcm_buffer.lock();
            let underrun = guard.pop_into_or_pad(&mut packet_samples, channels);
            runtime_stats
                .buffered_samples
                .store(guard.len_samples(), Ordering::Relaxed);
            underrun
        };
        let mut transfer_buffer = vec![0u8; total_bytes];
        encode_pcm_bytes(
            &packet_samples,
            &mut transfer_buffer,
            candidate.subslot_size,
        );

        if underrun {
            underrun_count = underrun_count.saturating_add(1);
            runtime_stats
                .underrun_count
                .store(underrun_count, Ordering::Relaxed);
            clean_transfers = 0;
            set_usb_stream_stable(false);
            if underrun_count <= 4 || underrun_count % 64 == 0 {
                eprintln!(
                    "Android USB direct underrun: count={}, buffer_fill={}ms, frames_per_packet={}, packets_per_transfer={}",
                    underrun_count,
                    runtime_stats.buffer_fill_ms(),
                    packet_bytes.first().copied().unwrap_or_default() / bytes_per_frame,
                    packet_bytes.len(),
                );
            }
        }

        if !logged_transfer_preview {
            log_stream_debug_preview(
                playback_format,
                &candidate,
                &packet_bytes,
                &packet_samples,
                &transfer_buffer,
            );
            logged_transfer_preview = true;
        }

        if let Err(error) = submit_iso_transfer(
            &context,
            &handle,
            candidate.endpoint_address,
            &packet_bytes,
            transfer_buffer,
        ) {
            set_usb_stream_stable(false);
            set_last_error(Some(format!(
                "Android USB direct transfer failed: {}",
                error
            )));
            set_android_usb_engine_state(
                AndroidDirectUsbEngineState::Error,
                Some(format!("Android USB direct transfer failed: {}", error)),
            );
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Android USB direct transfer failed: {}", error),
            });
            eprintln!("Android USB direct transfer failed: {}", error);
            break;
        }

        if let Some(feedback_endpoint) = candidate.feedback_endpoint {
            match read_feedback_report(&context, &handle, feedback_endpoint, device_fd) {
                Ok(Some(feedback_report)) => {
                    scheduler.update_feedback_frames_per_packet(
                        feedback_report.frames_per_packet,
                    );
                    feedback_report_count = feedback_report_count.saturating_add(1);
                    if feedback_report_count <= 4 || feedback_report_count % 128 == 0 {
                        eprintln!(
                            "[USB] Feedback endpoint 0x{:02x} {} bytes={:02x?} framesPerPacket={:.4} sampleRate≈{:.2}Hz",
                            feedback_endpoint.address,
                            transfer_type_label(feedback_endpoint.transfer_type),
                            feedback_report.raw_bytes,
                            feedback_report.frames_per_packet,
                            feedback_report.estimated_sample_rate,
                        );
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    eprintln!(
                        "[USB] Feedback endpoint 0x{:02x} read failed: {}",
                        feedback_endpoint.address, error
                    );
                }
            }
        }

        runtime_stats.frames_per_packet.store(
            packet_bytes.first().copied().unwrap_or_default() / bytes_per_frame,
            Ordering::Relaxed,
        );
        runtime_stats
            .consumer_frames
            .fetch_add((packet_samples.len() / channels) as u64, Ordering::Relaxed);

        if !underrun {
            clean_transfers = clean_transfers.saturating_add(1);
        }
        if clean_transfers >= ANDROID_USB_STABLE_TRANSFER_THRESHOLD {
            set_usb_stream_stable(true);
        }
    }

    cleanup_claimed_handle(
        AndroidDirectUsbClaimedHandle {
            device_fd,
            context,
            handle,
            claimed_interfaces,
        },
        Some(candidate.interface_number),
        current_lock_requested_for_fd(device_fd),
    );
    set_stream_active(false);
    set_runtime_stats(None);
    set_usb_stream_stable(false);
    if stop.load(Ordering::Acquire) {
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Idle, None);
    }
}

#[derive(Debug)]
struct AndroidUsbFeedbackReport {
    raw_bytes: Vec<u8>,
    frames_per_packet: f64,
    estimated_sample_rate: f64,
}

fn read_feedback_report(
    context: &Context,
    handle: &DeviceHandle<Context>,
    feedback_endpoint: AndroidUsbFeedbackEndpoint,
    _device_fd: RawFd,
) -> Result<Option<AndroidUsbFeedbackReport>, String> {
    let raw_bytes = match feedback_endpoint.transfer_type {
        TransferType::Interrupt => {
            read_interrupt_feedback_packet(handle, feedback_endpoint)?
        }
        TransferType::Isochronous => read_iso_feedback_packet(context, handle, feedback_endpoint)?,
        other => {
            return Err(format!(
                "Unsupported feedback transfer type {}",
                transfer_type_label(other)
            ));
        }
    };

    let Some(raw_bytes) = raw_bytes else {
        return Ok(None);
    };
    let Some((frames_per_packet, estimated_sample_rate)) =
        decode_feedback_report(&raw_bytes, feedback_endpoint)
    else {
        return Ok(None);
    };

    Ok(Some(AndroidUsbFeedbackReport {
        raw_bytes,
        frames_per_packet,
        estimated_sample_rate,
    }))
}

fn read_interrupt_feedback_packet(
    handle: &DeviceHandle<Context>,
    feedback_endpoint: AndroidUsbFeedbackEndpoint,
) -> Result<Option<Vec<u8>>, String> {
    let mut data = vec![0u8; feedback_endpoint.max_packet_bytes.max(4)];
    match handle.read_interrupt(
        feedback_endpoint.address,
        &mut data,
        Duration::from_millis(ANDROID_USB_FEEDBACK_TIMEOUT_MS as u64),
    ) {
        Ok(transferred) if transferred > 0 => {
            data.truncate(transferred);
            Ok(Some(data))
        }
        Ok(_) => Ok(None),
        Err(UsbError::Timeout) => Ok(None),
        Err(error) => Err(format!("interrupt feedback read failed: {}", error)),
    }
}

fn decode_feedback_report(
    raw_bytes: &[u8],
    feedback_endpoint: AndroidUsbFeedbackEndpoint,
) -> Option<(f64, f64)> {
    let (frames_per_base_interval, base_interval_us) = match raw_bytes.len() {
        3 => {
            let raw =
                u32::from(raw_bytes[0]) | (u32::from(raw_bytes[1]) << 8) | (u32::from(raw_bytes[2]) << 16);
            (
                raw as f64 / 16_384.0,
                if feedback_endpoint.service_interval_us < 1_000 {
                    125.0
                } else {
                    1_000.0
                },
            )
        }
        4.. => {
            let raw = u32::from_le_bytes([raw_bytes[0], raw_bytes[1], raw_bytes[2], raw_bytes[3]]);
            (
                raw as f64 / 65_536.0,
                if feedback_endpoint.service_interval_us < 1_000 {
                    125.0
                } else {
                    1_000.0
                },
            )
        }
        _ => return None,
    };

    let packet_multiplier = feedback_endpoint.service_interval_us as f64 / base_interval_us;
    let frames_per_packet = frames_per_base_interval * packet_multiplier;
    let estimated_sample_rate = frames_per_base_interval * (1_000_000.0 / base_interval_us);
    Some((frames_per_packet, estimated_sample_rate))
}

fn select_stream_candidate(
    device: &Device<Context>,
    playback_format: AndroidDirectUsbPlaybackFormat,
    speed: Speed,
) -> Result<AndroidIsoStreamCandidate, String> {
    let config_descriptor = device
        .active_config_descriptor()
        .map_err(|error| format!("Failed to read active USB config descriptor: {}", error))?;
    let mut candidates = Vec::new();
    for interface in config_descriptor.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() != USB_CLASS_AUDIO
                || descriptor.sub_class_code() != USB_SUBCLASS_AUDIOSTREAMING
            {
                continue;
            }

            let stream_format = match parse_android_streaming_interface_format(&descriptor) {
                Some(format) => format,
                None => continue,
            };
            let compatibility_penalty =
                transport_compatibility_penalty(&stream_format, playback_format);
            if compatibility_penalty == u32::MAX {
                continue;
            }

            for endpoint in descriptor.endpoint_descriptors() {
                if descriptor.setting_number() == 0 {
                    continue;
                }
                if endpoint.direction() != Direction::Out
                    || endpoint.transfer_type() != TransferType::Isochronous
                {
                    continue;
                }
                if endpoint.interval() == 0 {
                    eprintln!(
                        "Android USB direct skipping invalid isochronous endpoint=0x{:02x} on interface {} alt {} because bInterval=0",
                        endpoint.address(),
                        descriptor.interface_number(),
                        descriptor.setting_number(),
                    );
                    continue;
                }

                if !matches!(
                    endpoint.usage_type(),
                    UsageType::Data | UsageType::FeedbackData
                ) {
                    continue;
                }

                let service_interval_us = service_interval_micros(speed, endpoint.interval());
                let max_packet_bytes =
                    effective_iso_packet_bytes(endpoint.max_packet_size(), speed);
                let feedback_endpoint =
                    find_feedback_endpoint(&descriptor, endpoint.synch_address(), speed);
                let bytes_per_frame =
                    stream_format.subslot_size as usize * stream_format.channels as usize;
                let required_max_packet_bytes = required_max_packet_bytes(
                    playback_format.sample_rate,
                    service_interval_us,
                    bytes_per_frame,
                );

                eprintln!(
                    "Android USB direct stream candidate interface={} alt={} endpoint=0x{:02x} interval={} service={}us max_packet={} required={} sync={:?} usage={:?} fmt={} channels={} subslot={} bit_resolution={} sample_rates={:?} penalty={}",
                    descriptor.interface_number(),
                    descriptor.setting_number(),
                    endpoint.address(),
                    endpoint.interval(),
                    service_interval_us,
                    max_packet_bytes,
                    required_max_packet_bytes,
                    endpoint.sync_type(),
                    endpoint.usage_type(),
                    format_tag_label(stream_format.format_tag),
                    stream_format.channels,
                    stream_format.subslot_size,
                    stream_format.bit_resolution,
                    stream_format.sample_rates,
                    compatibility_penalty,
                );

                if endpoint.synch_address() != 0 && feedback_endpoint.is_none() {
                    eprintln!(
                        "[USB] Skipping async endpoint=0x{:02x} on interface {} alt {} because feedback endpoint 0x{:02x} was not found",
                        endpoint.address(),
                        descriptor.interface_number(),
                        descriptor.setting_number(),
                        endpoint.synch_address(),
                    );
                    continue;
                }

                if max_packet_bytes < required_max_packet_bytes {
                    continue;
                }

                candidates.push(AndroidIsoStreamCandidate {
                    interface_number: descriptor.interface_number(),
                    alt_setting: descriptor.setting_number(),
                    endpoint_address: endpoint.address(),
                    endpoint_interval: endpoint.interval(),
                    service_interval_us,
                    max_packet_bytes,
                    sync_type: endpoint.sync_type(),
                    usage_type: endpoint.usage_type(),
                    format_tag: stream_format.format_tag,
                    channels: stream_format.channels,
                    subslot_size: stream_format.subslot_size,
                    bit_resolution: stream_format.bit_resolution,
                    sample_rates: stream_format.sample_rates.clone(),
                    refresh: endpoint.refresh(),
                    synch_address: endpoint.synch_address(),
                    feedback_endpoint,
                });
            }
        }
    }

    candidates.sort_by_key(|candidate| {
        let required_bytes = required_max_packet_bytes(
            playback_format.sample_rate,
            candidate.service_interval_us,
            candidate.subslot_size as usize * candidate.channels as usize,
        );
        (
            transport_compatibility_penalty_for_candidate(candidate, playback_format),
            candidate.max_packet_bytes.saturating_sub(required_bytes),
            candidate.interface_number,
            candidate.alt_setting,
        )
    });

    candidates.into_iter().next().ok_or_else(|| {
        format!(
            "No isochronous OUT endpoint can carry {} Hz / {}-bit / {} ch",
            playback_format.sample_rate, playback_format.bit_depth, playback_format.channels
        )
    })
}

fn find_feedback_endpoint(
    descriptor: &rusb::InterfaceDescriptor,
    feedback_address: u8,
    speed: Speed,
) -> Option<AndroidUsbFeedbackEndpoint> {
    if feedback_address == 0 {
        return None;
    }

    descriptor.endpoint_descriptors().find_map(|endpoint| {
        if endpoint.address() != feedback_address || endpoint.direction() != Direction::In {
            return None;
        }

        if !matches!(
            endpoint.transfer_type(),
            TransferType::Isochronous | TransferType::Interrupt
        ) {
            return None;
        }

        Some(AndroidUsbFeedbackEndpoint {
            address: endpoint.address(),
            transfer_type: endpoint.transfer_type(),
            interval: endpoint.interval(),
            service_interval_us: service_interval_micros(speed, endpoint.interval()),
            max_packet_bytes: effective_iso_packet_bytes(endpoint.max_packet_size(), speed),
        })
    })
}

fn discover_audio_streaming_interfaces(device: &Device<Context>) -> Result<Vec<u8>, String> {
    let config_descriptor = device
        .active_config_descriptor()
        .map_err(|error| format!("Failed to read active USB config descriptor: {}", error))?;

    let mut interfaces = Vec::new();
    for interface in config_descriptor.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() == USB_CLASS_AUDIO
                && descriptor.sub_class_code() == USB_SUBCLASS_AUDIOSTREAMING
            {
                interfaces.push(descriptor.interface_number());
            }
        }
    }

    interfaces.sort_unstable();
    interfaces.dedup();

    if interfaces.is_empty() {
        return Err("No USB audio streaming interfaces were found on the device".to_string());
    }

    Ok(interfaces)
}

fn find_audio_control_clock(device: &Device<Context>) -> Option<AudioControlClock> {
    let config_descriptor = device.active_config_descriptor().ok()?;

    for interface in config_descriptor.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() != USB_CLASS_AUDIO
                || descriptor.sub_class_code() != USB_SUBCLASS_AUDIOCONTROL
            {
                continue;
            }

            let extra = descriptor.extra();
            let mut index = 0usize;
            while index + 2 < extra.len() {
                let length = extra[index] as usize;
                if length == 0 || index + length > extra.len() {
                    break;
                }

                let descriptor_type = extra[index + 1];
                let descriptor_subtype = extra.get(index + 2).copied().unwrap_or_default();
                if descriptor_type == USB_DT_CS_INTERFACE
                    && descriptor_subtype == UAC2_CLOCK_SOURCE
                    && length >= 4
                {
                    return Some(AudioControlClock {
                        interface_number: descriptor.interface_number(),
                        clock_id: extra[index + 3],
                    });
                }

                index += length;
            }
        }
    }

    None
}

fn set_sampling_frequency(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    clock_id: u8,
    sample_rate: u32,
) -> Result<(), String> {
    let request_type = USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let value = UAC2_CLOCK_SOURCE_SAM_FREQ_CONTROL;
    let index = (interface_number as u16) | ((clock_id as u16) << 8);
    let data = sample_rate.to_le_bytes();
    handle
        .write_control(
            request_type,
            UAC2_REQUEST_SET_CUR,
            value,
            index,
            &data,
            Duration::from_secs(1),
        )
        .map_err(|error| format!("Failed to set sampling frequency: {}", error))?;
    Ok(())
}

fn get_sampling_frequency(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    clock_id: u8,
) -> Result<u32, String> {
    let request_type = USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let value = UAC2_CLOCK_SOURCE_SAM_FREQ_CONTROL;
    let index = (interface_number as u16) | ((clock_id as u16) << 8);
    let mut data = [0u8; 4];
    let transferred = handle
        .read_control(
            request_type,
            UAC2_REQUEST_GET_CUR,
            value,
            index,
            &mut data,
            Duration::from_secs(1),
        )
        .map_err(|error| format!("Failed to read sampling frequency: {}", error))?;
    if transferred != data.len() {
        return Err(format!(
            "Sampling-frequency read returned {} bytes, expected {}",
            transferred,
            data.len()
        ));
    }
    Ok(u32::from_le_bytes(data))
}

fn get_sampling_frequency_ranges(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    clock_id: u8,
) -> Result<Vec<SamplingFrequencySubrange>, String> {
    let request_type = USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let value = UAC2_CLOCK_SOURCE_SAM_FREQ_CONTROL;
    let index = (interface_number as u16) | ((clock_id as u16) << 8);
    let mut data = [0u8; 512];
    let transferred = handle
        .read_control(
            request_type,
            UAC2_REQUEST_GET_RANGE,
            value,
            index,
            &mut data,
            Duration::from_secs(1),
        )
        .map_err(|error| format!("Failed to read sampling-frequency range: {}", error))?;
    if transferred < 2 {
        return Err(format!(
            "Sampling-frequency GET_RANGE returned {} bytes, expected at least 2",
            transferred
        ));
    }

    let count = u16::from_le_bytes([data[0], data[1]]) as usize;
    if count == 0 {
        return Err("Sampling-frequency GET_RANGE returned zero subranges".to_string());
    }

    let expected = 2 + count * 12;
    if transferred < expected {
        return Err(format!(
            "Sampling-frequency GET_RANGE returned {} bytes, expected at least {} for {} subranges",
            transferred, expected, count
        ));
    }

    let mut ranges = Vec::with_capacity(count);
    for index in 0..count {
        let offset = 2 + index * 12;
        ranges.push(SamplingFrequencySubrange {
            min: u32::from_le_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ]),
            max: u32::from_le_bytes([
                data[offset + 4],
                data[offset + 5],
                data[offset + 6],
                data[offset + 7],
            ]),
            res: u32::from_le_bytes([
                data[offset + 8],
                data[offset + 9],
                data[offset + 10],
                data[offset + 11],
            ]),
        });
    }

    Ok(ranges)
}

fn sampling_frequency_ranges_support_rate(
    ranges: &[SamplingFrequencySubrange],
    sample_rate: u32,
) -> bool {
    ranges.iter().any(|range| {
        if range.res == 0 {
            range.min == sample_rate && range.max == sample_rate
        } else {
            sample_rate >= range.min
                && sample_rate <= range.max
                && (sample_rate - range.min) % range.res == 0
        }
    })
}

fn format_sampling_frequency_ranges(ranges: &[SamplingFrequencySubrange]) -> String {
    ranges
        .iter()
        .map(|range| {
            if range.res == 0 || range.min == range.max {
                format!("{} Hz", range.min)
            } else {
                format!("{}..{} Hz step {}", range.min, range.max, range.res)
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn apply_sampling_frequency(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    clock_id: u8,
    sample_rate: u32,
    settle_delay_ms: u64,
) -> AndroidDirectUsbClockApplyOutcome {
    let supported_ranges = get_sampling_frequency_ranges(handle, interface_number, clock_id).ok();
    if let Some(ranges) = supported_ranges.as_ref() {
        if !sampling_frequency_ranges_support_rate(ranges, sample_rate) {
            return AndroidDirectUsbClockApplyOutcome {
                clock_ok: false,
                rate_verified: false,
                reported_sample_rate: get_sampling_frequency(handle, interface_number, clock_id).ok(),
                known_mismatch: true,
                message: Some(format!(
                    "Requested {} Hz is not supported by clock {} on interface {}; supported rates: {}",
                    sample_rate,
                    clock_id,
                    interface_number,
                    format_sampling_frequency_ranges(ranges),
                )),
            };
        }
    }

    if let Ok(current_rate) = get_sampling_frequency(handle, interface_number, clock_id) {
        if current_rate == sample_rate {
            return AndroidDirectUsbClockApplyOutcome {
                clock_ok: true,
                rate_verified: true,
                reported_sample_rate: Some(current_rate),
                known_mismatch: false,
                message: Some(format!(
                    "USB clock {} on interface {} is already running at {} Hz",
                    clock_id, interface_number, current_rate
                )),
            };
        }
    }

    let mut last_set_error = None;
    let mut last_readback_error = None;
    let mut last_reported_rate = None;

    for attempt in 1..=3 {
        match set_sampling_frequency(handle, interface_number, clock_id, sample_rate) {
            Ok(()) => {}
            Err(error) => {
                last_set_error = Some(error);
                thread::sleep(Duration::from_millis(settle_delay_ms));
                continue;
            }
        }

        thread::sleep(Duration::from_millis(settle_delay_ms));
        match get_sampling_frequency(handle, interface_number, clock_id) {
            Ok(reported_sample_rate) => {
                last_reported_rate = Some(reported_sample_rate);
                if reported_sample_rate == sample_rate {
                    eprintln!(
                        "Android USB direct set sampling frequency to {} Hz using clock {} on interface {}; device reports {} Hz after attempt {}",
                        sample_rate, clock_id, interface_number, reported_sample_rate, attempt,
                    );
                    return AndroidDirectUsbClockApplyOutcome {
                        clock_ok: true,
                        rate_verified: true,
                        reported_sample_rate: Some(reported_sample_rate),
                        known_mismatch: false,
                        message: None,
                    };
                }
            }
            Err(error) => {
                last_readback_error = Some(error);
                continue;
            }
        }
    }

    if let Some(reported_sample_rate) = last_reported_rate {
        return AndroidDirectUsbClockApplyOutcome {
            clock_ok: false,
            rate_verified: false,
            reported_sample_rate: Some(reported_sample_rate),
            known_mismatch: true,
            message: Some(format!(
                "Requested {} Hz, DAC reports {} Hz after SET_CUR on clock {} / interface {}",
                sample_rate, reported_sample_rate, clock_id, interface_number
            )),
        };
    }

    AndroidDirectUsbClockApplyOutcome {
        clock_ok: false,
        rate_verified: false,
        reported_sample_rate: None,
        known_mismatch: false,
        message: Some(format!(
            "Failed to set USB clock {} on interface {} to {} Hz{}{}",
            clock_id,
            interface_number,
            sample_rate,
            last_set_error
                .as_ref()
                .map(|error| format!(": {}", error))
                .unwrap_or_default(),
            last_readback_error
                .as_ref()
                .map(|error| format!("; readback failed: {}", error))
                .unwrap_or_default(),
        )),
    }
}

fn effective_iso_packet_bytes(raw_max_packet_size: u16, speed: Speed) -> usize {
    let base_bytes = (raw_max_packet_size & 0x07ff) as usize;
    let transactions = match speed {
        Speed::High | Speed::Super | Speed::SuperPlus => {
            1 + ((raw_max_packet_size >> 11) & 0x03) as usize
        }
        _ => 1,
    };
    base_bytes.saturating_mul(transactions)
}

fn service_interval_micros(speed: Speed, interval: u8) -> u32 {
    let exponent = interval.saturating_sub(1).min(15) as u32;
    let multiplier = 1u32 << exponent;
    match speed {
        Speed::High | Speed::Super | Speed::SuperPlus => 125u32.saturating_mul(multiplier),
        _ => 1_000u32.saturating_mul(multiplier),
    }
}

fn required_max_packet_bytes(
    sample_rate: u32,
    service_interval_us: u32,
    bytes_per_frame: usize,
) -> usize {
    let max_frames = ((sample_rate as u64 * service_interval_us as u64) + 999_999) / 1_000_000;
    max_frames as usize * bytes_per_frame
}

fn bytes_per_sample(bit_depth: u8) -> Option<usize> {
    match bit_depth {
        16 => Some(2),
        24 => Some(3),
        32 => Some(4),
        _ => None,
    }
}

fn parse_android_streaming_interface_format(
    descriptor: &rusb::InterfaceDescriptor,
) -> Option<AndroidStreamingInterfaceFormat> {
    let mut channels = None;
    let mut format_tag = None;
    let mut subslot_size = None;
    let mut bit_resolution = None;
    let mut sample_rates = Vec::new();

    for extra in DescriptorIter::new(descriptor.extra()) {
        if extra.len() < 3 || extra[1] != USB_DT_CS_INTERFACE {
            continue;
        }

        match extra[2] {
            UAC2_AS_GENERAL => {
                if extra.len() >= 16 {
                    channels = Some(extra[10] as u16);
                    format_tag =
                        Some(u32::from_le_bytes([extra[6], extra[7], extra[8], extra[9]]) as u16);
                } else if extra.len() >= 7 {
                    format_tag = Some(u16::from_le_bytes([extra[5], extra[6]]));
                }
            }
            UAC2_FORMAT_TYPE if extra.get(3).copied() == Some(UAC2_FORMAT_TYPE_I) => {
                if extra.len() >= 6 {
                    subslot_size = Some(extra[4]);
                    bit_resolution = Some(extra[5]);
                    if extra.len() > 6 {
                        sample_rates = extract_sample_rates_from_type_i(extra);
                    }
                }
            }
            _ => {}
        }
    }

    let format_tag = format_tag?;
    let subslot_size = subslot_size?;
    let bit_resolution = bit_resolution?;

    Some(AndroidStreamingInterfaceFormat {
        format_tag,
        channels: channels.unwrap_or(2),
        subslot_size,
        bit_resolution,
        sample_rates,
    })
}

fn extract_sample_rates_from_type_i(extra: &[u8]) -> Vec<u32> {
    if extra.len() < 7 {
        return Vec::new();
    }

    let count = extra[6] as usize;
    if count == 0 {
        if extra.len() >= 11 {
            return vec![u32::from_le_bytes([
                extra[7], extra[8], extra[9], extra[10],
            ])];
        }
        return Vec::new();
    }

    let mut rates = Vec::new();
    if extra.len() >= 7 + (count * 4) {
        for index in 0..count {
            let offset = 7 + index * 4;
            rates.push(u32::from_le_bytes([
                extra[offset],
                extra[offset + 1],
                extra[offset + 2],
                extra[offset + 3],
            ]));
        }
        return rates;
    }

    if extra.len() >= 7 + (count * 6) {
        for index in 0..count {
            let offset = 7 + index * 6;
            rates.push(u32::from_le_bytes([
                extra[offset],
                extra[offset + 1],
                extra[offset + 2],
                extra[offset + 3],
            ]));
        }
    }

    rates
}

fn transport_compatibility_penalty(
    stream_format: &AndroidStreamingInterfaceFormat,
    playback_format: AndroidDirectUsbPlaybackFormat,
) -> u32 {
    if stream_format.format_tag != FORMAT_TAG_PCM {
        return u32::MAX;
    }
    if stream_format.subslot_size == 0 || stream_format.channels == 0 {
        return u32::MAX;
    }
    if stream_format.channels != playback_format.channels {
        return u32::MAX;
    }
    if stream_format.bit_resolution != playback_format.bit_depth {
        return u32::MAX;
    }
    let Some(min_subslot_size) = bytes_per_sample(playback_format.bit_depth) else {
        return u32::MAX;
    };
    if stream_format.subslot_size < min_subslot_size as u8 {
        return u32::MAX;
    }

    let container_bits = u32::from(stream_format.subslot_size) * 8;
    if u32::from(stream_format.bit_resolution) > container_bits {
        return u32::MAX;
    }

    let sample_rate_penalty = if stream_format
        .sample_rates
        .contains(&playback_format.sample_rate)
    {
        0
    } else if stream_format.sample_rates.is_empty() {
        1
    } else {
        return u32::MAX;
    };

    sample_rate_penalty + u32::from(stream_format.subslot_size) - min_subslot_size as u32
}

fn transport_compatibility_penalty_for_candidate(
    candidate: &AndroidIsoStreamCandidate,
    playback_format: AndroidDirectUsbPlaybackFormat,
) -> u32 {
    transport_compatibility_penalty(
        &AndroidStreamingInterfaceFormat {
            format_tag: candidate.format_tag,
            channels: candidate.channels,
            subslot_size: candidate.subslot_size,
            bit_resolution: candidate.bit_resolution,
            sample_rates: candidate.sample_rates.clone(),
        },
        playback_format,
    )
}

fn format_tag_label(format_tag: u16) -> &'static str {
    match format_tag {
        FORMAT_TAG_PCM => "PCM",
        FORMAT_TAG_PCM8 => "PCM8",
        FORMAT_TAG_IEEE_FLOAT => "IEEE_FLOAT",
        _ => "OTHER",
    }
}

fn sync_type_label(sync_type: SyncType) -> &'static str {
    match sync_type {
        SyncType::Adaptive => "adaptive",
        SyncType::Asynchronous => "asynchronous",
        SyncType::Synchronous => "synchronous",
        SyncType::NoSync => "none",
    }
}

fn usage_type_label(usage_type: UsageType) -> &'static str {
    match usage_type {
        UsageType::Data => "data",
        UsageType::Feedback => "feedback",
        UsageType::FeedbackData => "feedback-data",
        UsageType::Reserved => "reserved",
    }
}

fn transfer_type_label(transfer_type: TransferType) -> &'static str {
    match transfer_type {
        TransferType::Control => "control",
        TransferType::Isochronous => "isochronous",
        TransferType::Bulk => "bulk",
        TransferType::Interrupt => "interrupt",
    }
}

fn validate_transport_against_playback_format(
    candidate: &AndroidIsoStreamCandidate,
    playback_format: AndroidDirectUsbPlaybackFormat,
) -> Result<(), String> {
    if candidate.format_tag != FORMAT_TAG_PCM {
        return Err(format!(
            "Android USB direct requires PCM transport, got {}",
            format_tag_label(candidate.format_tag)
        ));
    }
    if candidate.channels != playback_format.channels {
        return Err(format!(
            "Android USB direct requires {} channels, got {}",
            playback_format.channels, candidate.channels
        ));
    }
    if candidate.bit_resolution != playback_format.bit_depth {
        return Err(format!(
            "Android USB direct requires {}-bit transport, got {}",
            playback_format.bit_depth, candidate.bit_resolution
        ));
    }
    let Some(min_subslot_size) = bytes_per_sample(playback_format.bit_depth) else {
        return Err(format!(
            "Android USB direct does not support {}-bit sample packing",
            playback_format.bit_depth
        ));
    };
    if candidate.subslot_size < min_subslot_size as u8 {
        return Err(format!(
            "Android USB direct requires at least {} bytes per subslot for {}-bit transport, got {}",
            min_subslot_size, playback_format.bit_depth, candidate.subslot_size
        ));
    }
    Ok(())
}

fn convert_f32_to_pcm_samples(
    input: &[f32],
    output: &mut [i32],
    bit_depth: u8,
) -> Result<(), String> {
    if output.len() != input.len() {
        return Err(format!(
            "PCM sample buffer size mismatch: expected {}, got {}",
            input.len(),
            output.len()
        ));
    }

    for (destination, sample) in output.iter_mut().zip(input.iter()) {
        let clamped = sample.clamp(-1.0, 1.0);
        *destination = match bit_depth {
            16 => (clamped * i16::MAX as f32).round() as i16 as i32,
            24 => {
                let scaled = (clamped * 8_388_607.0).round() as i32;
                scaled.clamp(-8_388_608, 8_388_607)
            }
            32 => {
                let scaled = (clamped * i32::MAX as f32).round() as i64;
                scaled.clamp(i32::MIN as i64, i32::MAX as i64) as i32
            }
            _ => return Err(format!("Unsupported PCM bit depth: {}", bit_depth)),
        };
    }

    Ok(())
}

fn encode_pcm_bytes(input: &[i32], output: &mut [u8], subslot_size: u8) {
    debug_assert_eq!(output.len(), input.len() * usize::from(subslot_size));
    for (index, sample) in input.iter().enumerate() {
        let offset = index * usize::from(subslot_size);
        let bytes = sample.to_le_bytes();
        for byte_index in 0..usize::from(subslot_size) {
            output[offset + byte_index] = bytes[byte_index];
        }
    }
}

fn log_stream_debug_preview(
    playback_format: AndroidDirectUsbPlaybackFormat,
    candidate: &AndroidIsoStreamCandidate,
    packet_bytes: &[usize],
    packet_samples: &[i32],
    transfer_buffer: &[u8],
) {
    let frames_per_packet: Vec<usize> = packet_bytes
        .iter()
        .map(|packet| packet / (candidate.subslot_size as usize * candidate.channels as usize))
        .collect();
    let sample_preview: Vec<i32> = packet_samples.iter().take(10).copied().collect();
    let byte_decoded_preview: Vec<i32> = transfer_buffer
        .chunks_exact(candidate.subslot_size as usize)
        .take(10)
        .map(|chunk| {
            let mut bytes = [0u8; 4];
            for (index, byte) in chunk.iter().enumerate() {
                bytes[index] = *byte;
            }
            if candidate.subslot_size < 4 && chunk.last().copied().unwrap_or_default() & 0x80 != 0 {
                for byte in bytes.iter_mut().skip(candidate.subslot_size as usize) {
                    *byte = 0xff;
                }
            }
            i32::from_le_bytes(bytes)
        })
        .collect();
    let first_bytes_preview: Vec<String> = transfer_buffer
        .iter()
        .take(32)
        .map(|byte| format!("{:02x}", byte))
        .collect();

    eprintln!(
        "[USB] Stream start engineOutput=f32@{}Hz transport={} {}-bit {}ch {}-byte-subslot interface={} alt={} endpoint=0x{:02x} sync={} usage={} refresh={} synchAddress=0x{:02x} endpointMaxPacket={} feedback={} packetSizes={:?} framesPerPacket={:?}",
        playback_format.sample_rate,
        format_tag_label(candidate.format_tag),
        candidate.bit_resolution,
        candidate.channels,
        candidate.subslot_size,
        candidate.interface_number,
        candidate.alt_setting,
        candidate.endpoint_address,
        sync_type_label(candidate.sync_type),
        usage_type_label(candidate.usage_type),
        candidate.refresh,
        candidate.synch_address,
        candidate.max_packet_bytes,
        candidate
            .feedback_endpoint
            .map(|feedback| format!(
                "0x{:02x}/{}@interval{}",
                feedback.address,
                transfer_type_label(feedback.transfer_type),
                feedback.interval,
            ))
            .unwrap_or_else(|| "none".to_string()),
        packet_bytes,
        frames_per_packet,
    );
    eprintln!(
        "Android USB direct PCM16 sample preview: {:?}",
        sample_preview
    );
    eprintln!(
        "Android USB direct byte-decoded preview: {:?}",
        byte_decoded_preview
    );
    eprintln!(
        "Android USB direct first 32 bytes: {:?}",
        first_bytes_preview
    );
}

extern "system" fn iso_transfer_callback(transfer: *mut libusb_transfer) {
    let Some(transfer) = std::ptr::NonNull::new(transfer) else {
        return;
    };
    let user_data_ptr = unsafe { transfer.as_ref().user_data as *mut IsoTransferUserData };
    let Some(user_data) = std::ptr::NonNull::new(user_data_ptr) else {
        return;
    };

    let status = unsafe { transfer.as_ref().status };
    let completion = &unsafe { user_data.as_ref() }.completion;
    let mut guard = completion.status.lock().unwrap();
    *guard = Some(status);
    completion.condvar.notify_all();
}

fn submit_iso_transfer(
    context: &Context,
    handle: &DeviceHandle<Context>,
    endpoint: u8,
    packet_sizes: &[usize],
    buffer: Vec<u8>,
) -> Result<(), String> {
    let completion = Arc::new(IsoTransferCompletion {
        status: StdMutex::new(None),
        condvar: Condvar::new(),
    });
    let user_data = Box::new(IsoTransferUserData { completion, buffer });
    let user_data_ptr = Box::into_raw(user_data);
    let transfer = unsafe { libusb_alloc_transfer(packet_sizes.len() as i32) };
    let callback: libusb_transfer_cb_fn = iso_transfer_callback;

    let Some(mut transfer_ptr) = std::ptr::NonNull::new(transfer) else {
        unsafe {
            drop(Box::from_raw(user_data_ptr));
        }
        return Err("libusb_alloc_transfer returned null".to_string());
    };

    unsafe {
        libusb_fill_iso_transfer(
            transfer_ptr.as_mut(),
            handle.as_raw(),
            endpoint,
            (*user_data_ptr).buffer.as_mut_ptr(),
            (*user_data_ptr).buffer.len() as i32,
            packet_sizes.len() as i32,
            callback,
            user_data_ptr as *mut c_void,
            ISO_TRANSFER_TIMEOUT_MS,
        );

        for (index, packet_size) in packet_sizes.iter().enumerate() {
            (*transfer_ptr
                .as_mut()
                .iso_packet_desc
                .as_mut_ptr()
                .add(index))
            .length = *packet_size as u32;
        }

        let submit_result = libusb_submit_transfer(transfer_ptr.as_ptr());
        if submit_result != 0 {
            libusb_free_transfer(transfer_ptr.as_ptr());
            drop(Box::from_raw(user_data_ptr));
            return Err(format!(
                "libusb_submit_transfer failed with code {}",
                submit_result
            ));
        }
    }

    let completion = unsafe { &(*user_data_ptr).completion };
    let status = loop {
        if let Some(status) = *completion.status.lock().unwrap() {
            break status;
        }

        context
            .handle_events(Some(Duration::from_millis(50)))
            .map_err(|error| format!("libusb_handle_events failed: {}", error))?;
    };

    let packet_validation = unsafe {
        let transfer_ref = transfer_ptr.as_ref();
        validate_iso_packet_results(transfer_ref, packet_sizes)
    };

    unsafe {
        libusb_free_transfer(transfer_ptr.as_ptr());
        drop(Box::from_raw(user_data_ptr));
    }

    match status {
        LIBUSB_TRANSFER_COMPLETED => packet_validation,
        LIBUSB_TRANSFER_TIMED_OUT => Err("isochronous transfer timed out".to_string()),
        LIBUSB_TRANSFER_STALL => Err("isochronous transfer stalled".to_string()),
        LIBUSB_TRANSFER_NO_DEVICE => Err("USB DAC disconnected".to_string()),
        LIBUSB_TRANSFER_OVERFLOW => Err("isochronous transfer overflow".to_string()),
        LIBUSB_TRANSFER_CANCELLED => Err("isochronous transfer cancelled".to_string()),
        LIBUSB_TRANSFER_ERROR => Err("isochronous transfer failed".to_string()),
        other => Err(format!("isochronous transfer returned status {}", other)),
    }
}

fn read_iso_feedback_packet(
    context: &Context,
    handle: &DeviceHandle<Context>,
    feedback_endpoint: AndroidUsbFeedbackEndpoint,
) -> Result<Option<Vec<u8>>, String> {
    let completion = Arc::new(IsoTransferCompletion {
        status: StdMutex::new(None),
        condvar: Condvar::new(),
    });
    let buffer = vec![0u8; feedback_endpoint.max_packet_bytes.max(4)];
    let user_data = Box::new(IsoTransferUserData { completion, buffer });
    let user_data_ptr = Box::into_raw(user_data);
    let transfer = unsafe { libusb_alloc_transfer(1) };
    let callback: libusb_transfer_cb_fn = iso_transfer_callback;

    let Some(mut transfer_ptr) = std::ptr::NonNull::new(transfer) else {
        unsafe {
            drop(Box::from_raw(user_data_ptr));
        }
        return Err("libusb_alloc_transfer returned null for feedback transfer".to_string());
    };

    unsafe {
        libusb_fill_iso_transfer(
            transfer_ptr.as_mut(),
            handle.as_raw(),
            feedback_endpoint.address,
            (*user_data_ptr).buffer.as_mut_ptr(),
            (*user_data_ptr).buffer.len() as i32,
            1,
            callback,
            user_data_ptr as *mut c_void,
            ANDROID_USB_FEEDBACK_TIMEOUT_MS,
        );

        (*transfer_ptr.as_mut().iso_packet_desc.as_mut_ptr()).length =
            (*user_data_ptr).buffer.len() as u32;

        let submit_result = libusb_submit_transfer(transfer_ptr.as_ptr());
        if submit_result != 0 {
            libusb_free_transfer(transfer_ptr.as_ptr());
            drop(Box::from_raw(user_data_ptr));
            return Err(format!(
                "libusb_submit_transfer failed for feedback endpoint 0x{:02x} with code {}",
                feedback_endpoint.address, submit_result
            ));
        }
    }

    let completion = unsafe { &(*user_data_ptr).completion };
    let status = loop {
        if let Some(status) = *completion.status.lock().unwrap() {
            break status;
        }

        context
            .handle_events(Some(Duration::from_millis(10)))
            .map_err(|error| format!("libusb_handle_events failed: {}", error))?;
    };

    let (actual_length, data) = unsafe {
        let transfer_ref = transfer_ptr.as_ref();
        let actual_length = (*transfer_ref.iso_packet_desc.as_ptr()).actual_length as usize;
        let buffer = &(*user_data_ptr).buffer;
        let data = buffer[..actual_length.min(buffer.len())].to_vec();
        (actual_length, data)
    };

    unsafe {
        libusb_free_transfer(transfer_ptr.as_ptr());
        drop(Box::from_raw(user_data_ptr));
    }

    match status {
        LIBUSB_TRANSFER_COMPLETED if actual_length > 0 => Ok(Some(data)),
        LIBUSB_TRANSFER_COMPLETED => Ok(None),
        LIBUSB_TRANSFER_TIMED_OUT => Ok(None),
        LIBUSB_TRANSFER_CANCELLED => Ok(None),
        LIBUSB_TRANSFER_STALL => Err("isochronous feedback transfer stalled".to_string()),
        LIBUSB_TRANSFER_NO_DEVICE => Err("USB DAC disconnected".to_string()),
        LIBUSB_TRANSFER_OVERFLOW => Err("isochronous feedback transfer overflow".to_string()),
        LIBUSB_TRANSFER_ERROR => Err("isochronous feedback transfer failed".to_string()),
        other => Err(format!(
            "isochronous feedback transfer returned status {}",
            other
        )),
    }
}

fn validate_iso_packet_results(
    transfer: &libusb_transfer,
    packet_sizes: &[usize],
) -> Result<(), String> {
    let mut bad_statuses = Vec::new();
    let mut short_packets = Vec::new();

    for (index, expected_length) in packet_sizes.iter().enumerate() {
        let descriptor = unsafe { &*transfer.iso_packet_desc.as_ptr().add(index) };
        if descriptor.status != LIBUSB_TRANSFER_COMPLETED {
            bad_statuses.push(format!(
                "#{}:{}",
                index,
                iso_transfer_status_label(descriptor.status)
            ));
        }
        if descriptor.actual_length != descriptor.length {
            short_packets.push(format!(
                "#{}:{}/{}",
                index, descriptor.actual_length, descriptor.length
            ));
        } else if descriptor.actual_length as usize != *expected_length {
            short_packets.push(format!(
                "#{}:{}/{}",
                index, descriptor.actual_length, expected_length
            ));
        }
    }

    if bad_statuses.is_empty() && short_packets.is_empty() {
        return Ok(());
    }

    let mut parts = Vec::new();
    if !bad_statuses.is_empty() {
        parts.push(format!("packet_statuses={}", bad_statuses.join(",")));
    }
    if !short_packets.is_empty() {
        parts.push(format!("packet_lengths={}", short_packets.join(",")));
    }
    Err(format!(
        "isochronous transfer completed with packet errors: {}",
        parts.join("; ")
    ))
}

fn iso_transfer_status_label(status: i32) -> &'static str {
    match status {
        LIBUSB_TRANSFER_COMPLETED => "completed",
        LIBUSB_TRANSFER_TIMED_OUT => "timed_out",
        LIBUSB_TRANSFER_STALL => "stall",
        LIBUSB_TRANSFER_NO_DEVICE => "no_device",
        LIBUSB_TRANSFER_OVERFLOW => "overflow",
        LIBUSB_TRANSFER_CANCELLED => "cancelled",
        LIBUSB_TRANSFER_ERROR => "error",
        _ => "unknown",
    }
}
