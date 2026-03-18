mod audio_control_parser;
mod audio_streaming_parser;
mod builders;
mod constants;
mod factory;
mod helpers;
mod iad_parser;
mod parse;
mod parser_trait;
mod types;
mod validation;

pub use audio_control_parser::AudioControlParser;
pub use audio_streaming_parser::AudioStreamingParser;
pub use builders::{FeatureUnitBuilder, FormatTypeIBuilder, FormatTypeIIBuilder};
pub use factory::DescriptorFactory;
pub use parse::{
    parse_ac_interface_header, parse_as_interface_general, parse_feature_unit, parse_format_type_i,
    parse_format_type_ii, parse_format_type_iii, parse_iad, parse_input_terminal,
    parse_output_terminal, DescriptorIter,
};
pub use parser_trait::DescriptorParser;
pub use types::*;
