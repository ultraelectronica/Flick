use super::{DsdBitOrder, DsdChannelLayout, DsdFormatDecoder};
use anyhow::{anyhow, Result};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

pub struct DffDecoder {
    file: File,
    sample_rate: u32,
    channels: u16,
    total_samples: u64,
    data_offset: u64,
    current_position: u64,
    finished: bool,
}

impl DffDecoder {
    pub fn open(path: &Path) -> Result<Self> {
        let dff = dff_meta::DffFile::open(path)
            .map_err(|e| anyhow!("Failed to parse DFF header: {}", e))?;

        let sample_rate = dff
            .get_sample_rate()
            .map_err(|e| anyhow!("Failed to get DFF sample rate: {}", e))?;
        let channels =
            dff.get_num_channels()
                .map_err(|e| anyhow!("Failed to get DFF channel count: {}", e))? as u16;
        let data_offset = dff.get_dsd_data_offset();
        let audio_length = dff.get_audio_length();

        let total_samples = if sample_rate > 0 && channels > 0 {
            (audio_length * 8) / channels as u64
        } else {
            0
        };

        let mut file = File::open(path)?;
        file.seek(SeekFrom::Start(data_offset))?;

        drop(dff);

        Ok(Self {
            file,
            sample_rate,
            channels,
            total_samples,
            data_offset,
            current_position: 0,
            finished: false,
        })
    }
}

impl DsdFormatDecoder for DffDecoder {
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
        let byte_offset = (sample / 8) * self.channels as u64;
        self.file
            .seek(SeekFrom::Start(self.data_offset + byte_offset))?;
        self.current_position = sample;
        self.finished = false;
        Ok(())
    }

    fn read_dsd_bytes(&mut self, buf: &mut [u8]) -> Result<usize> {
        if self.finished {
            return Ok(0);
        }

        // FUSE-backed storage routinely returns short reads; fill the buffer
        // fully so interleaved channel pairs are never split.
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

        let samples_consumed = (bytes_read as u64 / self.channels as u64) * 8;
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
        DsdChannelLayout::Interleaved
    }

    fn bit_order(&self) -> DsdBitOrder {
        DsdBitOrder::MsbFirst
    }
}
