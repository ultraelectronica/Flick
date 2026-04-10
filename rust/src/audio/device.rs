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
        }
    }

    pub fn is_dap(&self) -> bool {
        matches!(self.kind, DeviceKind::Dap(_))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum DeviceKind {
    Dap(DapBrand),
    Phone,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum DapBrand {
    FiiO,
    IBasso,
    HiBy,
    Shanling,
    AstellKern,
    Cayin,
    Sony,
    Other,
}

impl DapBrand {
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::FiiO => "FiiO",
            Self::IBasso => "iBasso",
            Self::HiBy => "HiBy",
            Self::Shanling => "Shanling",
            Self::AstellKern => "Astell&Kern",
            Self::Cayin => "Cayin",
            Self::Sony => "Sony",
            Self::Other => "Other",
        }
    }
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
    pub manufacturer_match: Option<DapBrand>,
    pub model_match: bool,
    pub no_telephony: bool,
    pub audio_caps: AudioCapabilities,
    pub mango_mode: bool,
}

pub fn check_manufacturer(manufacturer: &str, brand: &str, model: &str) -> Option<DapBrand> {
    let manufacturer = manufacturer.to_ascii_lowercase();
    let brand = brand.to_ascii_lowercase();
    let model = model.trim().to_ascii_uppercase();

    if manufacturer.contains("fiio") || brand.contains("fiio") {
        return Some(DapBrand::FiiO);
    }

    if manufacturer.contains("ibasso") || brand.contains("ibasso") {
        return Some(DapBrand::IBasso);
    }

    if manufacturer.contains("hiby") || brand.contains("hiby") {
        return Some(DapBrand::HiBy);
    }

    if manufacturer.contains("shanling") || brand.contains("shanling") {
        return Some(DapBrand::Shanling);
    }

    if manufacturer.contains("astell")
        || manufacturer.contains("iriver")
        || brand.contains("astell")
        || brand.contains("iriver")
    {
        return Some(DapBrand::AstellKern);
    }

    if manufacturer.contains("cayin") || brand.contains("cayin") {
        return Some(DapBrand::Cayin);
    }

    if manufacturer == "sony" || brand == "sony" {
        return model.starts_with("NW-").then_some(DapBrand::Sony);
    }

    None
}

pub fn check_model_prefix(model: &str) -> bool {
    let model = model.trim().to_ascii_uppercase();
    let prefixes = [
        "M11", "M15", "M17", "M21", "M23", "M27", "JM21", "DX160", "DX170", "DX180", "DX220",
        "DX240", "DX260", "DX300", "DX320", "DX340", "R3", "R4", "R5", "R6", "R8", "M300", "M0",
        "M1", "M3", "M5", "M6", "M7", "M8", "SA", "SP", "SE", "A&", "N3", "N5", "N6", "N7", "NW-A",
        "NW-WM", "NW-ZX",
    ];

    prefixes.iter().any(|prefix| model.starts_with(prefix))
}

pub fn classify_device(signals: DeviceSignals) -> DeviceProfile {
    let manufacturer = signals.manufacturer.to_ascii_lowercase();
    let brand = signals.brand.to_ascii_lowercase();
    let manufacturer_match = signals.manufacturer_match.or_else(|| {
        if signals.mango_mode {
            Some(DapBrand::IBasso)
        } else {
            None
        }
    });
    let high_res_internal = signals.audio_caps.max_sample_rate >= 88_200;

    let kind = match manufacturer_match {
        Some(brand) => DeviceKind::Dap(brand),
        None if signals.no_telephony && high_res_internal && signals.model_match => {
            DeviceKind::Dap(DapBrand::Other)
        }
        None if manufacturer.contains("sony") || brand.contains("sony") => DeviceKind::Phone,
        None if !manufacturer.is_empty() || !brand.is_empty() => DeviceKind::Phone,
        None => DeviceKind::Unknown,
    };

    DeviceProfile {
        confirmed_bit_perfect: matches!(kind, DeviceKind::Dap(_)),
        kind,
        max_sample_rate: signals.audio_caps.max_sample_rate,
        has_balanced_output: signals.audio_caps.has_balanced_output,
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
    let manufacturer_match = check_manufacturer(&manufacturer, &brand, &model);
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
    let mango_mode = if matches!(manufacturer_match, Some(DapBrand::IBasso)) {
        detect_ibasso_mango_mode(env)
    } else {
        false
    };

    Ok(classify_device(DeviceSignals {
        manufacturer,
        model: model.clone(),
        brand,
        manufacturer_match,
        model_match: check_model_prefix(&model),
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
        check_manufacturer, check_model_prefix, classify_device, AudioCapabilities, DapBrand,
        DeviceKind, DeviceSignals,
    };

    #[test]
    fn detects_fiio_from_manufacturer() {
        assert_eq!(check_manufacturer("FiiO", "", "M23"), Some(DapBrand::FiiO));
    }

    #[test]
    fn detects_sony_dap_only_for_walkman_models() {
        assert_eq!(
            check_manufacturer("Sony", "Sony", "NW-WM1AM2"),
            Some(DapBrand::Sony)
        );
        assert_eq!(check_manufacturer("Sony", "Sony", "XQ-BC72"), None);
    }

    #[test]
    fn model_prefix_matches_known_dap_prefixes() {
        assert!(check_model_prefix("DX320"));
        assert!(check_model_prefix("NW-ZX707"));
        assert!(!check_model_prefix("Pixel 8"));
    }

    #[test]
    fn manufacturer_match_is_definitive_for_known_dap_brands() {
        let profile = classify_device(DeviceSignals {
            manufacturer: "HiBy".to_string(),
            model: "R6 III".to_string(),
            brand: "HiBy".to_string(),
            manufacturer_match: Some(DapBrand::HiBy),
            model_match: true,
            no_telephony: false,
            audio_caps: AudioCapabilities::default(),
            mango_mode: false,
        });

        assert_eq!(profile.kind, DeviceKind::Dap(DapBrand::HiBy));
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

        assert_eq!(profile.kind, DeviceKind::Dap(DapBrand::Other));
        assert!(profile.confirmed_bit_perfect);
    }
}
