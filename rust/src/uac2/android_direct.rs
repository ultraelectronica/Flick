use crate::audio::commands::AudioEvent;
use crate::audio::engine::{audio_callback, AudioCallbackData};
use crate::uac2::{iso_packet_scheduler::IsoPacketScheduler, AudioControlParser, DescriptorIter};
use crossbeam_channel::Sender;
use libusb1_sys::{
    constants::{
        LIBUSB_TRANSFER_CANCELLED, LIBUSB_TRANSFER_COMPLETED, LIBUSB_TRANSFER_ERROR,
        LIBUSB_TRANSFER_NO_DEVICE, LIBUSB_TRANSFER_OVERFLOW, LIBUSB_TRANSFER_STALL,
        LIBUSB_TRANSFER_TIMED_OUT,
    },
    libusb_alloc_transfer, libusb_cancel_transfer, libusb_fill_iso_transfer, libusb_free_transfer,
    libusb_submit_transfer, libusb_transfer, libusb_transfer_cb_fn,
};
use log::{error as log_error, info as log_info};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use rusb::{
    disable_device_discovery, supports_detach_kernel_driver, ConfigDescriptor, Context, Device,
    DeviceHandle, Direction, Error as UsbError, Speed, SyncType, TransferType, UsageType,
    UsbContext,
};
use serde::Serialize;
use std::collections::HashSet;
use std::ffi::c_void;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex as StdMutex, Once};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

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
const UAC2_CLOCK_SOURCE_CLOCK_VALID_CONTROL: u16 = 0x0200;
const UAC2_INPUT_TERMINAL: u8 = 0x02;
const UAC2_OUTPUT_TERMINAL: u8 = 0x03;
const UAC2_FEATURE_UNIT: u8 = 0x06;
const FORMAT_TAG_PCM: u16 = 0x0001;
const FORMAT_TAG_PCM8: u16 = 0x0002;
const FORMAT_TAG_IEEE_FLOAT: u16 = 0x0003;
const UAC2_REQUEST_GET_MIN: u8 = 0x82;
const UAC2_REQUEST_GET_MAX: u8 = 0x83;
const UAC2_REQUEST_GET_RES: u8 = 0x84;
const UAC2_FEATURE_UNIT_MUTE_CONTROL: u16 = 0x0101;
const UAC2_FEATURE_UNIT_VOLUME_CONTROL: u16 = 0x0100;
const FEATURE_MUTE: u32 = 0x0001;
const FEATURE_VOLUME: u32 = 0x0002;
const ISO_TRANSFER_TIMEOUT_MS: u32 = 1000;
const ANDROID_USB_BUFFER_CAPACITY_MS: usize = 200;
const ANDROID_USB_BUFFER_TARGET_MS: usize = 100;
const ANDROID_USB_RENDER_CHUNK_MS: usize = 10;
const ANDROID_USB_RENDER_POLL_MS: u64 = 2;
const ANDROID_USB_STABLE_TRANSFER_THRESHOLD: usize = 64;
const ANDROID_USB_TRANSFER_QUEUE_DEPTH: usize = 4;
const ANDROID_USB_REQUIRE_VERIFIED_RATE_DEFAULT: bool = true;
const ANDROID_USB_CLOCK_SETTLE_DELAY_MS_DEFAULT: u64 = 20;
const ANDROID_USB_FEEDBACK_TIMEOUT_MS: u32 = 50;
const ANDROID_USB_LOUD_RENDER_LOG_THRESHOLD: f32 = 0.1;
const ANDROID_USB_LOUD_TRANSFER_LOG_INTERVAL: u64 = 32;
const ANDROID_USB_TIMING_LOG_INTERVAL: u64 = 128;

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
    prefer_padded_24bit_transport: bool,
}

const KNOWN_DAC_QUIRKS: &[DacQuirk] = &[DacQuirk {
    vendor_id: 12230,
    product_id: 61546,
    product_name_contains: "MOONDROP Dawn Pro",
    clock_policy: DacClockPolicy::RequireVerifiedRate,
    settle_delay_ms: 50,
    prefer_padded_24bit_transport: true,
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

fn device_prefers_padded_24bit_transport(device: &Device<Context>) -> bool {
    let Ok(descriptor) = device.device_descriptor() else {
        return false;
    };

    KNOWN_DAC_QUIRKS.iter().any(|quirk| {
        quirk.prefer_padded_24bit_transport
            && quirk.vendor_id == descriptor.vendor_id()
            && quirk.product_id == descriptor.product_id()
    })
}

fn transport_container_preference_rank(
    candidate: &AndroidIsoStreamCandidate,
    playback_format: AndroidDirectUsbPlaybackFormat,
    prefer_padded_24bit_transport: bool,
) -> u8 {
    if !prefer_padded_24bit_transport || playback_format.bit_depth != 24 {
        return 0;
    }

    match (candidate.bit_resolution, candidate.subslot_size) {
        (24, 4) => 0,
        (24, 3) => 1,
        _ => 2,
    }
}

#[derive(Debug)]
struct AndroidDirectUsbOwnedFd(RawFd);

impl Drop for AndroidDirectUsbOwnedFd {
    fn drop(&mut self) {
        if self.0 >= 0 {
            unsafe {
                libc::close(self.0);
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct AndroidDirectUsbDevice {
    pub fd: RawFd,
    _fd_owner: Arc<AndroidDirectUsbOwnedFd>,
    pub vendor_id: u16,
    pub product_id: u16,
    pub product_name: String,
    pub manufacturer: String,
    pub serial: Option<String>,
    pub device_name: Option<String>,
}

impl AndroidDirectUsbDevice {
    pub fn try_new(
        fd: RawFd,
        vendor_id: u16,
        product_id: u16,
        product_name: String,
        manufacturer: String,
        serial: Option<String>,
        device_name: Option<String>,
    ) -> Result<Self, String> {
        let duplicated_fd = unsafe { libc::dup(fd) };
        if duplicated_fd < 0 {
            return Err(format!(
                "Failed to duplicate Android USB file descriptor: {}",
                std::io::Error::last_os_error()
            ));
        }

        Ok(Self {
            fd: duplicated_fd,
            _fd_owner: Arc::new(AndroidDirectUsbOwnedFd(duplicated_fd)),
            vendor_id,
            product_id,
            product_name,
            manufacturer,
            serial,
            device_name,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
    pub hardware_volume_supported: bool,
    pub hardware_mute_supported: bool,
    pub hardware_volume_normalized: Option<f64>,
    pub hardware_mute_active: Option<bool>,
    pub hardware_volume_min_raw: Option<i16>,
    pub hardware_volume_max_raw: Option<i16>,
    pub hardware_volume_resolution_raw: Option<i16>,
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
    pub transfer_queue_depth: Option<u32>,
    pub completed_transfers: Option<u64>,
    pub last_transfer_turnaround_us: Option<u64>,
    pub max_transfer_turnaround_us: Option<u64>,
    pub last_submit_gap_us: Option<u64>,
    pub max_submit_gap_us: Option<u64>,
    pub effective_consumer_rate_milli_hz: Option<u64>,
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
    hardware_volume_control: Option<AndroidDirectUsbHardwareVolumeControl>,
    hardware_volume_normalized: Option<f64>,
    hardware_mute_active: Option<bool>,
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

#[derive(Debug, Clone)]
struct AndroidDirectUsbHardwareVolumeControl {
    interface_number: u8,
    feature_unit_id: u8,
    volume_channel: u16,
    mute_channel: Option<u16>,
    min_volume_raw: i16,
    max_volume_raw: i16,
    resolution_raw: i16,
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
    transfer_queue_depth: AtomicUsize,
    frames_per_packet: AtomicUsize,
    buffered_samples: AtomicUsize,
    underrun_count: AtomicU64,
    producer_frames: AtomicU64,
    consumer_frames: AtomicU64,
    completed_transfers: AtomicU64,
    last_transfer_turnaround_us: AtomicU64,
    max_transfer_turnaround_us: AtomicU64,
    last_submit_gap_us: AtomicU64,
    max_submit_gap_us: AtomicU64,
    effective_consumer_rate_milli_hz: AtomicU64,
    /// Max |f32| over the `pcm_samples` prefix that was actually pushed (post-convert).
    last_push_max_abs_f32_bits: AtomicU32,
    /// Max |linear i32| over the pushed prefix (matches USB encoding input scale).
    last_push_max_abs_i32: AtomicU32,
}

#[derive(Debug)]
struct AndroidDirectUsbPcmRingBuffer {
    samples: Vec<i32>,
    capacity_samples: usize,
    read_index: usize,
    write_index: usize,
    len_samples: usize,
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
    /// bTerminalLink from the AS_GENERAL descriptor, used to trace the
    /// UAC2 topology to the correct Clock Entity.
    terminal_link: Option<u8>,
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

#[derive(Debug, Clone)]
struct AndroidStreamingInterfaceFormat {
    format_tag: u16,
    channels: u16,
    subslot_size: u8,
    bit_resolution: u8,
    terminal_link: Option<u8>,
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

struct IsoTransferSlot {
    transfer: std::ptr::NonNull<libusb_transfer>,
    user_data: *mut IsoTransferUserData,
    packet_sizes: Vec<usize>,
    queued_frame_count: usize,
    queued_underrun: bool,
    submitted_at: Option<Instant>,
    in_flight: bool,
}

struct IsoTransferPayload {
    packet_sizes: Vec<usize>,
    packet_samples: Vec<i32>,
    transfer_buffer: Vec<u8>,
    underrun: bool,
    frame_count: usize,
}

impl IsoTransferSlot {
    fn new(packet_count: usize, buffer_capacity: usize) -> Result<Self, String> {
        let completion = Arc::new(IsoTransferCompletion {
            status: StdMutex::new(None),
            condvar: Condvar::new(),
        });
        let user_data = Box::new(IsoTransferUserData {
            completion,
            buffer: vec![0u8; buffer_capacity.max(1)],
        });
        let user_data_ptr = Box::into_raw(user_data);
        let transfer = unsafe { libusb_alloc_transfer(packet_count as i32) };

        let Some(transfer) = std::ptr::NonNull::new(transfer) else {
            unsafe {
                drop(Box::from_raw(user_data_ptr));
            }
            return Err("libusb_alloc_transfer returned null".to_string());
        };

        Ok(Self {
            transfer,
            user_data: user_data_ptr,
            packet_sizes: vec![0; packet_count],
            queued_frame_count: 0,
            queued_underrun: false,
            submitted_at: None,
            in_flight: false,
        })
    }

    fn submit(
        &mut self,
        handle: &DeviceHandle<Context>,
        endpoint: u8,
        payload: IsoTransferPayload,
    ) -> Result<(), String> {
        if payload.packet_sizes.len() != self.packet_sizes.len() {
            return Err(format!(
                "isochronous packet count mismatch: slot={}, payload={}",
                self.packet_sizes.len(),
                payload.packet_sizes.len()
            ));
        }

        unsafe {
            let user_data = &mut *self.user_data;
            if payload.transfer_buffer.len() > user_data.buffer.len() {
                return Err(format!(
                    "isochronous transfer buffer too small: capacity={}, payload={}",
                    user_data.buffer.len(),
                    payload.transfer_buffer.len()
                ));
            }
            user_data.buffer[..payload.transfer_buffer.len()]
                .copy_from_slice(&payload.transfer_buffer);
            *user_data.completion.status.lock().unwrap() = None;

            libusb_fill_iso_transfer(
                self.transfer.as_mut(),
                handle.as_raw(),
                endpoint,
                user_data.buffer.as_mut_ptr(),
                payload.transfer_buffer.len() as i32,
                payload.packet_sizes.len() as i32,
                iso_transfer_callback,
                self.user_data as *mut c_void,
                ISO_TRANSFER_TIMEOUT_MS,
            );

            for (index, packet_size) in payload.packet_sizes.iter().enumerate() {
                (*self
                    .transfer
                    .as_mut()
                    .iso_packet_desc
                    .as_mut_ptr()
                    .add(index))
                .length = *packet_size as u32;
            }

            let submit_result = libusb_submit_transfer(self.transfer.as_ptr());
            if submit_result != 0 {
                return Err(format!(
                    "libusb_submit_transfer failed with code {}",
                    submit_result
                ));
            }
        }

        self.queued_frame_count = payload.frame_count;
        self.queued_underrun = payload.underrun;
        self.packet_sizes.copy_from_slice(&payload.packet_sizes);
        self.submitted_at = Some(Instant::now());
        self.in_flight = true;
        Ok(())
    }

    fn take_completion_status(&mut self) -> Option<i32> {
        let completion = unsafe { &(*self.user_data).completion };
        completion.status.lock().unwrap().take()
    }

    fn turnaround_us(&self) -> Option<u64> {
        self.submitted_at
            .map(|submitted_at| submitted_at.elapsed().as_micros().min(u128::from(u64::MAX)) as u64)
    }

    fn validate_packets(&self) -> Result<(), String> {
        let transfer = unsafe { self.transfer.as_ref() };
        validate_iso_packet_results(transfer, &self.packet_sizes)
    }

    fn mark_completed(&mut self) {
        self.queued_frame_count = 0;
        self.queued_underrun = false;
        self.submitted_at = None;
        self.in_flight = false;
    }

    fn cancel(&mut self) {
        if !self.in_flight {
            return;
        }

        let _ = unsafe { libusb_cancel_transfer(self.transfer.as_ptr()) };
    }
}

impl Drop for IsoTransferSlot {
    fn drop(&mut self) {
        unsafe {
            libusb_free_transfer(self.transfer.as_ptr());
            drop(Box::from_raw(self.user_data));
        }
    }
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
            transfer_queue_depth: AtomicUsize::new(0),
            frames_per_packet: AtomicUsize::new(0),
            buffered_samples: AtomicUsize::new(0),
            underrun_count: AtomicU64::new(0),
            producer_frames: AtomicU64::new(0),
            consumer_frames: AtomicU64::new(0),
            completed_transfers: AtomicU64::new(0),
            last_transfer_turnaround_us: AtomicU64::new(0),
            max_transfer_turnaround_us: AtomicU64::new(0),
            last_submit_gap_us: AtomicU64::new(0),
            max_submit_gap_us: AtomicU64::new(0),
            effective_consumer_rate_milli_hz: AtomicU64::new(0),
            last_push_max_abs_f32_bits: AtomicU32::new(0),
            last_push_max_abs_i32: AtomicU32::new(0),
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

    fn pop_into_or_pad(&mut self, output: &mut [i32], _channels: usize) -> bool {
        if output.is_empty() {
            return false;
        }

        let readable = output.len().min(self.len_samples);
        for destination in output.iter_mut().take(readable) {
            *destination = self.samples[self.read_index];
            self.read_index = (self.read_index + 1) % self.capacity_samples;
        }
        self.len_samples -= readable;

        let underrun = readable < output.len();
        if underrun {
            for sample in output[readable..].iter_mut() {
                *sample = 0;
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
/// Serializes JNI hardware volume/mute control transfers. Reusing the idle
/// `DIRECT_USB_LOCK` handle for feature-unit writes would require partial
/// interface release; a second transient open remains necessary, but we avoid
/// overlapping transient claims from concurrent UI/sync calls.
static ANDROID_DIRECT_HARDWARE_VOLUME_MUTEX: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));
static DIRECT_USB_DISCOVERY_DISABLED: Once = Once::new();
static ANDROID_DIRECT_USB_ENABLED: AtomicBool = AtomicBool::new(true);
static USB_SESSION_CLEAR_PENDING: AtomicBool = AtomicBool::new(false);

/// Global guard: only one USB streaming session may be active at a time.
/// Prevents "Resource busy" from concurrent or overlapping claim attempts.
static USB_SESSION_ACTIVE: AtomicBool = AtomicBool::new(false);

pub fn set_android_direct_usb_enabled(enabled: bool) {
    ANDROID_DIRECT_USB_ENABLED.store(enabled, Ordering::Release);
}

fn android_direct_usb_enabled() -> bool {
    ANDROID_DIRECT_USB_ENABLED.load(Ordering::Acquire)
}

pub fn is_usb_session_active() -> bool {
    USB_SESSION_ACTIVE.load(Ordering::SeqCst)
}

fn is_same_android_usb_device(a: &AndroidDirectUsbDevice, b: &AndroidDirectUsbDevice) -> bool {
    if a.device_name.is_some() && b.device_name.is_some() && a.device_name == b.device_name {
        return true;
    }

    if a.vendor_id != b.vendor_id || a.product_id != b.product_id {
        return false;
    }

    if a.serial.is_some() && b.serial.is_some() {
        return a.serial == b.serial;
    }

    a.product_name == b.product_name && a.manufacturer == b.manufacturer
}

fn clear_android_usb_device_state() {
    release_idle_lock();
    if DIRECT_USB_LIFECYCLE_STATE.lock().engine_state != AndroidDirectUsbEngineState::Fallback {
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Idle, None);
    }
    *DIRECT_USB_STATE.lock() = None;
}

fn clear_android_usb_device_now() {
    USB_SESSION_ACTIVE.store(false, Ordering::SeqCst);
    USB_SESSION_CLEAR_PENDING.store(false, Ordering::SeqCst);
    clear_android_usb_device_state();
}

fn complete_pending_android_usb_clear_if_idle() {
    if USB_SESSION_ACTIVE.load(Ordering::SeqCst) {
        return;
    }
    if !USB_SESSION_CLEAR_PENDING.swap(false, Ordering::SeqCst) {
        return;
    }

    eprintln!("Android USB direct: applying deferred clear after session stop");
    clear_android_usb_device_state();
}

/// Force-release the USB session guard. Called before re-initialization or on
/// unrecoverable errors to ensure the next attempt can proceed.
pub fn force_release_usb_session() {
    if USB_SESSION_ACTIVE.swap(false, Ordering::SeqCst) {
        eprintln!("Android USB direct: force-released USB session guard");
    }
    complete_pending_android_usb_clear_if_idle();
}

pub fn register_android_usb_device(device: AndroidDirectUsbDevice) -> Result<(), String> {
    let mut guard = DIRECT_USB_STATE.lock();
    if USB_SESSION_ACTIVE.load(Ordering::SeqCst) {
        if let Some(current_state) = guard.as_ref() {
            if is_same_android_usb_device(&current_state.device, &device) {
                eprintln!(
                    "Android USB direct: ignoring duplicate registration for '{}' while the session is active",
                    device.product_name
                );
                return Ok(());
            }
        }
        return Err(format!(
            "Android direct USB session is still active; refusing to replace registration for '{}'",
            device.product_name
        ));
    }

    USB_SESSION_CLEAR_PENDING.store(false, Ordering::SeqCst);
    let existing_format = guard.as_ref().and_then(|state| state.playback_format);

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
    *guard = Some(AndroidDirectUsbState {
        device,
        requested_playback_format: existing_format,
        playback_format: existing_format,
        lock_requested: true,
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
        hardware_volume_control: None,
        hardware_volume_normalized: None,
        hardware_mute_active: None,
        packet_schedule_frames_preview: Vec::new(),
        runtime_stats: None,
    });
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
        let format = sanitize_android_usb_playback_format(format);
        match state.dac_clock_policy {
            DacClockPolicy::Force48kHzOnly => {}
            DacClockPolicy::RequireVerifiedRate | DacClockPolicy::AllowUnverified => {}
        }
        format
    });

    if USB_SESSION_ACTIVE.load(Ordering::SeqCst)
        && state.playback_format == sanitized
        && state.requested_playback_format == sanitized
    {
        eprintln!(
            "[USB] Keeping active direct USB verification state for unchanged playback format"
        );
        return Ok(());
    }

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
            return Ok(());
        };

        state.lock_requested = enabled;
        state.stream_active
    };

    if enabled && !stream_active {
        ensure_android_usb_idle_lock()?;
    }

    Ok(())
}

pub fn clear_android_usb_device() {
    USB_SESSION_CLEAR_PENDING.store(true, Ordering::SeqCst);
    if USB_SESSION_ACTIVE.load(Ordering::SeqCst) {
        eprintln!("Android USB direct: deferring clear until the active session stops");
        return;
    }

    clear_android_usb_device_now();
}

pub fn wait_for_android_usb_session_stop(timeout: Duration) -> bool {
    let started_at = Instant::now();
    while USB_SESSION_ACTIVE.load(Ordering::SeqCst) {
        if started_at.elapsed() >= timeout {
            return false;
        }
        thread::sleep(Duration::from_millis(10));
    }

    complete_pending_android_usb_clear_if_idle();
    true
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
    let usb_session_active = USB_SESSION_ACTIVE.load(Ordering::SeqCst);
    if usb_session_active {
        eprintln!("Android USB direct debug: USB_SESSION_ACTIVE=true");
    }

    let Some(state) = state else {
        return AndroidDirectUsbDebugState {
            idle_lock_held,
            engine_state: Some(
                android_direct_usb_engine_state_label(lifecycle_state.engine_state).to_string(),
            ),
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
        engine_state: Some(
            android_direct_usb_engine_state_label(lifecycle_state.engine_state).to_string(),
        ),
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
        hardware_volume_supported: state.hardware_volume_control.is_some(),
        hardware_mute_supported: state
            .hardware_volume_control
            .as_ref()
            .is_some_and(|control| control.mute_channel.is_some()),
        hardware_volume_normalized: state.hardware_volume_normalized,
        hardware_mute_active: state.hardware_mute_active,
        hardware_volume_min_raw: state
            .hardware_volume_control
            .as_ref()
            .map(|control| control.min_volume_raw),
        hardware_volume_max_raw: state
            .hardware_volume_control
            .as_ref()
            .map(|control| control.max_volume_raw),
        hardware_volume_resolution_raw: state
            .hardware_volume_control
            .as_ref()
            .map(|control| control.resolution_raw),
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
        transfer_queue_depth: runtime_stats
            .map(|stats| stats.transfer_queue_depth.load(Ordering::Relaxed) as u32)
            .filter(|depth| *depth > 0),
        completed_transfers: runtime_stats
            .map(|stats| stats.completed_transfers.load(Ordering::Relaxed)),
        last_transfer_turnaround_us: runtime_stats
            .map(|stats| stats.last_transfer_turnaround_us.load(Ordering::Relaxed))
            .filter(|value| *value > 0),
        max_transfer_turnaround_us: runtime_stats
            .map(|stats| stats.max_transfer_turnaround_us.load(Ordering::Relaxed))
            .filter(|value| *value > 0),
        last_submit_gap_us: runtime_stats
            .map(|stats| stats.last_submit_gap_us.load(Ordering::Relaxed))
            .filter(|value| *value > 0),
        max_submit_gap_us: runtime_stats
            .map(|stats| stats.max_submit_gap_us.load(Ordering::Relaxed))
            .filter(|value| *value > 0),
        effective_consumer_rate_milli_hz: runtime_stats
            .map(|stats| {
                stats
                    .effective_consumer_rate_milli_hz
                    .load(Ordering::Relaxed)
            })
            .filter(|value| *value > 0),
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
        return Ok(preferred_sample_rate);
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

        if state.stream_active || USB_SESSION_ACTIVE.load(Ordering::SeqCst) {
            state.requested_playback_format = Some(requested_format);
            if state.playback_format.map(|f| f.sample_rate) != Some(requested_format.sample_rate) {
                state.playback_format = Some(requested_format);
            }
            return Ok(Some(requested_format.sample_rate));
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
        let capability_model =
            build_android_usb_capability_model(&usb_device, &claimed_handle.handle, speed).ok();
        set_capability_model(capability_model.clone());

        let candidate = match select_stream_candidate(
            &usb_device,
            &claimed_handle.handle,
            requested_format,
            speed,
        ) {
            Ok(c) => c,
            Err(error) => {
                set_last_error(Some(error.clone()));
                set_direct_mode_refusal_reason(Some(error.clone()));
                return Err(error);
            }
        };

        // Find clock entity AFTER selecting candidate so we can trace the
        // topology using the candidate's bTerminalLink.
        let clock =
            find_audio_control_clock(&usb_device, &claimed_handle.handle, candidate.terminal_link);

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
            if let Err(e) = claimed_handle.ensure_interface_claimed(clock.interface_number) {
                log::error!(
                    "[USB] Failed to claim AudioControl interface {}: {}",
                    clock.interface_number,
                    e,
                );
            }
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
                log::info!(
                    "[USB] NEGOTIATION: usbClaimed={}, alt={}, endpoint=0x{:02x}, rate={}Hz",
                    claimed_handle
                        .claimed_interfaces
                        .contains(&candidate.interface_number),
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
                log::info!(
                    "[USB] NEGOTIATION CLOCK: confirmed={}Hz, clockOk={}, rateVerified={}, clockId={}, iface={}",
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
                &claimed_handle.handle,
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
                reported_rate = reported_rate
                    .or(current_rate)
                    .or(Some(requested_format.sample_rate));
                last_message = Some(message);
            }
        } else if let Some(actual_rate) = choose_adaptive_sample_rate(
            requested_format.sample_rate,
            None,
            None,
            capability_model.as_ref(),
            &usb_device,
            &claimed_handle.handle,
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
    handle: &DeviceHandle<Context>,
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
        if select_stream_candidate(device, handle, candidate_format, speed).is_ok() {
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

fn set_hardware_volume_control(control: Option<AndroidDirectUsbHardwareVolumeControl>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        state.hardware_volume_control = control;
        if state.hardware_volume_control.is_none() {
            state.hardware_volume_normalized = None;
            state.hardware_mute_active = None;
        }
    }
}

fn set_hardware_volume_snapshot(volume: Option<f64>, muted: Option<bool>) {
    if let Some(state) = DIRECT_USB_STATE.lock().as_mut() {
        if let Some(volume) = volume {
            state.hardware_volume_normalized = Some(volume.clamp(0.0, 1.0));
        }
        if let Some(muted) = muted {
            state.hardware_mute_active = Some(muted);
        }
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
    let previous = lifecycle_state.engine_state;
    lifecycle_state.engine_state = state;
    lifecycle_state.reason = reason;
    if previous != state {
        eprintln!(
            "Android USB direct engine state: {:?} -> {:?}",
            previous, state
        );
    }
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
    if !state.stream_active {
        return false;
    }

    let Some(requested) = state.requested_playback_format else {
        return false;
    };
    let Some(effective) = state.playback_format else {
        return false;
    };

    // Bit-perfect requires: matching format, verified clock, and the engine
    // callback is running in bit_perfect bypass mode (no volume/EQ/dynamics).
    // Software volume is always inactive when bit_perfect bypass is enabled.
    requested.sample_rate == effective.sample_rate
        && requested.bit_depth == effective.bit_depth
        && requested.channels == effective.channels
        && state.clock_verification_passed
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

const CLAIM_RETRY_ATTEMPTS: u32 = 8;
const CLAIM_RETRY_DELAY_MS: u64 = 100;

fn claim_interface_with_recovery(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
) -> Result<(), String> {
    match handle.claim_interface(interface_number) {
        Ok(()) => return Ok(()),
        Err(initial_error) => {
            let mut details = vec![format!("initial claim failed: {}", initial_error)];

            if supports_detach_kernel_driver() {
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

                if let Ok(()) = handle.claim_interface(interface_number) {
                    eprintln!(
                        "Android USB direct claimed interface {} after kernel-driver recovery",
                        interface_number
                    );
                    return Ok(());
                }
            }

            for attempt in 1..=CLAIM_RETRY_ATTEMPTS {
                thread::sleep(Duration::from_millis(CLAIM_RETRY_DELAY_MS));
                match handle.claim_interface(interface_number) {
                    Ok(()) => {
                        eprintln!(
                            "Android USB direct claimed interface {} on retry {} after {}ms settle",
                            interface_number,
                            attempt,
                            attempt as u64 * CLAIM_RETRY_DELAY_MS,
                        );
                        return Ok(());
                    }
                    Err(error) => {
                        details.push(format!(
                            "retry {} after {}ms: {}",
                            attempt,
                            attempt as u64 * CLAIM_RETRY_DELAY_MS,
                            error
                        ));
                    }
                }
            }

            Err(format!(
                "Failed to claim USB interface {}: {}",
                interface_number,
                details.join("; ")
            ))
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

fn open_transient_usb_handle(
    device: &AndroidDirectUsbDevice,
) -> Result<AndroidDirectUsbClaimedHandle, String> {
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

#[derive(Debug, Clone)]
struct AndroidAudioControlTopology {
    interface_number: u8,
    feature_units: Vec<crate::uac2::FeatureUnit>,
    output_terminals: Vec<crate::uac2::OutputTerminal>,
}

fn parse_audio_control_topologies(
    device: &Device<Context>,
) -> Result<Vec<AndroidAudioControlTopology>, String> {
    let config_descriptor = device
        .active_config_descriptor()
        .map_err(|error| format!("Failed to read active USB config descriptor: {}", error))?;
    let parser = AudioControlParser;
    let mut topologies = Vec::new();

    for interface in config_descriptor.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() != USB_CLASS_AUDIO
                || descriptor.sub_class_code() != USB_SUBCLASS_AUDIOCONTROL
            {
                continue;
            }

            let mut topology = AndroidAudioControlTopology {
                interface_number: descriptor.interface_number(),
                feature_units: Vec::new(),
                output_terminals: Vec::new(),
            };

            for extra in DescriptorIter::new(descriptor.extra()) {
                let parsed = match extra.get(2).copied() {
                    Some(UAC2_OUTPUT_TERMINAL) => {
                        parser.parse_output_terminal(extra).ok().map(|value| {
                            topology.output_terminals.push(value);
                        })
                    }
                    Some(UAC2_FEATURE_UNIT) => parser.parse_feature_unit(extra).ok().map(|value| {
                        topology.feature_units.push(value);
                    }),
                    _ => None,
                };
                let _ = parsed;
            }

            if !topology.feature_units.is_empty() || !topology.output_terminals.is_empty() {
                topologies.push(topology);
            }
        }
    }

    Ok(topologies)
}

fn feature_unit_channel_with_control(
    feature_unit: &crate::uac2::FeatureUnit,
    control_mask: u32,
) -> Option<u16> {
    feature_unit
        .bma_controls
        .iter()
        .position(|controls| controls & control_mask != 0)
        .map(|index| index as u16)
}

fn read_feature_unit_i16_control(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    feature_unit_id: u8,
    channel: u16,
    request: u8,
    control_selector: u16,
) -> Result<i16, String> {
    let request_type = USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let value = control_selector | (channel & 0xff);
    let index = (interface_number as u16) | ((feature_unit_id as u16) << 8);
    let mut data = [0u8; 2];
    let transferred = handle
        .read_control(
            request_type,
            request,
            value,
            index,
            &mut data,
            Duration::from_secs(1),
        )
        .map_err(|error| format!("feature-unit control read failed: {}", error))?;
    if transferred < data.len() {
        return Err(format!(
            "feature-unit control read returned {} bytes, expected {}",
            transferred,
            data.len()
        ));
    }
    Ok(i16::from_le_bytes(data))
}

fn write_feature_unit_i16_control(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    feature_unit_id: u8,
    channel: u16,
    control_selector: u16,
    value_raw: i16,
) -> Result<(), String> {
    let request_type = USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let value = control_selector | (channel & 0xff);
    let index = (interface_number as u16) | ((feature_unit_id as u16) << 8);
    let data = value_raw.to_le_bytes();
    handle
        .write_control(
            request_type,
            UAC2_REQUEST_SET_CUR,
            value,
            index,
            &data,
            Duration::from_secs(1),
        )
        .map_err(|error| format!("feature-unit control write failed: {}", error))?;
    Ok(())
}

fn read_feature_unit_bool_control(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    feature_unit_id: u8,
    channel: u16,
    control_selector: u16,
) -> Result<bool, String> {
    let request_type = USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let value = control_selector | (channel & 0xff);
    let index = (interface_number as u16) | ((feature_unit_id as u16) << 8);
    let mut data = [0u8; 1];
    let transferred = handle
        .read_control(
            request_type,
            UAC2_REQUEST_GET_CUR,
            value,
            index,
            &mut data,
            Duration::from_secs(1),
        )
        .map_err(|error| format!("feature-unit mute read failed: {}", error))?;
    if transferred < data.len() {
        return Err(format!(
            "feature-unit mute read returned {} bytes, expected {}",
            transferred,
            data.len()
        ));
    }
    Ok(data[0] != 0)
}

fn write_feature_unit_bool_control(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    feature_unit_id: u8,
    channel: u16,
    control_selector: u16,
    enabled: bool,
) -> Result<(), String> {
    let request_type = USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let value = control_selector | (channel & 0xff);
    let index = (interface_number as u16) | ((feature_unit_id as u16) << 8);
    let data = [u8::from(enabled)];
    handle
        .write_control(
            request_type,
            UAC2_REQUEST_SET_CUR,
            value,
            index,
            &data,
            Duration::from_secs(1),
        )
        .map_err(|error| format!("feature-unit mute write failed: {}", error))?;
    Ok(())
}

fn read_feature_unit_volume_range(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    feature_unit_id: u8,
    channel: u16,
) -> Result<(i16, i16, i16), String> {
    Ok((
        read_feature_unit_i16_control(
            handle,
            interface_number,
            feature_unit_id,
            channel,
            UAC2_REQUEST_GET_MIN,
            UAC2_FEATURE_UNIT_VOLUME_CONTROL,
        )?,
        read_feature_unit_i16_control(
            handle,
            interface_number,
            feature_unit_id,
            channel,
            UAC2_REQUEST_GET_MAX,
            UAC2_FEATURE_UNIT_VOLUME_CONTROL,
        )?,
        read_feature_unit_i16_control(
            handle,
            interface_number,
            feature_unit_id,
            channel,
            UAC2_REQUEST_GET_RES,
            UAC2_FEATURE_UNIT_VOLUME_CONTROL,
        )?,
    ))
}

fn normalize_hardware_volume(value_raw: i16, min_raw: i16, max_raw: i16) -> f64 {
    if max_raw <= min_raw {
        return if value_raw >= max_raw { 1.0 } else { 0.0 };
    }

    ((value_raw - min_raw) as f64 / (max_raw - min_raw) as f64).clamp(0.0, 1.0)
}

fn quantize_hardware_volume(
    normalized: f64,
    min_raw: i16,
    max_raw: i16,
    resolution_raw: i16,
) -> i16 {
    let span = (max_raw - min_raw) as f64;
    let raw = min_raw as f64 + normalized.clamp(0.0, 1.0) * span;
    if resolution_raw <= 0 {
        return raw.round().clamp(min_raw as f64, max_raw as f64) as i16;
    }

    let step = resolution_raw as f64;
    let stepped = min_raw as f64 + ((raw - min_raw as f64) / step).round() * step;
    stepped.clamp(min_raw as f64, max_raw as f64) as i16
}

fn build_hardware_volume_control_from_feature_unit(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    feature_unit: &crate::uac2::FeatureUnit,
) -> Option<AndroidDirectUsbHardwareVolumeControl> {
    let volume_channel = feature_unit_channel_with_control(feature_unit, FEATURE_VOLUME)?;
    let mute_channel = feature_unit_channel_with_control(feature_unit, FEATURE_MUTE);
    let (min_volume_raw, max_volume_raw, resolution_raw) = read_feature_unit_volume_range(
        handle,
        interface_number,
        feature_unit.b_unit_id,
        volume_channel,
    )
    .ok()?;

    Some(AndroidDirectUsbHardwareVolumeControl {
        interface_number,
        feature_unit_id: feature_unit.b_unit_id,
        volume_channel,
        mute_channel,
        min_volume_raw,
        max_volume_raw,
        resolution_raw,
    })
}

fn discover_hardware_volume_control_for_terminal(
    handle: &DeviceHandle<Context>,
    topology: &AndroidAudioControlTopology,
    terminal_link: Option<u8>,
) -> Option<AndroidDirectUsbHardwareVolumeControl> {
    let terminal_link = terminal_link?;
    let mut pending = vec![terminal_link];
    let mut visited = HashSet::new();

    while let Some(entity_id) = pending.pop() {
        if !visited.insert(entity_id) {
            continue;
        }

        if let Some(feature_unit) = topology
            .feature_units
            .iter()
            .find(|feature_unit| feature_unit.b_unit_id == entity_id)
        {
            if let Some(control) = build_hardware_volume_control_from_feature_unit(
                handle,
                topology.interface_number,
                feature_unit,
            ) {
                return Some(control);
            }
            pending.push(feature_unit.b_source_id);
        }

        for feature_unit in &topology.feature_units {
            if feature_unit.b_source_id == entity_id {
                if let Some(control) = build_hardware_volume_control_from_feature_unit(
                    handle,
                    topology.interface_number,
                    feature_unit,
                ) {
                    return Some(control);
                }
                pending.push(feature_unit.b_unit_id);
            }
        }

        for output_terminal in &topology.output_terminals {
            if output_terminal.b_terminal_id == entity_id {
                pending.push(output_terminal.b_source_id);
            }
            if output_terminal.b_source_id == entity_id {
                pending.push(output_terminal.b_terminal_id);
            }
        }
    }

    None
}

fn discover_android_usb_hardware_volume_control(
    device: &Device<Context>,
    handle: &DeviceHandle<Context>,
    terminal_link: Option<u8>,
) -> Option<AndroidDirectUsbHardwareVolumeControl> {
    let topologies = parse_audio_control_topologies(device).ok()?;

    for topology in &topologies {
        if let Some(control) =
            discover_hardware_volume_control_for_terminal(handle, topology, terminal_link)
        {
            return Some(control);
        }
    }

    for topology in &topologies {
        for feature_unit in &topology.feature_units {
            if let Some(control) = build_hardware_volume_control_from_feature_unit(
                handle,
                topology.interface_number,
                feature_unit,
            ) {
                return Some(control);
            }
        }
    }

    None
}

fn refresh_android_usb_hardware_volume_snapshot_with_handle(
    handle: &DeviceHandle<Context>,
    control: &AndroidDirectUsbHardwareVolumeControl,
) -> Result<(f64, Option<bool>), String> {
    let current_raw = read_feature_unit_i16_control(
        handle,
        control.interface_number,
        control.feature_unit_id,
        control.volume_channel,
        UAC2_REQUEST_GET_CUR,
        UAC2_FEATURE_UNIT_VOLUME_CONTROL,
    )?;
    let normalized =
        normalize_hardware_volume(current_raw, control.min_volume_raw, control.max_volume_raw);
    let muted = control
        .mute_channel
        .map(|channel| {
            read_feature_unit_bool_control(
                handle,
                control.interface_number,
                control.feature_unit_id,
                channel,
                UAC2_FEATURE_UNIT_MUTE_CONTROL,
            )
        })
        .transpose()?;
    Ok((normalized, muted))
}

pub fn android_direct_has_hardware_volume_control() -> bool {
    DIRECT_USB_STATE
        .lock()
        .as_ref()
        .and_then(|state| state.hardware_volume_control.as_ref())
        .is_some()
}

pub fn android_direct_cached_hardware_volume() -> Option<f64> {
    DIRECT_USB_STATE
        .lock()
        .as_ref()
        .and_then(|state| state.hardware_volume_normalized)
}

pub fn android_direct_cached_hardware_mute() -> Option<bool> {
    DIRECT_USB_STATE
        .lock()
        .as_ref()
        .and_then(|state| state.hardware_mute_active)
}

pub fn android_direct_set_hardware_volume(volume: f64) -> Result<(), String> {
    let _hold = ANDROID_DIRECT_HARDWARE_VOLUME_MUTEX.lock();
    let state = DIRECT_USB_STATE
        .lock()
        .as_ref()
        .cloned()
        .ok_or_else(|| "No Android direct USB DAC is registered".to_string())?;
    let control = state
        .hardware_volume_control
        .clone()
        .ok_or_else(|| "Android direct USB hardware volume is unavailable".to_string())?;
    let mut claimed_handle = open_transient_usb_handle(&state.device)?;
    if let Err(error) = claimed_handle.ensure_interface_claimed(control.interface_number) {
        log_error!(
            "[USB] Failed to claim AudioControl interface {} for hardware volume: {}",
            control.interface_number,
            error
        );
    }

    let target_raw = quantize_hardware_volume(
        volume,
        control.min_volume_raw,
        control.max_volume_raw,
        control.resolution_raw,
    );
    let write_result = write_feature_unit_i16_control(
        &claimed_handle.handle,
        control.interface_number,
        control.feature_unit_id,
        control.volume_channel,
        UAC2_FEATURE_UNIT_VOLUME_CONTROL,
        target_raw,
    );
    let snapshot_result =
        refresh_android_usb_hardware_volume_snapshot_with_handle(&claimed_handle.handle, &control);
    release_claimed_interfaces(&claimed_handle.handle, &claimed_handle.claimed_interfaces);
    write_result?;
    let (normalized, muted) = snapshot_result?;
    set_hardware_volume_snapshot(Some(normalized), muted);
    Ok(())
}

pub fn android_direct_set_hardware_mute(muted: bool) -> Result<(), String> {
    let _hold = ANDROID_DIRECT_HARDWARE_VOLUME_MUTEX.lock();
    let state = DIRECT_USB_STATE
        .lock()
        .as_ref()
        .cloned()
        .ok_or_else(|| "No Android direct USB DAC is registered".to_string())?;
    let control = state
        .hardware_volume_control
        .clone()
        .ok_or_else(|| "Android direct USB hardware mute is unavailable".to_string())?;
    let mute_channel = control
        .mute_channel
        .ok_or_else(|| "Android direct USB hardware mute is unavailable".to_string())?;
    let mut claimed_handle = open_transient_usb_handle(&state.device)?;
    if let Err(error) = claimed_handle.ensure_interface_claimed(control.interface_number) {
        log_error!(
            "[USB] Failed to claim AudioControl interface {} for hardware mute: {}",
            control.interface_number,
            error
        );
    }

    let write_result = write_feature_unit_bool_control(
        &claimed_handle.handle,
        control.interface_number,
        control.feature_unit_id,
        mute_channel,
        UAC2_FEATURE_UNIT_MUTE_CONTROL,
        muted,
    );
    let snapshot_result =
        refresh_android_usb_hardware_volume_snapshot_with_handle(&claimed_handle.handle, &control);
    release_claimed_interfaces(&claimed_handle.handle, &claimed_handle.claimed_interfaces);
    write_result?;
    let (normalized, muted) = snapshot_result?;
    set_hardware_volume_snapshot(Some(normalized), muted);
    Ok(())
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
    build_android_usb_capability_model(&inspected_device, &handle, inspected_device.speed())
}

fn build_android_usb_capability_model(
    device: &Device<Context>,
    handle: &DeviceHandle<Context>,
    speed: Speed,
) -> Result<AndroidDirectUsbCapabilityModel, String> {
    let config_descriptor = device
        .active_config_descriptor()
        .map_err(|error| format!("Failed to read active USB config descriptor: {}", error))?;

    let mut alt_settings = Vec::new();
    let mut supported_sample_rates = Vec::new();
    let mut supported_bit_depths = Vec::new();
    let mut supported_channels = Vec::new();
    let mut stream_rate_cache =
        std::collections::HashMap::<(u8, Option<u8>), Vec<SamplingFrequencySubrange>>::new();

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
            let sample_rate_ranges = stream_rate_cache
                .entry((descriptor.interface_number(), stream_format.terminal_link))
                .or_insert_with(|| {
                    discover_stream_sample_rate_ranges(
                        device,
                        handle,
                        descriptor.interface_number(),
                        stream_format.terminal_link,
                    )
                })
                .clone();
            let sample_rates = representative_sample_rates_from_ranges(&sample_rate_ranges);

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
                supported_sample_rates.extend(sample_rates.iter().copied());
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
                    sample_rates: sample_rates.clone(),
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
    _keep_locked: bool,
) {
    if let Some(interface_number) = active_interface {
        let _ = claimed_handle
            .handle
            .set_alternate_setting(interface_number, 0);
    }

    let device_registered = DIRECT_USB_STATE.lock().is_some();
    if device_registered {
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
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(error.clone()));
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
    if USB_SESSION_CLEAR_PENDING.load(Ordering::SeqCst) {
        eprintln!(
            "Android USB direct backend skipped: clear requested before startup for preferred {} Hz",
            preferred_sample_rate
        );
        return Ok(None);
    }

    // Wait for any previous USB session to finish cleanup (up to 1.5s).
    // This prevents "Resource busy" when the engine is recreated for a
    // new track before the old backend's threads have fully stopped.
    for attempt in 0..15 {
        if !USB_SESSION_ACTIVE.load(Ordering::SeqCst) {
            break;
        }
        if attempt == 0 {
            eprintln!("Android USB direct: previous session still active, waiting for cleanup...");
        }
        thread::sleep(Duration::from_millis(100));
    }

    if USB_SESSION_ACTIVE.swap(true, Ordering::SeqCst) {
        eprintln!("Android USB direct: force-releasing stale USB session guard");
        force_release_usb_session();
        USB_SESSION_ACTIVE.store(true, Ordering::SeqCst);
    }

    match create_android_usb_backend_inner(callback_data, event_tx, preferred_sample_rate) {
        Ok(Some(backend)) => Ok(Some(backend)),
        Ok(None) => {
            USB_SESSION_ACTIVE.store(false, Ordering::SeqCst);
            Ok(None)
        }
        Err(error) => {
            USB_SESSION_ACTIVE.store(false, Ordering::SeqCst);
            Err(error)
        }
    }
}

fn create_android_usb_backend_inner(
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
        let requested_playback_format = state
            .requested_playback_format
            .unwrap_or(effective_playback_format);
        let (playback_format, use_requested_playback_format) = if effective_playback_format
            .sample_rate
            == preferred_sample_rate
        {
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
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(error.clone()));
        error
    })?;
    let requested_playback_format = state.requested_playback_format.unwrap_or(playback_format);
    let device = claimed_handle.handle.device();
    let speed = device.speed();
    let lock_requested = current_lock_requested_for_fd(state.device.fd);
    set_capability_model(
        build_android_usb_capability_model(&device, &claimed_handle.handle, speed).ok(),
    );
    let candidate =
        match select_stream_candidate(&device, &claimed_handle.handle, playback_format, speed) {
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
    let clock = find_audio_control_clock(&device, &claimed_handle.handle, candidate.terminal_link);
    let clock_detection_msg = match &clock {
        Some(c) => format!(
            "Clock found: interface={}, clockId={}, via_terminal_link={:?}",
            c.interface_number, c.clock_id, candidate.terminal_link,
        ),
        None => "Clock NOT FOUND: no UAC2 clock entity in any AudioControl descriptor".to_string(),
    };
    eprintln!(
        "[USB] Clock entity for '{}': {}",
        state.device.product_name, clock_detection_msg
    );

    set_last_error(Some(format!("[clock-diag] {}", clock_detection_msg)));
    set_direct_mode_refusal_reason(None);
    set_usb_stream_stable(false);
    set_active_transport(Some(&candidate));
    let hardware_volume_control = discover_android_usb_hardware_volume_control(
        &device,
        &claimed_handle.handle,
        candidate.terminal_link,
    );
    set_hardware_volume_control(hardware_volume_control.clone());
    if let Some(control) = hardware_volume_control.as_ref() {
        log_info!(
            "[USB] Hardware volume control found: feature_unit={}, interface={}, min={}, max={}, res={}",
            control.feature_unit_id,
            control.interface_number,
            control.min_volume_raw,
            control.max_volume_raw,
            control.resolution_raw
        );
        match refresh_android_usb_hardware_volume_snapshot_with_handle(
            &claimed_handle.handle,
            control,
        ) {
            Ok((volume, muted)) => {
                log_info!(
                    "[USB] Hardware volume initial: volume={}, muted={:?}",
                    volume,
                    muted
                );
                set_hardware_volume_snapshot(Some(volume), muted);
            }
            Err(error) => {
                log_error!(
                    "[USB] Failed to query hardware volume snapshot for feature unit {} on interface {}: {}",
                    control.feature_unit_id,
                    control.interface_number,
                    error
                );
            }
        }
    } else {
        log_info!("[USB] No hardware volume control discovered");
    }
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
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(error.clone()));
        cleanup_claimed_handle(claimed_handle, None, lock_requested);
        return Err(error);
    }

    claimed_handle
        .handle
        .set_alternate_setting(candidate.interface_number, 0)
        .ok();
    thread::sleep(Duration::from_millis(50));

    let mut clock_control_attempted = state.clock_control_attempted;
    let mut clock_control_succeeded = state.clock_control_succeeded;
    let mut clock_verification_passed = state.clock_verification_passed;
    let mut reported_sample_rate = state
        .clock_status
        .as_ref()
        .and_then(|status| status.reported_sample_rate);

    if let Some(clock) = clock {
        if let Err(e) = claimed_handle.ensure_interface_claimed(clock.interface_number) {
            log::error!(
                "[USB] Failed to claim AudioControl interface {}: {}",
                clock.interface_number,
                e,
            );
        }
        match state.dac_mode {
            DacMode::FullControl => {
                // ALWAYS send SET_CUR + verify, even if a previous negotiation
                // already programmed the clock. The alt-setting reset to 0 above
                // can cause some DACs to revert to a default rate (384kHz etc.),
                // and cached state from a prior session cannot be trusted.
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

                let clock_result_msg = format!(
                    "[clock-diag] SET_CUR {}Hz: clockOk={}, rateVerified={}, reported={}Hz, clockId={}, iface={}{}",
                    playback_format.sample_rate,
                    clock_outcome.clock_ok,
                    clock_outcome.rate_verified,
                    clock_outcome.reported_sample_rate.unwrap_or(0),
                    clock.clock_id,
                    clock.interface_number,
                    clock_outcome.message.as_ref().map(|m| format!(", msg={}", m)).unwrap_or_default(),
                );
                eprintln!("{}", clock_result_msg);
                set_last_error(Some(clock_result_msg));

                if !clock_outcome.clock_ok {
                    eprintln!(
                        "[USB] SET_CUR {}Hz -> FAILED: DAC reported={}Hz, verified={}",
                        playback_format.sample_rate,
                        clock_outcome.reported_sample_rate.unwrap_or(0),
                        clock_verification_passed,
                    );
                }

                if clock_outcome.known_mismatch {
                    eprintln!(
                        "[USB] SET_CUR {}Hz -> MISMATCH: DAC reports {}Hz",
                        playback_format.sample_rate,
                        clock_outcome.reported_sample_rate.unwrap_or_default(),
                    );
                }

                eprintln!(
                    "[USB] VALIDATION: usbClaimed={}, alt={}, endpoint=0x{:02x}, requestedRate={}Hz, dacRate={}Hz, verified={}",
                    claimed_handle.claimed_interfaces.contains(&candidate.interface_number),
                    candidate.alt_setting,
                    candidate.endpoint_address,
                    playback_format.sample_rate,
                    reported_sample_rate.unwrap_or(0),
                    clock_verification_passed,
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
                } else if let Ok(ranges) = get_sampling_frequency_ranges(
                    &claimed_handle.handle,
                    clock.interface_number,
                    clock.clock_id,
                ) {
                    if sampling_frequency_ranges_support_rate(&ranges, playback_format.sample_rate)
                    {
                        reported_sample_rate = Some(playback_format.sample_rate);
                        clock_verification_passed = true;
                        eprintln!(
                            "Android USB direct: using GET_RANGE-verified fixed clock {} Hz on alt setting {} without SET_CUR",
                            playback_format.sample_rate, candidate.alt_setting
                        );
                    } else {
                        eprintln!(
                            "[USB] Cannot verify fixed clock {}Hz for alt {} from GET_RANGE — will refuse streaming",
                            playback_format.sample_rate, candidate.alt_setting,
                        );
                        reported_sample_rate = None;
                        clock_verification_passed = false;
                        set_clock_verification(
                            clock_control_attempted,
                            clock_control_succeeded,
                            false,
                            None,
                        );
                    }
                } else {
                    eprintln!(
                        "[USB] Cannot verify fixed clock {}Hz for alt {} because GET_RANGE is unavailable — will refuse streaming",
                        playback_format.sample_rate, candidate.alt_setting,
                    );
                    reported_sample_rate = None;
                    clock_verification_passed = false;
                    set_clock_verification(
                        clock_control_attempted,
                        clock_control_succeeded,
                        false,
                        None,
                    );
                }

                set_clock_verification(
                    clock_control_attempted,
                    clock_control_succeeded,
                    clock_verification_passed,
                    reported_sample_rate,
                );
            }
        }
    } else {
        let message = format!(
            "[clock-diag] Cannot verify {}Hz: no clock entity for alt {} — will refuse",
            playback_format.sample_rate, candidate.alt_setting
        );
        reported_sample_rate = None;
        clock_verification_passed = false;
        set_clock_verification(
            clock_control_attempted,
            clock_control_succeeded,
            false,
            None,
        );
        eprintln!("{}", message);
        set_last_error(Some(message));
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
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(msg.clone()));
        cleanup_claimed_handle(claimed_handle, None, lock_requested);
        return Err(msg);
    }
    thread::sleep(Duration::from_millis(50));

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
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(refusal.clone()));
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
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(refusal.clone()));
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

    // Post-alt-setting clock re-verification.
    // Some DACs reset their clock when the alt setting changes. Re-read
    // GET_CUR after switching to the streaming alt setting and if the
    // rate is wrong, try one more SET_CUR + verify cycle.
    if let Some(clock) = clock {
        match get_sampling_frequency(
            &claimed_handle.handle,
            clock.interface_number,
            clock.clock_id,
        ) {
            Ok(post_alt_rate) => {
                eprintln!(
                    "[USB] GET_CUR (post-alt): clock {} reports {}Hz (expected {}Hz)",
                    clock.clock_id, post_alt_rate, playback_format.sample_rate,
                );
                if post_alt_rate != playback_format.sample_rate {
                    eprintln!(
                        "[USB] DAC clock drifted after alt-setting change ({} -> {}Hz); re-issuing SET_CUR",
                        playback_format.sample_rate, post_alt_rate,
                    );
                    let retry = apply_sampling_frequency(
                        &claimed_handle.handle,
                        clock.interface_number,
                        clock.clock_id,
                        playback_format.sample_rate,
                        clock_settle_delay_ms,
                    );
                    clock_control_attempted = true;
                    clock_control_succeeded = retry.clock_ok;
                    reported_sample_rate = retry.reported_sample_rate;
                    clock_verification_passed = retry.rate_verified
                        && retry.reported_sample_rate == Some(playback_format.sample_rate);
                    set_clock_verification(
                        clock_control_attempted,
                        clock_control_succeeded,
                        clock_verification_passed,
                        reported_sample_rate,
                    );
                    eprintln!(
                        "[USB] Re-SET_CUR result: clockOk={}, verified={}, reported={}Hz",
                        retry.clock_ok,
                        clock_verification_passed,
                        retry.reported_sample_rate.unwrap_or(0),
                    );
                }
            }
            Err(error) => {
                eprintln!(
                    "[USB] GET_CUR (post-alt): failed for clock {}: {}",
                    clock.clock_id, error,
                );
            }
        }
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

    // Hard-abort: if the clock is unverified or mismatched, refuse to
    // stream. Sending audio at the wrong sample rate causes chipmunk /
    // distorted playback.  There is NO "continue anyway" path.
    if !clock_verification_passed {
        reported_sample_rate = reported_sample_rate.or(Some(playback_format.sample_rate));
        set_clock_verification(
            clock_control_attempted,
            clock_control_succeeded,
            false,
            reported_sample_rate,
        );

        let refusal = format!(
            "USB direct refused: DAC clock not verified at {}Hz (reported={}Hz, attempted={}, succeeded={})",
            playback_format.sample_rate,
            reported_sample_rate.unwrap_or(0),
            clock_control_attempted,
            clock_control_succeeded,
        );
        eprintln!("[USB] {}", refusal);
        set_last_error(Some(refusal.clone()));
        set_direct_mode_refusal_reason(Some(refusal.clone()));
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(refusal.clone()));
        cleanup_claimed_handle(
            claimed_handle,
            Some(candidate.interface_number),
            lock_requested,
        );
        return Err(refusal);
    }

    if let Some(rate) = reported_sample_rate {
        if rate != playback_format.sample_rate {
            let refusal = format!(
                "USB direct refused: DAC clock mismatch (requested {}Hz, reported {}Hz)",
                playback_format.sample_rate, rate,
            );
            eprintln!("[USB] {}", refusal);
            set_last_error(Some(refusal.clone()));
            set_direct_mode_refusal_reason(Some(refusal.clone()));
            set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(refusal.clone()));
            cleanup_claimed_handle(
                claimed_handle,
                Some(candidate.interface_number),
                lock_requested,
            );
            return Err(refusal);
        }
    }

    let bytes_per_frame = candidate.subslot_size as usize * candidate.channels as usize;
    if bytes_per_frame == 0 {
        let refusal = format!(
            "USB direct refused: zero-size frame (subslot={}, channels={})",
            candidate.subslot_size, candidate.channels,
        );
        eprintln!("[USB] {}", refusal);
        set_last_error(Some(refusal.clone()));
        set_direct_mode_refusal_reason(Some(refusal.clone()));
        cleanup_claimed_handle(
            claimed_handle,
            Some(candidate.interface_number),
            lock_requested,
        );
        return Err(refusal);
    }

    eprintln!("[USB] === PRE-STREAM VALIDATION ===");
    eprintln!(
        "[USB]   requested_rate  = {}Hz",
        playback_format.sample_rate
    );
    eprintln!(
        "[USB]   dac_reported    = {}Hz",
        reported_sample_rate.unwrap_or(0)
    );
    eprintln!("[USB]   clock_verified  = {}", clock_verification_passed);
    eprintln!("[USB]   bit_depth       = {}", playback_format.bit_depth);
    eprintln!("[USB]   channels        = {}", playback_format.channels);
    eprintln!("[USB]   subslot_size    = {} bytes", candidate.subslot_size);
    eprintln!("[USB]   bytes_per_frame = {}", bytes_per_frame);
    eprintln!(
        "[USB]   interval_us     = {}",
        candidate.service_interval_us
    );
    eprintln!(
        "[USB]   max_packet_size = {} bytes",
        candidate.max_packet_bytes
    );
    eprintln!("[USB] ============================");
    log_info!(
        "[USB] FINAL_STREAM_FORMAT: sample_rate_hz={} dac_reported_hz={:?} clock_verified={} \
         app_bit_depth={} transport_bit_resolution={} subslot_bytes={} channels={} \
         endpoint=0x{:02x} alt={} format_tag=0x{:04x} max_packet_bytes={} \
         (A/B: try Dart prepare with 48000/16/2 if you suspect format mismatch)",
        playback_format.sample_rate,
        reported_sample_rate,
        clock_verification_passed,
        playback_format.bit_depth,
        candidate.bit_resolution,
        candidate.subslot_size,
        playback_format.channels,
        candidate.endpoint_address,
        candidate.alt_setting,
        candidate.format_tag,
        candidate.max_packet_bytes,
    );

    set_last_error(None);
    set_direct_mode_refusal_reason(None);
    set_stream_active(true);
    set_android_usb_engine_state(AndroidDirectUsbEngineState::UsbReady, None);
    set_software_volume_active(false);
    let runtime_stats = Arc::new(AndroidDirectUsbRuntimeStats::new(
        playback_format.sample_rate,
        playback_format.channels as usize,
        ANDROID_USB_BUFFER_CAPACITY_MS,
        ANDROID_USB_BUFFER_TARGET_MS,
    ));
    set_runtime_stats(Some(Arc::clone(&runtime_stats)));
    let mut preview_scheduler = IsoPacketScheduler::new(
        playback_format.sample_rate,
        bytes_per_frame,
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
        USB_SESSION_ACTIVE.store(false, Ordering::SeqCst);
        complete_pending_android_usb_clear_if_idle();
        Ok(())
    }
}

impl Drop for AndroidDirectUsbBackend {
    fn drop(&mut self) {
        let _ = self.stop();
        USB_SESSION_ACTIVE.store(false, Ordering::SeqCst);
        complete_pending_android_usb_clear_if_idle();
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
    let mut logged_render_preview = false;

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
            set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(message.clone()));
            let _ = event_tx.try_send(AudioEvent::Error { message });
            break;
        }

        {
            let non_zero = render_buffer.iter().filter(|s| **s != 0.0).count();
            if !logged_render_preview && non_zero > 0 {
                let f32_min = render_buffer.iter().cloned().fold(f32::INFINITY, f32::min);
                let f32_max = render_buffer
                    .iter()
                    .cloned()
                    .fold(f32::NEG_INFINITY, f32::max);
                let f32_max_abs = render_buffer.iter().fold(0.0f32, |m, &s| m.max(s.abs()));
                let i32_min = pcm_samples.iter().copied().min().unwrap_or(0);
                let i32_max = pcm_samples.iter().copied().max().unwrap_or(0);
                let i32_max_abs = pcm_samples
                    .iter()
                    .map(|&s| (s as i64).unsigned_abs())
                    .max()
                    .unwrap_or(0);
                let preview_base = render_buffer
                    .iter()
                    .enumerate()
                    .find_map(|(i, s)| (*s != 0.0).then_some(i))
                    .unwrap_or(0);
                let preview_len = 16.min(render_buffer.len().saturating_sub(preview_base));
                let f32_preview: Vec<f32> = render_buffer
                    .iter()
                    .skip(preview_base)
                    .take(preview_len)
                    .copied()
                    .collect();
                let i32_preview: Vec<i32> = pcm_samples
                    .iter()
                    .skip(preview_base)
                    .take(preview_len)
                    .copied()
                    .collect();
                log_info!(
                    "[USB-RENDER] === PIPELINE CHECK (first non-zero) === bit_depth={} channels={} chunk_frames={}{}",
                    playback_format.bit_depth,
                    channels,
                    chunk_frames,
                    if channels == 2 {
                        " layout=interleaved_LR (L,R,L,R — Symphonia channel index order)"
                    } else {
                        " layout=interleaved (channel index order)"
                    },
                );
                log_info!(
                    "[USB-RENDER] preview @sample_index={} ({} values): f32 {:?}",
                    preview_base,
                    preview_len,
                    f32_preview,
                );
                log_info!(
                    "[USB-RENDER] f32 stats: non_zero={}/{} min={:.6} max={:.6} max_abs={:.6}",
                    non_zero,
                    render_buffer.len(),
                    f32_min,
                    f32_max,
                    f32_max_abs,
                );
                log_info!(
                    "[USB-RENDER] i32 preview: {:?} | min={} max={} max_abs={} (linear i32 = clamp(f32 * 2147483647); USB 16-bit uses >>16)",
                    i32_preview,
                    i32_min,
                    i32_max,
                    i32_max_abs,
                );
                logged_render_preview = true;
            }
        }

        debug_assert!(
            pcm_samples.len() % channels == 0,
            "push_samples: input length {} is not frame-aligned (channels={})",
            pcm_samples.len(),
            channels,
        );
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

        if written_samples > 0 {
            let push_max_abs_f32 = render_buffer[..written_samples]
                .iter()
                .fold(0.0f32, |max_abs, sample| max_abs.max(sample.abs()));
            let push_max_abs_i32_u32 = pcm_samples[..written_samples]
                .iter()
                .map(|&s| (s as i64).unsigned_abs())
                .max()
                .unwrap_or(0)
                .min(u64::from(u32::MAX)) as u32;
            runtime_stats
                .last_push_max_abs_f32_bits
                .store(push_max_abs_f32.to_bits(), Ordering::Relaxed);
            runtime_stats
                .last_push_max_abs_i32
                .store(push_max_abs_i32_u32, Ordering::Relaxed);
        }

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

fn prepare_iso_transfer_payload(
    scheduler: &mut IsoPacketScheduler,
    pcm_buffer: &Arc<Mutex<AndroidDirectUsbPcmRingBuffer>>,
    runtime_stats: &AndroidDirectUsbRuntimeStats,
    candidate: &AndroidIsoStreamCandidate,
    slot_bytes: usize,
    channels: usize,
    bytes_per_frame: usize,
) -> Result<Option<IsoTransferPayload>, String> {
    let packet_sizes = scheduler.next_transfer_packet_bytes();
    let total_bytes: usize = packet_sizes.iter().sum();
    if total_bytes == 0 {
        return Ok(None);
    }

    if packet_sizes
        .iter()
        .any(|packet_size| *packet_size > candidate.max_packet_bytes)
    {
        return Err(format!(
            "Android USB direct packet exceeds endpoint max packet size: packets={:?}, endpoint_max={}",
            packet_sizes, candidate.max_packet_bytes
        ));
    }

    if packet_sizes
        .iter()
        .any(|packet_size| packet_size % bytes_per_frame != 0)
    {
        return Err(format!(
            "Android USB direct packet is not aligned to {}-byte transport frames: {:?}",
            bytes_per_frame, packet_sizes
        ));
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
    encode_usb_pcm_slots(
        &packet_samples,
        &mut transfer_buffer,
        candidate.subslot_size,
        candidate.bit_resolution,
    )?;

    Ok(Some(IsoTransferPayload {
        frame_count: packet_samples.len() / channels,
        packet_sizes,
        packet_samples,
        transfer_buffer,
        underrun,
    }))
}

fn update_transfer_timing_stats(
    runtime_stats: &AndroidDirectUsbRuntimeStats,
    turnaround_us: u64,
    submit_gap_us: u64,
    stream_started_at: Instant,
) {
    runtime_stats
        .last_transfer_turnaround_us
        .store(turnaround_us, Ordering::Relaxed);
    if turnaround_us
        > runtime_stats
            .max_transfer_turnaround_us
            .load(Ordering::Relaxed)
    {
        runtime_stats
            .max_transfer_turnaround_us
            .store(turnaround_us, Ordering::Relaxed);
    }

    runtime_stats
        .last_submit_gap_us
        .store(submit_gap_us, Ordering::Relaxed);
    if submit_gap_us > runtime_stats.max_submit_gap_us.load(Ordering::Relaxed) {
        runtime_stats
            .max_submit_gap_us
            .store(submit_gap_us, Ordering::Relaxed);
    }

    let elapsed_us = stream_started_at.elapsed().as_micros().max(1) as u64;
    let completed_frames = runtime_stats.consumer_frames.load(Ordering::Relaxed);
    let effective_consumer_rate_milli_hz = completed_frames
        .saturating_mul(1_000_000_000)
        .checked_div(elapsed_us)
        .unwrap_or(0);
    runtime_stats
        .effective_consumer_rate_milli_hz
        .store(effective_consumer_rate_milli_hz, Ordering::Relaxed);
}

fn drain_iso_transfer_slots(context: &Context, slots: &mut [IsoTransferSlot]) {
    for slot in slots.iter_mut() {
        slot.cancel();
    }

    let deadline = Instant::now() + Duration::from_millis(500);
    while slots.iter().any(|slot| slot.in_flight) && Instant::now() < deadline {
        let _ = context.handle_events(Some(Duration::from_millis(10)));
        for slot in slots.iter_mut() {
            if slot.take_completion_status().is_some() {
                slot.mark_completed();
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn record_prepared_iso_transfer(
    payload: &IsoTransferPayload,
    playback_format: AndroidDirectUsbPlaybackFormat,
    candidate: &AndroidIsoStreamCandidate,
    runtime_stats: &AndroidDirectUsbRuntimeStats,
    bytes_per_frame: usize,
    logged_transfer_preview: &mut bool,
    logged_usb_encode_format: &mut bool,
    underrun_count: &mut u64,
    loud_transfer_log_count: &mut u64,
) {
    if !*logged_usb_encode_format {
        log_info!(
            "[USB] PCM encoding: {}-bit (subslot {} bytes) per descriptor",
            candidate.bit_resolution,
            candidate.subslot_size,
        );
        *logged_usb_encode_format = true;
    }

    runtime_stats.frames_per_packet.store(
        payload.packet_sizes.first().copied().unwrap_or_default() / bytes_per_frame,
        Ordering::Relaxed,
    );

    let packet_max_abs_i64 = payload
        .packet_samples
        .iter()
        .map(|sample| i64::from(*sample).abs())
        .max()
        .unwrap_or(0);
    let packet_peak_equiv_f32 = (packet_max_abs_i64 as f64 / 2_147_483_647.0).min(1.0);
    if packet_peak_equiv_f32 >= f64::from(ANDROID_USB_LOUD_RENDER_LOG_THRESHOLD) {
        *loud_transfer_log_count = (*loud_transfer_log_count).saturating_add(1);
        if *loud_transfer_log_count <= 4
            || *loud_transfer_log_count % ANDROID_USB_LOUD_TRANSFER_LOG_INTERVAL == 0
        {
            let max_abs_i16 = payload
                .packet_samples
                .iter()
                .map(|sample| i32::from(linear_pcm_i32_to_i16(*sample)).abs())
                .max()
                .unwrap_or(0);
            let last_push_i32 = runtime_stats.last_push_max_abs_i32.load(Ordering::Relaxed);
            let last_push_f32 = f32::from_bits(
                runtime_stats
                    .last_push_max_abs_f32_bits
                    .load(Ordering::Relaxed),
            );
            log_info!(
                "[USB-PEAK] loud_packet packet_peak_equiv_f32={:.6} max_abs_i32={} max_abs_i16={} samples={} subslot={} bit_resolution={} last_push_max_abs_i32={} last_push_peak_abs_f32={:.6}",
                packet_peak_equiv_f32,
                packet_max_abs_i64,
                max_abs_i16,
                payload.packet_samples.len(),
                candidate.subslot_size,
                candidate.bit_resolution,
                last_push_i32,
                last_push_f32,
            );
        }
    }

    if payload.underrun {
        *underrun_count = (*underrun_count).saturating_add(1);
        runtime_stats
            .underrun_count
            .store(*underrun_count, Ordering::Relaxed);
        if *underrun_count <= 4 || *underrun_count % 64 == 0 {
            log_info!(
                "[USB] underrun count={} buffer_fill={}ms frames_per_packet={} packets_per_transfer={}",
                *underrun_count,
                runtime_stats.buffer_fill_ms(),
                payload.packet_sizes.first().copied().unwrap_or_default() / bytes_per_frame,
                payload.packet_sizes.len(),
            );
        }
    }

    if !*logged_transfer_preview {
        let has_nonzero = payload.packet_samples.iter().any(|sample| *sample != 0);
        if has_nonzero {
            let i32_pre: Vec<i32> = payload.packet_samples.iter().take(10).copied().collect();
            let byte_pre: Vec<u8> = payload.transfer_buffer.iter().take(24).copied().collect();
            log_info!(
                "[USB-OUTPUT] first 10 i32 samples (non-zero): {:?}",
                i32_pre,
            );
            if candidate.subslot_size == 2 && candidate.bit_resolution == 16 {
                let i16_pre: Vec<i16> = payload
                    .packet_samples
                    .iter()
                    .take(10)
                    .copied()
                    .map(linear_pcm_i32_to_i16)
                    .collect();
                log_info!("[USB-OUTPUT] first 10 as i16 (linear >>16): {:?}", i16_pre,);
            }
            log_info!("[USB-OUTPUT] first 24 encoded bytes: {:?}", byte_pre,);
            log_stream_debug_preview(
                playback_format,
                candidate,
                &payload.packet_sizes,
                &payload.packet_samples,
                &payload.transfer_buffer,
            );
            *logged_transfer_preview = true;
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
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(message.clone()));
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
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(error.clone()));
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
    let transfer_slot_count = ANDROID_USB_TRANSFER_QUEUE_DEPTH.max(1);
    let feedback_endpoint = candidate
        .feedback_endpoint
        .filter(|feedback| feedback.transfer_type == TransferType::Interrupt);
    if candidate.feedback_endpoint.is_some() && feedback_endpoint.is_none() {
        log_info!(
            "[USB] Skipping live isochronous feedback polling on endpoint 0x{:02x} to keep the libusb event loop single-threaded",
            candidate.feedback_endpoint.unwrap().address,
        );
    }
    runtime_stats
        .transfer_queue_depth
        .store(transfer_slot_count, Ordering::Relaxed);
    let mut logged_transfer_preview = false;
    let mut logged_usb_encode_format = false;
    // Isochronous OUT transfers that completed successfully (libusb COMPLETED). Not reset on underrun.
    let mut successful_transfers = 0usize;
    let mut logged_usb_stabilized = false;
    let mut underrun_count = 0u64;
    let mut feedback_report_count = 0usize;
    let mut loud_transfer_log_count = 0u64;
    let transfer_buffer_capacity = scheduler
        .packets_per_transfer()
        .saturating_mul(candidate.max_packet_bytes.max(1));
    let mut slots = Vec::with_capacity(transfer_slot_count);
    let mut active_slots = 0usize;
    let mut fatal_error: Option<String> = None;

    let priming_target = runtime_stats.buffer_target_samples;
    log_info!(
        "[USB] Waiting for stream prime: buffered_samples must reach buffer_target_samples={} before isochronous submit",
        priming_target,
    );
    while !stop.load(Ordering::Acquire) {
        let buffered = runtime_stats.buffered_samples.load(Ordering::Relaxed);
        if buffered >= priming_target {
            log_info!(
                "[USB] USB stream primed: {} samples buffered (target={})",
                buffered,
                priming_target,
            );
            break;
        }
        thread::sleep(Duration::from_millis(2));
    }

    for _ in 0..transfer_slot_count {
        match IsoTransferSlot::new(scheduler.packets_per_transfer(), transfer_buffer_capacity) {
            Ok(slot) => slots.push(slot),
            Err(error) => {
                fatal_error = Some(format!(
                    "Android USB direct failed to allocate transfer slot: {}",
                    error
                ));
                break;
            }
        }
    }

    let stream_started_at = Instant::now();
    if fatal_error.is_none() {
        for slot in slots.iter_mut() {
            let payload = match prepare_iso_transfer_payload(
                &mut scheduler,
                &pcm_buffer,
                &runtime_stats,
                &candidate,
                slot_bytes,
                channels,
                bytes_per_frame,
            ) {
                Ok(Some(payload)) => payload,
                Ok(None) => continue,
                Err(error) => {
                    fatal_error = Some(format!(
                        "Android USB direct transfer preparation failed: {}",
                        error
                    ));
                    break;
                }
            };

            record_prepared_iso_transfer(
                &payload,
                playback_format,
                &candidate,
                &runtime_stats,
                bytes_per_frame,
                &mut logged_transfer_preview,
                &mut logged_usb_encode_format,
                &mut underrun_count,
                &mut loud_transfer_log_count,
            );

            if let Err(error) = slot.submit(&handle, candidate.endpoint_address, payload) {
                fatal_error = Some(format!("Android USB direct transfer failed: {}", error));
                break;
            }
            active_slots = active_slots.saturating_add(1);
        }
    }

    while fatal_error.is_none() && (!stop.load(Ordering::Acquire) || active_slots > 0) {
        if active_slots == 0 {
            break;
        }

        if let Err(error) = context.handle_events(Some(Duration::from_millis(50))) {
            fatal_error = Some(format!("libusb_handle_events failed: {}", error));
            break;
        }

        for slot in slots.iter_mut() {
            let Some(status) = slot.take_completion_status() else {
                continue;
            };

            active_slots = active_slots.saturating_sub(1);
            let turnaround_us = slot.turnaround_us().unwrap_or_default();
            let queued_frame_count = slot.queued_frame_count as u64;
            let completed_underrun = slot.queued_underrun;
            let transfer_result = match status {
                LIBUSB_TRANSFER_COMPLETED => slot.validate_packets(),
                LIBUSB_TRANSFER_TIMED_OUT => Err("isochronous transfer timed out".to_string()),
                LIBUSB_TRANSFER_STALL => Err("isochronous transfer stalled".to_string()),
                LIBUSB_TRANSFER_NO_DEVICE => Err("USB DAC disconnected".to_string()),
                LIBUSB_TRANSFER_OVERFLOW => Err("isochronous transfer overflow".to_string()),
                LIBUSB_TRANSFER_CANCELLED => Err("isochronous transfer cancelled".to_string()),
                LIBUSB_TRANSFER_ERROR => Err("isochronous transfer failed".to_string()),
                other => Err(format!(
                    "isochronous transfer returned status {} ({})",
                    other,
                    iso_transfer_status_label(other)
                )),
            };
            slot.mark_completed();

            if let Err(error) = transfer_result {
                fatal_error = Some(format!("Android USB direct transfer failed: {}", error));
                break;
            }

            successful_transfers = successful_transfers.saturating_add(1);
            let completed_transfers = runtime_stats
                .completed_transfers
                .fetch_add(1, Ordering::Relaxed)
                .saturating_add(1);
            runtime_stats
                .consumer_frames
                .fetch_add(queued_frame_count, Ordering::Relaxed);

            if let Some(feedback_endpoint) = feedback_endpoint {
                match read_feedback_report(&context, &handle, feedback_endpoint, device_fd) {
                    Ok(Some(feedback_report)) => {
                        scheduler
                            .update_feedback_frames_per_packet(feedback_report.frames_per_packet);
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

            let mut submit_gap_us = 0u64;
            if !stop.load(Ordering::Acquire) {
                let completion_detected_at = Instant::now();
                match prepare_iso_transfer_payload(
                    &mut scheduler,
                    &pcm_buffer,
                    &runtime_stats,
                    &candidate,
                    slot_bytes,
                    channels,
                    bytes_per_frame,
                ) {
                    Ok(Some(payload)) => {
                        record_prepared_iso_transfer(
                            &payload,
                            playback_format,
                            &candidate,
                            &runtime_stats,
                            bytes_per_frame,
                            &mut logged_transfer_preview,
                            &mut logged_usb_encode_format,
                            &mut underrun_count,
                            &mut loud_transfer_log_count,
                        );

                        if let Err(error) =
                            slot.submit(&handle, candidate.endpoint_address, payload)
                        {
                            fatal_error =
                                Some(format!("Android USB direct transfer failed: {}", error));
                            break;
                        }
                        submit_gap_us = completion_detected_at
                            .elapsed()
                            .as_micros()
                            .min(u128::from(u64::MAX))
                            as u64;
                        active_slots = active_slots.saturating_add(1);
                    }
                    Ok(None) => {}
                    Err(error) => {
                        fatal_error = Some(format!(
                            "Android USB direct transfer preparation failed: {}",
                            error
                        ));
                        break;
                    }
                }
            }

            update_transfer_timing_stats(
                &runtime_stats,
                turnaround_us,
                submit_gap_us,
                stream_started_at,
            );

            if completed_transfers % ANDROID_USB_TIMING_LOG_INTERVAL == 0 {
                let effective_consumer_rate_hz = runtime_stats
                    .effective_consumer_rate_milli_hz
                    .load(Ordering::Relaxed)
                    as f64
                    / 1_000.0;
                log_info!(
                    "[USB-TIMING] completed={} queueDepth={} effectiveRateHz={:.3} lastTurnaroundUs={} maxTurnaroundUs={} lastSubmitGapUs={} maxSubmitGapUs={}",
                    completed_transfers,
                    runtime_stats.transfer_queue_depth.load(Ordering::Relaxed),
                    effective_consumer_rate_hz,
                    runtime_stats.last_transfer_turnaround_us.load(Ordering::Relaxed),
                    runtime_stats.max_transfer_turnaround_us.load(Ordering::Relaxed),
                    runtime_stats.last_submit_gap_us.load(Ordering::Relaxed),
                    runtime_stats.max_submit_gap_us.load(Ordering::Relaxed),
                );
            }

            if successful_transfers >= ANDROID_USB_STABLE_TRANSFER_THRESHOLD {
                if !completed_underrun {
                    set_usb_stream_stable(true);
                    if !logged_usb_stabilized {
                        if feedback_endpoint.is_none() {
                            scheduler.lock_to_nominal_packet_timing();
                            log_info!(
                                "[USB] USB stream stabilized after {} isochronous transfers (nominal packet timing locked)",
                                successful_transfers
                            );
                        } else {
                            log_info!(
                                "[USB] USB stream stabilized after {} isochronous transfers (keeping feedback-driven packet timing active)",
                                successful_transfers
                            );
                        }
                        logged_usb_stabilized = true;
                    }
                } else {
                    set_usb_stream_stable(false);
                }
            } else {
                set_usb_stream_stable(false);
            }
        }
    }

    if let Some(error) = fatal_error {
        set_usb_stream_stable(false);
        set_last_error(Some(error.clone()));
        set_android_usb_engine_state(AndroidDirectUsbEngineState::Error, Some(error.clone()));
        let _ = event_tx.try_send(AudioEvent::Error {
            message: error.clone(),
        });
        eprintln!("{}", error);
    }

    drain_iso_transfer_slots(&context, &mut slots);

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
    USB_SESSION_ACTIVE.store(false, Ordering::SeqCst);
    complete_pending_android_usb_clear_if_idle();
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
        TransferType::Interrupt => read_interrupt_feedback_packet(handle, feedback_endpoint)?,
        TransferType::Isochronous => {
            let _ = context;
            return Ok(None);
        }
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

#[allow(dead_code)]
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
            let raw = u32::from(raw_bytes[0])
                | (u32::from(raw_bytes[1]) << 8)
                | (u32::from(raw_bytes[2]) << 16);
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
    handle: &DeviceHandle<Context>,
    playback_format: AndroidDirectUsbPlaybackFormat,
    speed: Speed,
) -> Result<AndroidIsoStreamCandidate, String> {
    let config_descriptor = device
        .active_config_descriptor()
        .map_err(|error| format!("Failed to read active USB config descriptor: {}", error))?;
    let mut candidates = Vec::new();
    let prefer_padded_24bit_transport = device_prefers_padded_24bit_transport(device);
    let mut stream_rate_cache =
        std::collections::HashMap::<(u8, Option<u8>), Vec<SamplingFrequencySubrange>>::new();
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

            let sample_rate_ranges = stream_rate_cache
                .entry((descriptor.interface_number(), stream_format.terminal_link))
                .or_insert_with(|| {
                    discover_stream_sample_rate_ranges(
                        device,
                        handle,
                        descriptor.interface_number(),
                        stream_format.terminal_link,
                    )
                })
                .clone();
            let sample_rates = representative_sample_rates_from_ranges(&sample_rate_ranges);

            if !sample_rate_ranges.is_empty()
                && !sampling_frequency_ranges_support_rate(
                    &sample_rate_ranges,
                    playback_format.sample_rate,
                )
            {
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
                    sample_rates,
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
                    sample_rates: sample_rates.clone(),
                    refresh: endpoint.refresh(),
                    synch_address: endpoint.synch_address(),
                    feedback_endpoint,
                    terminal_link: stream_format.terminal_link,
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
            transport_container_preference_rank(
                candidate,
                playback_format,
                prefer_padded_24bit_transport,
            ),
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

/// Find the clock entity that feeds a specific streaming interface's terminal.
///
/// UAC2 topology: AudioStreaming AS_GENERAL.bTerminalLink → Terminal.bTerminalID,
/// then Terminal.bCSourceID gives the Clock Entity ID.
///
/// If `terminal_link` is None or the trace fails, falls back to the first
/// Clock Source found in the AudioControl descriptor.
fn find_audio_control_clock(
    device: &Device<Context>,
    handle: &DeviceHandle<Context>,
    terminal_link: Option<u8>,
) -> Option<AudioControlClock> {
    let config_descriptor = device.active_config_descriptor().ok()?;

    for interface in config_descriptor.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() != USB_CLASS_AUDIO
                || descriptor.sub_class_code() != USB_SUBCLASS_AUDIOCONTROL
            {
                continue;
            }

            let extra = descriptor.extra();
            eprintln!(
                "[USB] AudioControl interface {} alt {} extra bytes: {} bytes",
                descriptor.interface_number(),
                descriptor.setting_number(),
                extra.len(),
            );

            if extra.is_empty() {
                eprintln!(
                    "[USB] AudioControl interface {} has empty extra bytes; \
                     attempting raw GET_DESCRIPTOR fallback",
                    descriptor.interface_number(),
                );
                if let Some(clock) = find_clock_from_raw_config_descriptor(
                    handle,
                    &config_descriptor,
                    descriptor.interface_number(),
                ) {
                    return Some(clock);
                }
                continue;
            }

            // Pass 1: build maps of terminal_id → clock_source_id and
            // collect all clock source IDs.
            let mut terminal_to_clock: Vec<(u8, u8)> = Vec::new();
            let mut clock_source_ids: Vec<(u8, u8)> = Vec::new(); // (clock_id, ac_iface)
            let ac_iface = descriptor.interface_number();

            let mut index = 0usize;
            while index + 2 < extra.len() {
                let length = extra[index] as usize;
                if length == 0 || index + length > extra.len() {
                    break;
                }
                let desc_type = extra[index + 1];
                let desc_subtype = extra.get(index + 2).copied().unwrap_or_default();

                if desc_type == USB_DT_CS_INTERFACE {
                    match desc_subtype {
                        UAC2_INPUT_TERMINAL | UAC2_OUTPUT_TERMINAL if length >= 8 => {
                            let terminal_id = extra[index + 3];
                            let c_source_id = extra[index + 7];
                            eprintln!(
                                "[USB] Terminal id={} subtype={} -> bCSourceID={}",
                                terminal_id,
                                if desc_subtype == UAC2_INPUT_TERMINAL {
                                    "IN"
                                } else {
                                    "OUT"
                                },
                                c_source_id,
                            );
                            terminal_to_clock.push((terminal_id, c_source_id));
                        }
                        UAC2_CLOCK_SOURCE if length >= 4 => {
                            let clock_id = extra[index + 3];
                            eprintln!(
                                "[USB] Clock Source id={} on AC interface {}",
                                clock_id, ac_iface,
                            );
                            clock_source_ids.push((clock_id, ac_iface));
                        }
                        _ => {}
                    }
                }
                index += length;
            }

            // Pass 2: resolve via topology if terminal_link is known.
            if let Some(tl) = terminal_link {
                if let Some(&(_, c_source_id)) =
                    terminal_to_clock.iter().find(|(tid, _)| *tid == tl)
                {
                    // Verify this c_source_id is actually a clock source.
                    if clock_source_ids.iter().any(|(cid, _)| *cid == c_source_id) {
                        eprintln!(
                            "[USB] Clock resolved via topology: bTerminalLink={} -> bCSourceID={} on AC interface {}",
                            tl, c_source_id, ac_iface,
                        );
                        return Some(AudioControlClock {
                            interface_number: ac_iface,
                            clock_id: c_source_id,
                        });
                    }
                    eprintln!(
                        "[USB] Terminal {} references bCSourceID={} but no matching Clock Source entity found; falling back",
                        tl, c_source_id,
                    );
                } else {
                    eprintln!(
                        "[USB] bTerminalLink={} not found in AC descriptor terminals; falling back to first clock",
                        tl,
                    );
                }
            }

            // Fallback: return the first Clock Source entity.
            if let Some(&(clock_id, iface)) = clock_source_ids.first() {
                eprintln!(
                    "[USB] Using first Clock Source id={} on AC interface {} (fallback)",
                    clock_id, iface,
                );
                return Some(AudioControlClock {
                    interface_number: iface,
                    clock_id,
                });
            }
        }
    }

    eprintln!("[USB] No AudioControl clock source entity found in any interface descriptor");
    None
}

fn find_clock_from_raw_config_descriptor(
    handle: &DeviceHandle<Context>,
    config_descriptor: &ConfigDescriptor,
    ac_interface_number: u8,
) -> Option<AudioControlClock> {
    let config_value = config_descriptor.number();
    let mut raw = vec![0u8; 1024];
    let request_type: u8 = 0x80;
    let descriptor_type_config: u8 = 0x02;
    let read = handle
        .read_control(
            request_type,
            0x06,
            (descriptor_type_config as u16) << 8 | config_value as u16,
            0,
            &mut raw,
            Duration::from_secs(1),
        )
        .ok()?;

    if read < 4 {
        log::error!(
            "[USB] Raw GET_DESCRIPTOR returned only {} bytes; cannot parse config descriptor",
            read,
        );
        return None;
    }
    let total_length = u16::from_le_bytes([raw[2], raw[3]]) as usize;
    if total_length > read {
        let mut full_raw = vec![0u8; total_length];
        match handle.read_control(
            request_type,
            0x06,
            (descriptor_type_config as u16) << 8 | config_value as u16,
            0,
            &mut full_raw,
            Duration::from_secs(1),
        ) {
            Ok(n) => {
                raw = full_raw;
                raw.truncate(n);
            }
            Err(error) => {
                log::error!(
                    "[USB] Raw GET_DESCRIPTOR full read failed: {}; using partial {} bytes",
                    error,
                    read,
                );
                raw.truncate(read);
            }
        }
    } else {
        raw.truncate(read);
    }

    log::info!(
        "[USB] Raw config descriptor: {} bytes for config {}",
        raw.len(),
        config_value,
    );
    parse_clock_from_raw_config(&raw, ac_interface_number)
}

fn parse_clock_from_raw_config(raw: &[u8], ac_interface_number: u8) -> Option<AudioControlClock> {
    let mut pos = 0usize;
    let mut inside_ac_interface = false;

    while pos + 1 < raw.len() {
        let b_length = raw[pos] as usize;
        if b_length < 2 || pos + b_length > raw.len() {
            break;
        }
        let b_descriptor_type = raw[pos + 1];

        if b_descriptor_type == 0x04 && b_length >= 9 {
            let iface_num = raw[pos + 2];
            let iface_class = raw[pos + 5];
            let iface_subclass = raw[pos + 6];
            inside_ac_interface = iface_num == ac_interface_number
                && iface_class == USB_CLASS_AUDIO
                && iface_subclass == USB_SUBCLASS_AUDIOCONTROL;
        }

        if inside_ac_interface
            && b_descriptor_type == USB_DT_CS_INTERFACE
            && b_length >= 4
            && raw.get(pos + 2).copied() == Some(UAC2_CLOCK_SOURCE)
        {
            let clock_id = raw[pos + 3];
            log::info!(
                "[USB] Found clock source via raw config descriptor: interface={} clockId={}",
                ac_interface_number,
                clock_id,
            );
            return Some(AudioControlClock {
                interface_number: ac_interface_number,
                clock_id,
            });
        }

        pos += b_length;
    }

    log::error!(
        "[USB] Raw config descriptor fallback did not find a clock source for interface {}",
        ac_interface_number,
    );
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

/// UAC2 Clock Validity Control (CS_CLOCK_VALID_CONTROL = 0x02).
/// Returns Ok(true) if the clock is valid/stable, Ok(false) if invalid,
/// or Err if the request is not supported.
fn get_clock_validity(
    handle: &DeviceHandle<Context>,
    interface_number: u8,
    clock_id: u8,
) -> Result<bool, String> {
    let request_type = USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE;
    let value = UAC2_CLOCK_SOURCE_CLOCK_VALID_CONTROL;
    let index = (interface_number as u16) | ((clock_id as u16) << 8);
    let mut data = [0u8; 1];
    let transferred = handle
        .read_control(
            request_type,
            UAC2_REQUEST_GET_CUR,
            value,
            index,
            &mut data,
            Duration::from_millis(500),
        )
        .map_err(|error| format!("Clock Validity GET_CUR failed: {}", error))?;
    if transferred != 1 {
        return Err(format!(
            "Clock Validity returned {} bytes, expected 1",
            transferred
        ));
    }
    Ok(data[0] != 0)
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

fn discover_stream_sample_rate_ranges(
    device: &Device<Context>,
    handle: &DeviceHandle<Context>,
    streaming_interface_number: u8,
    terminal_link: Option<u8>,
) -> Vec<SamplingFrequencySubrange> {
    let Some(clock) = find_audio_control_clock(device, handle, terminal_link) else {
        return Vec::new();
    };

    match get_sampling_frequency_ranges(handle, clock.interface_number, clock.clock_id) {
        Ok(ranges) => ranges,
        Err(error) => {
            eprintln!(
                "[USB] GET_RANGE probe failed for streaming interface {} via clock {} on AC interface {}: {}",
                streaming_interface_number,
                clock.clock_id,
                clock.interface_number,
                error,
            );
            Vec::new()
        }
    }
}

fn representative_sample_rates_from_ranges(ranges: &[SamplingFrequencySubrange]) -> Vec<u32> {
    const COMMON_SAMPLE_RATES: &[u32] = &[
        8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000,
        176_400, 192_000, 352_800, 384_000, 705_600, 768_000,
    ];

    let mut sample_rates = Vec::new();

    for &rate in COMMON_SAMPLE_RATES {
        if sampling_frequency_ranges_support_rate(ranges, rate) {
            sample_rates.push(rate);
        }
    }

    for range in ranges {
        sample_rates.push(range.min);
        if range.max != range.min {
            sample_rates.push(range.max);
        }
    }

    sample_rates.sort_unstable();
    sample_rates.dedup();
    sample_rates
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
    log::info!(
        "[USB] apply_sampling_frequency: interface={} clockId={} targetRate={}Hz settleDelay={}ms",
        interface_number,
        clock_id,
        sample_rate,
        settle_delay_ms,
    );

    let supported_ranges = get_sampling_frequency_ranges(handle, interface_number, clock_id).ok();
    match &supported_ranges {
        Some(ranges) => {
            log::info!(
                "[USB] GET_RANGE: {} range(s) from clock {} on interface {}",
                ranges.len(),
                clock_id,
                interface_number,
            );
        }
        None => {
            log::warn!(
                "[USB] GET_RANGE: failed for clock {} on interface {}",
                clock_id,
                interface_number,
            );
        }
    }

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

    // Read current rate for diagnostics, but NEVER trust it as proof
    // that the clock is correct. Always issue SET_CUR unconditionally
    // because the DAC may report a stale rate or may have been
    // reprogrammed by another app / alt-setting change.
    match get_sampling_frequency(handle, interface_number, clock_id) {
        Ok(current_rate) => {
            eprintln!(
                "[USB] GET_CUR (pre-SET): clock {} on interface {} reports {}Hz (target={}Hz)",
                clock_id, interface_number, current_rate, sample_rate,
            );
        }
        Err(error) => {
            eprintln!(
                "[USB] GET_CUR (pre-SET): failed for clock {} on interface {}: {}",
                clock_id, interface_number, error,
            );
        }
    }

    let mut last_set_error = None;
    let mut last_readback_error = None;
    let mut last_reported_rate = None;

    for attempt in 1..=3 {
        log::info!(
            "[USB] SET_CUR attempt {}/3: clock {} interface {} rate {}Hz",
            attempt,
            clock_id,
            interface_number,
            sample_rate,
        );
        match set_sampling_frequency(handle, interface_number, clock_id, sample_rate) {
            Ok(()) => {
                log::info!("[USB] SET_CUR attempt {}/3: succeeded", attempt);
            }
            Err(error) => {
                log::error!("[USB] SET_CUR attempt {}/3: failed: {}", attempt, error);
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
                    // Rate verified — also check clock validity if supported.
                    let clock_valid = match get_clock_validity(handle, interface_number, clock_id) {
                        Ok(valid) => {
                            eprintln!(
                                "[USB] Clock Validity: clock {} valid={} (after SET_CUR {}Hz)",
                                clock_id, valid, sample_rate,
                            );
                            Some(valid)
                        }
                        Err(e) => {
                            eprintln!(
                                "[USB] Clock Validity: not supported for clock {} ({}); assuming valid",
                                clock_id, e,
                            );
                            None
                        }
                    };
                    if clock_valid == Some(false) {
                        eprintln!(
                            "[USB] Clock {} reports INVALID after SET_CUR {}Hz; retrying",
                            clock_id, sample_rate,
                        );
                        thread::sleep(Duration::from_millis(settle_delay_ms));
                        continue;
                    }
                    eprintln!(
                        "[USB] SET_CUR verified: {} Hz on clock {} interface {} after attempt {}",
                        sample_rate, clock_id, interface_number, attempt,
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
    let mut terminal_link = None;

    for extra in DescriptorIter::new(descriptor.extra()) {
        if extra.len() < 3 || extra[1] != USB_DT_CS_INTERFACE {
            continue;
        }

        match extra[2] {
            UAC2_AS_GENERAL => {
                // UAC2 AS_GENERAL layout: [0]=bLength [1]=bDescriptorType
                // [2]=bDescriptorSubtype [3]=bTerminalLink [4]=bmControls
                // [5]=bFormatType [6..9]=bmFormats [10]=bNrChannels ...
                if extra.len() >= 4 {
                    terminal_link = Some(extra[3]);
                }
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
                    // UAC2 sample rates live on the clock entity via GET_RANGE.
                    subslot_size = Some(extra[4]);
                    bit_resolution = Some(extra[5]);
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
        terminal_link,
    })
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

    u32::from(stream_format.subslot_size) - min_subslot_size as u32
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
            terminal_link: candidate.terminal_link,
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

/// Convert f32 samples (range [-1.0, 1.0]) to linear full-scale `i32` PCM values.
///
/// USB 16-bit packing takes the top 16 bits (`sample >> 16`) via [`linear_pcm_i32_to_i16`],
/// matching UAC-style scaling from a 32-bit linear container.
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
            16 | 24 | 32 => {
                let scaled = (clamped as f64 * 2_147_483_647.0) as i64;
                scaled.clamp(i32::MIN as i64, i32::MAX as i64) as i32
            }
            _ => return Err(format!("Unsupported PCM bit depth: {}", bit_depth)),
        };
    }

    Ok(())
}

/// Map linear PCM `i32` from [`convert_f32_to_pcm_samples`] to 16-bit samples for USB.
///
/// Uses the top 16 bits (arithmetic shift), matching UAC2-style downscale from a 32-bit
/// linear container and avoiding a float round-trip. For values produced by
/// `convert_f32_to_pcm_samples`, `sample >> 16` is always in `i16` range.
#[inline]
fn linear_pcm_i32_to_i16(sample: i32) -> i16 {
    (sample >> 16) as i16
}

/// 24-bit packed little-endian (3 bytes per channel), from linear full-scale i32.
#[inline]
fn encode_i24(sample: i32) -> [u8; 3] {
    let s = sample >> 8;
    [
        (s & 0xFF) as u8,
        ((s >> 8) & 0xFF) as u8,
        ((s >> 16) & 0xFF) as u8,
    ]
}

#[inline]
fn encode_i32_le(sample: i32) -> [u8; 4] {
    sample.to_le_bytes()
}

/// Pack PCM for the active UAC subslot (`subslot_size` bytes × `bit_resolution` significant bits).
fn encode_usb_pcm_slots(
    input: &[i32],
    output: &mut [u8],
    subslot_size: u8,
    bit_resolution: u8,
) -> Result<(), String> {
    let ss = subslot_size as usize;
    if ss == 0 {
        return Err("subslot_size is zero".to_string());
    }
    let expected = input.len().checked_mul(ss).ok_or_else(|| {
        format!(
            "USB PCM sample count overflow: {} samples × {} subslot",
            input.len(),
            ss
        )
    })?;
    if output.len() != expected {
        return Err(format!(
            "USB PCM buffer length mismatch: output {} bytes, expected {} ({} samples × {} subslot)",
            output.len(),
            expected,
            input.len(),
            ss
        ));
    }

    match subslot_size {
        2 => {
            if bit_resolution == 16 {
                encode_pcm_i16_le(input, output);
            } else {
                encode_pcm_bytes(input, output, subslot_size, bit_resolution);
            }
            Ok(())
        }
        3 => {
            for (index, sample) in input.iter().enumerate() {
                let slot = encode_i24(*sample);
                let offset = index * 3;
                output[offset..offset + 3].copy_from_slice(&slot);
            }
            Ok(())
        }
        4 => {
            for (index, &sample) in input.iter().enumerate() {
                let offset = index * 4;
                output[offset..offset + 4].copy_from_slice(&encode_i32_le(sample));
            }
            Ok(())
        }
        _ => {
            encode_pcm_bytes(input, output, subslot_size, bit_resolution);
            Ok(())
        }
    }
}

/// 16-bit PCM: linear i32 (from `convert_f32_to_pcm_samples`) → i16 (MSB extract) → LE.
fn encode_pcm_i16_le(input: &[i32], output: &mut [u8]) {
    debug_assert_eq!(output.len(), input.len() * 2);
    for (i, &sample) in input.iter().enumerate() {
        let i16_val = linear_pcm_i32_to_i16(sample);
        let bytes = i16_val.to_le_bytes();
        output[i * 2] = bytes[0];
        output[i * 2 + 1] = bytes[1];
    }
}

/// Pack i32 PCM samples into the USB subslot byte layout.
///
/// UAC2 Data Formats spec: PCM is signed two's complement, left-justified
/// (sign bit is the MSB of the container). Unused LSBs are zero-padded.
///
/// When `subslot_size * 8 > bit_resolution`, the sample is shifted left
/// so that the sign bit occupies the MSB of the container.
fn encode_pcm_bytes(input: &[i32], output: &mut [u8], subslot_size: u8, bit_resolution: u8) {
    let subslot_bytes = usize::from(subslot_size);
    debug_assert_eq!(output.len(), input.len() * subslot_bytes);

    let right_shift = 32u32.saturating_sub((subslot_size as u32) * 8);

    for (index, &sample) in input.iter().enumerate() {
        let offset = index * subslot_bytes;
        let shifted = if right_shift == 0 {
            sample
        } else {
            sample >> right_shift
        };
        let bytes = shifted.to_le_bytes();
        for byte_index in 0..subslot_bytes {
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

    log_info!(
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
    log_info!("[USB] PCM sample preview (i32): {:?}", sample_preview);
    log_info!(
        "[USB] byte-decoded preview (i32 from LE bytes): {:?}",
        byte_decoded_preview
    );
    log_info!("[USB] first 32 transfer bytes: {:?}", first_bytes_preview);
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

#[allow(dead_code)]
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

#[allow(dead_code)]
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
