use crate::uac2::error::Uac2Error;
use crate::uac2::stream_config::StreamConfig;
use crate::uac2::transfer_buffer::{BufferManager, TransferBuffer};
use rusb::{DeviceHandle, UsbContext};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tracing::{debug, info, trace, warn};

const TRANSFER_TIMEOUT_MS: u64 = 1000;
const MAX_RETRY_COUNT: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferStatus {
    Pending,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferError {
    Timeout,
    Overflow,
    Underflow,
    Stall,
    NoDevice,
    Other,
}

impl From<rusb::Error> for TransferError {
    fn from(err: rusb::Error) -> Self {
        match err {
            rusb::Error::Timeout => Self::Timeout,
            rusb::Error::Overflow => Self::Overflow,
            rusb::Error::Pipe => Self::Stall,
            rusb::Error::NoDevice => Self::NoDevice,
            _ => Self::Other,
        }
    }
}

pub struct TransferContext {
    pub buffer_index: usize,
    pub submitted_at: Instant,
    pub retry_count: usize,
}

impl TransferContext {
    pub fn new(buffer_index: usize) -> Self {
        Self {
            buffer_index,
            submitted_at: Instant::now(),
            retry_count: 0,
        }
    }

    pub fn elapsed(&self) -> Duration {
        self.submitted_at.elapsed()
    }

    pub fn should_retry(&self) -> bool {
        self.retry_count < MAX_RETRY_COUNT
    }

    pub fn increment_retry(&mut self) {
        self.retry_count += 1;
    }
}

pub struct TransferStats {
    pub total_submitted: u64,
    pub total_completed: u64,
    pub total_failed: u64,
    pub total_retried: u64,
    pub underruns: u64,
    pub overruns: u64,
}

impl TransferStats {
    pub fn new() -> Self {
        Self {
            total_submitted: 0,
            total_completed: 0,
            total_failed: 0,
            total_retried: 0,
            underruns: 0,
            overruns: 0,
        }
    }

    pub fn record_submit(&mut self) {
        self.total_submitted += 1;
    }

    pub fn record_completion(&mut self) {
        self.total_completed += 1;
    }

    pub fn record_failure(&mut self) {
        self.total_failed += 1;
    }

    pub fn record_retry(&mut self) {
        self.total_retried += 1;
    }

    pub fn record_underrun(&mut self) {
        self.underruns += 1;
    }

    pub fn record_overrun(&mut self) {
        self.overruns += 1;
    }

    pub fn success_rate(&self) -> f64 {
        if self.total_submitted == 0 {
            return 0.0;
        }
        (self.total_completed as f64) / (self.total_submitted as f64)
    }
}

impl Default for TransferStats {
    fn default() -> Self {
        Self::new()
    }
}

pub struct IsochronousTransfer<T: UsbContext> {
    handle: Arc<DeviceHandle<T>>,
    endpoint: u8,
    buffer_manager: Arc<Mutex<BufferManager>>,
    stats: Arc<Mutex<TransferStats>>,
    active_transfers: Arc<Mutex<Vec<TransferContext>>>,
}

impl<T: UsbContext> IsochronousTransfer<T> {
    pub fn new(
        handle: Arc<DeviceHandle<T>>,
        endpoint: u8,
        config: StreamConfig,
    ) -> Result<Self, Uac2Error> {
        info!(
            endpoint = format!("{:#04x}", endpoint),
            packet_size = config.packet_size,
            "Creating isochronous transfer"
        );

        let buffer_manager = Arc::new(Mutex::new(BufferManager::from_config(&config)?));
        let stats = Arc::new(Mutex::new(TransferStats::new()));
        let active_transfers = Arc::new(Mutex::new(Vec::new()));

        Ok(Self {
            handle,
            endpoint,
            buffer_manager,
            stats,
            active_transfers,
        })
    }

    pub fn submit_buffer(&self, data: Vec<u8>) -> Result<(), Uac2Error> {
        let mut buffer_manager = self.buffer_manager.lock().unwrap();

        if !buffer_manager.has_available() {
            self.stats.lock().unwrap().record_overrun();
            warn!("Buffer overrun detected - no available buffers");
            return Err(Uac2Error::BufferOverflow);
        }

        let (buffer_index, buffer) = buffer_manager
            .acquire_buffer()
            .ok_or(Uac2Error::BufferOverflow)?;

        let buffer_capacity = buffer.capacity();

        if data.len() > buffer_capacity {
            buffer_manager.release_buffer(buffer_index)?;
            warn!(
                data_size = data.len(),
                buffer_capacity = buffer_capacity,
                "Data exceeds buffer capacity"
            );
            return Err(Uac2Error::BufferOverflow);
        }

        trace!(
            buffer_index = buffer_index,
            data_size = data.len(),
            "Submitting transfer buffer"
        );

        let transfer_buffer = TransferBuffer::with_data(data);
        let context = TransferContext::new(buffer_index);

        self.active_transfers.lock().unwrap().push(context);
        self.stats.lock().unwrap().record_submit();

        self.perform_transfer(transfer_buffer.as_slice(), buffer_index)?;

        Ok(())
    }

    fn perform_transfer(&self, data: &[u8], buffer_index: usize) -> Result<(), Uac2Error> {
        let timeout = Duration::from_millis(TRANSFER_TIMEOUT_MS);

        let result = self.handle.write_bulk(self.endpoint, data, timeout);

        match result {
            Ok(bytes_written) => {
                trace!(
                    buffer_index = buffer_index,
                    bytes_written = bytes_written,
                    "Transfer completed successfully"
                );
                self.handle_completion(buffer_index, TransferStatus::Completed)?;
                Ok(())
            }
            Err(e) => {
                let transfer_error = TransferError::from(e);
                warn!(
                    buffer_index = buffer_index,
                    error = ?transfer_error,
                    "Transfer failed"
                );
                self.handle_error(buffer_index, transfer_error)?;
                Err(Uac2Error::TransferFailed(format!("{:?}", transfer_error)))
            }
        }
    }

    fn handle_completion(
        &self,
        buffer_index: usize,
        status: TransferStatus,
    ) -> Result<(), Uac2Error> {
        let mut active = self.active_transfers.lock().unwrap();
        if let Some(pos) = active
            .iter()
            .position(|ctx| ctx.buffer_index == buffer_index)
        {
            active.remove(pos);
        }

        if status == TransferStatus::Completed {
            self.stats.lock().unwrap().record_completion();
        }

        self.buffer_manager
            .lock()
            .unwrap()
            .release_buffer(buffer_index)?;

        Ok(())
    }

    fn handle_error(&self, buffer_index: usize, error: TransferError) -> Result<(), Uac2Error> {
        let mut active = self.active_transfers.lock().unwrap();
        let context_pos = active
            .iter()
            .position(|ctx| ctx.buffer_index == buffer_index);

        if let Some(pos) = context_pos {
            let mut context = active.remove(pos);

            if context.should_retry() && error != TransferError::NoDevice {
                context.increment_retry();
                self.stats.lock().unwrap().record_retry();
                debug!(
                    buffer_index = buffer_index,
                    retry_count = context.retry_count,
                    "Retrying transfer"
                );
                active.push(context);
                return Ok(());
            }
        }

        self.stats.lock().unwrap().record_failure();
        self.buffer_manager
            .lock()
            .unwrap()
            .release_buffer(buffer_index)?;

        Ok(())
    }

    pub fn available_buffers(&self) -> usize {
        self.buffer_manager.lock().unwrap().available_count()
    }

    pub fn active_transfers(&self) -> usize {
        self.active_transfers.lock().unwrap().len()
    }

    pub fn stats(&self) -> TransferStats {
        let stats = self.stats.lock().unwrap();
        let result = TransferStats {
            total_submitted: stats.total_submitted,
            total_completed: stats.total_completed,
            total_failed: stats.total_failed,
            total_retried: stats.total_retried,
            underruns: stats.underruns,
            overruns: stats.overruns,
        };

        debug!(
            submitted = result.total_submitted,
            completed = result.total_completed,
            failed = result.total_failed,
            retried = result.total_retried,
            success_rate = format!("{:.2}%", result.success_rate() * 100.0),
            "Transfer statistics"
        );

        result
    }

    pub fn reset_stats(&self) {
        *self.stats.lock().unwrap() = TransferStats::new();
    }
}

pub struct TransferSynchronizer {
    last_transfer: Option<Instant>,
    target_interval: Duration,
}

impl TransferSynchronizer {
    pub fn new(sample_rate: u32) -> Self {
        let interval_us = 1_000_000 / sample_rate;
        let target_interval = Duration::from_micros(interval_us as u64);

        Self {
            last_transfer: None,
            target_interval,
        }
    }

    pub fn wait_for_next(&mut self) {
        if let Some(last) = self.last_transfer {
            let elapsed = last.elapsed();
            if elapsed < self.target_interval {
                let wait_time = self.target_interval - elapsed;
                std::thread::sleep(wait_time);
            }
        }
        self.last_transfer = Some(Instant::now());
    }

    pub fn reset(&mut self) {
        self.last_transfer = None;
    }
}
