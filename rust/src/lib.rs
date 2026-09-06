pub mod api;

// Audio engine is now available on all platforms including Android (using CPAL with Oboe backend)
pub mod audio;
pub mod library_scan;

/// Custom UAC 2.0 USB Audio (DAC/AMP detection and direct playback paths).
/// Real implementation is gated by the `uac2` feature.
pub mod uac2;

mod frb_generated;

#[cfg(target_os = "android")]
use std::{ffi::c_void, sync::OnceLock};

#[cfg(target_os = "android")]
use jni::{
    objects::{GlobalRef, JObject, JString},
    sys::{jboolean, jdouble, jint, jstring},
    JNIEnv, JavaVM,
};

#[cfg(target_os = "android")]
static ANDROID_APP_CONTEXT: OnceLock<GlobalRef> = OnceLock::new();

#[cfg(target_os = "android")]
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(target_os = "android")]
static DEVELOPER_MODE: AtomicBool = AtomicBool::new(false);
#[cfg(not(target_os = "android"))]
use std::sync::atomic::AtomicBool;
#[cfg(not(target_os = "android"))]
static DEVELOPER_MODE: AtomicBool = AtomicBool::new(true);

#[macro_export]
macro_rules! dev_eprintln {
    ($($arg:tt)*) => {
        if crate::DEVELOPER_MODE.load(std::sync::atomic::Ordering::Relaxed) {
            let __msg = format!($($arg)*);
            eprintln!("{}", __msg);
            // ponytail: route through android_logger (tag "RustUSB") so devLogs
            // reach `adb logcat`. Raw eprintln/stderr is invisible on Android.
            log::info!("{}", __msg);
            crate::api::logging::forward_to_sink(__msg);
        }
    };
}

#[cfg(target_os = "android")]
fn initialize_android_app_context<'local>(
    env: &mut JNIEnv<'local>,
    context: &JObject<'local>,
) -> Result<(), String> {
    if ANDROID_APP_CONTEXT.get().is_some() {
        return Ok(());
    }

    let java_vm = env.get_java_vm().map_err(|error| error.to_string())?;
    let global_context = env
        .new_global_ref(context)
        .map_err(|error| error.to_string())?;
    let context_ptr = global_context.as_obj().as_raw() as *mut c_void;

    match ANDROID_APP_CONTEXT.set(global_context) {
        Ok(()) => {
            unsafe {
                ndk_context::initialize_android_context(
                    java_vm.get_java_vm_pointer() as *mut c_void,
                    context_ptr,
                );
            }
            Ok(())
        }
        Err(_) => Ok(()),
    }
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn JNI_OnLoad(_vm: JavaVM, _reserved: *mut c_void) -> jni::sys::jint {
    android_logger::init_once(
        android_logger::Config::default()
            // Debug builds log Debug+; release keeps Info so DSD transport
            // telemetry (starvation warns, SAS probe) reaches logcat.
            .with_max_level(if cfg!(debug_assertions) {
                log::LevelFilter::Debug
            } else {
                log::LevelFilter::Info
            })
            .with_tag("RustUSB"),
    );
    jni::JNIVersion::V6.into()
}

/// FRB installs its own `android_logger` during `RustLib.init` and clobbers
/// the max level, silencing our logs after boot. Call at audio API entry
/// points to keep debug builds logging for the whole session.
#[cfg(target_os = "android")]
pub fn assert_android_debug_logging() {
    if cfg!(debug_assertions) {
        log::set_max_level(log::LevelFilter::Debug);
    }
}

#[cfg(not(target_os = "android"))]
pub fn assert_android_debug_logging() {}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeInitRustAndroidContext<'local>(
    mut env: JNIEnv<'local>,
    _activity: JObject<'_>,
    context: JObject<'local>,
) -> jboolean {
    match initialize_android_app_context(&mut env, &context) {
        Ok(()) => {
            match crate::audio::device::detect_android_device_profile(&mut env, &context) {
                Ok(profile) => {
                    log::info!(
                        "[ANDROID] Cached device profile: kind={:?} bit_perfect={} max_rate_hz={} balanced={}",
                        profile.kind,
                        profile.confirmed_bit_perfect,
                        profile.max_sample_rate,
                        profile.has_balanced_output,
                    );
                    crate::audio::device::cache_android_device_profile(profile);
                }
                Err(error) => {
                    log::warn!("[ANDROID] Failed to detect device profile: {}", error);
                }
            }
            dev_eprintln!("Rust Android audio context initialized");
            1
        }
        Err(error) => {
            dev_eprintln!("Failed to initialize Android app context: {}", error);
            0
        }
    }
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeRegisterRustDirectUsbDevice(
    mut env: JNIEnv<'_>,
    _activity: JObject<'_>,
    fd: jint,
    vendor_id: jint,
    product_id: jint,
    product_name: JString<'_>,
    manufacturer: JString<'_>,
    serial: JString<'_>,
    device_name: JString<'_>,
) -> jboolean {
    let read_string = |env: &mut JNIEnv<'_>, value: JString<'_>| -> Option<String> {
        let object: JObject<'_> = value.into();
        if object.is_null() {
            return None;
        }

        env.get_string(&JString::from(object))
            .ok()
            .map(|value| value.to_string_lossy().into_owned())
    };

    let product_name =
        read_string(&mut env, product_name).unwrap_or_else(|| "USB Audio Device".to_string());
    let manufacturer = read_string(&mut env, manufacturer).unwrap_or_default();
    let serial = read_string(&mut env, serial);
    let device_name = read_string(&mut env, device_name);

    let device = match crate::uac2::AndroidDirectUsbDevice::try_new(
        fd,
        vendor_id as u16,
        product_id as u16,
        product_name,
        manufacturer,
        serial,
        device_name,
    ) {
        Ok(device) => device,
        Err(error) => {
            dev_eprintln!(
                "Failed to prepare Android direct USB DAC registration: {}",
                error
            );
            return 0;
        }
    };

    match crate::uac2::register_android_usb_device(device) {
        Ok(()) => 1,
        Err(error) => {
            dev_eprintln!("Failed to register Android direct USB DAC: {}", error);
            0
        }
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeRegisterRustDirectUsbDevice(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _fd: jint,
    _vendor_id: jint,
    _product_id: jint,
    _product_name: JString<'_>,
    _manufacturer: JString<'_>,
    _serial: JString<'_>,
    _device_name: JString<'_>,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDirectUsbPlaybackFormat(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    sample_rate: jint,
    bit_depth: jint,
    channels: jint,
    is_dop: jboolean,
    is_native_dsd: jboolean,
) -> jboolean {
    let dsd_transport = if is_dop != 0 {
        crate::uac2::DsdTransportMode::DoP
    } else if is_native_dsd != 0 {
        crate::uac2::DsdTransportMode::Native
    } else {
        crate::uac2::DsdTransportMode::None
    };
    let playback_format = if sample_rate <= 0 || bit_depth <= 0 || channels <= 0 {
        None
    } else {
        Some(crate::uac2::AndroidDirectUsbPlaybackFormat {
            sample_rate: sample_rate as u32,
            bit_depth: bit_depth as u8,
            channels: channels as u16,
            is_dop: is_dop != 0,
            dsd_transport,
            dsd_bit_rate: 0,
        })
    };

    match crate::uac2::set_android_usb_playback_format(playback_format) {
        Ok(()) => 1,
        Err(error) => {
            dev_eprintln!(
                "Failed to update Android direct USB playback format: {}",
                error
            );
            0
        }
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDirectUsbPlaybackFormat(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _sample_rate: jint,
    _bit_depth: jint,
    _channels: jint,
    _is_dop: jboolean,
    _is_native_dsd: jboolean,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDirectUsbLockEnabled(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    enabled: jboolean,
) -> jboolean {
    match crate::uac2::set_android_usb_lock_enabled(enabled != 0) {
        Ok(()) => 1,
        Err(error) => {
            dev_eprintln!("Failed to update Android direct USB lock state: {}", error);
            0
        }
    }
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeHasRustDirectUsbHardwareVolume(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jboolean {
    if crate::uac2::android_direct_has_hardware_volume_control() {
        1
    } else {
        0
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeHasRustDirectUsbHardwareVolume(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeGetRustDirectUsbHardwareVolume(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jdouble {
    crate::uac2::android_direct_cached_hardware_volume().unwrap_or(f64::NAN)
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeGetRustDirectUsbHardwareVolume(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jdouble {
    f64::NAN
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDirectUsbHardwareVolume(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    volume: jdouble,
) -> jboolean {
    match crate::uac2::android_direct_set_hardware_volume(volume) {
        Ok(()) => 1,
        Err(error) => {
            dev_eprintln!(
                "Failed to set Android direct USB hardware volume: {}",
                error
            );
            0
        }
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDirectUsbHardwareVolume(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _volume: jdouble,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeGetRustDirectUsbHardwareMute(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jint {
    match crate::uac2::android_direct_cached_hardware_mute() {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeGetRustDirectUsbHardwareMute(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jint {
    -1
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDirectUsbHardwareMute(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    muted: jboolean,
) -> jboolean {
    match crate::uac2::android_direct_set_hardware_mute(muted != 0) {
        Ok(()) => 1,
        Err(error) => {
            dev_eprintln!("Failed to set Android direct USB hardware mute: {}", error);
            0
        }
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDirectUsbHardwareMute(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _muted: jboolean,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeVerifyRustDirectUsbHardwareVolumeHealth(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jint {
    match crate::uac2::android_direct_verify_hardware_volume_health() {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => -1,
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeVerifyRustDirectUsbHardwareVolumeHealth(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jint {
    -1
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDirectUsbLockEnabled(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _enabled: jboolean,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeGetRustAudioDebugStateJson(
    env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jstring {
    let engine_state = crate::api::audio_api::audio_get_runtime_debug_json_state();
    let direct_usb_state = crate::uac2::android_direct_debug_state();
    let payload = serde_json::json!({
        "engine": engine_state,
        "device_profile": crate::audio::device::current_device_profile(),
        "direct_usb": direct_usb_state,
    });
    let json = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
    env.new_string(json)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeGetRustAudioDebugStateJson(
    env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jstring {
    let payload = serde_json::json!({
        "engine": crate::api::audio_api::audio_get_runtime_debug_json_state(),
        "device_profile": crate::audio::device::current_device_profile(),
        "direct_usb": {
            "registered": false,
            "idle_lock_held": false,
            "stream_active": false,
        },
    });
    let json = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
    env.new_string(json)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeClearRustDirectUsbPlayback(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jboolean {
    crate::uac2::clear_android_usb_device();
    1
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeWaitRustDirectUsbSessionStopped(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    timeout_ms: jint,
) -> jboolean {
    crate::uac2::wait_for_android_usb_session_stop(std::time::Duration::from_millis(
        timeout_ms.max(0) as u64,
    )) as jboolean
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeIsRustDirectUsbSessionActive(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jboolean {
    crate::uac2::is_usb_session_active() as jboolean
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeMarkRustDirectUsbFallback(
    mut env: JNIEnv<'_>,
    _activity: JObject<'_>,
    reason: JString<'_>,
) -> jboolean {
    let reason = {
        let object: JObject<'_> = reason.into();
        if object.is_null() {
            None
        } else {
            env.get_string(&JString::from(object))
                .ok()
                .map(|value| value.to_string_lossy().into_owned())
        }
    };
    crate::uac2::mark_android_usb_fallback(reason);
    1
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeMarkRustDirectUsbFallback(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _reason: JString<'_>,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeClearRustDirectUsbPlayback(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeWaitRustDirectUsbSessionStopped(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _timeout_ms: jint,
) -> jboolean {
    1
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeIsRustDirectUsbSessionActive(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jboolean {
    0
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_mossapps_flick_MainActivity_nativeSetRustDeveloperMode(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    enabled: jboolean,
) {
    DEVELOPER_MODE.store(enabled != 0, Ordering::Relaxed);
    // Developer mode off still keeps Info: DSD starvation/SAS diagnostics
    // must survive in release builds.
    let level = if enabled != 0 {
        log::LevelFilter::Debug
    } else {
        log::LevelFilter::Info
    };
    log::set_max_level(level);
}
