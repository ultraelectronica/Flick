use crate::audio::dsd_engine::dsd::{DsdOutputMode, DsdRate};
use crate::audio::dsd_engine::format::{
    open_dsd_decoder, DsdBitOrder, DsdChannelLayout, DsdFormatDecoder,
};
use crate::audio::dsd_engine::output::DsdOutputRouter;
use crate::audio::source::{AudioSource, SourceInfo, SourceProducer};
use anyhow::{anyhow, Result};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

const DSD_READ_CHUNK_SIZE: usize = 16384;

pub struct DsdDecoderThread {
    handle: Option<JoinHandle<Result<()>>>,
    stop_signal: Arc<AtomicBool>,
}

impl DsdDecoderThread {
    pub fn spawn(
        path: PathBuf,
        output_mode: DsdOutputMode,
        target_rate: u32,
        output_channels: usize,
    ) -> Result<(AudioSource, Self)> {
        Self::spawn_with_seek(path, output_mode, target_rate, output_channels, None)
    }

    pub fn spawn_with_seek(
        path: PathBuf,
        output_mode: DsdOutputMode,
        target_rate: u32,
        output_channels: usize,
        start_position_secs: Option<f64>,
    ) -> Result<(AudioSource, Self)> {
        let decoder = open_dsd_decoder(&path)?;

        let dsd_rate = DsdRate::from_sample_rate(decoder.sample_rate())
            .ok_or_else(|| anyhow!("Unsupported DSD sample rate: {}", decoder.sample_rate()))?;

        let source_channels = decoder.channels() as usize;
        let duration_secs = decoder.duration_secs();
        let channel_layout = decoder.channel_layout();
        let source_bit_order = decoder.bit_order();

        let output_sample_rate = match output_mode {
            DsdOutputMode::PcmDecimation | DsdOutputMode::Auto => {
                dsd_rate.best_pcm_target(target_rate)
            }
            DsdOutputMode::Dop => dsd_rate.dop_carrier_rate(),
            DsdOutputMode::Native => dsd_rate.byte_rate(),
        };

        log::info!(
            "[DSD-DECODER] spawn: path={}, file_rate={} Hz, dsd_rate={:?}, output_mode={:?}, target_rate={} Hz, output_rate={} Hz",
            path.display(),
            decoder.sample_rate(),
            dsd_rate,
            output_mode,
            target_rate,
            output_sample_rate,
        );

        let total_output_samples = if duration_secs > 0.0 {
            (duration_secs * output_sample_rate as f64 * output_channels as f64) as u64
        } else {
            0
        };

        let source_info = SourceInfo {
            path: path.clone(),
            original_sample_rate: decoder.sample_rate(),
            output_sample_rate,
            channels: output_channels,
            total_samples: total_output_samples,
            duration_secs,
            http_origin: None,
        };

        let (source, producer) = AudioSource::new(source_info);
        if let Some(pos) = start_position_secs {
            if pos > 0.0 {
                source.set_position_secs(pos);
            }
        }

        let output_router = DsdOutputRouter::new(
            output_mode,
            dsd_rate,
            output_sample_rate,
            source_channels,
            source_bit_order,
        );

        let stop_signal = Arc::new(AtomicBool::new(false));
        let stop_clone = Arc::clone(&stop_signal);

        let handle = thread::Builder::new()
            .name(format!("dsd-decoder-{}", path.display()))
            .spawn(move || {
                dsd_decode_thread(
                    decoder,
                    producer,
                    output_router,
                    source_channels,
                    output_channels,
                    stop_clone,
                    start_position_secs,
                    channel_layout,
                    source_bit_order,
                )
            })
            .map_err(|e| anyhow!("Failed to spawn DSD decoder thread: {}", e))?;

        Ok((
            source,
            Self {
                handle: Some(handle),
                stop_signal,
            },
        ))
    }

    pub fn stop(&self) {
        self.stop_signal.store(true, Ordering::Release);
    }

    pub fn join(mut self) -> Result<()> {
        if let Some(handle) = self.handle.take() {
            handle
                .join()
                .map_err(|_| anyhow!("DSD decoder thread panicked"))?
        } else {
            Ok(())
        }
    }

    pub fn is_running(&self) -> bool {
        self.handle
            .as_ref()
            .map(|h| !h.is_finished())
            .unwrap_or(false)
    }
}

impl Drop for DsdDecoderThread {
    fn drop(&mut self) {
        self.stop();
    }
}

enum ChannelData {
    Owned(Vec<u8>),
}

impl ChannelData {
    fn as_slice(&self) -> &[u8] {
        match self {
            ChannelData::Owned(v) => v,
        }
    }
}

fn dsd_decode_thread(
    mut decoder: Box<dyn DsdFormatDecoder>,
    mut producer: SourceProducer,
    mut output_router: DsdOutputRouter,
    source_channels: usize,
    _output_channels: usize,
    stop_signal: Arc<AtomicBool>,
    start_position_secs: Option<f64>,
    channel_layout: DsdChannelLayout,
    _source_bit_order: DsdBitOrder,
) -> Result<()> {
    if let Some(pos) = start_position_secs {
        if pos > 0.0 {
            let dsd_rate = decoder.sample_rate();
            let target_sample = (pos * dsd_rate as f64) as u64;
            decoder.seek(target_sample)?;
            output_router.reset();
        }
    }

    let read_size = match &channel_layout {
        DsdChannelLayout::SequentialBlocks { block_size } => {
            let aligned = block_size * source_channels;
            let chunks = (DSD_READ_CHUNK_SIZE + aligned - 1) / aligned;
            chunks * aligned
        }
        DsdChannelLayout::Interleaved => DSD_READ_CHUNK_SIZE,
    };

    let mut dsd_buf = vec![0u8; read_size];
    let mut output_buf: Vec<f32> = Vec::with_capacity(DSD_READ_CHUNK_SIZE);

    // Offline wire-vs-reference diffing. Only the first decoder thread to
    // claim the flag dumps, so a gapless preload decoder can't interleave.
    static DUMP_CLAIMED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    let dump_enabled = !DUMP_CLAIMED.swap(true, Ordering::AcqRel);
    let mut dump_raw: Option<std::fs::File> = None;
    let mut dump_prod: Option<std::fs::File> = None;
    let mut dump_raw_n: usize = 0;
    let mut dump_prod_n: usize = 0;
    if dump_enabled {
        use std::fs::OpenOptions;
        let dir = std::path::Path::new("/storage/6438-6261/flick_dsd_dump");
        let _ = std::fs::create_dir_all(dir);
        dump_raw = OpenOptions::new()
            .create(true).write(true).truncate(true)
            .open(dir.join("dsd_raw_full.bin")).ok();
        dump_prod = OpenOptions::new()
            .create(true).write(true).truncate(true)
            .open(dir.join("dsd_prod_full.bin")).ok();
        log::info!(
            "[DSD-DECODER] dump capture claimed (raw+prod), read_size={}",
            read_size
        );
    }

    log::info!(
        "[DSD-DECODER] Starting: dsd_rate={} channels={} layout={:?} bit_order={:?}",
        decoder.sample_rate(),
        source_channels,
        channel_layout,
        _source_bit_order,
    );

    loop {
        if stop_signal.load(Ordering::Acquire) || producer.should_stop() {
            break;
        }

        let bytes_read = decoder.read_dsd_bytes(&mut dsd_buf)?;
        if bytes_read == 0 {
            break;
        }

        if let Some(f) = dump_raw.as_mut() {
            if dump_raw_n < (5 << 20) {
                use std::io::Write;
                let cap = ((5 << 20) - dump_raw_n).min(bytes_read);
                let _ = f.write_all(&dsd_buf[..cap]);
                dump_raw_n += cap;
            }
        }

        let (data, offsets) = match &channel_layout {
            DsdChannelLayout::Interleaved => {
                let deint = deinterleave_dsd(&dsd_buf[..bytes_read], source_channels);
                let bytes_per_ch = deint.len() / source_channels.max(1);
                let off: Vec<usize> = (0..source_channels).map(|ch| ch * bytes_per_ch).collect();
                (ChannelData::Owned(deint), off)
            }
            DsdChannelLayout::SequentialBlocks { block_size } => {
                let deint = deinterleave_sequential_blocks(
                    &dsd_buf[..bytes_read],
                    source_channels,
                    *block_size,
                );
                let bytes_per_ch = deint.len() / source_channels.max(1);
                let off: Vec<usize> = (0..source_channels).map(|ch| ch * bytes_per_ch).collect();
                (ChannelData::Owned(deint), off)
            }
        };

        if let Err(e) = output_router.process_dsd_bytes(data.as_slice(), &offsets, &mut output_buf)
        {
            log::error!("[DSD-DECODER] Processing error: {}", e);
            break;
        }

        if let Some(f) = dump_prod.as_mut() {
            if dump_prod_n < (5 << 20) {
                use std::io::Write;
                let mut tmp: Vec<u8> = Vec::with_capacity(output_buf.len());
                for s in &output_buf {
                    tmp.push(s.to_bits() as u8);
                }
                let cap = ((5 << 20) - dump_prod_n).min(tmp.len());
                let _ = f.write_all(&tmp[..cap]);
                dump_prod_n += cap;
            }
        }

        write_to_ring_buffer(&output_buf, &mut producer, &stop_signal);
    }

    producer.finish();
    Ok(())
}

fn deinterleave_dsd(interleaved: &[u8], channels: usize) -> Vec<u8> {
    if channels <= 1 {
        return interleaved.to_vec();
    }

    let frames = interleaved.len() / channels;
    let mut output = vec![0u8; interleaved.len()];

    for ch in 0..channels {
        for frame in 0..frames {
            output[ch * frames + frame] = interleaved[frame * channels + ch];
        }
    }

    output
}

fn deinterleave_sequential_blocks(data: &[u8], channels: usize, block_size: usize) -> Vec<u8> {
    if channels <= 1 {
        return data.to_vec();
    }
    let macro_block = block_size * channels;
    let num_blocks = data.len() / macro_block;
    let bytes_per_ch = num_blocks * block_size;
    let mut out = vec![0u8; bytes_per_ch * channels];

    for ch in 0..channels {
        for block in 0..num_blocks {
            let src = block * macro_block + ch * block_size;
            let dst = ch * bytes_per_ch + block * block_size;
            out[dst..dst + block_size].copy_from_slice(&data[src..src + block_size]);
        }
    }
    out
}

fn write_to_ring_buffer(samples: &[f32], producer: &mut SourceProducer, stop_signal: &AtomicBool) {
    if samples.is_empty() {
        return;
    }

    let mut offset = 0;
    while offset < samples.len() {
        if stop_signal.load(Ordering::Acquire) || producer.should_stop() {
            break;
        }

        let chunk = &samples[offset..];
        let written = producer.write(chunk);
        offset += written;

        if written == 0 {
            producer.wait_for_space(chunk.len().min(1024), 100);
        }
    }
}
