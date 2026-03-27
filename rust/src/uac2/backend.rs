use crate::audio::source::SourceProvider;
use crate::uac2::connection_manager::ConnectionManager;
use crate::uac2::fallback_handler::FallbackHandler;
use crate::uac2::{AudioFormat, Uac2AudioSink, Uac2Device, Uac2Error};
use parking_lot::Mutex;
use rusb::UsbContext;
use std::sync::Arc;
use tracing::{error, info};

pub trait AudioBackend: Send + Sync {
    fn start(&mut self, source_provider: Arc<Mutex<SourceProvider>>) -> Result<(), String>;
    fn stop(&mut self) -> Result<(), String>;
    fn is_active(&self) -> bool;
    fn name(&self) -> &str;
}

pub struct Uac2Backend<T: UsbContext + Send + 'static> {
    sink: Option<Uac2AudioSink<T>>,
    device: Arc<Uac2Device<T>>,
    format: AudioFormat,
    active: bool,
    connection_manager: Arc<ConnectionManager<T>>,
    fallback_handler: Arc<Mutex<FallbackHandler>>,
}

impl<T: UsbContext + Send + 'static> Uac2Backend<T> {
    pub fn new(
        device: Arc<Uac2Device<T>>,
        format: AudioFormat,
        connection_manager: Arc<ConnectionManager<T>>,
    ) -> Result<Self, Uac2Error> {
        Ok(Self {
            sink: None,
            device,
            format,
            active: false,
            connection_manager,
            fallback_handler: Arc::new(Mutex::new(FallbackHandler::new())),
        })
    }

    pub fn device(&self) -> &Uac2Device<T> {
        &self.device
    }

    pub fn format(&self) -> &AudioFormat {
        &self.format
    }

    pub fn register_fallback_handler(&self, _handler: Arc<Mutex<FallbackHandler>>) {
        info!("Registering fallback handler for UAC2 backend");
    }
}

impl<T: UsbContext + Send + 'static> AudioBackend for Uac2Backend<T> {
    fn start(&mut self, source_provider: Arc<Mutex<SourceProvider>>) -> Result<(), String> {
        if self.active {
            return Ok(());
        }

        if !self.connection_manager.is_connected() {
            error!("Cannot start UAC2 backend: device not connected");
            return Err("Device not connected".to_string());
        }

        let mut sink = Uac2AudioSink::new(
            Arc::clone(&self.device),
            self.format.clone(),
            Arc::clone(&self.connection_manager),
        )
        .map_err(|e| format!("Failed to create UAC2 sink: {:?}", e))?;

        sink.start(source_provider).map_err(|e| {
            error!("Failed to start UAC2 sink: {:?}", e);
            if e.requires_reconnection() {
                let mut fallback = self.fallback_handler.lock();
                if let Err(fb_err) = fallback.activate_fallback() {
                    error!("Failed to activate fallback: {:?}", fb_err);
                }
            }
            format!("Failed to start UAC2 sink: {:?}", e)
        })?;

        self.sink = Some(sink);
        self.active = true;

        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        if !self.active {
            return Ok(());
        }

        if let Some(mut sink) = self.sink.take() {
            sink.stop()
                .map_err(|e| format!("Failed to stop UAC2 sink: {:?}", e))?;
        }

        self.active = false;
        Ok(())
    }

    fn is_active(&self) -> bool {
        self.active
    }

    fn name(&self) -> &str {
        "UAC2"
    }
}
