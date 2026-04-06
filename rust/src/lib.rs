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
    sys::{jboolean, jint, jstring},
    JNIEnv, JavaVM,
};

#[cfg(target_os = "android")]
static ANDROID_APP_CONTEXT: OnceLock<GlobalRef> = OnceLock::new();

#[cfg(target_os = "android")]
fn initialize_android_app_context(
    env: &mut JNIEnv<'_>,
    context: JObject<'_>,
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

// JNI load only advertises the supported JNI version.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn JNI_OnLoad(_vm: JavaVM, _reserved: *mut c_void) -> jni::sys::jint {
    jni::JNIVersion::V6.into()
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeInitRustAndroidContext(
    mut env: JNIEnv<'_>,
    _activity: JObject<'_>,
    context: JObject<'_>,
) -> jboolean {
    match initialize_android_app_context(&mut env, context) {
        Ok(()) => {
            eprintln!("Rust Android audio context initialized");
            1
        }
        Err(error) => {
            eprintln!("Failed to initialize Android app context: {}", error);
            0
        }
    }
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeRegisterRustDirectUsbDevice(
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

    match crate::uac2::register_android_usb_device(crate::uac2::AndroidDirectUsbDevice {
        fd,
        vendor_id: vendor_id as u16,
        product_id: product_id as u16,
        product_name,
        manufacturer,
        serial,
        device_name,
    }) {
        Ok(()) => 1,
        Err(error) => {
            eprintln!("Failed to register Android direct USB DAC: {}", error);
            0
        }
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeRegisterRustDirectUsbDevice(
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
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeSetRustDirectUsbPlaybackFormat(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    sample_rate: jint,
    bit_depth: jint,
    channels: jint,
) -> jboolean {
    let playback_format = if sample_rate <= 0 || bit_depth <= 0 || channels <= 0 {
        None
    } else {
        Some(crate::uac2::AndroidDirectUsbPlaybackFormat {
            sample_rate: sample_rate as u32,
            bit_depth: bit_depth as u8,
            channels: channels as u16,
        })
    };

    match crate::uac2::set_android_usb_playback_format(playback_format) {
        Ok(()) => 1,
        Err(error) => {
            eprintln!(
                "Failed to update Android direct USB playback format: {}",
                error
            );
            0
        }
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeSetRustDirectUsbPlaybackFormat(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _sample_rate: jint,
    _bit_depth: jint,
    _channels: jint,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeSetRustDirectUsbLockEnabled(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    enabled: jboolean,
) -> jboolean {
    match crate::uac2::set_android_usb_lock_enabled(enabled != 0) {
        Ok(()) => 1,
        Err(error) => {
            eprintln!("Failed to update Android direct USB lock state: {}", error);
            0
        }
    }
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeSetRustDirectUsbLockEnabled(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _enabled: jboolean,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeGetRustAudioDebugStateJson(
    env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jstring {
    let engine_state = crate::api::audio_api::audio_get_runtime_debug_state();
    let direct_usb_state = crate::uac2::android_direct_debug_state();
    let payload = serde_json::json!({
        "engine": engine_state,
        "direct_usb": direct_usb_state,
    });
    let json = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
    env.new_string(json)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeGetRustAudioDebugStateJson(
    env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jstring {
    let payload = serde_json::json!({
        "engine": crate::api::audio_api::audio_get_runtime_debug_state(),
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
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeClearRustDirectUsbPlayback(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jboolean {
    crate::uac2::clear_android_usb_device();
    1
}

#[cfg(all(target_os = "android", feature = "uac2"))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeMarkRustDirectUsbFallback(
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
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeMarkRustDirectUsbFallback(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    _reason: JString<'_>,
) -> jboolean {
    0
}

#[cfg(all(target_os = "android", not(feature = "uac2")))]
#[no_mangle]
pub extern "system" fn Java_com_ultraelectronica_flick_MainActivity_nativeClearRustDirectUsbPlayback(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
) -> jboolean {
    0
}
