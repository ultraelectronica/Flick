use super::types::{FeatureUnit, FormatTypeI, FormatTypeII};

pub struct FeatureUnitBuilder {
    b_unit_id: u8,
    b_source_id: u8,
    b_control_size: u8,
    bma_controls: Vec<u32>,
}

impl FeatureUnitBuilder {
    pub fn new(b_unit_id: u8, b_source_id: u8) -> Self {
        Self {
            b_unit_id,
            b_source_id,
            b_control_size: 4,
            bma_controls: Vec::new(),
        }
    }

    pub fn bma_controls(mut self, controls: Vec<u32>) -> Self {
        self.bma_controls = controls;
        self
    }

    pub fn build(self) -> FeatureUnit {
        FeatureUnit {
            b_unit_id: self.b_unit_id,
            b_source_id: self.b_source_id,
            b_control_size: self.b_control_size,
            bma_controls: self.bma_controls,
        }
    }
}

pub struct FormatTypeIBuilder {
    b_subslot_size: u8,
    b_bit_resolution: u8,
    b_sam_freq_type: u8,
    sample_rates: Vec<u32>,
}

impl FormatTypeIBuilder {
    pub fn new(b_subslot_size: u8, b_bit_resolution: u8) -> Self {
        Self {
            b_subslot_size,
            b_bit_resolution,
            b_sam_freq_type: 0,
            sample_rates: Vec::new(),
        }
    }

    pub fn continuous_sample_rate(mut self, rate: u32) -> Self {
        self.b_sam_freq_type = 0;
        self.sample_rates = vec![rate];
        self
    }

    pub fn discrete_sample_rates(mut self, rates: Vec<u32>) -> Self {
        self.b_sam_freq_type = rates.len() as u8;
        self.sample_rates = rates;
        self
    }

    pub fn build(self) -> FormatTypeI {
        FormatTypeI {
            b_subslot_size: self.b_subslot_size,
            b_bit_resolution: self.b_bit_resolution,
            b_sam_freq_type: self.b_sam_freq_type,
            sample_rates: self.sample_rates,
        }
    }
}

pub struct FormatTypeIIBuilder {
    w_max_bit_rate: u16,
    w_samples_per_frame: u16,
    b_sam_freq_type: u8,
    sample_rates: Vec<u32>,
}

impl FormatTypeIIBuilder {
    pub fn new(w_max_bit_rate: u16, w_samples_per_frame: u16) -> Self {
        Self {
            w_max_bit_rate,
            w_samples_per_frame,
            b_sam_freq_type: 0,
            sample_rates: Vec::new(),
        }
    }

    pub fn continuous_sample_rate(mut self, rate: u32) -> Self {
        self.b_sam_freq_type = 0;
        self.sample_rates = vec![rate];
        self
    }

    pub fn discrete_sample_rates(mut self, rates: Vec<u32>) -> Self {
        self.b_sam_freq_type = rates.len() as u8;
        self.sample_rates = rates;
        self
    }

    pub fn build(self) -> FormatTypeII {
        FormatTypeII {
            w_max_bit_rate: self.w_max_bit_rate,
            w_samples_per_frame: self.w_samples_per_frame,
            b_sam_freq_type: self.b_sam_freq_type,
            sample_rates: self.sample_rates,
        }
    }
}
