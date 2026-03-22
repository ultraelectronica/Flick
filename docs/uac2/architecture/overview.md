# Architecture Overview

The UAC 2.0 implementation follows a layered architecture with clear separation of concerns.

## System Layers

```
┌─────────────────────────────────────────┐
│         Flutter UI Layer                │
│  (Device Selection, Status Display)     │
└─────────────────┬───────────────────────┘
                  │ FFI Bridge
┌─────────────────▼───────────────────────┐
│      Dart Service Layer                 │
│  (Uac2Service, State Management)        │
└─────────────────┬───────────────────────┘
                  │ flutter_rust_bridge
┌─────────────────▼───────────────────────┐
│       Rust Core Layer                   │
│  (Device, Pipeline, Transfer)           │
└─────────────────┬───────────────────────┘
                  │ rusb
┌─────────────────▼───────────────────────┐
│      USB Hardware Layer                 │
│  (DAC/AMP Devices)                      │
└─────────────────────────────────────────┘
```

## Core Principles

### SOLID Design
- **Single Responsibility**: Each module handles one specific concern
- **Open/Closed**: Extensible through traits without modifying existing code
- **Liskov Substitution**: Trait implementations are interchangeable
- **Interface Segregation**: Small, focused traits
- **Dependency Inversion**: Depends on abstractions, not concrete types

### DRY (Don't Repeat Yourself)
- Common functionality extracted into reusable modules
- Traits for shared behavior
- Generic implementations where applicable

## Key Components

### Device Management
- **Device Discovery**: Enumerates USB audio devices
- **Device Registry**: Manages connected devices
- **Device Classifier**: Identifies DAC/AMP capabilities

### Protocol Layer
- **Descriptor Parser**: Parses UAC 2.0 descriptors
- **Control Requests**: Handles device control operations
- **Capabilities**: Extracts device capabilities

### Audio Pipeline
- **Audio Sink**: Integrates with audio engine
- **Format Negotiation**: Selects optimal audio format
- **Transfer Manager**: Manages isochronous transfers
- **Ring Buffer**: Lock-free audio buffering

### Error Handling
- **Error Types**: Comprehensive error taxonomy
- **Recovery Strategies**: Automatic reconnection and fallback
- **Logging**: Structured diagnostic logging

## Data Flow

### Device Connection Flow
1. USB device connected (hot-plug event)
2. Device enumeration and filtering
3. Descriptor parsing
4. Capability extraction
5. Device registration
6. UI notification

### Audio Streaming Flow
1. Format negotiation
2. Endpoint configuration
3. Transfer buffer allocation
4. Audio data from engine
5. Format conversion (if needed)
6. Isochronous transfer to device
7. Transfer completion callback

## Thread Model

- **Main Thread**: UI and state management
- **Audio Thread**: High-priority audio processing
- **USB Thread**: Asynchronous USB operations
- **Worker Threads**: Parallel descriptor parsing

## Memory Management

- Pre-allocated transfer buffers
- Lock-free ring buffer for audio data
- Zero-copy where possible
- Minimal allocations in hot path

## Performance Considerations

- Descriptor parsing results are cached
- Format conversion avoided when possible
- Direct passthrough for native formats
- Optimized buffer sizes for low latency
