//! Custom USB Audio Class 2.0 (UAC 2.0) support for DAC/AMP detection and bit-perfect playback.

#[cfg(feature = "uac2")]
mod audio_format;
#[cfg(feature = "uac2")]
mod audio_pipeline;
#[cfg(feature = "uac2")]
mod audio_sink;
#[cfg(feature = "uac2")]
mod backend;
#[cfg(feature = "uac2")]
mod capabilities;
#[cfg(feature = "uac2")]
mod format_negotiation;
#[cfg(feature = "uac2")]
pub mod constants;
#[cfg(feature = "uac2")]
mod control_requests;
#[cfg(feature = "uac2")]
mod descriptors;
#[cfg(feature = "uac2")]
mod device;
#[cfg(feature = "uac2")]
mod device_classifier;
#[cfg(feature = "uac2")]
mod device_enumeration;
#[cfg(feature = "uac2")]
mod device_info_extractor;
#[cfg(feature = "uac2")]
mod endpoint;
#[cfg(feature = "uac2")]
mod connection_manager;
#[cfg(feature = "uac2")]
mod error;
#[cfg(feature = "uac2")]
mod error_recovery;
#[cfg(feature = "uac2")]
mod fallback_handler;
#[cfg(feature = "uac2")]
mod logging;
#[cfg(feature = "uac2")]
mod registry;
#[cfg(feature = "uac2")]
mod ring_buffer;
#[cfg(feature = "uac2")]
mod stream_config;
#[cfg(feature = "uac2")]
mod stream_setup;
#[cfg(feature = "uac2")]
mod transfer;
#[cfg(feature = "uac2")]
mod transfer_buffer;
#[cfg(feature = "uac2")]
mod transfer_manager;

#[cfg(all(test, feature = "uac2"))]
mod tests;

#[cfg(feature = "uac2")]
pub use audio_format::{
    AudioFormat, BitDepth, ChannelConfig, FormatNegotiator, FormatType, SampleRate,
};
#[cfg(feature = "uac2")]
pub use audio_pipeline::{
    AudioPipeline, BitDepthConverter, FormatConverter, PassthroughConverter, SampleRateConverter,
};
#[cfg(feature = "uac2")]
pub use audio_sink::Uac2AudioSink;
#[cfg(feature = "uac2")]
pub use backend::{AudioBackend, Uac2Backend};
#[cfg(feature = "uac2")]
pub use capabilities::{
    CapabilityDetector, ControlCapabilities, DeviceCapabilities, DeviceType, FormatMatcher,
    PowerCapabilities,
};
#[cfg(feature = "uac2")]
pub use format_negotiation::{
    FormatMismatchHandler, FormatNegotiationEngine, FormatNegotiationStrategy,
};
#[cfg(feature = "uac2")]
pub use device_classifier::{
    AudioRequirements, DeviceClassifier, DeviceMatchingLogic, FormatClass, PowerClass,
};
#[cfg(feature = "uac2")]
pub use device_info_extractor::{DeviceInfoExtractor, StringDescriptorCache};
#[cfg(feature = "uac2")]
pub use control_requests::{
    ControlRequest, ControlRequestBuilder, ControlRequestType, ControlSelector, MuteControl,
    SamplingFreqControl, VolumeControl,
};
#[cfg(feature = "uac2")]
pub use descriptors::{
    parse_ac_interface_header, parse_as_interface_general, parse_feature_unit, parse_format_type_i,
    parse_format_type_ii, parse_format_type_iii, parse_iad, parse_input_terminal,
    parse_output_terminal, AcInterfaceHeader, AsInterfaceGeneral, AudioControlDescriptor,
    AudioControlParser, AudioStreamingDescriptor, AudioStreamingParser, DescriptorFactory,
    DescriptorIter, DescriptorKind, DescriptorParser, FeatureUnit, FeatureUnitBuilder, FormatTypeI,
    FormatTypeIBuilder, FormatTypeII, FormatTypeIIBuilder, FormatTypeIII, Iad, InputTerminal,
    OutputTerminal,
};
#[cfg(feature = "uac2")]
pub use device::{DeviceIdentification, DeviceInfo, DeviceMetadata, Uac2Device};
#[cfg(feature = "uac2")]
pub use device_enumeration::enumerate_uac2_devices;
#[cfg(feature = "uac2")]
pub use connection_manager::{ConnectionManager, ConnectionState};
#[cfg(feature = "uac2")]
pub use error::Uac2Error;
#[cfg(feature = "uac2")]
pub use error_recovery::{ErrorRecovery, Recoverable, RecoveryStrategy, ReconnectionManager};
#[cfg(feature = "uac2")]
pub use fallback_handler::{FallbackAudioOutput, FallbackHandler};
#[cfg(feature = "uac2")]
pub use logging::{init_logging, LogConfig, LogContext, LogLevel};
#[cfg(feature = "uac2")]
pub use registry::{DeviceKey, DeviceRegistry};
#[cfg(feature = "uac2")]
pub use ring_buffer::{AdaptiveBuffer, AudioBuffer, LockFreeRingBuffer, RingBuffer};
#[cfg(feature = "uac2")]
pub use stream_config::{FormatSelector, StreamConfig, StreamConfigBuilder};
#[cfg(feature = "uac2")]
pub use stream_setup::{StreamActivator, StreamSetup, StreamSetupBuilder};
#[cfg(feature = "uac2")]
pub use transfer::{
    IsochronousTransfer, TransferContext, TransferError, TransferStats, TransferStatus,
    TransferSynchronizer,
};
#[cfg(feature = "uac2")]
pub use transfer_buffer::{BufferManager, BufferPool, TransferBuffer};
#[cfg(feature = "uac2")]
pub use transfer_manager::{TransferManager, TransferRecovery};
