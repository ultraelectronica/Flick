use crate::uac2::audio_format::{AudioFormat, BitDepth, FormatType, SampleRate};
use crate::uac2::capabilities::{DeviceCapabilities, DeviceType};
use crate::uac2::constants::*;
use crate::uac2::descriptors::{InputTerminal, OutputTerminal};

pub struct DeviceClassifier;

impl DeviceClassifier {
    pub fn classify(capabilities: &DeviceCapabilities) -> DeviceType {
        let has_dac = Self::has_dac_capability(&capabilities.input_terminals);
        let has_amp = Self::has_amp_capability(&capabilities.output_terminals);

        match (has_dac, has_amp) {
            (true, true) => DeviceType::DacAmpCombo,
            (true, false) => DeviceType::DacOnly,
            (false, true) => DeviceType::AmpOnly,
            (false, false) => DeviceType::Unknown,
        }
    }

    fn has_dac_capability(input_terminals: &[InputTerminal]) -> bool {
        input_terminals
            .iter()
            .any(|it| it.w_terminal_type == TERMINAL_TYPE_USB_STREAMING)
    }

    fn has_amp_capability(output_terminals: &[OutputTerminal]) -> bool {
        output_terminals.iter().any(|ot| {
            ot.w_terminal_type == TERMINAL_TYPE_OUTPUT_SPEAKER
                || ot.w_terminal_type == TERMINAL_TYPE_OUTPUT_HEADPHONES
        })
    }

    pub fn classify_by_format(formats: &[AudioFormat]) -> FormatClass {
        if formats.is_empty() {
            return FormatClass::Unknown;
        }

        let has_hi_res = formats.iter().any(|f| {
            f.sample_rates.iter().any(|r| r.hz() >= 96_000) && f.bit_depth.bits() >= 24
        });

        let has_dsd = formats
            .iter()
            .any(|f| f.format_type == FormatType::Dsd);

        if has_dsd {
            FormatClass::Dsd
        } else if has_hi_res {
            FormatClass::HiRes
        } else {
            FormatClass::Standard
        }
    }

    pub fn classify_by_power(max_power_ma: u16) -> PowerClass {
        match max_power_ma {
            0..=100 => PowerClass::Low,
            101..=500 => PowerClass::Medium,
            _ => PowerClass::High,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatClass {
    Standard,
    HiRes,
    Dsd,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PowerClass {
    Low,
    Medium,
    High,
}

pub struct DeviceMatchingLogic;

impl DeviceMatchingLogic {
    pub fn find_best_match<'a>(
        devices: &'a [DeviceCapabilities],
        requirements: &AudioRequirements,
    ) -> Option<&'a DeviceCapabilities> {
        let mut candidates: Vec<&DeviceCapabilities> = devices
            .iter()
            .filter(|d| Self::meets_requirements(d, requirements))
            .collect();

        if candidates.is_empty() {
            return None;
        }

        candidates.sort_by(|a, b| Self::rank_device(b, requirements).cmp(&Self::rank_device(a, requirements)));
        candidates.first().copied()
    }

    fn meets_requirements(device: &DeviceCapabilities, requirements: &AudioRequirements) -> bool {
        if let Some(min_rate) = requirements.min_sample_rate {
            if let Some(max_rate) = device.max_sample_rate {
                if max_rate.hz() < min_rate.hz() {
                    return false;
                }
            } else {
                return false;
            }
        }

        if let Some(min_depth) = requirements.min_bit_depth {
            if let Some(max_depth) = device.max_bit_depth {
                if max_depth.bits() < min_depth.bits() {
                    return false;
                }
            } else {
                return false;
            }
        }

        if let Some(required_type) = requirements.device_type {
            if device.device_type != required_type {
                return false;
            }
        }

        true
    }

    fn rank_device(device: &DeviceCapabilities, requirements: &AudioRequirements) -> u64 {
        let mut score = 0u64;

        if let Some(max_rate) = device.max_sample_rate {
            score += max_rate.hz() as u64;
        }

        if let Some(max_depth) = device.max_bit_depth {
            score += (max_depth.bits() as u64) << 32;
        }

        if let Some(max_channels) = device.max_channels {
            score += (max_channels.count() as u64) << 16;
        }

        if device.controls.has_volume {
            score += 1000;
        }

        if let Some(preferred_type) = requirements.device_type {
            if device.device_type == preferred_type {
                score += 10000;
            }
        }

        score
    }
}

#[derive(Debug, Clone)]
pub struct AudioRequirements {
    pub min_sample_rate: Option<SampleRate>,
    pub min_bit_depth: Option<BitDepth>,
    pub device_type: Option<DeviceType>,
}

impl AudioRequirements {
    pub fn new() -> Self {
        Self {
            min_sample_rate: None,
            min_bit_depth: None,
            device_type: None,
        }
    }

    pub fn with_sample_rate(mut self, rate: SampleRate) -> Self {
        self.min_sample_rate = Some(rate);
        self
    }

    pub fn with_bit_depth(mut self, depth: BitDepth) -> Self {
        self.min_bit_depth = Some(depth);
        self
    }

    pub fn with_device_type(mut self, device_type: DeviceType) -> Self {
        self.device_type = Some(device_type);
        self
    }
}

impl Default for AudioRequirements {
    fn default() -> Self {
        Self::new()
    }
}
