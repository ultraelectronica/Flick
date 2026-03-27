use crate::uac2::device::Uac2Device;
use crate::uac2::error::{Result, Uac2Error};
use crate::uac2::error_recovery::ReconnectionManager;
use rusb::{Device, UsbContext};
use std::sync::{Arc, Mutex};
use tracing::{debug, error, info, warn};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
    Failed,
}

pub struct ConnectionManager<T: UsbContext> {
    device: Arc<Mutex<Option<Uac2Device<T>>>>,
    state: Arc<Mutex<ConnectionState>>,
    reconnection_manager: Arc<Mutex<ReconnectionManager>>,
    auto_reconnect: bool,
}

impl<T: UsbContext> ConnectionManager<T> {
    pub fn new(auto_reconnect: bool) -> Self {
        Self {
            device: Arc::new(Mutex::new(None)),
            state: Arc::new(Mutex::new(ConnectionState::Disconnected)),
            reconnection_manager: Arc::new(Mutex::new(ReconnectionManager::new())),
            auto_reconnect,
        }
    }

    pub fn connect(&self, usb_device: &Device<T>) -> Result<()> {
        self.set_state(ConnectionState::Connecting);

        match Uac2Device::from_usb_device(usb_device) {
            Ok(device) => {
                info!(
                    "Connected to device: {} (VID: {:04x}, PID: {:04x})",
                    device.metadata.product_name,
                    device.identification.vendor_id,
                    device.identification.product_id
                );

                *self.device.lock().unwrap() = Some(device);
                self.set_state(ConnectionState::Connected);
                self.reconnection_manager.lock().unwrap().reset();
                Ok(())
            }
            Err(e) => {
                error!("Failed to connect to device: {}", e);
                self.set_state(ConnectionState::Failed);
                Err(e.with_context("Device connection failed"))
            }
        }
    }

    pub fn disconnect(&self) {
        debug!("Disconnecting device");
        *self.device.lock().unwrap() = None;
        self.set_state(ConnectionState::Disconnected);
    }

    pub fn handle_disconnection(&self) -> Result<()> {
        warn!("Device disconnected");
        self.set_state(ConnectionState::Disconnected);
        *self.device.lock().unwrap() = None;

        if self.auto_reconnect {
            info!("Auto-reconnect enabled, will attempt reconnection");
            Ok(())
        } else {
            Err(Uac2Error::DeviceDisconnected)
        }
    }

    pub fn attempt_reconnect(&self, usb_device: &Device<T>) -> Result<()> {
        if !self.auto_reconnect {
            return Err(Uac2Error::DeviceDisconnected);
        }

        self.set_state(ConnectionState::Reconnecting);

        self.reconnection_manager
            .lock()
            .unwrap()
            .attempt_reconnect(|| self.connect(usb_device))
    }

    pub fn state(&self) -> ConnectionState {
        *self.state.lock().unwrap()
    }

    pub fn is_connected(&self) -> bool {
        matches!(self.state(), ConnectionState::Connected)
    }

    pub fn device(&self) -> Arc<Mutex<Option<Uac2Device<T>>>> {
        Arc::clone(&self.device)
    }

    pub fn reconnect_attempts(&self) -> usize {
        self.reconnection_manager
            .lock()
            .unwrap()
            .reconnect_attempts()
    }

    fn set_state(&self, state: ConnectionState) {
        let mut current_state = self.state.lock().unwrap();
        if *current_state != state {
            debug!(
                "Connection state changed: {:?} -> {:?}",
                *current_state, state
            );
            *current_state = state;
        }
    }
}

impl<T: UsbContext> Clone for ConnectionManager<T> {
    fn clone(&self) -> Self {
        Self {
            device: Arc::clone(&self.device),
            state: Arc::clone(&self.state),
            reconnection_manager: Arc::clone(&self.reconnection_manager),
            auto_reconnect: self.auto_reconnect,
        }
    }
}
