#[derive(Debug, Clone)]
pub struct Iad {
    pub b_first_interface: u8,
    pub b_interface_count: u8,
    pub b_function_class: u8,
    pub b_function_sub_class: u8,
    pub b_function_protocol: u8,
    pub i_function: u8,
}

#[derive(Debug, Clone)]
pub struct AcInterfaceHeader {
    pub bcd_adc: u16,
    pub b_category: u8,
    pub w_total_length: u16,
    pub bm_controls: u16,
}

#[derive(Debug, Clone)]
pub struct InputTerminal {
    pub b_terminal_id: u8,
    pub w_terminal_type: u16,
    pub b_assoc_terminal: u8,
    pub b_c_source_id: u8,
    pub b_nr_channels: u16,
    pub w_channel_config: u32,
    pub i_terminal: u8,
}

#[derive(Debug, Clone)]
pub struct OutputTerminal {
    pub b_terminal_id: u8,
    pub w_terminal_type: u16,
    pub b_assoc_terminal: u8,
    pub b_source_id: u8,
    pub i_terminal: u8,
}

#[derive(Debug, Clone)]
pub struct FeatureUnit {
    pub b_unit_id: u8,
    pub b_source_id: u8,
    pub b_control_size: u8,
    pub bma_controls: Vec<u32>,
}

#[derive(Debug, Clone)]
pub struct AsInterfaceGeneral {
    pub b_terminal_link: u8,
    pub b_delay: u8,
    pub w_format_tag: u16,
}

#[derive(Debug, Clone)]
pub struct FormatTypeI {
    pub b_subslot_size: u8,
    pub b_bit_resolution: u8,
    pub b_sam_freq_type: u8,
    pub sample_rates: Vec<u32>,
}

#[derive(Debug, Clone)]
pub struct FormatTypeII {
    pub w_max_bit_rate: u16,
    pub w_samples_per_frame: u16,
    pub b_sam_freq_type: u8,
    pub sample_rates: Vec<u32>,
}

#[derive(Debug, Clone)]
pub struct FormatTypeIII {
    pub b_subslot_size: u8,
    pub b_bit_resolution: u8,
}

#[derive(Debug, Clone)]
pub enum AudioControlDescriptor {
    Header(AcInterfaceHeader),
    InputTerminal(InputTerminal),
    OutputTerminal(OutputTerminal),
    FeatureUnit(FeatureUnit),
}

#[derive(Debug, Clone)]
pub enum AudioStreamingDescriptor {
    General(AsInterfaceGeneral),
    FormatTypeI(FormatTypeI),
    FormatTypeII(FormatTypeII),
    FormatTypeIII(FormatTypeIII),
}

#[derive(Debug, Clone)]
pub enum DescriptorKind {
    Iad(Iad),
    AudioControl(AudioControlDescriptor),
    AudioStreaming(AudioStreamingDescriptor),
}
