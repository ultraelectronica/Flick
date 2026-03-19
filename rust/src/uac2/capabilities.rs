use crate::uac2::audio_format::{AudioFormat, BitDepth, ChannelConfig, FormatType, SampleRate};
use crate::uac2::descriptors::{
    AudioControlDescriptor, AudioStreamingDescriptor, DescriptorKind, FeatureUnit, InputTerminal,
    OutputTerminal,
};
use crate::uac2::device_classifier::DeviceClassifier;
use crate::uac2::device_info_extractor::DeviceInfoExtractor;
use crate::uac2::error::Uac2Error;
use rusb::{Device, DeviceHandle, UsbContext};
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceType {
    DacOnly,
    AmpOnly,
    DacAmpCombo,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct PowerCapabilities {
    pub max_power_ma: u16,
    pub self_powered: bool,
}

#[derive(Debug, Clone)]
pub struct ControlCapabilities {
    pub has_volume: bool,
    pub has_mute: bool,
    pub has_bass: bool,
    pub has_treble: bool,
    pub has_eq: bool,
}

#[derive(Debug, Clone)]
pub struct DeviceCapabilities {
    pub device_type: DeviceType,
    pub supported_formats: Vec<AudioFormat>,
    pub max_sample_rate: Option<SampleRate>,
    pub max_bit_depth: Option<BitDepth>,
    pub max_channels: Option<ChannelConfig>,
    pub power: PowerCapabilities,
    pub controls: ControlCapabilities,
    pub feature_units: Vec<FeatureUnit>,
    pub input_terminals: Vec<InputTerminal>,
    pub output_terminals: Vec<OutputTerminal>,
}

impl Default for DeviceCapabilities {
    fn default() -> Self {
        Self {
            device_type: DeviceType::Unknown,
            supported_formats: Vec::new(),
            max_sample_rate: None,
            max_bit_depth: None,
            max_channels: None,
            power: PowerCapabilities {
                max_power_ma: 0,
                self_powered: false,
            },
            controls: ControlCapabilities {
                has_volume: false,
                has_mute: false,
                has_bass: false,
                has_treble: false,
                has_eq: false,
            },
            feature_units: Vec::new(),
            input_terminals: Vec::new(),
            output_terminals: Vec::new(),
        }
    }
}

pub struct CapabilityDetector;

impl CapabilityDetector {
    pub fn detect<T: UsbContext>(
        device: &Device<T>,
        handle: &DeviceHandle<T>,
    ) -> Result<DeviceCapabilities, Uac2Error> {
        let mut capabilities = DeviceCapabilities::default();

        let device_desc = device.device_descriptor()?;
        capabilities.power = DeviceInfoExtractor::extract_power_info(&device_desc);

        let config_desc = device.active_config_descriptor()?;
        let descriptors = Self::parse_all_descriptors(device, handle, &config_desc)?;

        Self::extract_terminals(&descriptors, &mut capabilities);
        Self::extract_feature_units(&descriptors, &mut capabilities);
        Self::extract_formats(&descriptors, &mut capabilities)?;
        
        capabilities.device_type = DeviceClassifier::classify(&capabilities);

        Ok(capabilities)
    }



    fn parse_all_descriptors<T: UsbContext>(
        _device: &Device<T>,
        _handle: &DeviceHandle<T>,
        _config_desc: &rusb::ConfigDescriptor,
    ) -> Result<Vec<DescriptorKind>, Uac2Error> {
        Ok(Vec::new())
    }

    fn extract_terminals(descriptors: &[DescriptorKind], capabilities: &mut DeviceCapabilities) {
        for desc in descriptors {
            match desc {
                DescriptorKind::AudioControl(AudioControlDescriptor::InputTerminal(it)) => {
                    capabilities.input_terminals.push(it.clone());
                }
                DescriptorKind::AudioControl(AudioControlDescriptor::OutputTerminal(ot)) => {
                    capabilities.output_terminals.push(ot.clone());
                }
                _ => {}
            }
        }
    }

    fn extract_feature_units(descriptors: &[DescriptorKind], capabilities: &mut DeviceCapabilities) {
        for desc in descriptors {
            if let DescriptorKind::AudioControl(AudioControlDescriptor::FeatureUnit(fu)) = desc {
                capabilities.feature_units.push(fu.clone());
            }
        }
        
        capabilities.controls = DeviceInfoExtractor::extract_control_capabilities(&capabilities.feature_units);
    }

    fn extract_formats(
        descriptors: &[DescriptorKind],
        capabilities: &mut DeviceCapabilities,
    ) -> Result<(), Uac2Error> {
        let mut formats = Vec::new();
        let mut current_format_tag: Option<u16> = None;

        for desc in descriptors {
            match desc {
                DescriptorKind::AudioStreaming(AudioStreamingDescriptor::General(gen)) => {
                    current_format_tag = Some(gen.w_format_tag);
                }
                DescriptorKind::AudioStreaming(AudioStreamingDescriptor::FormatTypeI(fmt)) => {
                    if let Some(tag) = current_format_tag {
                        if let Ok(audio_fmt) = AudioFormat::try_from((fmt, tag)) {
                            formats.push(audio_fmt);
                        }
                    }
                }
                DescriptorKind::AudioStreaming(AudioStreamingDescriptor::FormatTypeII(fmt)) => {
                    if let Some(tag) = current_format_tag {
                        if let Ok(audio_fmt) = AudioFormat::try_from((fmt, tag)) {
                            formats.push(audio_fmt);
                        }
                    }
                }
                DescriptorKind::AudioStreaming(AudioStreamingDescriptor::FormatTypeIII(fmt)) => {
                    if let Ok(audio_fmt) = AudioFormat::try_from(fmt) {
                        formats.push(audio_fmt);
                    }
                }
                _ => {}
            }
        }

        capabilities.supported_formats = formats;
        Self::compute_max_capabilities(capabilities);
        Ok(())
    }

    fn compute_max_capabilities(capabilities: &mut DeviceCapabilities) {
        if capabilities.supported_formats.is_empty() {
            return;
        }

        let mut max_rate = 0u32;
        let mut max_depth = 0u8;
        let mut max_channels = 0u16;

        for format in &capabilities.supported_formats {
            if let Some(rate) = format.sample_rates.iter().map(|r| r.hz()).max() {
                max_rate = max_rate.max(rate);
            }
            max_depth = max_depth.max(format.bit_depth.bits());
            max_channels = max_channels.max(format.channels.count());
        }

        capabilities.max_sample_rate = SampleRate::new(max_rate).ok();
        capabilities.max_bit_depth = BitDepth::from_bits(max_depth).ok();
        capabilities.max_channels = ChannelConfig::from_count(max_channels).ok();
    }


}

pub struct FormatMatcher;

impl FormatMatcher {
    pub fn find_optimal_format<'a>(
        formats: &'a [AudioFormat],
        preferred_rate: Option<SampleRate>,
        preferred_depth: Option<BitDepth>,
    ) -> Option<&'a AudioFormat> {
        if formats.is_empty() {
            return None;
        }

        let mut candidates: Vec<&AudioFormat> = formats.iter().collect();

        if let Some(rate) = preferred_rate {
            let with_rate: Vec<&AudioFormat> = candidates
                .iter()
                .filter(|f| f.supports_sample_rate(rate))
                .copied()
                .collect();
            if !with_rate.is_empty() {
                candidates = with_rate;
            }
        }

        if let Some(depth) = preferred_depth {
            let with_depth: Vec<&AudioFormat> = candidates
                .iter()
                .filter(|f| f.bit_depth == depth)
                .copied()
                .collect();
            if !with_depth.is_empty() {
                candidates = with_depth;
            }
        }

        candidates
            .into_iter()
            .max_by_key(|f| Self::rank_format(f))
    }

    fn rank_format(format: &AudioFormat) -> u64 {
        let depth_score = format.bit_depth.bits() as u64;
        let rate_score = format
            .sample_rates
            .iter()
            .map(|r| r.hz())
            .max()
            .unwrap_or(0) as u64;
        let channel_score = format.channels.count() as u64;
        let format_score = match format.format_type {
            FormatType::Pcm => 100,
            FormatType::IeeFloat => 90,
            FormatType::Dsd => 80,
            _ => 50,
        };

        (depth_score << 48) | (rate_score << 16) | (channel_score << 8) | format_score
    }

    pub fn find_compatible_formats<'a>(
        formats: &'a [AudioFormat],
        source_format: &AudioFormat,
    ) -> Vec<&'a AudioFormat> {
        let source_rates: HashSet<u32> = source_format.sample_rates.iter().map(|r| r.hz()).collect();

        formats
            .iter()
            .filter(|f| {
                f.bit_depth >= source_format.bit_depth
                    && f.channels.count() >= source_format.channels.count()
                    && f.sample_rates.iter().any(|r| source_rates.contains(&r.hz()))
            })
            .collect()
    }
}
