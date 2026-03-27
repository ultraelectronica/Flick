use crate::uac2::audio_format::{AudioFormat, BitDepth, ChannelConfig, SampleRate};
use crate::uac2::capabilities::DeviceCapabilities;
use crate::uac2::error::Uac2Error;

#[derive(Debug, Clone)]
pub struct StreamConfig {
    pub sample_rate: SampleRate,
    pub bit_depth: BitDepth,
    pub channels: ChannelConfig,
    pub endpoint_address: u8,
    pub packet_size: usize,
    pub interval: u8,
}

impl StreamConfig {
    pub fn new(
        sample_rate: SampleRate,
        bit_depth: BitDepth,
        channels: ChannelConfig,
        endpoint_address: u8,
    ) -> Result<Self, Uac2Error> {
        let packet_size = Self::calculate_packet_size(sample_rate, bit_depth, channels)?;
        let interval = Self::calculate_interval(sample_rate);

        Ok(Self {
            sample_rate,
            bit_depth,
            channels,
            endpoint_address,
            packet_size,
            interval,
        })
    }

    fn calculate_packet_size(
        sample_rate: SampleRate,
        bit_depth: BitDepth,
        channels: ChannelConfig,
    ) -> Result<usize, Uac2Error> {
        let bytes_per_sample = (bit_depth.bits() / 8) as usize;
        let channel_count = channels.count() as usize;
        let samples_per_ms = sample_rate.hz() as usize / 1000;

        let packet_size = samples_per_ms * bytes_per_sample * channel_count;

        if packet_size == 0 || packet_size > 1024 * 1024 {
            return Err(Uac2Error::InvalidConfiguration(format!(
                "invalid packet size: {}",
                packet_size
            )));
        }

        Ok(packet_size)
    }

    fn calculate_interval(sample_rate: SampleRate) -> u8 {
        match sample_rate.hz() {
            0..=48_000 => 1,
            48_001..=96_000 => 2,
            96_001..=192_000 => 4,
            _ => 8,
        }
    }

    pub fn bytes_per_frame(&self) -> usize {
        let bytes_per_sample = (self.bit_depth.bits() / 8) as usize;
        bytes_per_sample * self.channels.count() as usize
    }
}

pub struct StreamConfigBuilder {
    sample_rate: Option<SampleRate>,
    bit_depth: Option<BitDepth>,
    channels: Option<ChannelConfig>,
    endpoint_address: Option<u8>,
}

impl StreamConfigBuilder {
    pub fn new() -> Self {
        Self {
            sample_rate: None,
            bit_depth: None,
            channels: None,
            endpoint_address: None,
        }
    }

    pub fn sample_rate(mut self, rate: SampleRate) -> Self {
        self.sample_rate = Some(rate);
        self
    }

    pub fn bit_depth(mut self, depth: BitDepth) -> Self {
        self.bit_depth = Some(depth);
        self
    }

    pub fn channels(mut self, channels: ChannelConfig) -> Self {
        self.channels = Some(channels);
        self
    }

    pub fn endpoint_address(mut self, address: u8) -> Self {
        self.endpoint_address = Some(address);
        self
    }

    pub fn build(self) -> Result<StreamConfig, Uac2Error> {
        let sample_rate = self
            .sample_rate
            .ok_or_else(|| Uac2Error::InvalidConfiguration("sample rate not set".to_string()))?;
        let bit_depth = self
            .bit_depth
            .ok_or_else(|| Uac2Error::InvalidConfiguration("bit depth not set".to_string()))?;
        let channels = self
            .channels
            .ok_or_else(|| Uac2Error::InvalidConfiguration("channels not set".to_string()))?;
        let endpoint_address = self.endpoint_address.ok_or_else(|| {
            Uac2Error::InvalidConfiguration("endpoint address not set".to_string())
        })?;

        StreamConfig::new(sample_rate, bit_depth, channels, endpoint_address)
    }
}

impl Default for StreamConfigBuilder {
    fn default() -> Self {
        Self::new()
    }
}

pub struct FormatSelector;

impl FormatSelector {
    pub fn select_optimal(
        capabilities: &DeviceCapabilities,
        source_format: Option<&AudioFormat>,
    ) -> Result<AudioFormat, Uac2Error> {
        if capabilities.supported_formats.is_empty() {
            return Err(Uac2Error::NoSupportedFormats);
        }

        if let Some(source) = source_format {
            if let Some(matching) = Self::find_exact_match(&capabilities.supported_formats, source)
            {
                return Ok(matching.clone());
            }

            if let Some(compatible) = Self::find_compatible(&capabilities.supported_formats, source)
            {
                return Ok(compatible.clone());
            }
        }

        Self::select_highest_quality(&capabilities.supported_formats)
    }

    fn find_exact_match<'a>(
        formats: &'a [AudioFormat],
        source: &AudioFormat,
    ) -> Option<&'a AudioFormat> {
        formats.iter().find(|f| {
            f.bit_depth == source.bit_depth
                && f.channels.count() == source.channels.count()
                && f.sample_rates
                    .iter()
                    .any(|r| source.sample_rates.contains(r))
        })
    }

    fn find_compatible<'a>(
        formats: &'a [AudioFormat],
        source: &AudioFormat,
    ) -> Option<&'a AudioFormat> {
        formats
            .iter()
            .filter(|f| {
                f.bit_depth >= source.bit_depth && f.channels.count() >= source.channels.count()
            })
            .min_by_key(|f| {
                let depth_diff = f.bit_depth.bits() as i32 - source.bit_depth.bits() as i32;
                let channel_diff = f.channels.count() as i32 - source.channels.count() as i32;
                depth_diff.abs() + channel_diff.abs()
            })
    }

    fn select_highest_quality(formats: &[AudioFormat]) -> Result<AudioFormat, Uac2Error> {
        formats
            .iter()
            .max_by_key(|f| Self::quality_score(f))
            .cloned()
            .ok_or(Uac2Error::NoSupportedFormats)
    }

    fn quality_score(format: &AudioFormat) -> u64 {
        let depth_score = format.bit_depth.bits() as u64;
        let rate_score = format
            .sample_rates
            .iter()
            .map(|r| r.hz())
            .max()
            .unwrap_or(0) as u64;
        let channel_score = format.channels.count() as u64;

        (depth_score << 48) | (rate_score << 16) | channel_score
    }
}
