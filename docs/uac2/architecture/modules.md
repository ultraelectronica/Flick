# Module Structure

The UAC 2.0 implementation is organized into focused modules following the Single Responsibility Principle.

## Rust Module Hierarchy

```
rust/src/uac2/
├── mod.rs                      # Module exports and public API
├── device.rs                   # Device representation
├── device_classifier.rs        # Device type classification
├── capabilities.rs             # Device capability extraction
├── endpoint.rs                 # USB endpoint management
├── stream_config.rs            # Stream configuration
├── format_negotiation.rs       # Audio format selection
├── transfer.rs                 # Isochronous transfer management
├── transfer_buffer.rs          # Transfer buffer management
├── audio_pipeline.rs           # Audio processing pipeline
├── audio_sink.rs               # Audio engine integration
├── ring_buffer.rs              # Lock-free ring buffer
├── connection_manager.rs       # Device lifecycle management
├── error.rs                    # Error types
├── error_recovery.rs           # Recovery strategies
├── fallback_handler.rs         # Fallback to default audio
├── logging.rs                  # Logging configuration
└── tests/                      # Unit and integration tests
    ├── device_classifier_tests.rs
    ├── capabilities_tests.rs
    ├── stream_config_tests.rs
    ├── control_requests_tests.rs
    ├── transfer_tests.rs
    ├── audio_format_tests.rs
    └── audio_pipeline_tests.rs
```

## Module Responsibilities

### Core Device Modules

#### `device.rs`
Represents a UAC 2.0 device with its metadata and USB handle.

**Key Types:**
- `Uac2Device`: Main device struct
- `DeviceInfo`: Device identification and metadata

**Responsibilities:**
- Device lifecycle management
- USB handle management
- Device comparison and equality

#### `device_classifier.rs`
Classifies devices by type and capabilities.

**Key Types:**
- `DeviceType`: DAC, AMP, or combo classification
- `DeviceClassifier`: Classification logic

**Responsibilities:**
- Analyze device descriptors
- Determine device type
- Extract device-specific features

#### `capabilities.rs`
Extracts and represents device capabilities.

**Key Types:**
- `DeviceCapabilities`: Supported formats and features
- `AudioFormat`: Sample rate, bit depth, channels

**Responsibilities:**
- Parse format descriptors
- Extract supported sample rates
- Identify channel configurations

### Protocol Modules

#### `endpoint.rs`
Manages USB endpoints for audio streaming.

**Key Types:**
- `AudioEndpoint`: Endpoint representation
- `EndpointDescriptor`: Parsed endpoint data

**Responsibilities:**
- Endpoint discovery
- Endpoint configuration
- Packet size calculation

#### `stream_config.rs`
Configures audio streaming parameters.

**Key Types:**
- `StreamConfig`: Stream configuration
- `StreamParams`: Runtime parameters

**Responsibilities:**
- Format selection
- Buffer size calculation
- Timing configuration

#### `format_negotiation.rs`
Negotiates optimal audio format between source and device.

**Key Types:**
- `FormatNegotiator`: Negotiation logic
- `FormatMatch`: Match quality assessment

**Responsibilities:**
- Compare source and device formats
- Select best match
- Determine if conversion needed

### Transfer Modules

#### `transfer.rs`
Manages isochronous USB transfers.

**Key Types:**
- `TransferManager`: Transfer lifecycle
- `IsochronousTransfer`: Transfer wrapper

**Responsibilities:**
- Transfer submission
- Completion handling
- Error recovery

#### `transfer_buffer.rs`
Manages transfer buffer pool.

**Key Types:**
- `TransferBuffer`: Buffer wrapper
- `BufferPool`: Pre-allocated buffers

**Responsibilities:**
- Buffer allocation
- Buffer recycling
- Memory management

#### `ring_buffer.rs`
Lock-free ring buffer for audio data.

**Key Types:**
- `RingBuffer`: Lock-free buffer
- `Producer`/`Consumer`: Buffer endpoints

**Responsibilities:**
- Thread-safe audio buffering
- Underrun/overrun detection
- Zero-copy operations

### Audio Pipeline Modules

#### `audio_pipeline.rs`
Processes audio data for USB transfer.

**Key Types:**
- `AudioPipeline`: Processing pipeline
- `PipelineStage`: Processing stage

**Responsibilities:**
- Format conversion (if needed)
- Sample rate conversion (if needed)
- Bit depth conversion (if needed)

#### `audio_sink.rs`
Integrates with the audio engine.

**Key Types:**
- `Uac2AudioSink`: Audio sink implementation

**Responsibilities:**
- Receive audio from engine
- Route to USB device
- Handle format mismatches

### Management Modules

#### `connection_manager.rs`
Manages device connection lifecycle.

**Key Types:**
- `ConnectionManager`: Lifecycle coordinator
- `ConnectionState`: State machine

**Responsibilities:**
- Device connection/disconnection
- State transitions
- Event notifications

#### `error.rs`
Defines error types.

**Key Types:**
- `Uac2Error`: Error enum
- Error context and chaining

**Responsibilities:**
- Error classification
- Error context
- Error conversion

#### `error_recovery.rs`
Implements error recovery strategies.

**Key Types:**
- `RecoveryStrategy`: Recovery logic
- `RecoveryAction`: Recovery steps

**Responsibilities:**
- Automatic reconnection
- Transfer retry
- Graceful degradation

#### `fallback_handler.rs`
Handles fallback to default audio output.

**Key Types:**
- `FallbackHandler`: Fallback logic

**Responsibilities:**
- Detect unrecoverable errors
- Switch to default audio
- Notify user

## Dart Module Structure

```
lib/
├── services/
│   ├── uac2_service.dart           # Main UAC2 service
│   └── uac2_preferences_service.dart # Preferences management
├── providers/
│   └── uac2_provider.dart          # Riverpod providers
├── widgets/uac2/
│   ├── uac2_device_selector.dart   # Device selection widget
│   ├── uac2_status_indicator.dart  # Status display
│   ├── uac2_device_capabilities.dart # Capability display
│   └── uac2_player_status.dart     # Player integration
└── features/settings/screens/
    ├── uac2_settings_screen.dart   # Settings UI
    └── uac2_preferences_screen.dart # Preferences UI
```

## Module Dependencies

```
device.rs
  └─> capabilities.rs
  └─> device_classifier.rs

audio_sink.rs
  └─> audio_pipeline.rs
  └─> transfer.rs
  └─> ring_buffer.rs

transfer.rs
  └─> transfer_buffer.rs
  └─> endpoint.rs

connection_manager.rs
  └─> device.rs
  └─> error_recovery.rs
  └─> fallback_handler.rs
```

## Design Patterns

- **Factory Pattern**: Device and descriptor creation
- **Builder Pattern**: Complex configuration objects
- **Strategy Pattern**: Format negotiation and error recovery
- **Observer Pattern**: State change notifications
- **Pool Pattern**: Transfer buffer management
