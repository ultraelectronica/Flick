# UAC 2.0 Documentation

This directory contains comprehensive documentation for the USB Audio Class 2.0 (UAC 2.0) implementation in Flick Player.

## Documentation Structure

### Architecture & Design
- [Architecture Overview](architecture/overview.md) - High-level system design
- [Module Structure](architecture/modules.md) - Component organization
- [Data Flow](architecture/data-flow.md) - Audio pipeline and control flow

### Core Components
- [Device Discovery](components/device-discovery.md) - USB device enumeration
- [Descriptor Parsing](components/descriptors.md) - UAC 2.0 protocol parsing
- [Audio Pipeline](components/audio-pipeline.md) - Streaming and format handling
- [Error Handling](components/error-handling.md) - Recovery strategies

### API Reference
- [Rust API](api/rust-api.md) - Core Rust implementation
- [Flutter API](api/flutter-api.md) - Dart service layer
- [FFI Bridge](api/ffi-bridge.md) - Cross-language communication

### Guides
- [Getting Started](guides/getting-started.md) - Quick start guide
- [Device Compatibility](guides/device-compatibility.md) - Supported devices
- [Troubleshooting](guides/troubleshooting.md) - Common issues and solutions
- [Testing](guides/testing.md) - Testing strategies

### Examples
- [Basic Usage](examples/basic-usage.md) - Simple integration examples
- [Advanced Usage](examples/advanced-usage.md) - Complex scenarios

## Quick Links

- [Implementation Checklist](../UAC2_IMPLEMENTATION_CHECKLIST.md)
- [Phase 6 Summary](../UAC2_PHASE_6_SUMMARY.md)
- [Main Documentation](../DOCUMENTATION.md)

## Overview

The UAC 2.0 implementation enables bit-perfect audio playback through external USB DACs and amplifiers. It provides:

- Automatic device detection and enumeration
- Full UAC 2.0 protocol support
- Bit-perfect audio streaming
- Hot-plug support
- Format negotiation
- Error recovery

## Key Features

- **Zero DSP Processing**: Direct audio passthrough for bit-perfect playback
- **Format Negotiation**: Automatic selection of optimal audio format
- **Low Latency**: Optimized isochronous transfer management
- **Device Classification**: Automatic DAC/AMP capability detection
- **Robust Error Handling**: Graceful recovery from device issues

## Getting Started

For a quick introduction, see the [Getting Started Guide](guides/getting-started.md).

For detailed API documentation, see the [API Reference](api/rust-api.md).
