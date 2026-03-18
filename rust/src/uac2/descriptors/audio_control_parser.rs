use super::constants::*;
use super::helpers::{read_u16_le, read_u32_le, require_len};
use super::parser_trait::DescriptorParser;
use super::types::*;
use super::validation::{
    validate_ac_interface_header, validate_feature_unit, validate_input_terminal,
    validate_output_terminal,
};
use crate::uac2::error::Uac2Error;

pub struct AudioControlParser;

impl AudioControlParser {
    pub fn parse_ac_header(&self, data: &[u8]) -> Result<AcInterfaceHeader, Uac2Error> {
        const HEADER_LEN: usize = 9;
        require_len(data, HEADER_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_AC_HEADER {
            return Err(Uac2Error::InvalidDescriptor("not CS_AC header".to_string()));
        }
        let h = AcInterfaceHeader {
            bcd_adc: read_u16_le(data, 3),
            b_category: data[5],
            w_total_length: read_u16_le(data, 6),
            bm_controls: read_u16_le(data, 8),
        };
        validate_ac_interface_header(&h)?;
        Ok(h)
    }

    pub fn parse_input_terminal(&self, data: &[u8]) -> Result<InputTerminal, Uac2Error> {
        const LEN: usize = 15;
        require_len(data, LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_INPUT_TERMINAL {
            return Err(Uac2Error::InvalidDescriptor(
                "not input terminal".to_string(),
            ));
        }
        let t = InputTerminal {
            b_terminal_id: data[3],
            w_terminal_type: read_u16_le(data, 4),
            b_assoc_terminal: data[6],
            b_c_source_id: data[7],
            b_nr_channels: read_u16_le(data, 8),
            w_channel_config: read_u32_le(data, 10),
            i_terminal: data[14],
        };
        validate_input_terminal(&t)?;
        Ok(t)
    }

    pub fn parse_output_terminal(&self, data: &[u8]) -> Result<OutputTerminal, Uac2Error> {
        const LEN: usize = 9;
        require_len(data, LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_OUTPUT_TERMINAL {
            return Err(Uac2Error::InvalidDescriptor(
                "not output terminal".to_string(),
            ));
        }
        let t = OutputTerminal {
            b_terminal_id: data[3],
            w_terminal_type: read_u16_le(data, 4),
            b_assoc_terminal: data[6],
            b_source_id: data[7],
            i_terminal: data[8],
        };
        validate_output_terminal(&t)?;
        Ok(t)
    }

    pub fn parse_feature_unit(&self, data: &[u8]) -> Result<FeatureUnit, Uac2Error> {
        const MIN_LEN: usize = 7;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_FEATURE_UNIT {
            return Err(Uac2Error::InvalidDescriptor("not feature unit".to_string()));
        }
        let len = data[0] as usize;
        if len < MIN_LEN || (len - 7) % 4 != 0 {
            return Err(Uac2Error::InvalidDescriptor(
                "invalid feature unit length".to_string(),
            ));
        }
        let n = (len - 7) / 4;
        require_len(data, len)?;
        let bma_controls: Vec<u32> = (0..n).map(|i| read_u32_le(data, 7 + i * 4)).collect();
        let f = FeatureUnit {
            b_unit_id: data[3],
            b_source_id: data[4],
            b_control_size: data[5],
            bma_controls,
        };
        validate_feature_unit(&f)?;
        Ok(f)
    }
}

impl DescriptorParser for AudioControlParser {
    type Output = AudioControlDescriptor;

    fn parse(&self, data: &[u8]) -> Result<Self::Output, Uac2Error> {
        if data.len() < 3 {
            return Err(Uac2Error::InvalidDescriptor(
                "descriptor too short".to_string(),
            ));
        }
        if data[1] != USB_DT_CS_INTERFACE {
            return Err(Uac2Error::InvalidDescriptor("not CS interface".to_string()));
        }
        match data[2] {
            UAC2_AC_HEADER => self
                .parse_ac_header(data)
                .map(AudioControlDescriptor::Header),
            UAC2_INPUT_TERMINAL => self
                .parse_input_terminal(data)
                .map(AudioControlDescriptor::InputTerminal),
            UAC2_OUTPUT_TERMINAL => self
                .parse_output_terminal(data)
                .map(AudioControlDescriptor::OutputTerminal),
            UAC2_FEATURE_UNIT => self
                .parse_feature_unit(data)
                .map(AudioControlDescriptor::FeatureUnit),
            _ => Err(Uac2Error::InvalidDescriptor(format!(
                "unknown AC descriptor subtype {}",
                data[2]
            ))),
        }
    }
}
