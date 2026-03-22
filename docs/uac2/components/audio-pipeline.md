# Audio Pipeline

The audio pipeline processes audio data from the engine and prepares it for USB transfer to the DAC/AMP.

## Overview

The pipeline handles:
- Format conversion (if needed)
- Sample rate conversion (if needed)
- Bit depth conversion (if needed)
- Buffering for USB transfer
- Bit-perfect passthrough (when possible)

## Pipeline Architecture

```
Audio Engine
     │
     ▼
┌─────────────────┐
│ Uac2AudioSink   │  ← Receives audio from engine
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Format Check    │  ← Compare source vs device format
└────────┬────────┘
         │
         ├─> Match: Direct Passthrough
         │   │
         │   ▼
         │ ┌─────────────────┐
         │ │ Zero Processing │  ← Bit-perfect
         │ └────────┬────────┘
         │          │
         └──────────┘
         │
         └─> Mismatch: Convert
             │
             ▼
           ┌─────────────────┐
           │ AudioPipeline   │  ← Format conversion
           └────────┬────────┘
                    │
                    ▼
         ┌─────────────────┐
         │ RingBuffer      │  ← Buffering
         └────────┬────────┘
                  │
                  ▼
         ┌─────────────────┐
         │ USB Transfer    │  ← Send to device
         └─────────────────┘
```

## Components

### Uac2AudioSink

**Module:** `rust/src/uac2/audio_sink.rs`

Integrates with the audio engine:
- Receives PCM audio data
- Checks format compatibility
- Routes to pipeline or direct transfer

```rust
impl AudioSink for Uac2AudioSink {
    fn write(&mut self, data: &[f32]) -> Result<(), AudioError> {
        // Check if format matches
        if self.needs_conversion() {
            self.pipeline.process(data)?;
        } else {
            self.direct_write(data)?;
        }
        Ok(())
    }
}
```

### AudioPipeline

**Module:** `rust/src/uac2/audio_pipeline.rs`

Processes audio when conversion is needed:
- Sample rate conversion
- Bit depth conversion
- Channel layout conversion

```rust
pub struct AudioPipeline {
    resampler: Option<Resampler>,
    bit_converter: Option<BitDepthConverter>,
    channel_mixer: Option<ChannelMixer>,
}
```

### RingBuffer

**Module:** `rust/src/uac2/ring_buffer.rs`

Lock-free buffer for audio data:
- Producer: Audio engine writes
- Consumer: USB transfer reads
- Handles underrun/overrun

```rust
pub struct RingBuffer<T> {
    buffer: Vec<T>,
    read_pos: AtomicUsize,
    write_pos: AtomicUsize,
}
```

## Format Conversion

### Sample Rate Conversion

Converts between different sample rates:
- Uses high-quality resampler
- Minimizes artifacts
- Only when necessary

Example: 44.1 kHz → 48 kHz

### Bit Depth Conversion

Converts between bit depths:
- 16-bit ↔ 24-bit
- 24-bit ↔ 32-bit
- Proper dithering for downsampling

### Channel Conversion

Converts channel layouts:
- Mono → Stereo (duplicate)
- Stereo → Mono (mix)
- Multi-channel mapping

## Bit-Perfect Mode

When source and device formats match exactly:
- No resampling
- No bit depth conversion
- No channel mixing
- Direct memory copy
- Zero DSP processing

This ensures bit-perfect audio reproduction.

## Buffering Strategy

### Buffer Sizing

Buffer size balances latency and stability:
- Smaller buffer: Lower latency, higher risk of underrun
- Larger buffer: Higher latency, more stable

Typical sizes:
- Low latency: 256-512 samples
- Balanced: 1024-2048 samples
- High stability: 4096+ samples

### Adaptive Buffering

Buffer size adjusts based on:
- Transfer success rate
- Underrun frequency
- Device latency characteristics

### Underrun Handling

When buffer runs empty:
- Insert silence to prevent glitches
- Log underrun event
- Increase buffer size if frequent

### Overrun Handling

When buffer fills up:
- Drop oldest samples
- Log overrun event
- Decrease buffer size if frequent

## Transfer Management

### Transfer Buffers

**Module:** `rust/src/uac2/transfer_buffer.rs`

Pre-allocated buffers for USB transfers:
- Pool of reusable buffers
- Sized for isochronous packets
- Recycled after transfer completion

### Isochronous Transfers

**Module:** `rust/src/uac2/transfer.rs`

Real-time USB transfers:
- Fixed interval (1ms typical)
- No retransmission
- Time-critical delivery

```rust
pub struct TransferManager {
    active_transfers: Vec<Transfer>,
    buffer_pool: BufferPool,
}
```

## Performance Optimization

### Zero-Copy Operations

Minimize memory copies:
- Direct buffer access where possible
- Memory mapping for large transfers
- Avoid intermediate buffers

### Lock-Free Design

Ring buffer uses atomic operations:
- No mutex contention
- Suitable for real-time audio
- Predictable latency

### SIMD Optimization

Format conversion uses SIMD:
- Vectorized operations
- Faster processing
- Lower CPU usage

## Latency Optimization

Total latency sources:
- Buffer latency: Buffer size / sample rate
- Processing latency: Conversion time
- USB latency: Transfer interval
- Device latency: DAC processing

Minimize by:
- Smaller buffers
- Avoid unnecessary conversion
- Optimize transfer scheduling

## Error Handling

Pipeline errors:
- **Buffer Underrun**: Insert silence, increase buffer
- **Buffer Overrun**: Drop samples, decrease buffer
- **Transfer Error**: Retry, fallback if persistent
- **Format Error**: Reconfigure pipeline

## Monitoring

Pipeline provides metrics:
- Buffer fill level
- Underrun/overrun count
- Transfer success rate
- Processing latency

## Example Usage

```rust
// Create audio sink
let sink = Uac2AudioSink::new(device, config)?;

// Configure audio engine
engine.set_sink(Box::new(sink));

// Start playback
engine.play()?;

// Audio flows automatically through pipeline
```

## Related Components

- [Audio Sink](../api/rust-api.md#audio-sink)
- [Transfer Management](../api/rust-api.md#transfer)
- [Error Handling](error-handling.md)
