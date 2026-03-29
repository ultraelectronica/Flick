use crate::audio::commands::AudioEvent;
use crate::audio::engine::{audio_callback, AudioCallbackData};
use crate::uac2::control_requests::{ControlRequest, ControlRequestType, ControlSelector};
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
    disable_device_discovery, Context, Device, DeviceHandle, Direction, Speed, SyncType,
    TransferType, UsageType, UsbContext,
};
use std::ffi::c_void;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex as StdMutex, Once};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const USB_CLASS_AUDIO: u8 = 0x01;
const USB_SUBCLASS_AUDIOCONTROL: u8 = 0x01;
const USB_SUBCLASS_AUDIOSTREAMING: u8 = 0x02;
const USB_DT_CS_INTERFACE: u8 = 0x24;
const UAC2_CLOCK_SOURCE: u8 = 0x0a;
const ISO_TRANSFER_TIMEOUT_MS: u32 = 1000;

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

#[derive(Debug, Clone)]
struct AndroidDirectUsbState {
    device: AndroidDirectUsbDevice,
    playback_format: Option<AndroidDirectUsbPlaybackFormat>,
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
}

#[derive(Debug)]
struct AudioControlClock {
    interface_number: u8,
    clock_id: u8,
}

#[derive(Debug)]
struct IsoPacketScheduler {
    sample_rate: u32,
    service_interval_us: u32,
    remainder: u64,
    bytes_per_frame: usize,
    packets_per_transfer: usize,
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

pub struct AndroidDirectUsbBackend {
    stop: Arc<AtomicBool>,
    thread_handle: Option<JoinHandle<()>>,
}

static DIRECT_USB_STATE: Lazy<Mutex<Option<AndroidDirectUsbState>>> =
    Lazy::new(|| Mutex::new(None));
static DIRECT_USB_DISCOVERY_DISABLED: Once = Once::new();

pub fn register_android_usb_device(device: AndroidDirectUsbDevice) -> Result<(), String> {
    let existing_format = DIRECT_USB_STATE
        .lock()
        .as_ref()
        .and_then(|state| state.playback_format);

    *DIRECT_USB_STATE.lock() = Some(AndroidDirectUsbState {
        device,
        playback_format: existing_format,
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

    state.playback_format = playback_format;
    Ok(())
}

pub fn clear_android_usb_device() {
    *DIRECT_USB_STATE.lock() = None;
}

pub fn android_direct_output_signature(preferred_sample_rate: Option<u32>) -> Option<String> {
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

pub fn create_android_usb_backend(
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    preferred_sample_rate: u32,
) -> Result<Option<AndroidDirectUsbBackend>, String> {
    let state = {
        let guard = DIRECT_USB_STATE.lock();
        let Some(state) = guard.as_ref() else {
            return Ok(None);
        };
        let Some(playback_format) = state.playback_format else {
            return Ok(None);
        };
        if playback_format.sample_rate != preferred_sample_rate {
            return Ok(None);
        }
        state.clone()
    };

    DIRECT_USB_DISCOVERY_DISABLED.call_once(|| {
        if let Err(error) = disable_device_discovery() {
            eprintln!(
                "Android USB direct: failed to disable libusb device discovery: {}",
                error
            );
        }
    });

    let context =
        Context::new().map_err(|error| format!("Failed to create libusb context: {}", error))?;
    let handle = unsafe { context.open_device_with_fd(state.device.fd) }
        .map_err(|error| format!("Failed to wrap Android USB file descriptor: {}", error))?;
    let device = handle.device();
    let speed = device.speed();
    let candidate = select_stream_candidate(&device, state.playback_format.unwrap(), speed)?;
    let clock = find_audio_control_clock(&device);

    eprintln!(
        "Android USB direct candidate '{}' (endpoint=0x{:02x}, interface={}, alt={}, interval={}, service={}us, max_packet={}, sync={:?}, usage={:?}, speed={:?})",
        state.device.product_name,
        candidate.endpoint_address,
        candidate.interface_number,
        candidate.alt_setting,
        candidate.endpoint_interval,
        candidate.service_interval_us,
        candidate.max_packet_bytes,
        candidate.sync_type,
        candidate.usage_type,
        speed,
    );

    handle
        .claim_interface(candidate.interface_number)
        .map_err(|error| {
            format!(
                "Failed to claim USB interface {}: {}",
                candidate.interface_number, error
            )
        })?;
    handle
        .set_alternate_setting(candidate.interface_number, candidate.alt_setting)
        .map_err(|error| {
            format!(
                "Failed to set USB alt setting {} on interface {}: {}",
                candidate.alt_setting, candidate.interface_number, error
            )
        })?;

    if let Some(clock) = clock {
        if let Err(error) = set_sampling_frequency(
            &handle,
            clock.interface_number,
            clock.clock_id,
            state.playback_format.unwrap().sample_rate,
        ) {
            eprintln!(
                "Android USB direct could not set sampling frequency on clock {}: {}",
                clock.clock_id, error
            );
        } else {
            eprintln!(
                "Android USB direct set sampling frequency to {} Hz using clock {} on interface {}",
                state.playback_format.unwrap().sample_rate,
                clock.clock_id,
                clock.interface_number,
            );
        }
    }

    eprintln!(
        "Android USB direct output opened '{}' requested {} Hz / {}-bit / {} ch on endpoint 0x{:02x} (interface {}, alt {}, speed {:?})",
        state.device.product_name,
        state.playback_format.unwrap().sample_rate,
        state.playback_format.unwrap().bit_depth,
        state.playback_format.unwrap().channels,
        candidate.endpoint_address,
        candidate.interface_number,
        candidate.alt_setting,
        speed,
    );

    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = Arc::clone(&stop);
    let thread_handle = thread::Builder::new()
        .name("android-usb-direct-output".to_string())
        .spawn(move || {
            run_usb_output_loop(
                context,
                handle,
                candidate,
                state,
                callback_data,
                event_tx,
                stop_clone,
            );
        })
        .map_err(|error| {
            format!(
                "Failed to spawn Android USB direct output thread: {}",
                error
            )
        })?;

    Ok(Some(AndroidDirectUsbBackend {
        stop,
        thread_handle: Some(thread_handle),
    }))
}

impl AndroidDirectUsbBackend {
    pub fn stop(&mut self) -> Result<(), String> {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.thread_handle.take() {
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
    fn new(format: AndroidDirectUsbPlaybackFormat, service_interval_us: u32) -> Self {
        let bytes_per_frame =
            bytes_per_sample(format.bit_depth).unwrap_or(0) * format.channels as usize;
        let packets_per_transfer = if service_interval_us >= 1_000 {
            8usize
        } else {
            (1_000u32 / service_interval_us).clamp(1, 8) as usize
        };

        Self {
            sample_rate: format.sample_rate,
            service_interval_us,
            remainder: 0,
            bytes_per_frame,
            packets_per_transfer,
        }
    }

    fn next_transfer_packet_bytes(&mut self) -> Vec<usize> {
        (0..self.packets_per_transfer)
            .map(|_| self.next_packet_bytes())
            .collect()
    }

    fn next_packet_bytes(&mut self) -> usize {
        let total = self.remainder + (self.sample_rate as u64 * self.service_interval_us as u64);
        let frames = (total / 1_000_000) as usize;
        self.remainder = total % 1_000_000;
        frames.saturating_mul(self.bytes_per_frame)
    }
}

fn run_usb_output_loop(
    context: Context,
    handle: DeviceHandle<Context>,
    candidate: AndroidIsoStreamCandidate,
    state: AndroidDirectUsbState,
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    stop: Arc<AtomicBool>,
) {
    let playback_format = state.playback_format.unwrap();
    let bytes_per_sample = match bytes_per_sample(playback_format.bit_depth) {
        Some(value) => value,
        None => {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!(
                    "Unsupported Android USB direct bit depth: {}",
                    playback_format.bit_depth
                ),
            });
            return;
        }
    };

    let channels = playback_format.channels as usize;
    let mut scheduler = IsoPacketScheduler::new(playback_format, candidate.service_interval_us);

    while !stop.load(Ordering::Acquire) {
        let packet_bytes = scheduler.next_transfer_packet_bytes();
        let total_bytes: usize = packet_bytes.iter().sum();
        if total_bytes == 0 {
            thread::sleep(Duration::from_millis(1));
            continue;
        }

        let total_samples = (total_bytes / bytes_per_sample).max(channels);
        let mut scratch = vec![0.0f32; total_samples];
        audio_callback(&mut scratch, &callback_data, &event_tx);

        let mut transfer_buffer = vec![0u8; total_bytes];
        let usable_samples = total_bytes / bytes_per_sample;
        if let Err(error) = convert_f32_to_pcm(
            &scratch[..usable_samples.min(scratch.len())],
            playback_format.bit_depth,
            &mut transfer_buffer,
        ) {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Android USB direct PCM conversion failed: {}", error),
            });
            break;
        }

        if let Err(error) = submit_iso_transfer(
            &context,
            &handle,
            candidate.endpoint_address,
            &packet_bytes,
            transfer_buffer,
        ) {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Android USB direct transfer failed: {}", error),
            });
            eprintln!("Android USB direct transfer failed: {}", error);
            break;
        }
    }

    let _ = handle.set_alternate_setting(candidate.interface_number, 0);
    let _ = handle.release_interface(candidate.interface_number);
}

fn select_stream_candidate(
    device: &Device<Context>,
    playback_format: AndroidDirectUsbPlaybackFormat,
    speed: Speed,
) -> Result<AndroidIsoStreamCandidate, String> {
    let config_descriptor = device
        .active_config_descriptor()
        .map_err(|error| format!("Failed to read active USB config descriptor: {}", error))?;
    let bytes_per_frame = bytes_per_sample(playback_format.bit_depth)
        .ok_or_else(|| format!("Unsupported bit depth: {}", playback_format.bit_depth))?
        * playback_format.channels as usize;

    let mut candidates = Vec::new();
    for interface in config_descriptor.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() != USB_CLASS_AUDIO
                || descriptor.sub_class_code() != USB_SUBCLASS_AUDIOSTREAMING
            {
                continue;
            }

            for endpoint in descriptor.endpoint_descriptors() {
                if endpoint.direction() != Direction::Out
                    || endpoint.transfer_type() != TransferType::Isochronous
                {
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
                let required_max_packet_bytes = required_max_packet_bytes(
                    playback_format.sample_rate,
                    service_interval_us,
                    bytes_per_frame,
                );

                eprintln!(
                    "Android USB direct stream candidate interface={} alt={} endpoint=0x{:02x} interval={} service={}us max_packet={} required={} sync={:?} usage={:?}",
                    descriptor.interface_number(),
                    descriptor.setting_number(),
                    endpoint.address(),
                    endpoint.interval(),
                    service_interval_us,
                    max_packet_bytes,
                    required_max_packet_bytes,
                    endpoint.sync_type(),
                    endpoint.usage_type(),
                );

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
                });
            }
        }
    }

    candidates.sort_by_key(|candidate| {
        (
            candidate.max_packet_bytes,
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
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::SetCur)
        .selector(ControlSelector::SamplingFreq)
        .interface(interface_number)
        .entity_id(clock_id)
        .data(sample_rate.to_le_bytes().to_vec())
        .build()
        .map_err(|error| format!("Failed to build sampling-frequency request: {}", error))?;

    request
        .execute(handle)
        .map_err(|error| format!("Failed to set sampling frequency: {}", error))?;
    Ok(())
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

fn convert_f32_to_pcm(input: &[f32], bit_depth: u8, output: &mut [u8]) -> Result<(), String> {
    let bytes_per_sample = bytes_per_sample(bit_depth)
        .ok_or_else(|| format!("Unsupported bit depth: {}", bit_depth))?;
    if output.len() != input.len() * bytes_per_sample {
        return Err(format!(
            "PCM output buffer size mismatch: expected {}, got {}",
            input.len() * bytes_per_sample,
            output.len()
        ));
    }

    for (index, sample) in input.iter().enumerate() {
        let sample = sample.clamp(-1.0, 1.0);
        let offset = index * bytes_per_sample;

        match bit_depth {
            16 => {
                let value = (sample * 32768.0).round() as i32;
                let clamped = value.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
                output[offset..offset + 2].copy_from_slice(&clamped.to_le_bytes());
            }
            24 => {
                let value = (sample * 8_388_608.0).round() as i32;
                let clamped = value.clamp(-8_388_608, 8_388_607);
                let bytes = clamped.to_le_bytes();
                output[offset] = bytes[0];
                output[offset + 1] = bytes[1];
                output[offset + 2] = bytes[2];
            }
            32 => {
                let value = (sample * 2_147_483_648.0).round() as i64;
                let clamped = value.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
                output[offset..offset + 4].copy_from_slice(&clamped.to_le_bytes());
            }
            _ => return Err(format!("Unsupported bit depth: {}", bit_depth)),
        }
    }

    Ok(())
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

    unsafe {
        libusb_free_transfer(transfer_ptr.as_ptr());
        drop(Box::from_raw(user_data_ptr));
    }

    match status {
        LIBUSB_TRANSFER_COMPLETED => Ok(()),
        LIBUSB_TRANSFER_TIMED_OUT => Err("isochronous transfer timed out".to_string()),
        LIBUSB_TRANSFER_STALL => Err("isochronous transfer stalled".to_string()),
        LIBUSB_TRANSFER_NO_DEVICE => Err("USB DAC disconnected".to_string()),
        LIBUSB_TRANSFER_OVERFLOW => Err("isochronous transfer overflow".to_string()),
        LIBUSB_TRANSFER_CANCELLED => Err("isochronous transfer cancelled".to_string()),
        LIBUSB_TRANSFER_ERROR => Err("isochronous transfer failed".to_string()),
        other => Err(format!("isochronous transfer returned status {}", other)),
    }
}
