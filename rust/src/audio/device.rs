use serde::Serialize;

#[cfg(target_os = "android")]
use std::sync::OnceLock;

#[cfg(target_os = "android")]
use jni::{
    objects::{JIntArray, JObject, JObjectArray, JString, JValue},
    JNIEnv,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DeviceProfile {
    pub kind: DeviceKind,
    pub confirmed_bit_perfect: bool,
    pub max_sample_rate: u32,
    pub has_balanced_output: bool,
    pub supports_native_dsd: bool,
}

impl Default for DeviceProfile {
    fn default() -> Self {
        Self::unknown()
    }
}

impl DeviceProfile {
    pub const fn unknown() -> Self {
        Self {
            kind: DeviceKind::Unknown,
            confirmed_bit_perfect: false,
            max_sample_rate: 0,
            has_balanced_output: false,
            supports_native_dsd: false,
        }
    }

    pub fn is_dap(&self) -> bool {
        matches!(self.kind, DeviceKind::Dap(_))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum DeviceKind {
    Dap(String),
    Phone,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DapSignature {
    pub id: &'static str,
    pub label: &'static str,
    pub keywords: &'static [&'static str],
    pub model_prefixes: &'static [&'static str],
    pub manufacturer_sufficient: bool,
}

static DAP_REGISTRY: &[DapSignature] = &[
    DapSignature {
        id: "fiio",
        label: "FiiO",
        keywords: &["fiio"],
        model_prefixes: &[
            "M11", "M15", "M17", "M21", "M23", "M27", "JM21", "M0", "M1", "M3", "M5", "M6", "M7",
            "M8",
        ],
        manufacturer_sufficient: true,
    },
    DapSignature {
        id: "ibasso",
        label: "iBasso",
        keywords: &["ibasso"],
        model_prefixes: &[
            "DX160", "DX170", "DX180", "DX220", "DX240", "DX260", "DX300", "DX320", "DX340",
        ],
        manufacturer_sufficient: true,
    },
    DapSignature {
        id: "hiby",
        label: "HiBy",
        keywords: &["hiby"],
        model_prefixes: &["R3", "R4", "R5", "R6", "R8"],
        manufacturer_sufficient: true,
    },
    DapSignature {
        id: "shanling",
        label: "Shanling",
        keywords: &["shanling"],
        model_prefixes: &["M300"],
        manufacturer_sufficient: true,
    },
    DapSignature {
        id: "astellkern",
        label: "Astell&Kern",
        keywords: &["astell", "iriver"],
        model_prefixes: &["SA", "SP", "SE", "A&"],
        manufacturer_sufficient: true,
    },
    DapSignature {
        id: "cayin",
        label: "Cayin",
        keywords: &["cayin"],
        model_prefixes: &["N3", "N5", "N6", "N7"],
        manufacturer_sufficient: true,
    },
    DapSignature {
        id: "sony",
        label: "Sony",
        keywords: &["sony"],
        model_prefixes: &["NW-A", "NW-WM", "NW-ZX"],
        manufacturer_sufficient: false,
    },
    DapSignature {
        id: "tempotec",
        label: "TempoTec",
        keywords: &["tempotec"],
        model_prefixes: &["V6", "S3", "Mobi", "Sonata", "iDSD"],
        manufacturer_sufficient: true,
    },
    DapSignature {
        id: "luxury_precision",
        label: "Luxury & Precision",
        keywords: &["luxury", "luxuryprecision"],
        model_prefixes: &["P6"],
        manufacturer_sufficient: true,
    },
];

pub fn detect_dap(manufacturer: &str, brand: &str, model: &str) -> Option<&'static DapSignature> {
    let manufacturer_lower = manufacturer.to_ascii_lowercase();
    let brand_lower = brand.to_ascii_lowercase();
    let model_upper = model.trim().to_ascii_uppercase();

    for signature in DAP_REGISTRY {
        let keyword_match = signature
            .keywords
            .iter()
            .any(|kw| manufacturer_lower.contains(kw) || brand_lower.contains(kw));

        if keyword_match && signature.manufacturer_sufficient {
            return Some(signature);
        }

        if keyword_match
            && signature
                .model_prefixes
                .iter()
                .any(|p| model_upper.starts_with(p))
        {
            return Some(signature);
        }
    }

    None
}

pub fn is_known_dap_model(model: &str) -> bool {
    let model_upper = model.trim().to_ascii_uppercase();
    DAP_REGISTRY.iter().any(|sig| {
        sig.model_prefixes
            .iter()
            .any(|p| model_upper.starts_with(p))
    })
}

pub fn dap_signatures() -> &'static [DapSignature] {
    DAP_REGISTRY
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AudioCapabilities {
    pub max_sample_rate: u32,
    pub max_bit_depth: u32,
    pub supports_native_dsd: bool,
    pub has_balanced_output: bool,
}

#[derive(Debug, Clone)]
pub struct DeviceSignals {
    pub manufacturer: String,
    pub model: String,
    pub brand: String,
    pub manufacturer_match: Option<String>,
    pub model_match: bool,
    pub no_telephony: bool,
    pub audio_caps: AudioCapabilities,
    pub mango_mode: bool,
}

pub fn classify_device(signals: DeviceSignals) -> DeviceProfile {
    let manufacturer = signals.manufacturer.to_ascii_lowercase();
    let brand = signals.brand.to_ascii_lowercase();
    let manufacturer_match = signals.manufacturer_match.or_else(|| {
        if signals.mango_mode {
            Some("iBasso".to_string())
        } else {
            None
        }
    });
    let high_res_internal = signals.audio_caps.max_sample_rate >= 88_200;

    let kind = match manufacturer_match {
        Some(brand_label) => DeviceKind::Dap(brand_label),
        None if signals.no_telephony && high_res_internal && signals.model_match => {
            DeviceKind::Dap("Other".to_string())
        }
        None if manufacturer.contains("sony") || brand.contains("sony") => DeviceKind::Phone,
        None if !manufacturer.is_empty() || !brand.is_empty() => DeviceKind::Phone,
        None => DeviceKind::Unknown,
    };

    let is_dap = matches!(kind, DeviceKind::Dap(_));
    let native_dsd_from_caps = signals.audio_caps.supports_native_dsd;
    let native_dsd_from_runtime = if is_dap && !native_dsd_from_caps {
        crate::audio::dsd_native_jni::is_dsd_encoding_cached_available()
    } else {
        false
    };
    // ALSA direct path: DAPs whose HAL doesn't expose ENCODING_DSD may still
    // have a kernel ALSA driver that supports DSD natively. This is what pro
    // players (UAPP, Neutron) use to bypass AudioFlinger entirely.
    let native_dsd_from_alsa =
        is_dap && !native_dsd_from_caps && !native_dsd_from_runtime && {
            let probe = crate::audio::dsd_alsa_direct::dsd_alsa_probe();
            if probe {
                log::info!("[DSD-NATIVE] ALSA direct DSD path available for {:?}", kind);
            }
            probe
        };
    // Vendor offload shim: libsmartaudioservice.so (public on DAP firmware)
    // creates framework DSD_NATIVE AudioTracks — the stock player's path and
    // the only native route on SELinux-locked DAPs. Cheap dlopen check.
    let native_dsd_from_sas =
        is_dap && !native_dsd_from_caps && !native_dsd_from_runtime && {
            let available = crate::audio::dsd_sas_shim::probe_available();
            if available {
                log::info!(
                    "[DSD-NATIVE] SAS offload shim available for {:?} (libsmartaudioservice.so)",
                    kind
                );
            } else if let Some(reason) = crate::audio::dsd_sas_shim::probe_unavailable_reason() {
                log::info!("[DSD-NATIVE] SAS offload shim unavailable: {}", reason);
            }
            available
        };
    DeviceProfile {
        confirmed_bit_perfect: is_dap,
        kind,
        max_sample_rate: signals.audio_caps.max_sample_rate,
        has_balanced_output: signals.audio_caps.has_balanced_output,
        supports_native_dsd: native_dsd_from_caps
            || native_dsd_from_runtime
            || native_dsd_from_alsa
            || native_dsd_from_sas,
    }
}

#[cfg(target_os = "android")]
static ANDROID_DEVICE_PROFILE: OnceLock<DeviceProfile> = OnceLock::new();

#[cfg(target_os = "android")]
pub fn cache_android_device_profile(profile: DeviceProfile) {
    let _ = ANDROID_DEVICE_PROFILE.set(profile);
}

pub fn current_device_profile() -> Option<DeviceProfile> {
    #[cfg(target_os = "android")]
    {
        return ANDROID_DEVICE_PROFILE.get().cloned();
    }

    #[cfg(not(target_os = "android"))]
    {
        None
    }
}

#[cfg(target_os = "android")]
pub fn detect_android_device_profile<'local>(
    env: &mut JNIEnv<'local>,
    context: &JObject<'local>,
) -> Result<DeviceProfile, String> {
    let manufacturer = get_build_field(env, "MANUFACTURER")?;
    let model = get_build_field(env, "MODEL")?;
    let brand = get_build_field(env, "BRAND")?;
    let manufacturer_match =
        detect_dap(&manufacturer, &brand, &model).map(|sig| sig.label.to_string());
    let audio_caps = match probe_audio_capabilities(env, context) {
        Ok(caps) => caps,
        Err(error) => {
            clear_pending_exception(env);
            log::warn!("[ANDROID] Audio capability probe failed: {}", error);
            AudioCapabilities::default()
        }
    };
    let no_telephony = if manufacturer_match.is_none() {
        match get_phone_type(env, context) {
            Ok(phone_type) => phone_type == Some(0),
            Err(error) => {
                clear_pending_exception(env);
                log::warn!("[ANDROID] Telephony probe failed: {}", error);
                false
            }
        }
    } else {
        false
    };
    let mango_mode = if manufacturer_match.as_deref() == Some("iBasso") {
        detect_ibasso_mango_mode(env)
    } else {
        false
    };

    // Populate the ENCODING_DSD runtime cache for DAPs that don't advertise it in
    // AudioDeviceInfo encodings. The Kotlin probe validates field existence +
    // getMinBufferSize at DSD64, so only real hardware reports true.
    if manufacturer_match.is_some() && !audio_caps.supports_native_dsd {
        let probe = crate::audio::dsd_native_jni::dsd_track_class_available();
        log::info!(
            "[DSD-NATIVE] ENCODING_DSD probe for {:?}: supported={}",
            manufacturer_match,
            probe
        );
    }

    Ok(classify_device(DeviceSignals {
        manufacturer,
        model: model.clone(),
        brand,
        manufacturer_match,
        model_match: is_known_dap_model(&model),
        no_telephony,
        audio_caps,
        mango_mode,
    }))
}

#[cfg(target_os = "android")]
fn get_build_field(env: &mut JNIEnv<'_>, field: &str) -> Result<String, String> {
    let value = match env.get_static_field("android/os/Build", field, "Ljava/lang/String;") {
        Ok(value) => value,
        Err(error) => {
            clear_pending_exception(env);
            return Err(format!("Failed to read Build.{}: {}", field, error));
        }
    };
    let value = match value.l() {
        Ok(value) => value,
        Err(error) => {
            clear_pending_exception(env);
            return Err(format!("Failed to resolve Build.{}: {}", field, error));
        }
    };
    java_string(env, value)
}

#[cfg(target_os = "android")]
fn probe_audio_capabilities<'local>(
    env: &mut JNIEnv<'local>,
    context: &JObject<'local>,
) -> Result<AudioCapabilities, String> {
    if get_sdk_int(env).unwrap_or_default() < 23 {
        return Ok(AudioCapabilities::default());
    }

    let audio_manager = get_system_service(env, context, "AUDIO_SERVICE")?;
    if audio_manager.is_null() {
        return Ok(AudioCapabilities::default());
    }

    let get_devices_outputs = env
        .get_static_field("android/media/AudioManager", "GET_DEVICES_OUTPUTS", "I")
        .map_err(|error| format!("Failed to read AudioManager.GET_DEVICES_OUTPUTS: {}", error))?
        .i()
        .map_err(|error| format!("Invalid AudioManager.GET_DEVICES_OUTPUTS: {}", error))?;
    let devices = env
        .call_method(
            &audio_manager,
            "getDevices",
            "(I)[Landroid/media/AudioDeviceInfo;",
            &[JValue::Int(get_devices_outputs)],
        )
        .map_err(|error| format!("AudioManager.getDevices failed: {}", error))?
        .l()
        .map_err(|error| format!("AudioManager.getDevices returned invalid data: {}", error))?;
    if devices.is_null() {
        return Ok(AudioCapabilities::default());
    }

    let relevant_types = [
        audio_device_type(env, "TYPE_AUX_LINE"),
        audio_device_type(env, "TYPE_WIRED_HEADPHONES"),
        audio_device_type(env, "TYPE_WIRED_HEADSET"),
        audio_device_type(env, "TYPE_LINE_ANALOG"),
        audio_device_type(env, "TYPE_LINE_DIGITAL"),
    ];
    let encoding_pcm_24 = audio_format_encoding(env, "ENCODING_PCM_24BIT_PACKED");
    let encoding_pcm_32 = audio_format_encoding(env, "ENCODING_PCM_32BIT");
    let encoding_float = audio_format_encoding(env, "ENCODING_PCM_FLOAT");
    let encoding_dsd = audio_format_encoding(env, "ENCODING_DSD");
    let device_array = JObjectArray::from(devices);
    let device_count = env
        .get_array_length(&device_array)
        .map_err(|error| format!("Failed to read AudioDeviceInfo array length: {}", error))?;

    let mut max_sample_rate = 0_u32;
    let mut max_bit_depth = 0_u32;
    let mut supports_native_dsd = false;
    let mut has_balanced_output = false;

    for index in 0..device_count {
        let device = env
            .get_object_array_element(&device_array, index)
            .map_err(|error| format!("Failed to read AudioDeviceInfo[{}]: {}", index, error))?;
        let device_type = env
            .call_method(&device, "getType", "()I", &[])
            .map_err(|error| format!("AudioDeviceInfo.getType failed: {}", error))?
            .i()
            .map_err(|error| format!("AudioDeviceInfo.getType returned invalid data: {}", error))?;
        if !relevant_types
            .into_iter()
            .flatten()
            .any(|value| value == device_type)
        {
            continue;
        }

        let sample_rates = int_array_values(env, &device, "getSampleRates")?;
        let encodings = int_array_values(env, &device, "getEncodings")?;
        let product_name = audio_device_label(env, &device, "getProductName")?;
        let address = audio_device_label(env, &device, "getAddress")?;
        let label = format!("{} {}", product_name, address).to_ascii_lowercase();

        max_sample_rate = max_sample_rate.max(
            sample_rates
                .into_iter()
                .filter(|rate| *rate > 0)
                .map(|rate| rate as u32)
                .max()
                .unwrap_or_default(),
        );

        if encodings
            .iter()
            .any(|encoding| Some(*encoding) == encoding_pcm_32)
        {
            max_bit_depth = max_bit_depth.max(32);
        } else if encodings
            .iter()
            .any(|encoding| Some(*encoding) == encoding_pcm_24)
        {
            max_bit_depth = max_bit_depth.max(24);
        } else if encodings
            .iter()
            .any(|encoding| Some(*encoding) == encoding_float)
        {
            max_bit_depth = max_bit_depth.max(32);
        }

        if encodings
            .iter()
            .any(|encoding| Some(*encoding) == encoding_dsd)
        {
            supports_native_dsd = true;
        }

        if label.contains("balanced") || label.contains("4.4") || label.contains("2.5") {
            has_balanced_output = true;
        }
    }

    Ok(AudioCapabilities {
        max_sample_rate,
        max_bit_depth,
        supports_native_dsd,
        has_balanced_output,
    })
}

#[cfg(target_os = "android")]
fn get_phone_type<'local>(
    env: &mut JNIEnv<'local>,
    context: &JObject<'local>,
) -> Result<Option<i32>, String> {
    let telephony_manager = get_system_service(env, context, "TELEPHONY_SERVICE")?;
    if telephony_manager.is_null() {
        return Ok(None);
    }

    env.call_method(&telephony_manager, "getPhoneType", "()I", &[])
        .map(|value| value.i().ok())
        .map_err(|error| format!("TelephonyManager.getPhoneType failed: {}", error))
}

#[cfg(target_os = "android")]
fn detect_ibasso_mango_mode(env: &mut JNIEnv<'_>) -> bool {
    [
        "ro.ibasso.mango_mode",
        "persist.ibasso.mango_mode",
        "persist.sys.ibasso.mango_mode",
    ]
    .into_iter()
    .filter_map(|key| get_system_property(env, key))
    .any(|value| {
        let value = value.trim().to_ascii_lowercase();
        value == "1" || value == "true" || value == "on" || value == "mango"
    })
}

#[cfg(target_os = "android")]
fn get_system_property(env: &mut JNIEnv<'_>, key: &str) -> Option<String> {
    let key = match env.new_string(key) {
        Ok(key) => key,
        Err(_) => {
            clear_pending_exception(env);
            return None;
        }
    };
    let value = match env.call_static_method(
        "android/os/SystemProperties",
        "get",
        "(Ljava/lang/String;)Ljava/lang/String;",
        &[JValue::Object(&JObject::from(key))],
    ) {
        Ok(value) => value,
        Err(_) => {
            clear_pending_exception(env);
            return None;
        }
    };
    let value = match value.l() {
        Ok(value) => value,
        Err(_) => {
            clear_pending_exception(env);
            return None;
        }
    };
    match java_string(env, value) {
        Ok(value) => Some(value),
        Err(_) => {
            clear_pending_exception(env);
            None
        }
    }
}

#[cfg(target_os = "android")]
fn get_sdk_int(env: &mut JNIEnv<'_>) -> Result<i32, String> {
    let value = match env.get_static_field("android/os/Build$VERSION", "SDK_INT", "I") {
        Ok(value) => value,
        Err(error) => {
            clear_pending_exception(env);
            return Err(format!("Failed to read Build.VERSION.SDK_INT: {}", error));
        }
    };
    match value.i() {
        Ok(value) => Ok(value),
        Err(error) => {
            clear_pending_exception(env);
            Err(format!("Invalid Build.VERSION.SDK_INT: {}", error))
        }
    }
}

#[cfg(target_os = "android")]
fn get_system_service<'local>(
    env: &mut JNIEnv<'local>,
    context: &JObject<'local>,
    field_name: &str,
) -> Result<JObject<'local>, String> {
    let service_name =
        match env.get_static_field("android/content/Context", field_name, "Ljava/lang/String;") {
            Ok(value) => value,
            Err(error) => {
                clear_pending_exception(env);
                return Err(format!("Failed to read Context.{}: {}", field_name, error));
            }
        };
    let service_name = match service_name.l() {
        Ok(value) => value,
        Err(error) => {
            clear_pending_exception(env);
            return Err(format!("Invalid Context.{} value: {}", field_name, error));
        }
    };
    let service = match env.call_method(
        context,
        "getSystemService",
        "(Ljava/lang/String;)Ljava/lang/Object;",
        &[JValue::Object(&service_name)],
    ) {
        Ok(value) => value,
        Err(error) => {
            clear_pending_exception(env);
            return Err(format!(
                "Context.getSystemService({}) failed: {}",
                field_name, error
            ));
        }
    };
    match service.l() {
        Ok(value) => Ok(value),
        Err(error) => {
            clear_pending_exception(env);
            Err(format!(
                "Context.getSystemService({}) returned invalid data: {}",
                field_name, error
            ))
        }
    }
}

#[cfg(target_os = "android")]
fn audio_device_type(env: &mut JNIEnv<'_>, field: &str) -> Option<i32> {
    let value = match env.get_static_field("android/media/AudioDeviceInfo", field, "I") {
        Ok(value) => value,
        Err(_) => {
            clear_pending_exception(env);
            return None;
        }
    };
    match value.i() {
        Ok(value) => Some(value),
        Err(_) => {
            clear_pending_exception(env);
            None
        }
    }
}

#[cfg(target_os = "android")]
fn audio_format_encoding(env: &mut JNIEnv<'_>, field: &str) -> Option<i32> {
    let value = match env.get_static_field("android/media/AudioFormat", field, "I") {
        Ok(value) => value,
        Err(_) => {
            clear_pending_exception(env);
            return None;
        }
    };
    match value.i() {
        Ok(value) => Some(value),
        Err(_) => {
            clear_pending_exception(env);
            None
        }
    }
}

#[cfg(target_os = "android")]
fn int_array_values(
    env: &mut JNIEnv<'_>,
    object: &JObject<'_>,
    method: &str,
) -> Result<Vec<i32>, String> {
    let values = match env.call_method(object, method, "()[I", &[]) {
        Ok(value) => value,
        Err(_) => {
            clear_pending_exception(env);
            return Ok(Vec::new());
        }
    };
    let values = match values.l() {
        Ok(value) => value,
        Err(_) => {
            clear_pending_exception(env);
            return Ok(Vec::new());
        }
    };
    if values.is_null() {
        return Ok(Vec::new());
    }

    let values = JIntArray::from(values);
    let len = match env.get_array_length(&values) {
        Ok(len) => len,
        Err(_) => {
            clear_pending_exception(env);
            return Ok(Vec::new());
        }
    };
    let mut buffer = vec![0; len as usize];
    if env.get_int_array_region(&values, 0, &mut buffer).is_err() {
        clear_pending_exception(env);
        return Ok(Vec::new());
    }
    Ok(buffer)
}

#[cfg(target_os = "android")]
fn audio_device_label(
    env: &mut JNIEnv<'_>,
    object: &JObject<'_>,
    method: &str,
) -> Result<String, String> {
    let signature = if method == "getAddress" {
        "()Ljava/lang/String;"
    } else {
        "()Ljava/lang/CharSequence;"
    };
    let value = env
        .call_method(object, method, signature, &[])
        .map_err(|error| format!("AudioDeviceInfo.{} failed: {}", method, error));
    let Ok(value) = value else {
        clear_pending_exception(env);
        return Ok(String::new());
    };
    let value = match value.l() {
        Ok(value) => value,
        Err(_) => {
            clear_pending_exception(env);
            return Ok(String::new());
        }
    };
    if value.is_null() {
        return Ok(String::new());
    }

    if method == "getAddress" {
        return match java_string(env, value) {
            Ok(value) => Ok(value),
            Err(_) => {
                clear_pending_exception(env);
                Ok(String::new())
            }
        };
    }

    let rendered = env
        .call_method(&value, "toString", "()Ljava/lang/String;", &[])
        .map_err(|error| format!("CharSequence.toString failed: {}", error));
    let Ok(rendered) = rendered else {
        clear_pending_exception(env);
        return Ok(String::new());
    };
    let rendered = match rendered.l() {
        Ok(value) => value,
        Err(_) => {
            clear_pending_exception(env);
            return Ok(String::new());
        }
    };
    match java_string(env, rendered) {
        Ok(value) => Ok(value),
        Err(_) => {
            clear_pending_exception(env);
            Ok(String::new())
        }
    }
}

#[cfg(target_os = "android")]
fn java_string(env: &mut JNIEnv<'_>, object: JObject<'_>) -> Result<String, String> {
    if object.is_null() {
        return Ok(String::new());
    }

    match env.get_string(&JString::from(object)) {
        Ok(value) => Ok(value.to_string_lossy().into_owned()),
        Err(error) => {
            clear_pending_exception(env);
            Err(format!("Failed to read Java string: {}", error))
        }
    }
}

#[cfg(target_os = "android")]
fn clear_pending_exception(env: &mut JNIEnv<'_>) {
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
    }
}

#[cfg(test)]
mod tests {
    use super::{
        classify_device, detect_dap, is_known_dap_model, AudioCapabilities, DeviceKind,
        DeviceSignals,
    };

    #[test]
    fn detects_fiio_from_manufacturer() {
        assert_eq!(detect_dap("FiiO", "", "M23").map(|s| s.label), Some("FiiO"));
    }

    #[test]
    fn detects_ibasso_from_manufacturer() {
        assert_eq!(
            detect_dap("iBasso", "", "DX320").map(|s| s.label),
            Some("iBasso")
        );
    }

    #[test]
    fn detects_hiby_from_brand() {
        assert_eq!(detect_dap("", "HiBy", "R6").map(|s| s.label), Some("HiBy"));
    }

    #[test]
    fn detects_astellkern_from_manufacturer_iriver() {
        assert_eq!(
            detect_dap("iriver", "", "SP2000").map(|s| s.label),
            Some("Astell&Kern")
        );
    }

    #[test]
    fn detects_sony_dap_only_for_walkman_models() {
        assert_eq!(
            detect_dap("Sony", "Sony", "NW-WM1AM2").map(|s| s.label),
            Some("Sony")
        );
        assert_eq!(detect_dap("Sony", "Sony", "XQ-BC72"), None);
    }

    #[test]
    fn model_prefix_matches_known_dap_prefixes() {
        assert!(is_known_dap_model("DX320"));
        assert!(is_known_dap_model("NW-ZX707"));
        assert!(!is_known_dap_model("Pixel 8"));
    }

    #[test]
    fn manufacturer_match_is_definitive_for_known_dap_brands() {
        let profile = classify_device(DeviceSignals {
            manufacturer: "HiBy".to_string(),
            model: "R6 III".to_string(),
            brand: "HiBy".to_string(),
            manufacturer_match: Some("HiBy".to_string()),
            model_match: true,
            no_telephony: false,
            audio_caps: AudioCapabilities::default(),
            mango_mode: false,
        });

        assert_eq!(profile.kind, DeviceKind::Dap("HiBy".to_string()));
        assert!(profile.confirmed_bit_perfect);
    }

    #[test]
    fn unknown_high_res_non_phone_can_be_classified_as_other_dap() {
        let profile = classify_device(DeviceSignals {
            manufacturer: "Acme".to_string(),
            model: "DX999".to_string(),
            brand: "Acme".to_string(),
            manufacturer_match: None,
            model_match: true,
            no_telephony: true,
            audio_caps: AudioCapabilities {
                max_sample_rate: 192_000,
                ..AudioCapabilities::default()
            },
            mango_mode: false,
        });

        assert_eq!(profile.kind, DeviceKind::Dap("Other".to_string()));
        assert!(profile.confirmed_bit_perfect);
    }

    #[test]
    fn dap_without_audio_caps_native_dsd_gets_false_without_runtime_probe() {
        crate::audio::dsd_native_jni::set_dsd_encoding_available(false);
        let profile = classify_device(DeviceSignals {
            manufacturer: "HiBy".to_string(),
            model: "R6 III".to_string(),
            brand: "HiBy".to_string(),
            manufacturer_match: Some("HiBy".to_string()),
            model_match: true,
            no_telephony: false,
            audio_caps: AudioCapabilities::default(),
            mango_mode: false,
        });
        assert!(profile.is_dap());
        assert!(!profile.supports_native_dsd);
    }

    #[test]
    fn dap_with_audio_caps_native_dsd_gets_true() {
        let profile = classify_device(DeviceSignals {
            manufacturer: "HiBy".to_string(),
            model: "R6 III".to_string(),
            brand: "HiBy".to_string(),
            manufacturer_match: Some("HiBy".to_string()),
            model_match: true,
            no_telephony: false,
            audio_caps: AudioCapabilities {
                supports_native_dsd: true,
                ..AudioCapabilities::default()
            },
            mango_mode: false,
        });
        assert!(profile.is_dap());
        assert!(profile.supports_native_dsd);
    }

    #[test]
    fn dap_with_runtime_probe_cached_gets_native_dsd() {
        crate::audio::dsd_native_jni::set_dsd_encoding_available(true);
        let profile = classify_device(DeviceSignals {
            manufacturer: "HiBy".to_string(),
            model: "R6 III".to_string(),
            brand: "HiBy".to_string(),
            manufacturer_match: Some("HiBy".to_string()),
            model_match: true,
            no_telephony: false,
            audio_caps: AudioCapabilities::default(),
            mango_mode: false,
        });
        assert!(profile.is_dap());
        assert!(profile.supports_native_dsd);
        crate::audio::dsd_native_jni::set_dsd_encoding_available(false);
    }
}
