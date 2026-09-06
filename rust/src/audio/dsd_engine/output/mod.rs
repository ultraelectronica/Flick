use super::dsd::dop::DopPacker;
use super::dsd::DsdDecimationPipeline;
use super::dsd::{DsdOutputMode, DsdRate};
use super::format::DsdBitOrder;
use anyhow::Result;
use std::sync::atomic::{AtomicBool, AtomicI8, AtomicU8, Ordering};

static DSD_BIT_REVERSE_OVERRIDE: AtomicBool = AtomicBool::new(false);

pub fn set_dsd_bit_reverse_override(enabled: bool) {
    DSD_BIT_REVERSE_OVERRIDE.store(enabled, Ordering::Relaxed);
    log::info!(
        "[DSD-FORMATTER] Bit-reverse override: {}",
        if enabled { "FORCED ON" } else { "auto (off)" }
    );
}

pub fn dsd_bit_reverse_override() -> bool {
    DSD_BIT_REVERSE_OVERRIDE.load(Ordering::Relaxed)
}

// Native-DSD wire byte order for the USB direct transport (DSD_U32 packing).
// -1 = auto (defer to device quirk), 0 = force little-endian, 1 = force big-endian.
static DSD_BIG_ENDIAN_OVERRIDE: AtomicI8 = AtomicI8::new(-1);

pub fn set_dsd_big_endian_override(value: Option<bool>) {
    let encoded = match value {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    };
    DSD_BIG_ENDIAN_OVERRIDE.store(encoded, Ordering::Relaxed);
    log::info!(
        "[DSD-TRANSPORT] Native DSD byte order override: {}",
        match encoded {
            1 => "FORCED big-endian",
            0 => "FORCED little-endian",
            _ => "auto (quirk)",
        }
    );
}

pub fn dsd_big_endian_override() -> Option<bool> {
    match DSD_BIG_ENDIAN_OVERRIDE.load(Ordering::Relaxed) {
        1 => Some(true),
        0 => Some(false),
        _ => None,
    }
}

// Native-DSD subslot size for the USB direct transport.
// 0 = auto (defer to descriptor / device quirk), else force (1=U8, 2=U16, 4=U32).
static DSD_SUBSLOT_OVERRIDE: AtomicU8 = AtomicU8::new(0);

pub fn set_dsd_subslot_override(value: Option<u8>) {
    let encoded = value.unwrap_or(0);
    DSD_SUBSLOT_OVERRIDE.store(encoded, Ordering::Relaxed);
    log::info!(
        "[DSD-TRANSPORT] Native DSD subslot override: {}",
        if encoded == 0 {
            "auto".to_string()
        } else {
            format!("U{}", encoded * 8)
        }
    );
}

pub fn dsd_subslot_override() -> Option<u8> {
    let v = DSD_SUBSLOT_OVERRIDE.load(Ordering::Relaxed);
    if v == 0 {
        None
    } else {
        Some(v)
    }
}

pub struct DsdOutputRouter {
    mode: DsdOutputMode,
    source_bit_order: DsdBitOrder,
    pcm_pipeline: Option<DsdDecimationPipeline>,
    dop_packer: Option<DopPacker>,
}

impl DsdOutputRouter {
    pub fn new(
        mode: DsdOutputMode,
        dsd_rate: DsdRate,
        target_rate: u32,
        channels: usize,
        source_bit_order: DsdBitOrder,
    ) -> Self {
        let pcm_pipeline = match mode {
            DsdOutputMode::PcmDecimation | DsdOutputMode::Auto => {
                Some(DsdDecimationPipeline::new(dsd_rate, target_rate, channels))
            }
            DsdOutputMode::Dop | DsdOutputMode::Native => None,
        };

        let dop_packer = match mode {
            DsdOutputMode::Dop => Some(DopPacker::with_bit_reverse(
                dsd_rate,
                channels,
                dop_needs_bit_reverse(source_bit_order),
            )),
            DsdOutputMode::PcmDecimation | DsdOutputMode::Native | DsdOutputMode::Auto => None,
        };

        Self {
            mode,
            source_bit_order,
            pcm_pipeline,
            dop_packer,
        }
    }

    pub fn output_sample_rate(&self, dsd_rate: DsdRate) -> u32 {
        match self.mode {
            DsdOutputMode::PcmDecimation | DsdOutputMode::Auto => self
                .pcm_pipeline
                .as_ref()
                .map(|p| p.target_pcm_rate())
                .unwrap_or(dsd_rate.dop_carrier_rate()),
            DsdOutputMode::Dop => dsd_rate.dop_carrier_rate(),
            DsdOutputMode::Native => dsd_rate.byte_rate(),
        }
    }

    pub fn mode(&self) -> DsdOutputMode {
        self.mode
    }

    pub fn process_dsd_bytes(
        &mut self,
        dsd_bytes: &[u8],
        channel_offsets: &[usize],
        output: &mut Vec<f32>,
    ) -> Result<()> {
        match self.mode {
            DsdOutputMode::PcmDecimation | DsdOutputMode::Auto => {
                if let Some(ref mut pipeline) = self.pcm_pipeline {
                    pipeline.process_bytes(dsd_bytes, channel_offsets, output);
                }
            }
            DsdOutputMode::Dop => {
                if let Some(ref mut packer) = self.dop_packer {
                    packer.pack_to_f32(dsd_bytes, channel_offsets, output);
                }
            }
            DsdOutputMode::Native => {
                pack_native_dsd_f32(dsd_bytes, channel_offsets, self.source_bit_order, output);
            }
        }
        Ok(())
    }

    pub fn reset(&mut self) {
        if let Some(ref mut pipeline) = self.pcm_pipeline {
            pipeline.reset();
        }
        if let Some(ref mut packer) = self.dop_packer {
            packer.reset();
        }
    }
}

#[inline]
fn reverse_bits(b: u8) -> u8 {
    b.reverse_bits()
}

fn normalize_dsd_byte(byte: u8, source_order: DsdBitOrder) -> u8 {
    let needs_reverse = match source_order {
        DsdBitOrder::LsbFirst => true,
        DsdBitOrder::MsbFirst => false,
    };
    if DSD_BIT_REVERSE_OVERRIDE.load(Ordering::Relaxed) {
        if needs_reverse {
            byte
        } else {
            reverse_bits(byte)
        }
    } else if needs_reverse {
        reverse_bits(byte)
    } else {
        byte
    }
}

fn dop_needs_bit_reverse(source_order: DsdBitOrder) -> bool {
    let source_lsb = matches!(source_order, DsdBitOrder::LsbFirst);
    if DSD_BIT_REVERSE_OVERRIDE.load(Ordering::Relaxed) {
        !source_lsb
    } else {
        source_lsb
    }
}

fn pack_native_dsd_f32(
    dsd_bytes: &[u8],
    channel_offsets: &[usize],
    source_bit_order: DsdBitOrder,
    output: &mut Vec<f32>,
) {
    let channels = channel_offsets.len().max(1);
    let bytes_per_ch = dsd_bytes.len() / channels;
    output.clear();

    if channels == 1 {
        output.reserve(dsd_bytes.len());
        for &b in dsd_bytes {
            let normalized = normalize_dsd_byte(b, source_bit_order);
            output.push(f32::from_bits(normalized as u32));
        }
        return;
    }

    let frames = bytes_per_ch;
    output.reserve(frames * channels);
    for i in 0..frames {
        for ch in 0..channels {
            let ch_offset = channel_offsets
                .get(ch)
                .copied()
                .unwrap_or(ch * bytes_per_ch);
            let b = dsd_bytes[ch_offset + i];
            let normalized = normalize_dsd_byte(b, source_bit_order);
            output.push(f32::from_bits(normalized as u32));
        }
    }
}
