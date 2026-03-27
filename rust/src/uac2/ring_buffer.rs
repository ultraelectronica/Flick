use crate::uac2::error::Uac2Error;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

const MIN_BUFFER_SIZE: usize = 4096;
const MAX_BUFFER_SIZE: usize = 1024 * 1024 * 16;

pub trait AudioBuffer: Send + Sync {
    fn write(&mut self, data: &[u8]) -> Result<usize, Uac2Error>;
    fn read(&mut self, output: &mut [u8]) -> Result<usize, Uac2Error>;
    fn available(&self) -> usize;
    fn capacity(&self) -> usize;
    fn reset(&mut self);
}

pub struct RingBuffer {
    buffer: Vec<u8>,
    capacity: usize,
    read_pos: usize,
    write_pos: usize,
    available: usize,
}

impl RingBuffer {
    pub fn new(capacity: usize) -> Result<Self, Uac2Error> {
        if capacity < MIN_BUFFER_SIZE || capacity > MAX_BUFFER_SIZE {
            return Err(Uac2Error::InvalidConfiguration(format!(
                "buffer size must be between {} and {}",
                MIN_BUFFER_SIZE, MAX_BUFFER_SIZE
            )));
        }

        Ok(Self {
            buffer: vec![0u8; capacity],
            capacity,
            read_pos: 0,
            write_pos: 0,
            available: 0,
        })
    }

    pub fn with_latency(
        sample_rate: u32,
        latency_ms: u32,
        frame_size: usize,
    ) -> Result<Self, Uac2Error> {
        let samples = (sample_rate * latency_ms) / 1000;
        let capacity = (samples as usize * frame_size).max(MIN_BUFFER_SIZE);
        Self::new(capacity)
    }

    fn free_space(&self) -> usize {
        self.capacity - self.available
    }

    pub fn is_full(&self) -> bool {
        self.available == self.capacity
    }

    pub fn is_empty(&self) -> bool {
        self.available == 0
    }
}

impl AudioBuffer for RingBuffer {
    fn write(&mut self, data: &[u8]) -> Result<usize, Uac2Error> {
        if data.is_empty() {
            return Ok(0);
        }

        let free = self.free_space();
        if free == 0 {
            return Err(Uac2Error::BufferOverflow);
        }

        let to_write = data.len().min(free);
        let end_pos = self.write_pos + to_write;

        if end_pos <= self.capacity {
            self.buffer[self.write_pos..end_pos].copy_from_slice(&data[..to_write]);
        } else {
            let first_chunk = self.capacity - self.write_pos;
            let second_chunk = to_write - first_chunk;

            self.buffer[self.write_pos..self.capacity].copy_from_slice(&data[..first_chunk]);
            self.buffer[..second_chunk].copy_from_slice(&data[first_chunk..to_write]);
        }

        self.write_pos = (self.write_pos + to_write) % self.capacity;
        self.available += to_write;

        Ok(to_write)
    }

    fn read(&mut self, output: &mut [u8]) -> Result<usize, Uac2Error> {
        if output.is_empty() {
            return Ok(0);
        }

        if self.is_empty() {
            return Err(Uac2Error::BufferUnderflow);
        }

        let to_read = output.len().min(self.available);
        let end_pos = self.read_pos + to_read;

        if end_pos <= self.capacity {
            output[..to_read].copy_from_slice(&self.buffer[self.read_pos..end_pos]);
        } else {
            let first_chunk = self.capacity - self.read_pos;
            let second_chunk = to_read - first_chunk;

            output[..first_chunk].copy_from_slice(&self.buffer[self.read_pos..self.capacity]);
            output[first_chunk..to_read].copy_from_slice(&self.buffer[..second_chunk]);
        }

        self.read_pos = (self.read_pos + to_read) % self.capacity;
        self.available -= to_read;

        Ok(to_read)
    }

    fn available(&self) -> usize {
        self.available
    }

    fn capacity(&self) -> usize {
        self.capacity
    }

    fn reset(&mut self) {
        self.read_pos = 0;
        self.write_pos = 0;
        self.available = 0;
    }
}

pub struct LockFreeRingBuffer {
    buffer: Vec<u8>,
    capacity: usize,
    read_pos: Arc<AtomicUsize>,
    write_pos: Arc<AtomicUsize>,
}

impl LockFreeRingBuffer {
    pub fn new(capacity: usize) -> Result<Self, Uac2Error> {
        if capacity < MIN_BUFFER_SIZE || capacity > MAX_BUFFER_SIZE {
            return Err(Uac2Error::InvalidConfiguration(format!(
                "buffer size must be between {} and {}",
                MIN_BUFFER_SIZE, MAX_BUFFER_SIZE
            )));
        }

        let power_of_two = capacity.next_power_of_two();

        Ok(Self {
            buffer: vec![0u8; power_of_two],
            capacity: power_of_two,
            read_pos: Arc::new(AtomicUsize::new(0)),
            write_pos: Arc::new(AtomicUsize::new(0)),
        })
    }

    fn available_internal(&self) -> usize {
        let write = self.write_pos.load(Ordering::Acquire);
        let read = self.read_pos.load(Ordering::Acquire);
        write.wrapping_sub(read)
    }

    fn free_space(&self) -> usize {
        self.capacity - self.available_internal()
    }
}

impl AudioBuffer for LockFreeRingBuffer {
    fn write(&mut self, data: &[u8]) -> Result<usize, Uac2Error> {
        if data.is_empty() {
            return Ok(0);
        }

        let free = self.free_space();
        if free == 0 {
            return Err(Uac2Error::BufferOverflow);
        }

        let to_write = data.len().min(free);
        let write_pos = self.write_pos.load(Ordering::Acquire);
        let mask = self.capacity - 1;
        let start = write_pos & mask;
        let end = (write_pos + to_write) & mask;

        if start < end {
            self.buffer[start..end].copy_from_slice(&data[..to_write]);
        } else {
            let first_chunk = self.capacity - start;
            let second_chunk = to_write - first_chunk;

            self.buffer[start..self.capacity].copy_from_slice(&data[..first_chunk]);
            self.buffer[..second_chunk].copy_from_slice(&data[first_chunk..to_write]);
        }

        self.write_pos
            .store(write_pos.wrapping_add(to_write), Ordering::Release);

        Ok(to_write)
    }

    fn read(&mut self, output: &mut [u8]) -> Result<usize, Uac2Error> {
        if output.is_empty() {
            return Ok(0);
        }

        let available = self.available_internal();
        if available == 0 {
            return Err(Uac2Error::BufferUnderflow);
        }

        let to_read = output.len().min(available);
        let read_pos = self.read_pos.load(Ordering::Acquire);
        let mask = self.capacity - 1;
        let start = read_pos & mask;
        let end = (read_pos + to_read) & mask;

        if start < end {
            output[..to_read].copy_from_slice(&self.buffer[start..end]);
        } else {
            let first_chunk = self.capacity - start;
            let second_chunk = to_read - first_chunk;

            output[..first_chunk].copy_from_slice(&self.buffer[start..self.capacity]);
            output[first_chunk..to_read].copy_from_slice(&self.buffer[..second_chunk]);
        }

        self.read_pos
            .store(read_pos.wrapping_add(to_read), Ordering::Release);

        Ok(to_read)
    }

    fn available(&self) -> usize {
        self.available_internal()
    }

    fn capacity(&self) -> usize {
        self.capacity
    }

    fn reset(&mut self) {
        self.read_pos.store(0, Ordering::Release);
        self.write_pos.store(0, Ordering::Release);
    }
}

pub struct AdaptiveBuffer {
    inner: Box<dyn AudioBuffer>,
    target_latency_ms: u32,
    sample_rate: u32,
    frame_size: usize,
    underrun_count: usize,
    overrun_count: usize,
}

impl AdaptiveBuffer {
    pub fn new(
        sample_rate: u32,
        frame_size: usize,
        initial_latency_ms: u32,
    ) -> Result<Self, Uac2Error> {
        let inner = Box::new(RingBuffer::with_latency(
            sample_rate,
            initial_latency_ms,
            frame_size,
        )?);

        Ok(Self {
            inner,
            target_latency_ms: initial_latency_ms,
            sample_rate,
            frame_size,
            underrun_count: 0,
            overrun_count: 0,
        })
    }

    pub fn underrun_count(&self) -> usize {
        self.underrun_count
    }

    pub fn overrun_count(&self) -> usize {
        self.overrun_count
    }

    pub fn should_adjust(&self) -> bool {
        self.underrun_count > 3 || self.overrun_count > 3
    }

    pub fn adjust_latency(&mut self, increase: bool) -> Result<(), Uac2Error> {
        let new_latency = if increase {
            (self.target_latency_ms * 2).min(1000)
        } else {
            (self.target_latency_ms / 2).max(10)
        };

        if new_latency != self.target_latency_ms {
            self.target_latency_ms = new_latency;
            self.inner = Box::new(RingBuffer::with_latency(
                self.sample_rate,
                new_latency,
                self.frame_size,
            )?);
            self.underrun_count = 0;
            self.overrun_count = 0;
        }

        Ok(())
    }
}

impl AudioBuffer for AdaptiveBuffer {
    fn write(&mut self, data: &[u8]) -> Result<usize, Uac2Error> {
        match self.inner.write(data) {
            Ok(n) => Ok(n),
            Err(Uac2Error::BufferOverflow) => {
                self.overrun_count += 1;
                Err(Uac2Error::BufferOverflow)
            }
            Err(e) => Err(e),
        }
    }

    fn read(&mut self, output: &mut [u8]) -> Result<usize, Uac2Error> {
        match self.inner.read(output) {
            Ok(n) => Ok(n),
            Err(Uac2Error::BufferUnderflow) => {
                self.underrun_count += 1;
                Err(Uac2Error::BufferUnderflow)
            }
            Err(e) => Err(e),
        }
    }

    fn available(&self) -> usize {
        self.inner.available()
    }

    fn capacity(&self) -> usize {
        self.inner.capacity()
    }

    fn reset(&mut self) {
        self.inner.reset();
        self.underrun_count = 0;
        self.overrun_count = 0;
    }
}
