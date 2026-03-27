use crate::uac2::audio_format::AudioFormat;
use crate::uac2::capabilities::DeviceCapabilities;
use crate::uac2::endpoint::{EndpointDescriptor, EndpointManager, EndpointSelector};
use crate::uac2::error::Uac2Error;
use crate::uac2::stream_config::{FormatSelector, StreamConfig, StreamConfigBuilder};
use rusb::{Device, DeviceHandle, UsbContext};

pub struct StreamSetup {
    pub config: StreamConfig,
    pub endpoint: EndpointDescriptor,
    pub interface_number: u8,
    pub alt_setting: u8,
}

impl StreamSetup {
    pub fn new(
        config: StreamConfig,
        endpoint: EndpointDescriptor,
        interface_number: u8,
        alt_setting: u8,
    ) -> Self {
        Self {
            config,
            endpoint,
            interface_number,
            alt_setting,
        }
    }
}

pub struct StreamSetupBuilder<'a, T: UsbContext> {
    device: &'a Device<T>,
    capabilities: &'a DeviceCapabilities,
    source_format: Option<&'a AudioFormat>,
    interface_number: u8,
}

impl<'a, T: UsbContext> StreamSetupBuilder<'a, T> {
    pub fn new(
        device: &'a Device<T>,
        capabilities: &'a DeviceCapabilities,
        interface_number: u8,
    ) -> Self {
        Self {
            device,
            capabilities,
            source_format: None,
            interface_number,
        }
    }

    pub fn with_source_format(mut self, format: &'a AudioFormat) -> Self {
        self.source_format = Some(format);
        self
    }

    pub fn build(self) -> Result<StreamSetup, Uac2Error> {
        let selected_format =
            FormatSelector::select_optimal(self.capabilities, self.source_format)?;

        let sample_rate = selected_format
            .sample_rates
            .iter()
            .max()
            .copied()
            .ok_or(Uac2Error::NoSupportedFormats)?;

        let (endpoint, alt_setting) = self.find_suitable_endpoint(&selected_format)?;

        let config = StreamConfigBuilder::new()
            .sample_rate(sample_rate)
            .bit_depth(selected_format.bit_depth)
            .channels(selected_format.channels)
            .endpoint_address(endpoint.address)
            .build()?;

        EndpointManager::validate_endpoint(&endpoint, &config)?;

        Ok(StreamSetup::new(
            config,
            endpoint,
            self.interface_number,
            alt_setting,
        ))
    }

    fn find_suitable_endpoint(
        &self,
        format: &AudioFormat,
    ) -> Result<(EndpointDescriptor, u8), Uac2Error> {
        let sample_rate = format
            .sample_rates
            .iter()
            .max()
            .copied()
            .ok_or(Uac2Error::NoSupportedFormats)?;

        let temp_config = StreamConfigBuilder::new()
            .sample_rate(sample_rate)
            .bit_depth(format.bit_depth)
            .channels(format.channels)
            .endpoint_address(0)
            .build()?;

        EndpointSelector::select_best(self.device, self.interface_number, &temp_config)
    }
}

pub struct StreamActivator;

impl StreamActivator {
    pub fn activate<T: UsbContext>(
        handle: &DeviceHandle<T>,
        setup: &StreamSetup,
    ) -> Result<(), Uac2Error> {
        EndpointManager::configure_endpoint(handle, setup.interface_number, setup.alt_setting)?;

        Ok(())
    }

    pub fn deactivate<T: UsbContext>(
        handle: &DeviceHandle<T>,
        interface_number: u8,
    ) -> Result<(), Uac2Error> {
        EndpointManager::configure_endpoint(handle, interface_number, 0)?;
        Ok(())
    }
}
