use crate::uac2::audio_format::{AudioFormat, BitDepth, ChannelConfig, SampleRate};
use crate::uac2::error::Uac2Error;
use crate::uac2::ring_buffer::{AudioBuffer, RingBuffer};
use std::sync::{Arc, Mutex};
use tracing::{debug, info, warn};

pub trait FormatConverter: Send + Sync {
    fn convert(&self, input: &[u8], output: &mut [u8]) -> Result<usize, Uac2Error>;
    fn output_size(&self, input_size: usize) -> usize;
}

pub struct PassthroughConverter;

impl FormatConverter for PassthroughConverter {
    fn convert(&self, input: &[u8], output: &mut [u8]) -> Result<usize, Uac2Error> {
        let len = input.len().min(output.len());
        output[..len].copy_from_slice(&input[..len]);
        Ok(len)
    }

    fn output_size(&self, input_size: usize) -> usize {
        input_size
    }
}

pub struct BitDepthConverter {
    source_depth: BitDepth,
    target_depth: BitDepth,
}

impl BitDepthConverter {
    pub fn new(source_depth: BitDepth, target_depth: BitDepth) -> Self {
        Self {
            source_depth,
            target_depth,
        }
    }

    fn convert_sample(&self, sample: i32) -> i32 {
        let source_bits = self.source_depth.bits();
        let target_bits = self.target_depth.bits();

        if source_bits == target_bits {
            return sample;
        }

        if source_bits < target_bits {
            sample << (target_bits - source_bits)
        } else {
            sample >> (source_bits - target_bits)
        }
    }
}

impl FormatConverter for BitDepthConverter {
    fn convert(&self, input: &[u8], output: &mut [u8]) -> Result<usize, Uac2Error> {
        let source_bytes = (self.source_depth.bits() / 8) as usize;
        let target_bytes = (self.target_depth.bits() / 8) as usize;

        let sample_count = input.len() / source_bytes;
        let output_len = sample_count * target_bytes;

        if output.len() < output_len {
            return Err(Uac2Error::BufferOverflow);
        }

        for i in 0..sample_count {
            let sample = self.read_sample(&input[i * source_bytes..(i + 1) * source_bytes]);
            let converted = self.convert_sample(sample);
            self.write_sample(
                converted,
                &mut output[i * target_bytes..(i + 1) * target_bytes],
            );
        }

        Ok(output_len)
    }

    fn output_size(&self, input_size: usize) -> usize {
        let source_bytes = (self.source_depth.bits() / 8) as usize;
        let target_bytes = (self.target_depth.bits() / 8) as usize;
        (input_size / source_bytes) * target_bytes
    }
}

impl BitDepthConverter {
    fn read_sample(&self, bytes: &[u8]) -> i32 {
        match self.source_depth {
            BitDepth::Bits16 => i16::from_le_bytes([bytes[0], bytes[1]]) as i32,
            BitDepth::Bits24 => {
                let val = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], 0]);
                val >> 8
            }
            BitDepth::Bits32 => i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
        }
    }

    fn write_sample(&self, sample: i32, bytes: &mut [u8]) {
        match self.target_depth {
            BitDepth::Bits16 => {
                let val = (sample as i16).to_le_bytes();
                bytes[0] = val[0];
                bytes[1] = val[1];
            }
            BitDepth::Bits24 => {
                let val = (sample << 8).to_le_bytes();
                bytes[0] = val[0];
                bytes[1] = val[1];
                bytes[2] = val[2];
            }
            BitDepth::Bits32 => {
                let val = sample.to_le_bytes();
                bytes[0] = val[0];
                bytes[1] = val[1];
                bytes[2] = val[2];
                bytes[3] = val[3];
            }
        }
    }
}

pub struct SampleRateConverter {
    source_rate: SampleRate,
    target_rate: SampleRate,
    channels: u16,
    bytes_per_sample: usize,
}

impl SampleRateConverter {
    pub fn new(
        source_rate: SampleRate,
        target_rate: SampleRate,
        channels: ChannelConfig,
        bit_depth: BitDepth,
    ) -> Self {
        Self {
            source_rate,
            target_rate,
            channels: channels.count(),
            bytes_per_sample: (bit_depth.bits() / 8) as usize,
        }
    }
}

impl FormatConverter for SampleRateConverter {
    fn convert(&self, input: &[u8], output: &mut [u8]) -> Result<usize, Uac2Error> {
        let frame_size = self.channels as usize * self.bytes_per_sample;
        let input_frames = input.len() / frame_size;

        let ratio = self.target_rate.hz() as f64 / self.source_rate.hz() as f64;
        let output_frames = (input_frames as f64 * ratio) as usize;
        let output_len = output_frames * frame_size;

        if output.len() < output_len {
            return Err(Uac2Error::BufferOverflow);
        }

        for i in 0..output_frames {
            let source_pos = (i as f64 / ratio) as usize;
            if source_pos >= input_frames {
                break;
            }

            let src_offset = source_pos * frame_size;
            let dst_offset = i * frame_size;
            output[dst_offset..dst_offset + frame_size]
                .copy_from_slice(&input[src_offset..src_offset + frame_size]);
        }

        Ok(output_len)
    }

    fn output_size(&self, input_size: usize) -> usize {
        let frame_size = self.channels as usize * self.bytes_per_sample;
        let input_frames = input_size / frame_size;
        let ratio = self.target_rate.hz() as f64 / self.source_rate.hz() as f64;
        let output_frames = (input_frames as f64 * ratio) as usize;
        output_frames * frame_size
    }
}

pub struct AudioPipeline {
    source_format: AudioFormat,
    target_format: AudioFormat,
    converter: Box<dyn FormatConverter>,
    buffer: Arc<Mutex<RingBuffer>>,
}

impl AudioPipeline {
    pub fn new(
        source_format: AudioFormat,
        target_format: AudioFormat,
        buffer_size: usize,
    ) -> Result<Self, Uac2Error> {
        info!(
            source_rate = source_format.sample_rates.first().map(|r| r.hz()),
            source_depth = source_format.bit_depth.bits(),
            source_channels = source_format.channels.count(),
            target_rate = target_format.sample_rates.first().map(|r| r.hz()),
            target_depth = target_format.bit_depth.bits(),
            target_channels = target_format.channels.count(),
            buffer_size = buffer_size,
            "Creating audio pipeline"
        );

        let converter = Self::create_converter(&source_format, &target_format)?;
        let buffer = Arc::new(Mutex::new(RingBuffer::new(buffer_size)?));

        let is_passthrough = Self::is_bit_perfect(&source_format, &target_format);
        if is_passthrough {
            info!("Bit-perfect passthrough mode enabled");
        } else {
            warn!("Format conversion required - not bit-perfect");
        }

        Ok(Self {
            source_format,
            target_format,
            converter,
            buffer,
        })
    }

    fn is_bit_perfect(source: &AudioFormat, target: &AudioFormat) -> bool {
        source.bit_depth == target.bit_depth
            && source.channels.count() == target.channels.count()
            && source
                .sample_rates
                .iter()
                .any(|r| target.sample_rates.contains(r))
            && source.format_type == target.format_type
    }

    fn create_converter(
        source: &AudioFormat,
        target: &AudioFormat,
    ) -> Result<Box<dyn FormatConverter>, Uac2Error> {
        if Self::is_bit_perfect(source, target) {
            debug!("Using passthrough converter");
            return Ok(Box::new(PassthroughConverter));
        }

        if source.bit_depth != target.bit_depth {
            info!(
                source_depth = source.bit_depth.bits(),
                target_depth = target.bit_depth.bits(),
                "Using bit depth converter"
            );
            return Ok(Box::new(BitDepthConverter::new(
                source.bit_depth,
                target.bit_depth,
            )));
        }

        if !source
            .sample_rates
            .iter()
            .any(|r| target.sample_rates.contains(r))
        {
            let source_rate = source.sample_rates[0];
            let target_rate = target.sample_rates[0];
            info!(
                source_rate = source_rate.hz(),
                target_rate = target_rate.hz(),
                "Using sample rate converter"
            );
            return Ok(Box::new(SampleRateConverter::new(
                source_rate,
                target_rate,
                source.channels,
                source.bit_depth,
            )));
        }

        debug!("Using passthrough converter (fallback)");
        Ok(Box::new(PassthroughConverter))
    }

    pub fn is_passthrough(&self) -> bool {
        Self::is_bit_perfect(&self.source_format, &self.target_format)
    }

    pub fn process(&self, input: &[u8]) -> Result<usize, Uac2Error> {
        let output_size = self.converter.output_size(input.len());
        let mut temp_buffer = vec![0u8; output_size];

        let converted_size = self.converter.convert(input, &mut temp_buffer)?;

        let mut buffer = self.buffer.lock().unwrap();
        let written = buffer.write(&temp_buffer[..converted_size])?;

        if written < converted_size {
            warn!(
                requested = converted_size,
                written = written,
                "Buffer overflow during audio processing"
            );
        }

        Ok(written)
    }

    pub fn read(&self, output: &mut [u8]) -> Result<usize, Uac2Error> {
        let mut buffer = self.buffer.lock().unwrap();
        buffer.read(output)
    }

    pub fn available(&self) -> usize {
        self.buffer.lock().unwrap().available()
    }

    pub fn source_format(&self) -> &AudioFormat {
        &self.source_format
    }

    pub fn target_format(&self) -> &AudioFormat {
        &self.target_format
    }
}
