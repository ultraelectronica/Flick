use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum OutputStrategy {
    DapNative,
    MixerBitPerfect,
    MixerMatched,
    UsbDirect,
    ResampledFallback,
}

impl OutputStrategy {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::DapNative => "dap_native",
            Self::MixerBitPerfect => "mixer_bit_perfect",
            Self::MixerMatched => "mixer_matched",
            Self::UsbDirect => "usb_direct",
            Self::ResampledFallback => "resampled_fallback",
        }
    }

    pub fn requests_passthrough(self) -> bool {
        matches!(
            self,
            Self::DapNative | Self::MixerBitPerfect | Self::UsbDirect
        )
    }
}

#[derive(Debug, Clone, Copy)]
pub struct TrackInfo {
    pub sample_rate: u32,
    pub channels: usize,
}

#[derive(Debug, Clone)]
pub struct DeviceCaps {
    pub api_level: Option<u32>,
    pub confirmed_dap_native: bool,
    pub supports_mixer_bit_perfect: bool,
    pub supports_requested_rate: bool,
    pub direct_usb_available: bool,
    pub direct_usb_verified: bool,
}

pub fn select_strategy(track: TrackInfo, device: &DeviceCaps) -> OutputStrategy {
    if device.confirmed_dap_native && track.sample_rate > 0 && track.channels > 0 {
        return OutputStrategy::DapNative;
    }

    if device.api_level.unwrap_or_default() >= 34 && device.supports_mixer_bit_perfect {
        return OutputStrategy::MixerBitPerfect;
    }

    if device.supports_requested_rate && track.sample_rate > 0 && track.channels > 0 {
        return OutputStrategy::MixerMatched;
    }

    if device.direct_usb_available && device.direct_usb_verified {
        return OutputStrategy::UsbDirect;
    }

    OutputStrategy::ResampledFallback
}

#[cfg(test)]
mod tests {
    use super::{select_strategy, DeviceCaps, OutputStrategy, TrackInfo};

    #[test]
    fn picks_mixer_bit_perfect_when_platform_supports_it() {
        let strategy = select_strategy(
            TrackInfo {
                sample_rate: 44_100,
                channels: 2,
            },
            &DeviceCaps {
                api_level: Some(34),
                confirmed_dap_native: false,
                supports_mixer_bit_perfect: true,
                supports_requested_rate: true,
                direct_usb_available: true,
                direct_usb_verified: true,
            },
        );

        assert_eq!(strategy, OutputStrategy::MixerBitPerfect);
    }

    #[test]
    fn picks_usb_direct_when_direct_path_is_only_verified_option() {
        let strategy = select_strategy(
            TrackInfo {
                sample_rate: 192_000,
                channels: 2,
            },
            &DeviceCaps {
                api_level: Some(33),
                confirmed_dap_native: false,
                supports_mixer_bit_perfect: false,
                supports_requested_rate: false,
                direct_usb_available: true,
                direct_usb_verified: true,
            },
        );

        assert_eq!(strategy, OutputStrategy::UsbDirect);
    }

    #[test]
    fn falls_back_to_resampler_when_no_exact_path_exists() {
        let strategy = select_strategy(
            TrackInfo {
                sample_rate: 44_100,
                channels: 2,
            },
            &DeviceCaps {
                api_level: Some(33),
                confirmed_dap_native: false,
                supports_mixer_bit_perfect: false,
                supports_requested_rate: false,
                direct_usb_available: false,
                direct_usb_verified: false,
            },
        );

        assert_eq!(strategy, OutputStrategy::ResampledFallback);
    }

    #[test]
    fn picks_dap_native_for_confirmed_dap_routes() {
        let strategy = select_strategy(
            TrackInfo {
                sample_rate: 192_000,
                channels: 2,
            },
            &DeviceCaps {
                api_level: Some(31),
                confirmed_dap_native: true,
                supports_mixer_bit_perfect: false,
                supports_requested_rate: false,
                direct_usb_available: false,
                direct_usb_verified: false,
            },
        );

        assert_eq!(strategy, OutputStrategy::DapNative);
    }
}
