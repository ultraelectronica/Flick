use crate::uac2::{AudioFormat, BitDepth, DeviceCapabilities, SampleRate, Uac2Error};

pub struct FormatNegotiationStrategy {
    prefer_quality: bool,
}

impl FormatNegotiationStrategy {
    pub fn new(prefer_quality: bool) -> Self {
        Self { prefer_quality }
    }

    pub fn quality_first() -> Self {
        Self {
            prefer_quality: true,
        }
    }

    pub fn compatibility_first() -> Self {
        Self {
            prefer_quality: false,
        }
    }
}

pub struct FormatNegotiationEngine {
    strategy: FormatNegotiationStrategy,
}

impl FormatNegotiationEngine {
    pub fn new(strategy: FormatNegotiationStrategy) -> Self {
        Self { strategy }
    }

    pub fn negotiate(
        &self,
        source_format: &AudioFormat,
        device_caps: &DeviceCapabilities,
    ) -> Result<AudioFormat, Uac2Error> {
        let sample_rate = self.negotiate_sample_rate(source_format, device_caps)?;
        let bit_depth = self.negotiate_bit_depth(source_format, device_caps)?;
        let channels = self.negotiate_channels(source_format, device_caps)?;

        AudioFormat::new(
            vec![sample_rate],
            bit_depth,
            channels,
            source_format.format_type,
        )
    }

    fn negotiate_sample_rate(
        &self,
        source: &AudioFormat,
        caps: &DeviceCapabilities,
    ) -> Result<SampleRate, Uac2Error> {
        let source_rate = source
            .sample_rates
            .first()
            .ok_or(Uac2Error::InvalidDescriptor(
                "No sample rates in source format".to_string(),
            ))?;

        // Check if any supported format contains the source rate
        for format in &caps.supported_formats {
            if format.sample_rates.contains(source_rate) {
                return Ok(*source_rate);
            }
        }

        // Collect all available sample rates from supported formats
        let mut available_rates: Vec<SampleRate> = caps
            .supported_formats
            .iter()
            .flat_map(|f| f.sample_rates.iter().copied())
            .collect();
        available_rates.sort();
        available_rates.dedup();

        if available_rates.is_empty() {
            return Err(Uac2Error::NoSupportedFormat);
        }

        if self.strategy.prefer_quality {
            available_rates
                .iter()
                .filter(|&&rate| rate.hz() >= source_rate.hz())
                .min_by_key(|rate| rate.hz())
                .or_else(|| available_rates.iter().max_by_key(|rate| rate.hz()))
                .copied()
                .ok_or(Uac2Error::NoSupportedFormat)
        } else {
            available_rates
                .iter()
                .min_by_key(|rate| (rate.hz() as i32 - source_rate.hz() as i32).abs())
                .copied()
                .ok_or(Uac2Error::NoSupportedFormat)
        }
    }

    fn negotiate_bit_depth(
        &self,
        source: &AudioFormat,
        caps: &DeviceCapabilities,
    ) -> Result<BitDepth, Uac2Error> {
        // Check if any supported format has the source bit depth
        for format in &caps.supported_formats {
            if format.bit_depth == source.bit_depth {
                return Ok(source.bit_depth);
            }
        }

        // Collect all available bit depths from supported formats
        let mut available_depths: Vec<BitDepth> =
            caps.supported_formats.iter().map(|f| f.bit_depth).collect();
        available_depths.sort();
        available_depths.dedup();

        if available_depths.is_empty() {
            return Err(Uac2Error::NoSupportedFormat);
        }

        if self.strategy.prefer_quality {
            available_depths
                .iter()
                .filter(|&&depth| {
                    Self::bit_depth_value(depth) >= Self::bit_depth_value(source.bit_depth)
                })
                .min_by_key(|depth| Self::bit_depth_value(**depth))
                .or_else(|| {
                    available_depths
                        .iter()
                        .max_by_key(|depth| Self::bit_depth_value(**depth))
                })
                .copied()
                .ok_or(Uac2Error::NoSupportedFormat)
        } else {
            available_depths
                .iter()
                .min_by_key(|depth| {
                    (Self::bit_depth_value(**depth) as i32
                        - Self::bit_depth_value(source.bit_depth) as i32)
                        .abs()
                })
                .copied()
                .ok_or(Uac2Error::NoSupportedFormat)
        }
    }

    fn negotiate_channels(
        &self,
        source: &AudioFormat,
        caps: &DeviceCapabilities,
    ) -> Result<crate::uac2::ChannelConfig, Uac2Error> {
        // Check if any supported format has the source channel config
        for format in &caps.supported_formats {
            if format.channels == source.channels {
                return Ok(source.channels);
            }
        }

        // Collect all available channel configs from supported formats
        let mut available_channels: Vec<crate::uac2::ChannelConfig> =
            caps.supported_formats.iter().map(|f| f.channels).collect();
        available_channels.sort_by_key(|ch| ch.count());
        available_channels.dedup();

        if available_channels.is_empty() {
            return Err(Uac2Error::NoSupportedFormat);
        }

        let source_count = source.channels.count();

        if self.strategy.prefer_quality {
            available_channels
                .iter()
                .filter(|ch| ch.count() >= source_count)
                .min_by_key(|ch| ch.count())
                .or_else(|| available_channels.iter().max_by_key(|ch| ch.count()))
                .copied()
                .ok_or(Uac2Error::NoSupportedFormat)
        } else {
            available_channels
                .iter()
                .min_by_key(|ch| (ch.count() as i32 - source_count as i32).abs())
                .copied()
                .ok_or(Uac2Error::NoSupportedFormat)
        }
    }

    fn bit_depth_value(depth: BitDepth) -> u8 {
        depth.bits()
    }
}

pub struct FormatMismatchHandler;

impl FormatMismatchHandler {
    pub fn can_handle(source: &AudioFormat, target: &AudioFormat) -> bool {
        Self::can_convert_sample_rate(source, target)
            && Self::can_convert_bit_depth(source, target)
            && Self::can_convert_channels(source, target)
    }

    pub fn requires_conversion(source: &AudioFormat, target: &AudioFormat) -> bool {
        let source_rate = source.sample_rates.first();
        let target_rate = target.sample_rates.first();

        source_rate != target_rate
            || source.bit_depth != target.bit_depth
            || source.channels != target.channels
    }

    fn can_convert_sample_rate(source: &AudioFormat, target: &AudioFormat) -> bool {
        let source_rate = source.sample_rates.first();
        let target_rate = target.sample_rates.first();

        match (source_rate, target_rate) {
            (Some(src), Some(tgt)) => {
                let ratio = src.hz() as f64 / tgt.hz() as f64;
                ratio >= 0.25 && ratio <= 4.0
            }
            _ => false,
        }
    }

    fn can_convert_bit_depth(_source: &AudioFormat, _target: &AudioFormat) -> bool {
        true
    }

    fn can_convert_channels(source: &AudioFormat, target: &AudioFormat) -> bool {
        use crate::uac2::ChannelConfig;

        matches!(
            (source.channels, target.channels),
            (ChannelConfig::Mono, ChannelConfig::Stereo)
                | (ChannelConfig::Stereo, ChannelConfig::Mono)
        ) || source.channels == target.channels
    }
}
