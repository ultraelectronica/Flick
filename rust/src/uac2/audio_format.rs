use crate::uac2::descriptors::{FormatTypeI, FormatTypeII, FormatTypeIII};
use crate::uac2::error::Uac2Error;

const MIN_SAMPLE_RATE: u32 = 8_000;
const MAX_SAMPLE_RATE: u32 = 768_000;

const BIT_DEPTH_16: u8 = 16;
const BIT_DEPTH_24: u8 = 24;
const BIT_DEPTH_32: u8 = 32;

const CHANNEL_MONO: u16 = 1;
const CHANNEL_STEREO: u16 = 2;

const FORMAT_TAG_PCM: u16 = 0x0001;
const FORMAT_TAG_PCM8: u16 = 0x0002;
const FORMAT_TAG_IEEE_FLOAT: u16 = 0x0003;
const FORMAT_TAG_DSD: u16 = 0x0008;
const FORMAT_TAG_MPEG: u16 = 0x0050;
const FORMAT_TAG_AC3: u16 = 0x0092;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct SampleRate(pub u32);

impl SampleRate {
    pub fn new(hz: u32) -> Result<Self, Uac2Error> {
        if hz < MIN_SAMPLE_RATE || hz > MAX_SAMPLE_RATE {
            return Err(Uac2Error::InvalidDescriptor(format!(
                "sample rate {} Hz out of range [{}, {}]",
                hz, MIN_SAMPLE_RATE, MAX_SAMPLE_RATE
            )));
        }
        Ok(Self(hz))
    }

    pub fn hz(self) -> u32 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum BitDepth {
    Bits16 = 16,
    Bits24 = 24,
    Bits32 = 32,
}

impl BitDepth {
    pub fn from_bits(bits: u8) -> Result<Self, Uac2Error> {
        match bits {
            BIT_DEPTH_16 => Ok(Self::Bits16),
            BIT_DEPTH_24 => Ok(Self::Bits24),
            BIT_DEPTH_32 => Ok(Self::Bits32),
            other => Err(Uac2Error::InvalidDescriptor(format!(
                "unsupported bit depth: {}",
                other
            ))),
        }
    }

    pub fn bits(self) -> u8 {
        self as u8
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelConfig {
    Mono,
    Stereo,
    MultiChannel(u16),
}

impl ChannelConfig {
    pub fn from_count(count: u16) -> Result<Self, Uac2Error> {
        match count {
            0 => Err(Uac2Error::InvalidDescriptor(
                "channel count must be >= 1".to_string(),
            )),
            CHANNEL_MONO => Ok(Self::Mono),
            CHANNEL_STEREO => Ok(Self::Stereo),
            n => Ok(Self::MultiChannel(n)),
        }
    }

    pub fn count(self) -> u16 {
        match self {
            Self::Mono => CHANNEL_MONO,
            Self::Stereo => CHANNEL_STEREO,
            Self::MultiChannel(n) => n,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatType {
    Pcm,
    Pcm8,
    IeeFloat,
    Dsd,
    Mpeg,
    Ac3,
    Other(u16),
}

impl FormatType {
    pub fn from_tag(tag: u16) -> Self {
        match tag {
            FORMAT_TAG_PCM => Self::Pcm,
            FORMAT_TAG_PCM8 => Self::Pcm8,
            FORMAT_TAG_IEEE_FLOAT => Self::IeeFloat,
            FORMAT_TAG_DSD => Self::Dsd,
            FORMAT_TAG_MPEG => Self::Mpeg,
            FORMAT_TAG_AC3 => Self::Ac3,
            other => Self::Other(other),
        }
    }

    pub fn tag(self) -> u16 {
        match self {
            Self::Pcm => FORMAT_TAG_PCM,
            Self::Pcm8 => FORMAT_TAG_PCM8,
            Self::IeeFloat => FORMAT_TAG_IEEE_FLOAT,
            Self::Dsd => FORMAT_TAG_DSD,
            Self::Mpeg => FORMAT_TAG_MPEG,
            Self::Ac3 => FORMAT_TAG_AC3,
            Self::Other(t) => t,
        }
    }
}

#[derive(Debug, Clone)]
pub struct AudioFormat {
    pub sample_rates: Vec<SampleRate>,
    pub bit_depth: BitDepth,
    pub channels: ChannelConfig,
    pub format_type: FormatType,
}

impl AudioFormat {
    pub fn new(
        sample_rates: Vec<SampleRate>,
        bit_depth: BitDepth,
        channels: ChannelConfig,
        format_type: FormatType,
    ) -> Result<Self, Uac2Error> {
        if sample_rates.is_empty() {
            return Err(Uac2Error::InvalidDescriptor(
                "AudioFormat must have at least one sample rate".to_string(),
            ));
        }
        Ok(Self {
            sample_rates,
            bit_depth,
            channels,
            format_type,
        })
    }

    pub fn supports_sample_rate(&self, rate: SampleRate) -> bool {
        self.sample_rates.contains(&rate)
    }
}

fn parse_sample_rates(raw: &[u32]) -> Result<Vec<SampleRate>, Uac2Error> {
    raw.iter().map(|&hz| SampleRate::new(hz)).collect()
}

impl TryFrom<(&FormatTypeI, u16)> for AudioFormat {
    type Error = Uac2Error;

    fn try_from((f, format_tag): (&FormatTypeI, u16)) -> Result<Self, Uac2Error> {
        let sample_rates = parse_sample_rates(&f.sample_rates)?;
        let bit_depth = BitDepth::from_bits(f.b_bit_resolution)?;
        let channels = ChannelConfig::from_count(f.b_subslot_size as u16)?;
        AudioFormat::new(
            sample_rates,
            bit_depth,
            channels,
            FormatType::from_tag(format_tag),
        )
    }
}

impl TryFrom<(&FormatTypeII, u16)> for AudioFormat {
    type Error = Uac2Error;

    fn try_from((f, format_tag): (&FormatTypeII, u16)) -> Result<Self, Uac2Error> {
        let sample_rates = parse_sample_rates(&f.sample_rates)?;
        let bit_depth = BitDepth::Bits16;
        let channels = ChannelConfig::from_count(f.w_samples_per_frame)?;
        AudioFormat::new(
            sample_rates,
            bit_depth,
            channels,
            FormatType::from_tag(format_tag),
        )
    }
}

impl TryFrom<&FormatTypeIII> for AudioFormat {
    type Error = Uac2Error;

    fn try_from(f: &FormatTypeIII) -> Result<Self, Uac2Error> {
        let bit_depth = BitDepth::from_bits(f.b_bit_resolution)?;
        let channels = ChannelConfig::from_count(f.b_subslot_size as u16)?;
        let rate = SampleRate::new(48_000)?;
        AudioFormat::new(vec![rate], bit_depth, channels, FormatType::Ac3)
    }
}

pub struct FormatNegotiator;

impl FormatNegotiator {
    pub fn negotiate_best<'a>(&self, formats: &'a [AudioFormat]) -> Option<&'a AudioFormat> {
        formats
            .iter()
            .max_by(|a, b| self.rank(a).cmp(&self.rank(b)))
    }

    pub fn negotiate_for_rate<'a>(
        &self,
        formats: &'a [AudioFormat],
        preferred_rate: SampleRate,
    ) -> Option<&'a AudioFormat> {
        let with_rate: Vec<&AudioFormat> = formats
            .iter()
            .filter(|f| f.supports_sample_rate(preferred_rate))
            .collect();
        if with_rate.is_empty() {
            return self.negotiate_best(formats);
        }
        with_rate
            .into_iter()
            .max_by(|a, b| self.rank(a).cmp(&self.rank(b)))
    }

    fn rank(&self, fmt: &AudioFormat) -> u64 {
        let depth = fmt.bit_depth.bits() as u64;
        let rate = fmt.sample_rates.iter().map(|r| r.hz()).max().unwrap_or(0) as u64;
        let channels = fmt.channels.count() as u64;
        (depth << 48) | (rate << 8) | channels
    }
}
