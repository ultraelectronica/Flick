use super::{DsdBitOrder, DsdChannelLayout, DsdFormatDecoder};
use anyhow::{anyhow, Result};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

const DSF_FALLBACK_SAMPLE_DATA_OFFSET: u64 = 100;

pub struct DsfDecoder {
    file: File,
    sample_rate: u32,
    channels: u16,
    total_samples: u64,
    data_offset: u64,
    block_size: u32,
    current_position: u64,
    finished: bool,
}

impl DsfDecoder {
    pub fn open(path: &Path) -> Result<Self> {
        let dsf = dsf_meta::DsfFile::open(path)
            .map_err(|e| anyhow!("Failed to parse DSF header: {}", e))?;

        let fmt = dsf.fmt_chunk();
        let sample_rate = fmt.sampling_frequency();
        let channels = fmt.channel_num() as u16;
        let total_samples = fmt.sample_count();
        let block_size = fmt.block_size_per_channel();

        let mut file = dsf
            .file()
            .try_clone()
            .map_err(|e| anyhow!("Failed to clone DSF file handle: {}", e))?;
        drop(dsf);

        let data_offset =
            Self::read_sample_data_offset(&mut file).unwrap_or(DSF_FALLBACK_SAMPLE_DATA_OFFSET);

        file.seek(SeekFrom::Start(data_offset))?;

        Ok(Self {
            file,
            sample_rate,
            channels,
            total_samples,
            data_offset,
            block_size,
            current_position: 0,
            finished: false,
        })
    }

    fn read_sample_data_offset(file: &mut File) -> Option<u64> {
        file.seek(SeekFrom::Start(92)).ok()?;
        let mut buf = [0u8; 8];
        file.read_exact(&mut buf).ok()?;
        let offset = u64::from_le_bytes(buf);
        if offset >= DSF_FALLBACK_SAMPLE_DATA_OFFSET && offset < (1 << 40) {
            Some(offset)
        } else {
            None
        }
    }

    pub fn block_size_per_channel(&self) -> u32 {
        self.block_size
    }
}

impl DsdFormatDecoder for DsfDecoder {
    fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    fn channels(&self) -> u16 {
        self.channels
    }

    fn total_samples(&self) -> u64 {
        self.total_samples
    }

    fn duration_secs(&self) -> f64 {
        if self.sample_rate == 0 {
            return 0.0;
        }
        self.total_samples as f64 / self.sample_rate as f64
    }

    fn seek(&mut self, sample: u64) -> Result<()> {
        let bytes_per_sample_block = self.block_size as u64 * self.channels as u64;
        let sample_block = sample / (self.block_size as u64 * 8);
        let target_byte = sample_block * bytes_per_sample_block;

        self.file
            .seek(SeekFrom::Start(self.data_offset + target_byte))?;
        self.current_position = sample;
        self.finished = false;
        Ok(())
    }

    fn read_dsd_bytes(&mut self, buf: &mut [u8]) -> Result<usize> {
        if self.finished {
            return Ok(0);
        }

        // FUSE-backed storage routinely returns short reads; keep reading so
        // the consumer always gets whole macro blocks (a truncated tail would
        // silently desync the per-channel blocks and tick audibly).
        let mut bytes_read = 0usize;
        while bytes_read < buf.len() {
            match self.file.read(&mut buf[bytes_read..]) {
                Ok(0) => break,
                Ok(n) => bytes_read += n,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e.into()),
            }
        }
        if bytes_read == 0 {
            self.finished = true;
        }

        let macro_block = self.block_size as u64 * self.channels as u64;
        let num_macro_blocks = bytes_read as u64 / macro_block;
        let samples_consumed = num_macro_blocks * self.block_size as u64 * 8;
        self.current_position += samples_consumed;

        if self.current_position >= self.total_samples {
            self.finished = true;
        }

        Ok(bytes_read)
    }

    fn is_finished(&self) -> bool {
        self.finished
    }

    fn channel_layout(&self) -> DsdChannelLayout {
        DsdChannelLayout::SequentialBlocks {
            block_size: self.block_size as usize,
        }
    }

    fn bit_order(&self) -> DsdBitOrder {
        DsdBitOrder::LsbFirst
    }
}
