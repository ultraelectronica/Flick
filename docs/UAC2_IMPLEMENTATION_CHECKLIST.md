# Custom UAC 2.0 Implementation Checklist

## Overview

This checklist outlines the implementation of a custom USB Audio Class 2.0 (UAC 2.0) driver in Rust for the Flick Player music application. The implementation will follow DRY (Don't Repeat Yourself) and SOLID principles, enable DAC/AMP detection, and support bit-perfect audio playback.

---

## Phase 1: Project Setup & Dependencies

### 1.1 Rust Dependencies

- [X] Add USB library dependencies to `rust/Cargo.toml`
  - [X] `rusb` - USB device access and control (optional, feature `uac2`)
  - [X] `libusb1-sys` - Low-level USB bindings (if needed) — provided by `rusb`, not separate
  - [X] `usb-device` - USB device framework (optional, for device-side) — skipped (host-side only)
  - [X] `usbd-audio` - USB Audio Class implementation (if available) — skipped (device-side only)
- [X] Add async runtime if needed (`tokio` or `async-std`) — `tokio` (optional, feature `uac2`)
- [X] Add error handling utilities (`thiserror`, `anyhow`) — `thiserror` added; `anyhow` already present
- [X] Add logging (`log`, `env_logger` or `tracing`) — `log`, `tracing`, `tracing-subscriber` with env-filter
- [X] Add serialization for device info (`serde` with derive) — already present

### 1.2 Flutter Bridge Setup

- [X] Create new Rust module `rust/src/uac2/mod.rs`
- [X] Define FFI bridge types in `rust/src/api/uac2_api.rs`
- [X] Generate Dart bindings using `flutter_rust_bridge_codegen`
- [X] Create Dart service wrapper `lib/services/uac2_service.dart`
- [X] Update `rust/src/lib.rs` to export UAC2 module

### 1.3 Platform-Specific Setup

- [X] Add Android USB Host API integration
- [X] Document platform-specific setup in README

---

## Phase 2: USB Device Discovery & Enumeration

### 2.1 USB Device Detection

- [X] Implement USB device enumeration function
- [X] Filter devices by USB Audio Class (Class Code 0x01)
- [X] Filter by UAC 2.0 (Subclass 0x02, Protocol 0x20)
- [X] Extract device vendor ID (VID) and product ID (PID)
- [X] Extract device serial number, manufacturer, and product name
- [X] Handle device hot-plug events (connect/disconnect)
- [X] Implement device list caching with refresh mechanism

### 2.2 Device Information Structure

- [X] Create `Uac2Device` struct following Single Responsibility Principle
  - [X] Device identification (VID, PID, serial)
  - [X] Device metadata (name, manufacturer)
  - [X] USB device handle
  - [X] Device capabilities
- [X] Implement `DeviceInfo` trait for device information extraction
- [X] Create `DeviceRegistry` struct for managing multiple devices (Open/Closed Principle)
- [X] Implement device comparison and equality traits

### 2.3 Error Handling

- [X] Define custom error types (`Uac2Error` enum)
- [X] Implement proper error propagation
- [X] Handle USB permission errors gracefully
- [X] Handle device busy/unavailable errors
- [X] Add error logging and user-friendly error messages

---

## Phase 3: UAC 2.0 Protocol Implementation

### 3.1 USB Audio Class Descriptors

- [X] Parse Interface Association Descriptor (IAD)
- [X] Parse Audio Control Interface Descriptor
- [X] Parse Audio Streaming Interface Descriptors
- [X] Parse Class-Specific Audio Control (CS_AC) Interface Header Descriptor
- [X] Parse Input/Output Terminal Descriptors
- [X] Parse Feature Unit Descriptors
- [X] Parse Audio Streaming Interface Descriptors (AS_IF)
- [X] Parse Format Type Descriptors (Type I, II, III)
- [X] Parse Class-Specific AS Interface Descriptors

### 3.2 Descriptor Parsing Architecture (SOLID Principles)

- [X] Create `DescriptorParser` trait (Interface Segregation)
- [X] Implement `AudioControlParser` struct
- [X] Implement `AudioStreamingParser` struct
- [X] Create `DescriptorFactory` for descriptor creation (Factory Pattern)
- [X] Use builder pattern for complex descriptor structures
- [X] Implement validation for descriptor integrity

### 3.3 UAC 2.0 Control Requests

- [X] Implement GET_CUR/GET_MIN/GET_MAX/GET_RES requests
- [X] Implement SET_CUR requests for volume control
- [X] Implement SET_MUTE control
- [X] Implement SET_SAMPLING_FREQ control
- [X] Implement GET_SAMPLING_FREQ control
- [X] Create `ControlRequest` enum for type safety
- [X] Implement request builder pattern (DRY principle)

### 3.4 Audio Format Support

- [X] Parse supported sample rates from descriptors
- [X] Parse supported bit depths (16, 24, 32-bit)
- [X] Parse supported channel configurations (mono, stereo, multi-channel)
- [X] Parse supported format types (PCM, DSD, etc.)
- [X] Create `AudioFormat` struct with validation
- [X] Implement format negotiation logic

---

## Phase 4: DAC/AMP Detection & Capabilities

### 4.1 Device Capability Detection

- [X] Detect DAC capabilities (supported formats, sample rates)
- [X] Detect AMP capabilities (power output, impedance)
- [X] Read device-specific feature units
- [X] Parse device-specific extension units (if present)
- [X] Extract device-specific control capabilities

### 4.2 Device Information Extraction

- [X] Read device manufacturer string descriptor
- [X] Read device product string descriptor
- [X] Read device serial number string descriptor
- [X] Extract device-specific capabilities from descriptors
- [X] Parse device-specific control ranges (volume, gain, etc.)
- [X] Create `DeviceCapabilities` struct

### 4.3 Device Classification

- [X] Implement device type detection (DAC-only, AMP-only, DAC/AMP combo)
- [X] Classify device by supported formats
- [X] Classify device by power capabilities
- [X] Create `DeviceType` enum for classification
- [X] Implement device matching logic for optimal format selection

---

## Phase 5: Bit-Perfect Audio Streaming

### 5.1 Audio Stream Setup

- [X] Select optimal audio format (highest quality supported)
- [X] Configure sample rate (match source or device max)
- [X] Configure bit depth (match source or device max)
- [X] Configure channel layout
- [X] Set up isochronous transfer endpoints
- [X] Calculate packet size and interval

### 5.2 Isochronous Transfer Management

- [X] Implement isochronous OUT endpoint setup
- [X] Create transfer buffer management system
- [X] Implement zero-copy buffer strategy where possible
- [X] Handle transfer completion callbacks
- [X] Implement transfer error recovery
- [X] Add transfer timing synchronization

### 5.3 Audio Data Pipeline

- [X] Create `AudioPipeline` struct (Single Responsibility)
- [X] Implement format conversion (if needed, with minimal processing)
- [X] Implement sample rate conversion (only if necessary)
- [X] Implement bit depth conversion (only if necessary)
- [X] Ensure no DSP processing (bit-perfect requirement)
- [X] Implement direct passthrough mode for native formats

### 5.4 Buffer Management

- [X] Design ring buffer for audio data
- [X] Implement lock-free buffer operations (if possible)
- [X] Add buffer underrun/overrun detection
- [X] Implement adaptive buffering based on device latency
- [X] Create `AudioBuffer` trait for abstraction (Dependency Inversion)

---

## Phase 6: Integration with Existing Audio Engine

### 6.1 Rust Audio Engine Integration

- [X] Create `Uac2AudioSink` struct implementing audio sink trait
- [X] Integrate with existing `rust/src/audio/engine.rs`
- [X] Add UAC2 as optional audio backend
- [X] Implement audio format negotiation between engine and UAC2
- [X] Handle format mismatches gracefully
- [X] Maintain compatibility with existing audio pipeline

### 6.2 Flutter Service Integration

- [X] Create `Uac2Service` in `lib/services/uac2_service.dart`
- [X] Implement device discovery methods
- [X] Implement device selection methods
- [X] Add device capability queries
- [X] Integrate with `PlayerService` for audio routing
- [X] Add Riverpod providers for UAC2 state management
- [X] Create UI for device selection and status

### 6.3 State Management

- [X] Create `Uac2State` enum (Idle, Connecting, Connected, Streaming, Error)
- [X] Implement state machine for device lifecycle
- [X] Add state change notifications to Flutter
- [X] Handle state transitions properly
- [X] Add state persistence (selected device)

---

## Phase 7: Error Handling & Recovery

### 7.1 Error Handling Architecture

- [X] Implement comprehensive error types (`Uac2Error`)
- [X] Add error context and chain support
- [X] Implement error recovery strategies
- [X] Add automatic reconnection logic
- [X] Handle device disconnection gracefully
- [X] Implement fallback to default audio output

### 7.2 Logging & Debugging

- [X] Add structured logging throughout UAC2 module
- [X] Log device discovery events
- [X] Log descriptor parsing details
- [X] Log control request/response details
- [X] Log audio streaming statistics
- [X] Add debug mode for verbose logging
- [X] Create logging configuration

### 7.3 Testing & Validation

- [X] Unit tests for descriptor parsing
- [X] Unit tests for control requests
- [X] Integration tests for device enumeration
- [X] Integration tests for audio streaming
- [X] Test with multiple UAC 2.0 devices
- [X] Test bit-perfect verification (compare input/output)
- [X] Performance tests for low-latency streaming

---

## Phase 8: UI/UX Integration

### 8.1 Settings UI

- [X] Create UAC2 device selection screen
- [X] Display detected devices with capabilities
- [X] Show device status (connected/disconnected)
- [X] Display current audio format (sample rate, bit depth)
- [X] Add device refresh button
- [X] Add manual device selection option
- [X] Show bit-perfect indicator

### 8.2 Status Indicators

- [X] Add UAC2 device indicator in player UI
- [X] Show active device name
- [X] Display current audio format
- [X] Show connection status
- [X] Add error notifications
- [X] Display device capabilities

### 8.3 User Preferences

- [X] Save selected UAC2 device preference
- [X] Save preferred audio format
- [X] Add auto-select device option
- [X] Add format preference (highest quality vs. compatibility)

---

## Phase 9: Documentation & Code Quality

### 9.1 Code Documentation

- [X] Document all public APIs with rustdoc
- [X] Add inline comments for complex logic
- [X] Document UAC 2.0 protocol implementation details
- [X] Create architecture documentation
- [X] Document device compatibility notes
- [X] Add code examples for common use cases

### 9.2 Code Quality (DRY & SOLID)

- [ ] Review code for duplication (DRY violations)
- [ ] Extract common functionality into reusable modules
- [ ] Ensure Single Responsibility Principle (each struct/function has one job)
- [ ] Ensure Open/Closed Principle (extensible without modification)
- [ ] Ensure Liskov Substitution Principle (if using traits/interfaces)
- [ ] Ensure Interface Segregation (small, focused interfaces)
- [ ] Ensure Dependency Inversion (depend on abstractions)

### 9.3 Refactoring

- [ ] Identify and eliminate code duplication
- [ ] Extract magic numbers into constants
- [ ] Create helper functions for repeated patterns
- [ ] Use traits for shared behavior
- [ ] Optimize hot paths (audio streaming)
- [ ] Profile and optimize performance bottlenecks

---

## Phase 10: Platform-Specific Considerations

### 10.1 Android

- [X] Integrate Android USB Host API
- [X] Handle USB device permissions on Android
- [X] Test with Android audio routing
- [X] Handle Android audio focus

---

## Phase 11: Performance Optimization

### 11.1 Latency Optimization

- [ ] Minimize buffer sizes for low latency
- [ ] Optimize isochronous transfer scheduling
- [ ] Reduce memory allocations in hot path
- [ ] Use lock-free data structures where possible
- [ ] Profile and optimize critical sections

### 11.2 Memory Management

- [ ] Use pre-allocated buffers
- [ ] Minimize memory copies
- [ ] Use zero-copy techniques where possible
- [ ] Profile memory usage
- [ ] Optimize buffer pool management

### 11.3 CPU Optimization

- [ ] Avoid unnecessary format conversions
- [ ] Optimize descriptor parsing (cache results)
- [ ] Use SIMD for format conversions (if needed)
- [ ] Profile CPU usage during playback
- [ ] Optimize control request handling

---

## Phase 12: Testing & Validation

### 12.1 Unit Testing

- [X] Test descriptor parsing with various devices
- [X] Test control request building
- [X] Test format negotiation logic
- [X] Test error handling paths
- [X] Test device enumeration logic
- [X] Achieve >80% code coverage

### 12.2 Integration Testing

- [ ] Test with real UAC 2.0 devices
- [ ] Test device hot-plug scenarios
- [ ] Test format switching
- [ ] Test bit-perfect playback verification
- [ ] Test error recovery scenarios
- [ ] Test with multiple simultaneous devices

### 12.3 Bit-Perfect Verification

- [ ] Implement bit-perfect verification tool
- [ ] Compare input audio data with USB output
- [ ] Verify no sample rate conversion (when not needed)
- [ ] Verify no bit depth conversion (when not needed)
- [ ] Verify no DSP processing
- [ ] Document verification methodology

---

## Phase 13: Release Preparation

### 13.1 Final Checks

- [ ] Code review for DRY and SOLID principles
- [ ] Performance benchmarking
- [ ] Memory leak testing
- [ ] Stress testing (long playback sessions)
- [ ] Compatibility testing with various devices
- [ ] Documentation completeness check

### 13.2 Release Documentation

- [ ] Update main README with UAC2 feature
- [ ] Create UAC2 user guide
- [ ] Document supported devices
- [ ] Document known limitations
- [ ] Create troubleshooting guide
- [ ] Add changelog entry

---

## Notes

### Key Design Principles

- **DRY (Don't Repeat Yourself)**: Extract common functionality, use traits and generics, create reusable utilities
- **SOLID Principles**:
  - **S**ingle Responsibility: Each module/struct has one clear purpose
  - **O**pen/Closed: Extensible through traits and composition
  - **L**iskov Substitution: Proper trait implementations
  - **I**nterface Segregation: Small, focused traits
  - **D**ependency Inversion: Depend on abstractions (traits), not concrete types

### Bit-Perfect Requirements

- No sample rate conversion unless absolutely necessary
- No bit depth conversion unless absolutely necessary
- No DSP processing (EQ, effects, etc.)
- Direct passthrough of audio data when format matches
- Minimal buffering (only for USB transfer requirements)

### USB Audio Class 2.0 Resources

- USB Audio Class 2.0 Specification (USB.org)
- USB Device Class Definition for Audio Devices Release 2.0
- USB 2.0 Specification for isochronous transfers
- Platform-specific USB APIs documentation

---

## Estimated Complexity

- **High Complexity**: USB protocol implementation, descriptor parsing, isochronous transfers
- **Medium Complexity**: Device detection, format negotiation, Flutter integration
- **Low Complexity**: UI components, state management, documentation

---

*Last Updated: 2026-03-22*
