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

- [ ] Configure Linux USB permissions (udev rules)
- [ ] Configure Windows USB driver requirements
- [ ] Configure macOS USB permissions (if needed)
- [X] Add Android USB Host API integration (if targeting Android)
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

- [ ] Parse Interface Association Descriptor (IAD)
- [ ] Parse Audio Control Interface Descriptor
- [ ] Parse Audio Streaming Interface Descriptors
- [ ] Parse Class-Specific Audio Control (CS_AC) Interface Header Descriptor
- [ ] Parse Input/Output Terminal Descriptors
- [ ] Parse Feature Unit Descriptors
- [ ] Parse Audio Streaming Interface Descriptors (AS_IF)
- [ ] Parse Format Type Descriptors (Type I, II, III)
- [ ] Parse Class-Specific AS Interface Descriptors

### 3.2 Descriptor Parsing Architecture (SOLID Principles)

- [ ] Create `DescriptorParser` trait (Interface Segregation)
- [ ] Implement `AudioControlParser` struct
- [ ] Implement `AudioStreamingParser` struct
- [ ] Create `DescriptorFactory` for descriptor creation (Factory Pattern)
- [ ] Use builder pattern for complex descriptor structures
- [ ] Implement validation for descriptor integrity

### 3.3 UAC 2.0 Control Requests

- [ ] Implement GET_CUR/GET_MIN/GET_MAX/GET_RES requests
- [ ] Implement SET_CUR requests for volume control
- [ ] Implement SET_MUTE control
- [ ] Implement SET_SAMPLING_FREQ control
- [ ] Implement GET_SAMPLING_FREQ control
- [ ] Create `ControlRequest` enum for type safety
- [ ] Implement request builder pattern (DRY principle)

### 3.4 Audio Format Support

- [ ] Parse supported sample rates from descriptors
- [ ] Parse supported bit depths (16, 24, 32-bit)
- [ ] Parse supported channel configurations (mono, stereo, multi-channel)
- [ ] Parse supported format types (PCM, DSD, etc.)
- [ ] Create `AudioFormat` struct with validation
- [ ] Implement format negotiation logic

---

## Phase 4: DAC/AMP Detection & Capabilities

### 4.1 Device Capability Detection

- [ ] Detect DAC capabilities (supported formats, sample rates)
- [ ] Detect AMP capabilities (power output, impedance)
- [ ] Read device-specific feature units
- [ ] Parse device-specific extension units (if present)
- [ ] Extract device-specific control capabilities

### 4.2 Device Information Extraction

- [ ] Read device manufacturer string descriptor
- [ ] Read device product string descriptor
- [ ] Read device serial number string descriptor
- [ ] Extract device-specific capabilities from descriptors
- [ ] Parse device-specific control ranges (volume, gain, etc.)
- [ ] Create `DeviceCapabilities` struct

### 4.3 Device Classification

- [ ] Implement device type detection (DAC-only, AMP-only, DAC/AMP combo)
- [ ] Classify device by supported formats
- [ ] Classify device by power capabilities
- [ ] Create `DeviceType` enum for classification
- [ ] Implement device matching logic for optimal format selection

---

## Phase 5: Bit-Perfect Audio Streaming

### 5.1 Audio Stream Setup

- [ ] Select optimal audio format (highest quality supported)
- [ ] Configure sample rate (match source or device max)
- [ ] Configure bit depth (match source or device max)
- [ ] Configure channel layout
- [ ] Set up isochronous transfer endpoints
- [ ] Calculate packet size and interval

### 5.2 Isochronous Transfer Management

- [ ] Implement isochronous OUT endpoint setup
- [ ] Create transfer buffer management system
- [ ] Implement zero-copy buffer strategy where possible
- [ ] Handle transfer completion callbacks
- [ ] Implement transfer error recovery
- [ ] Add transfer timing synchronization

### 5.3 Audio Data Pipeline

- [ ] Create `AudioPipeline` struct (Single Responsibility)
- [ ] Implement format conversion (if needed, with minimal processing)
- [ ] Implement sample rate conversion (only if necessary)
- [ ] Implement bit depth conversion (only if necessary)
- [ ] Ensure no DSP processing (bit-perfect requirement)
- [ ] Implement direct passthrough mode for native formats

### 5.4 Buffer Management

- [ ] Design ring buffer for audio data
- [ ] Implement lock-free buffer operations (if possible)
- [ ] Add buffer underrun/overrun detection
- [ ] Implement adaptive buffering based on device latency
- [ ] Create `AudioBuffer` trait for abstraction (Dependency Inversion)

---

## Phase 6: Integration with Existing Audio Engine

### 6.1 Rust Audio Engine Integration

- [ ] Create `Uac2AudioSink` struct implementing audio sink trait
- [ ] Integrate with existing `rust/src/audio/engine.rs`
- [ ] Add UAC2 as optional audio backend
- [ ] Implement audio format negotiation between engine and UAC2
- [ ] Handle format mismatches gracefully
- [ ] Maintain compatibility with existing audio pipeline

### 6.2 Flutter Service Integration

- [ ] Create `Uac2Service` in `lib/services/uac2_service.dart`
- [ ] Implement device discovery methods
- [ ] Implement device selection methods
- [ ] Add device capability queries
- [ ] Integrate with `PlayerService` for audio routing
- [ ] Add Riverpod providers for UAC2 state management
- [ ] Create UI for device selection and status

### 6.3 State Management

- [ ] Create `Uac2State` enum (Idle, Connecting, Connected, Streaming, Error)
- [ ] Implement state machine for device lifecycle
- [ ] Add state change notifications to Flutter
- [ ] Handle state transitions properly
- [ ] Add state persistence (selected device)

---

## Phase 7: Error Handling & Recovery

### 7.1 Error Handling Architecture

- [ ] Implement comprehensive error types (`Uac2Error`)
- [ ] Add error context and chain support
- [ ] Implement error recovery strategies
- [ ] Add automatic reconnection logic
- [ ] Handle device disconnection gracefully
- [ ] Implement fallback to default audio output

### 7.2 Logging & Debugging

- [ ] Add structured logging throughout UAC2 module
- [ ] Log device discovery events
- [ ] Log descriptor parsing details
- [ ] Log control request/response details
- [ ] Log audio streaming statistics
- [ ] Add debug mode for verbose logging
- [ ] Create logging configuration

### 7.3 Testing & Validation

- [ ] Unit tests for descriptor parsing
- [ ] Unit tests for control requests
- [ ] Integration tests for device enumeration
- [ ] Integration tests for audio streaming
- [ ] Test with multiple UAC 2.0 devices
- [ ] Test bit-perfect verification (compare input/output)
- [ ] Performance tests for low-latency streaming

---

## Phase 8: UI/UX Integration

### 8.1 Settings UI

- [ ] Create UAC2 device selection screen
- [ ] Display detected devices with capabilities
- [ ] Show device status (connected/disconnected)
- [ ] Display current audio format (sample rate, bit depth)
- [ ] Add device refresh button
- [ ] Add manual device selection option
- [ ] Show bit-perfect indicator

### 8.2 Status Indicators

- [ ] Add UAC2 device indicator in player UI
- [ ] Show active device name
- [ ] Display current audio format
- [ ] Show connection status
- [ ] Add error notifications
- [ ] Display device capabilities

### 8.3 User Preferences

- [ ] Save selected UAC2 device preference
- [ ] Save preferred audio format
- [ ] Add auto-select device option
- [ ] Add format preference (highest quality vs. compatibility)

---

## Phase 9: Documentation & Code Quality

### 9.1 Code Documentation

- [ ] Document all public APIs with rustdoc
- [ ] Add inline comments for complex logic
- [ ] Document UAC 2.0 protocol implementation details
- [ ] Create architecture documentation
- [ ] Document device compatibility notes
- [ ] Add code examples for common use cases

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

### 10.1 Linux

- [ ] Test with libusb backend
- [ ] Handle udev rules for device access
- [ ] Test with different USB controllers (USB 2.0, USB 3.0)
- [ ] Handle USB device permissions
- [ ] Test with ALSA/PulseAudio coexistence

### 10.2 Windows

- [ ] Test with WinUSB backend
- [ ] Handle driver installation requirements
- [ ] Test with different USB controllers
- [ ] Handle Windows audio session management
- [ ] Test exclusive mode audio

### 10.3 macOS

- [ ] Test with IOKit backend (if using native)
- [ ] Handle macOS USB permissions
- [ ] Test with Core Audio coexistence
- [ ] Handle macOS audio session management

### 10.4 Android (if applicable)

- [ ] Integrate Android USB Host API
- [ ] Handle USB device permissions on Android
- [ ] Test with Android audio routing
- [ ] Handle Android audio focus

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

- [ ] Test descriptor parsing with various devices
- [ ] Test control request building
- [ ] Test format negotiation logic
- [ ] Test error handling paths
- [ ] Test device enumeration logic
- [ ] Achieve >80% code coverage

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

*Last Updated: 2026-02-14*
