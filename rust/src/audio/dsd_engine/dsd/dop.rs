use super::DsdRate;

pub struct DopPacker {
    dsd_rate: DsdRate,
    channels: usize,
    marker_state: u8,
    dsd_bytes_per_ch: usize,
    needs_bit_reverse: bool,
}

impl DopPacker {
    pub fn new(dsd_rate: DsdRate, channels: usize) -> Self {
        Self::with_bit_reverse(dsd_rate, channels, false)
    }

    /// `needs_bit_reverse` covers sources stored LSB-first (DSF): the DoP
    /// wire is MSB-first, so bytes must be reversed before packing.
    pub fn with_bit_reverse(
        dsd_rate: DsdRate,
        channels: usize,
        needs_bit_reverse: bool,
    ) -> Self {
        let dsd_bytes_per_ch = dsd_rate.dsd_bytes_per_channel_per_dop_frame();
        Self {
            dsd_rate,
            channels,
            marker_state: 0x05,
            dsd_bytes_per_ch,
            needs_bit_reverse,
        }
    }

    pub fn carrier_rate(&self) -> u32 {
        self.dsd_rate.dop_carrier_rate()
    }

    pub fn bits_per_frame(&self) -> u8 {
        self.dsd_rate.dop_bits_per_frame()
    }

    pub fn dsd_bytes_per_ch_per_frame(&self) -> usize {
        self.dsd_bytes_per_ch
    }

    pub fn pack_to_f32(
        &mut self,
        dsd_bytes: &[u8],
        channel_offsets: &[usize],
        output: &mut Vec<f32>,
    ) {
        output.clear();

        let bytes_per_channel = dsd_bytes.len() / self.channels.max(1);
        let num_frames = bytes_per_channel / self.dsd_bytes_per_ch.max(1);

        for frame_index in 0..num_frames {
            for ch in 0..self.channels {
                let ch_base = channel_offsets
                    .get(ch)
                    .copied()
                    .unwrap_or(ch * bytes_per_channel);
                let frame_byte_offset = ch_base + frame_index * self.dsd_bytes_per_ch;

                let sample = self.build_dop_word(dsd_bytes, frame_byte_offset);

                output.push(f32::from_bits(sample));
            }
            self.advance_marker();
        }
    }

    /// Pack DoP frames into i32 samples for integer audio output (AAudio I32).
    /// Each sample is a left-justified 24-bit DoP word in a 32-bit container:
    /// bits 31:24 = marker, bits 23:8 = DSD data, bits 7:0 = zero.
    pub fn pack_to_i32(
        &mut self,
        dsd_bytes: &[u8],
        channel_offsets: &[usize],
        output: &mut Vec<i32>,
    ) {
        output.clear();

        let bytes_per_channel = dsd_bytes.len() / self.channels.max(1);
        let num_frames = bytes_per_channel / self.dsd_bytes_per_ch.max(1);

        for frame_index in 0..num_frames {
            for ch in 0..self.channels {
                let ch_base = channel_offsets
                    .get(ch)
                    .copied()
                    .unwrap_or(ch * bytes_per_channel);
                let frame_byte_offset = ch_base + frame_index * self.dsd_bytes_per_ch;

                let word = self.build_dop_word(dsd_bytes, frame_byte_offset);

                output.push(word as i32);
            }
            self.advance_marker();
        }
    }

    fn build_dop_word(&self, dsd_bytes: &[u8], frame_byte_offset: usize) -> u32 {
        let bits = self.bits_per_frame() as usize;
        let dsd_data_bits = bits - 8;
        let mut sample: u32 = (self.marker_state as u32) << dsd_data_bits;

        for byte_idx in 0..self.dsd_bytes_per_ch {
            let read_pos = frame_byte_offset + byte_idx;
            if read_pos < dsd_bytes.len() {
                let shift = dsd_data_bits - 8 * (byte_idx + 1);
                let byte = dsd_bytes[read_pos];
                let byte = if self.needs_bit_reverse {
                    byte.reverse_bits()
                } else {
                    byte
                };
                sample |= (byte as u32) << shift;
            }
        }

        sample << (32 - bits)
    }

    fn advance_marker(&mut self) {
        self.marker_state = if self.marker_state == 0x05 {
            0xFA
        } else {
            0x05
        };
    }

    pub fn dop_frame_size(&self) -> usize {
        1 + self.dsd_bytes_per_ch * self.channels
    }

    pub fn reset(&mut self) {
        self.marker_state = 0x05;
    }
}
