//! Custom USB Audio Class 2.0 (UAC 2.0) support for DAC/AMP detection and bit-perfect playback.

#[cfg(feature = "uac2")]
mod descriptors;
#[cfg(feature = "uac2")]
mod device_enumeration;
#[cfg(feature = "uac2")]
mod device;
#[cfg(feature = "uac2")]
mod error;
#[cfg(feature = "uac2")]
mod registry;

#[cfg(feature = "uac2")]
pub use descriptors::{
    AcInterfaceHeader, AsInterfaceGeneral, AudioControlDescriptor, AudioControlParser,
    AudioStreamingDescriptor, AudioStreamingParser, DescriptorFactory, DescriptorIter,
    DescriptorKind, DescriptorParser, FeatureUnit, FeatureUnitBuilder, FormatTypeI, FormatTypeIBuilder,
    FormatTypeII, FormatTypeIIBuilder, FormatTypeIII, Iad, InputTerminal, OutputTerminal,
    parse_ac_interface_header, parse_as_interface_general, parse_feature_unit, parse_format_type_i,
    parse_format_type_ii, parse_format_type_iii, parse_iad, parse_input_terminal, parse_output_terminal,
};
#[cfg(feature = "uac2")]
pub use device_enumeration::enumerate_uac2_devices;
#[cfg(feature = "uac2")]
pub use device::{DeviceCapabilities, DeviceIdentification, DeviceInfo, DeviceMetadata, Uac2Device};
#[cfg(feature = "uac2")]
pub use error::Uac2Error;
#[cfg(feature = "uac2")]
pub use registry::{DeviceKey, DeviceRegistry};
