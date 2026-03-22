# Descriptor Parsing

USB descriptors define device capabilities and configuration. The UAC 2.0 implementation parses these descriptors to understand device features.

## Overview

USB Audio Class 2.0 devices provide descriptors that describe:
- Audio interfaces
- Supported formats
- Sample rates and bit depths
- Channel configurations
- Control capabilities

## Descriptor Types

### Standard Descriptors

#### Device Descriptor
Basic device information:
- Vendor ID (VID)
- Product ID (PID)
- Device class
- USB version

#### Configuration Descriptor
Device configuration:
- Number of interfaces
- Power requirements
- Configuration attributes

#### Interface Descriptor
Interface information:
- Interface class (0x01 for Audio)
- Subclass (0x02 for Streaming)
- Protocol (0x20 for UAC 2.0)
- Number of endpoints

#### Endpoint Descriptor
Endpoint configuration:
- Endpoint address
- Transfer type (isochronous)
- Max packet size
- Interval

### Audio Class Descriptors

#### Interface Association Descriptor (IAD)
Groups related interfaces:
- Audio Control interface
- Audio Streaming interfaces

#### Audio Control Interface Header
Control interface information:
- UAC version
- Total length
- Number of streaming interfaces

#### Input/Output Terminal Descriptors
Audio terminals:
- Terminal type (USB streaming, speaker, etc.)
- Channel configuration
- Controls available

#### Feature Unit Descriptor
Audio controls:
- Volume control
- Mute control
- Bass/treble controls
- Channel-specific controls

#### Audio Streaming Interface Descriptor
Streaming interface:
- Terminal link
- Format type
- Controls

#### Format Type Descriptor
Audio format details:
- Format type (Type I PCM, Type II, Type III)
- Subframe size (bytes per sample)
- Bit resolution
- Supported sample rates

## Parsing Architecture

### Parser Traits

```rust
pub trait DescriptorParser {
    type Output;
    fn parse(&self, data: &[u8]) -> Result<Self::Output, Uac2Error>;
}
```

### Descriptor Parsers

**AudioControlParser**
- Parses Audio Control interface descriptors
- Extracts terminal and unit information
- Builds control topology

**AudioStreamingParser**
- Parses Audio Streaming interface descriptors
- Extracts format information
- Identifies endpoints

**FormatTypeParser**
- Parses Format Type descriptors
- Extracts sample rates
- Identifies bit depths and channel counts

## Parsing Process

1. **Read Configuration Descriptor**
   - Get full configuration descriptor
   - Identify total length

2. **Parse Interface Descriptors**
   - Find Audio Control interface
   - Find Audio Streaming interfaces
   - Extract interface numbers

3. **Parse Audio Control Descriptors**
   - Parse header descriptor
   - Parse terminal descriptors
   - Parse unit descriptors

4. **Parse Audio Streaming Descriptors**
   - Parse AS interface descriptor
   - Parse format type descriptor
   - Extract supported formats

5. **Parse Endpoint Descriptors**
   - Find isochronous endpoints
   - Extract packet size and interval
   - Identify endpoint addresses

6. **Build Capability Model**
   - Aggregate format information
   - Build supported format list
   - Create device capabilities

## Descriptor Validation

Descriptors are validated for:
- Correct length fields
- Valid descriptor types
- Consistent references
- Supported format types
- Valid sample rates

Invalid descriptors result in parsing errors.

## Format Extraction

### Sample Rates

Sample rates are extracted from Format Type descriptors:
- Discrete rates (list of specific rates)
- Continuous range (min/max/resolution)

Common rates:
- 44100 Hz (CD quality)
- 48000 Hz (Professional audio)
- 96000 Hz (High-resolution)
- 192000 Hz (Ultra high-resolution)

### Bit Depths

Bit depths indicate sample precision:
- 16-bit (CD quality)
- 24-bit (High-resolution)
- 32-bit (Professional/floating-point)

### Channel Configurations

Channel layouts:
- Mono (1 channel)
- Stereo (2 channels)
- Multi-channel (5.1, 7.1, etc.)

## Caching

Parsed descriptors are cached to avoid repeated parsing:
- Descriptors cached per device
- Cache invalidated on device reconnection
- Reduces USB bus traffic

## Error Handling

Common parsing errors:

- **Invalid Length**: Descriptor length mismatch
- **Unknown Type**: Unsupported descriptor type
- **Malformed Data**: Corrupted descriptor data
- **Missing Required**: Required descriptor not found

## Example

```rust
// Parse device descriptors
let config_desc = device.active_config_descriptor()?;
let parser = AudioStreamingParser::new();

// Extract formats
let formats = parser.parse_formats(&config_desc)?;

// Find best format
let best = formats.iter()
    .max_by_key(|f| f.sample_rate * f.bit_depth);
```

## Performance

Parsing is optimized:
- Single-pass parsing where possible
- Minimal allocations
- Parallel parsing for multiple interfaces
- Results cached

## Related Components

- [Device Discovery](device-discovery.md)
- [Audio Pipeline](audio-pipeline.md)
- [Capabilities API](../api/rust-api.md#capabilities)
