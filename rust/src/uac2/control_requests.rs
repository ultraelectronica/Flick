//! UAC 2.0 Control Requests implementation.
//! Follows DRY and SOLID principles: type-safe control requests with builder pattern.

use crate::uac2::error::Uac2Error;
use rusb::{DeviceHandle, UsbContext};

const USB_DIR_IN: u8 = 0x80;
const USB_DIR_OUT: u8 = 0x00;
const USB_TYPE_CLASS: u8 = 0x20;
#[allow(dead_code)]
const USB_TYPE_VENDOR: u8 = 0x40;
const USB_RECIP_INTERFACE: u8 = 0x01;
const USB_RECIP_ENDPOINT: u8 = 0x02;

pub const UAC2_REQUEST_GET_CUR: u8 = 0x81;
pub const UAC2_REQUEST_GET_MIN: u8 = 0x82;
pub const UAC2_REQUEST_GET_MAX: u8 = 0x83;
pub const UAC2_REQUEST_GET_RES: u8 = 0x84;
pub const UAC2_REQUEST_SET_CUR: u8 = 0x01;
pub const UAC2_REQUEST_SET_MIN: u8 = 0x02;
pub const UAC2_REQUEST_SET_MAX: u8 = 0x03;
pub const UAC2_REQUEST_SET_RES: u8 = 0x04;

pub const UAC2_CS_CONTROL_VOLUME: u16 = 0x0100;
pub const UAC2_CS_CONTROL_MUTE: u16 = 0x0101;
pub const UAC2_CS_CONTROL_BASS: u16 = 0x0200;
pub const UAC2_CS_CONTROL_MID: u16 = 0x0300;
pub const UAC2_CS_CONTROL_TREBLE: u16 = 0x0400;
pub const UAC2_CS_CONTROL_GRAPHIC_EQUALIZER: u16 = 0x0500;
pub const UAC2_CS_CONTROL_AUTOMATIC_GAIN: u16 = 0x0600;
pub const UAC2_CS_CONTROL_DELAY: u16 = 0x0700;
pub const UAC2_CS_CONTROL_BASS_BOOST: u16 = 0x0800;
pub const UAC2_CS_CONTROL_LOUDNESS: u16 = 0x0900;
pub const UAC2_CS_CONTROL_INPUT_GAIN: u16 = 0x0102;
pub const UAC2_CS_CONTROL_INPUT_GAIN_PAD: u16 = 0x0103;
pub const UAC2_CS_CONTROL_PHYSICAL_WNDW: u16 = 0x0104;
pub const UAC2_CS_CONTROL_LOGICAL_WNDW: u16 = 0x0105;
pub const UAC2_CS_CONTROL_SAMPLING_FREQ: u16 = 0x0106;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlRequestType {
    GetCur,
    GetMin,
    GetMax,
    GetRes,
    SetCur,
    SetMin,
    SetMax,
    SetRes,
}

impl ControlRequestType {
    pub fn request_code(&self) -> u8 {
        match self {
            ControlRequestType::GetCur => UAC2_REQUEST_GET_CUR,
            ControlRequestType::GetMin => UAC2_REQUEST_GET_MIN,
            ControlRequestType::GetMax => UAC2_REQUEST_GET_MAX,
            ControlRequestType::GetRes => UAC2_REQUEST_GET_RES,
            ControlRequestType::SetCur => UAC2_REQUEST_SET_CUR,
            ControlRequestType::SetMin => UAC2_REQUEST_SET_MIN,
            ControlRequestType::SetMax => UAC2_REQUEST_SET_MAX,
            ControlRequestType::SetRes => UAC2_REQUEST_SET_RES,
        }
    }

    pub fn direction(&self) -> u8 {
        match self {
            ControlRequestType::GetCur
            | ControlRequestType::GetMin
            | ControlRequestType::GetMax
            | ControlRequestType::GetRes => USB_DIR_IN,
            ControlRequestType::SetCur
            | ControlRequestType::SetMin
            | ControlRequestType::SetMax
            | ControlRequestType::SetRes => USB_DIR_OUT,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlSelector {
    Volume,
    Mute,
    Bass,
    Mid,
    Treble,
    GraphicEqualizer,
    AutomaticGain,
    Delay,
    BassBoost,
    Loudness,
    InputGain,
    InputGainPad,
    PhysicalWndw,
    LogicalWndw,
    SamplingFreq,
}

impl ControlSelector {
    pub fn code(&self) -> u16 {
        match self {
            ControlSelector::Volume => UAC2_CS_CONTROL_VOLUME,
            ControlSelector::Mute => UAC2_CS_CONTROL_MUTE,
            ControlSelector::Bass => UAC2_CS_CONTROL_BASS,
            ControlSelector::Mid => UAC2_CS_CONTROL_MID,
            ControlSelector::Treble => UAC2_CS_CONTROL_TREBLE,
            ControlSelector::GraphicEqualizer => UAC2_CS_CONTROL_GRAPHIC_EQUALIZER,
            ControlSelector::AutomaticGain => UAC2_CS_CONTROL_AUTOMATIC_GAIN,
            ControlSelector::Delay => UAC2_CS_CONTROL_DELAY,
            ControlSelector::BassBoost => UAC2_CS_CONTROL_BASS_BOOST,
            ControlSelector::Loudness => UAC2_CS_CONTROL_LOUDNESS,
            ControlSelector::InputGain => UAC2_CS_CONTROL_INPUT_GAIN,
            ControlSelector::InputGainPad => UAC2_CS_CONTROL_INPUT_GAIN_PAD,
            ControlSelector::PhysicalWndw => UAC2_CS_CONTROL_PHYSICAL_WNDW,
            ControlSelector::LogicalWndw => UAC2_CS_CONTROL_LOGICAL_WNDW,
            ControlSelector::SamplingFreq => UAC2_CS_CONTROL_SAMPLING_FREQ,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlRecipient {
    Interface,
    Endpoint,
}

impl ControlRecipient {
    pub fn code(&self) -> u8 {
        match self {
            ControlRecipient::Interface => USB_RECIP_INTERFACE,
            ControlRecipient::Endpoint => USB_RECIP_ENDPOINT,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ControlRequest {
    request_type: ControlRequestType,
    selector: ControlSelector,
    recipient: ControlRecipient,
    interface: u8,
    entity_id: u8,
    channel: u16,
    #[allow(dead_code)]
    value: u32,
    data: Vec<u8>,
}

impl ControlRequest {
    pub fn builder() -> ControlRequestBuilder {
        ControlRequestBuilder::new()
    }

    pub fn execute<T: UsbContext>(&self, handle: &DeviceHandle<T>) -> Result<Vec<u8>, Uac2Error> {
        let request_type = self.request_type.direction() | USB_TYPE_CLASS | self.recipient.code();

        let w_value = self.selector.code() | (self.channel & 0xFF);
        let w_index = (self.interface as u16) | ((self.entity_id as u16) << 8);

        let data = if self.request_type.direction() == USB_DIR_IN {
            let mut buf = vec![0u8; self.data.len()];
            let transferred = handle.read_control(
                request_type,
                self.request_type.request_code(),
                w_value,
                w_index,
                &mut buf,
                std::time::Duration::from_secs(1),
            )?;
            buf.truncate(transferred);
            buf
        } else {
            handle.write_control(
                request_type,
                self.request_type.request_code(),
                w_value,
                w_index,
                &self.data,
                std::time::Duration::from_secs(1),
            )?;
            self.data.clone()
        };

        Ok(data)
    }

    pub fn request_type(&self) -> ControlRequestType {
        self.request_type
    }

    pub fn selector(&self) -> ControlSelector {
        self.selector
    }
}

pub struct ControlRequestBuilder {
    request_type: Option<ControlRequestType>,
    selector: Option<ControlSelector>,
    recipient: Option<ControlRecipient>,
    interface: Option<u8>,
    entity_id: Option<u8>,
    channel: Option<u16>,
    value: Option<u32>,
    data: Option<Vec<u8>>,
}

impl ControlRequestBuilder {
    pub fn new() -> Self {
        Self {
            request_type: None,
            selector: None,
            recipient: Some(ControlRecipient::Interface),
            interface: None,
            entity_id: None,
            channel: Some(0),
            value: None,
            data: None,
        }
    }

    pub fn request_type(mut self, request_type: ControlRequestType) -> Self {
        self.request_type = Some(request_type);
        self
    }

    pub fn selector(mut self, selector: ControlSelector) -> Self {
        self.selector = Some(selector);
        self
    }

    pub fn recipient(mut self, recipient: ControlRecipient) -> Self {
        self.recipient = Some(recipient);
        self
    }

    pub fn interface(mut self, interface: u8) -> Self {
        self.interface = Some(interface);
        self
    }

    pub fn entity_id(mut self, entity_id: u8) -> Self {
        self.entity_id = Some(entity_id);
        self
    }

    pub fn channel(mut self, channel: u16) -> Self {
        self.channel = Some(channel);
        self
    }

    pub fn value(mut self, value: u32) -> Self {
        self.value = Some(value);
        self
    }

    pub fn data(mut self, data: Vec<u8>) -> Self {
        self.data = Some(data);
        self
    }

    pub fn build(self) -> Result<ControlRequest, Uac2Error> {
        let request_type = self
            .request_type
            .ok_or_else(|| Uac2Error::InvalidDescriptor("request_type is required".to_string()))?;
        let selector = self
            .selector
            .ok_or_else(|| Uac2Error::InvalidDescriptor("selector is required".to_string()))?;
        let recipient = self
            .recipient
            .ok_or_else(|| Uac2Error::InvalidDescriptor("recipient is required".to_string()))?;
        let interface = self
            .interface
            .ok_or_else(|| Uac2Error::InvalidDescriptor("interface is required".to_string()))?;
        let entity_id = self
            .entity_id
            .ok_or_else(|| Uac2Error::InvalidDescriptor("entity_id is required".to_string()))?;
        let channel = self.channel.unwrap_or(0);
        let value = self.value.unwrap_or(0);

        let data = self.data.unwrap_or_else(|| match request_type {
            ControlRequestType::GetCur
            | ControlRequestType::GetMin
            | ControlRequestType::GetMax
            | ControlRequestType::GetRes => vec![0u8; 4],
            ControlRequestType::SetCur
            | ControlRequestType::SetMin
            | ControlRequestType::SetMax
            | ControlRequestType::SetRes => {
                vec![
                    (value & 0xFF) as u8,
                    ((value >> 8) & 0xFF) as u8,
                    ((value >> 16) & 0xFF) as u8,
                    ((value >> 24) & 0xFF) as u8,
                ]
            }
        });

        Ok(ControlRequest {
            request_type,
            selector,
            recipient,
            interface,
            entity_id,
            channel,
            value,
            data,
        })
    }
}

impl Default for ControlRequestBuilder {
    fn default() -> Self {
        Self::new()
    }
}

pub struct VolumeControl {
    handle: DeviceHandle<rusb::Context>,
    interface: u8,
    entity_id: u8,
    channel: u16,
}

impl VolumeControl {
    pub fn new(
        handle: DeviceHandle<rusb::Context>,
        interface: u8,
        entity_id: u8,
        channel: u16,
    ) -> Self {
        Self {
            handle,
            interface,
            entity_id,
            channel,
        }
    }

    pub fn get_volume(&self) -> Result<i32, Uac2Error> {
        let request = ControlRequest::builder()
            .request_type(ControlRequestType::GetCur)
            .selector(ControlSelector::Volume)
            .interface(self.interface)
            .entity_id(self.entity_id)
            .channel(self.channel)
            .build()?;

        let data = request.execute(&self.handle)?;
        Ok(i32::from_le_bytes([data[0], data[1], data[2], data[3]]))
    }

    pub fn set_volume(&self, volume: i32) -> Result<(), Uac2Error> {
        let request = ControlRequest::builder()
            .request_type(ControlRequestType::SetCur)
            .selector(ControlSelector::Volume)
            .interface(self.interface)
            .entity_id(self.entity_id)
            .channel(self.channel)
            .value(volume as u32)
            .build()?;

        request.execute(&self.handle)?;
        Ok(())
    }

    pub fn get_volume_range(&self) -> Result<(i32, i32, i32), Uac2Error> {
        let min_request = ControlRequest::builder()
            .request_type(ControlRequestType::GetMin)
            .selector(ControlSelector::Volume)
            .interface(self.interface)
            .entity_id(self.entity_id)
            .channel(self.channel)
            .build()?;

        let max_request = ControlRequest::builder()
            .request_type(ControlRequestType::GetMax)
            .selector(ControlSelector::Volume)
            .interface(self.interface)
            .entity_id(self.entity_id)
            .channel(self.channel)
            .build()?;

        let res_request = ControlRequest::builder()
            .request_type(ControlRequestType::GetRes)
            .selector(ControlSelector::Volume)
            .interface(self.interface)
            .entity_id(self.entity_id)
            .channel(self.channel)
            .build()?;

        let min_data = min_request.execute(&self.handle)?;
        let max_data = max_request.execute(&self.handle)?;
        let res_data = res_request.execute(&self.handle)?;

        let min = i32::from_le_bytes([min_data[0], min_data[1], min_data[2], min_data[3]]);
        let max = i32::from_le_bytes([max_data[0], max_data[1], max_data[2], max_data[3]]);
        let res = i32::from_le_bytes([res_data[0], res_data[1], res_data[2], res_data[3]]);

        Ok((min, max, res))
    }
}

pub struct MuteControl {
    handle: DeviceHandle<rusb::Context>,
    interface: u8,
    entity_id: u8,
    channel: u16,
}

impl MuteControl {
    pub fn new(
        handle: DeviceHandle<rusb::Context>,
        interface: u8,
        entity_id: u8,
        channel: u16,
    ) -> Self {
        Self {
            handle,
            interface,
            entity_id,
            channel,
        }
    }

    pub fn get_mute(&self) -> Result<bool, Uac2Error> {
        let request = ControlRequest::builder()
            .request_type(ControlRequestType::GetCur)
            .selector(ControlSelector::Mute)
            .interface(self.interface)
            .entity_id(self.entity_id)
            .channel(self.channel)
            .build()?;

        let data = request.execute(&self.handle)?;
        Ok(data[0] != 0)
    }

    pub fn set_mute(&self, mute: bool) -> Result<(), Uac2Error> {
        let request = ControlRequest::builder()
            .request_type(ControlRequestType::SetCur)
            .selector(ControlSelector::Mute)
            .interface(self.interface)
            .entity_id(self.entity_id)
            .channel(self.channel)
            .data(vec![mute as u8])
            .build()?;

        request.execute(&self.handle)?;
        Ok(())
    }
}

pub struct SamplingFreqControl {
    handle: DeviceHandle<rusb::Context>,
    interface: u8,
    endpoint: u8,
}

impl SamplingFreqControl {
    pub fn new(handle: DeviceHandle<rusb::Context>, interface: u8, endpoint: u8) -> Self {
        Self {
            handle,
            interface,
            endpoint,
        }
    }

    pub fn get_sampling_freq(&self) -> Result<u32, Uac2Error> {
        let request = ControlRequest::builder()
            .request_type(ControlRequestType::GetCur)
            .selector(ControlSelector::SamplingFreq)
            .recipient(ControlRecipient::Endpoint)
            .interface(self.interface)
            .entity_id(self.endpoint)
            .build()?;

        let data = request.execute(&self.handle)?;
        Ok(u32::from_le_bytes([data[0], data[1], data[2], data[3]]))
    }

    pub fn set_sampling_freq(&self, frequency: u32) -> Result<(), Uac2Error> {
        let request = ControlRequest::builder()
            .request_type(ControlRequestType::SetCur)
            .selector(ControlSelector::SamplingFreq)
            .recipient(ControlRecipient::Endpoint)
            .interface(self.interface)
            .entity_id(self.endpoint)
            .value(frequency)
            .build()?;

        request.execute(&self.handle)?;
        Ok(())
    }

    pub fn get_sampling_freq_range(&self) -> Result<(u32, u32, u32), Uac2Error> {
        let min_request = ControlRequest::builder()
            .request_type(ControlRequestType::GetMin)
            .selector(ControlSelector::SamplingFreq)
            .recipient(ControlRecipient::Endpoint)
            .interface(self.interface)
            .entity_id(self.endpoint)
            .build()?;

        let max_request = ControlRequest::builder()
            .request_type(ControlRequestType::GetMax)
            .selector(ControlSelector::SamplingFreq)
            .recipient(ControlRecipient::Endpoint)
            .interface(self.interface)
            .entity_id(self.endpoint)
            .build()?;

        let res_request = ControlRequest::builder()
            .request_type(ControlRequestType::GetRes)
            .selector(ControlSelector::SamplingFreq)
            .recipient(ControlRecipient::Endpoint)
            .interface(self.interface)
            .entity_id(self.endpoint)
            .build()?;

        let min_data = min_request.execute(&self.handle)?;
        let max_data = max_request.execute(&self.handle)?;
        let res_data = res_request.execute(&self.handle)?;

        let min = u32::from_le_bytes([min_data[0], min_data[1], min_data[2], min_data[3]]);
        let max = u32::from_le_bytes([max_data[0], max_data[1], max_data[2], max_data[3]]);
        let res = u32::from_le_bytes([res_data[0], res_data[1], res_data[2], res_data[3]]);

        Ok((min, max, res))
    }
}
