# Error Handling

The UAC 2.0 implementation uses comprehensive error handling to ensure robust operation.

## Error Types

### Uac2Error Enum

**Module:** `rust/src/uac2/error.rs`

Main error type covering all failure modes:

```rust
pub enum Uac2Error {
    // USB errors
    UsbError(rusb::Error),
    DeviceNotFound,
    DeviceBusy,
    PermissionDenied,
    
    // Descriptor errors
    InvalidDescriptor,
    UnsupportedFormat,
    MalformedDescriptor,
    
    // Transfer errors
    TransferFailed,
    TransferTimeout,
    TransferStalled,
    
    // Audio errors
    BufferUnderrun,
    BufferOverrun,
    FormatMismatch,
    
    // Connection errors
    ConnectionLost,
    DeviceDisconnected,
    
    // Configuration errors
    InvalidConfiguration,
    UnsupportedSampleRate,
    UnsupportedBitDepth,
}
```

## Error Context

Errors include context for debugging:

```rust
impl Uac2Error {
    pub fn with_context(self, context: &str) -> Self {
        // Add context to error
    }
}
```

Example:
```rust
device.connect()
    .map_err(|e| e.with_context("Failed to connect to DAC"))?;
```

## Error Recovery

### Recovery Strategies

**Module:** `rust/src/uac2/error_recovery.rs`

Defines recovery actions for different error types:

```rust
pub enum RecoveryStrategy {
    Retry { max_attempts: u32, delay: Duration },
    Reconnect,
    Fallback,
    Abort,
}
```

### Automatic Recovery

Errors trigger automatic recovery:

1. **Transient Errors**: Retry with backoff
   - Transfer timeout
   - Device busy
   - Buffer underrun

2. **Connection Errors**: Attempt reconnection
   - Connection lost
   - Device reset

3. **Fatal Errors**: Fallback to default audio
   - Device disconnected
   - Unsupported format
   - Permission denied

## Error Handling Flow

```
Error Occurs
     │
     ▼
┌─────────────────┐
│ Classify Error  │
└────────┬────────┘
         │
         ├─> Transient
         │   │
         │   ▼
         │ ┌─────────────────┐
         │ │ Retry Logic     │
         │ └────────┬────────┘
         │          │
         │          ├─> Success: Resume
         │          └─> Max Retries: Fallback
         │
         ├─> Connection
         │   │
         │   ▼
         │ ┌─────────────────┐
         │ │ Reconnect       │
         │ └────────┬────────┘
         │          │
         │          ├─> Success: Resume
         │          └─> Failed: Fallback
         │
         └─> Fatal
             │
             ▼
           ┌─────────────────┐
           │ Fallback        │
           └────────┬────────┘
                    │
                    ▼
                  ┌─────────────────┐
                  │ Notify User     │
                  └─────────────────┘
```

## Retry Logic

### Exponential Backoff

Retries use exponential backoff:

```rust
pub struct RetryPolicy {
    max_attempts: u32,
    initial_delay: Duration,
    max_delay: Duration,
    multiplier: f64,
}
```

Example:
- Attempt 1: 10ms delay
- Attempt 2: 20ms delay
- Attempt 3: 40ms delay
- Attempt 4: 80ms delay
- Max: 500ms delay

### Retry Conditions

Errors eligible for retry:
- Transfer timeout
- Device busy
- Temporary USB errors
- Buffer underrun (with buffer adjustment)

Errors not retried:
- Permission denied
- Device disconnected
- Unsupported format
- Invalid configuration

## Fallback Handler

**Module:** `rust/src/uac2/fallback_handler.rs`

Handles fallback to default audio output:

```rust
pub struct FallbackHandler {
    default_sink: Box<dyn AudioSink>,
}

impl FallbackHandler {
    pub fn activate(&mut self) -> Result<(), AudioError> {
        // Stop UAC2 streaming
        // Switch to default audio sink
        // Notify application
    }
}
```

### Fallback Triggers

Fallback occurs when:
- Device disconnected during playback
- Unrecoverable transfer errors
- Max retry attempts exceeded
- User cancels connection

### Fallback Process

1. Stop UAC2 streaming
2. Release USB device
3. Switch to default audio sink
4. Resume playback
5. Notify user

## Error Logging

### Structured Logging

**Module:** `rust/src/uac2/logging.rs`

Errors are logged with context:

```rust
tracing::error!(
    device_id = %device.id(),
    error = %err,
    "Failed to start audio stream"
);
```

### Log Levels

- **ERROR**: Unrecoverable errors
- **WARN**: Recoverable errors, retries
- **INFO**: Error recovery success
- **DEBUG**: Detailed error context

### Error Metrics

Track error statistics:
- Error frequency by type
- Retry success rate
- Fallback frequency
- Recovery time

## User Notification

### Error Messages

User-friendly error messages:

```rust
impl Display for Uac2Error {
    fn fmt(&self, f: &mut Formatter) -> fmt::Result {
        match self {
            Self::PermissionDenied => 
                write!(f, "USB permission denied. Please grant access."),
            Self::DeviceDisconnected => 
                write!(f, "Device disconnected. Switching to default audio."),
            // ... other messages
        }
    }
}
```

### Flutter Integration

Errors propagate to Flutter:

```dart
try {
  await uac2Service.connect(device);
} on Uac2Exception catch (e) {
  // Show user-friendly error
  showErrorDialog(e.message);
}
```

## Error Prevention

### Validation

Prevent errors through validation:
- Validate device before connection
- Validate format before streaming
- Validate buffer sizes
- Check device capabilities

### Defensive Programming

- Check return values
- Validate inputs
- Handle edge cases
- Use type safety

## Testing

### Error Injection

Tests inject errors to verify handling:

```rust
#[test]
fn test_transfer_timeout_recovery() {
    // Inject timeout error
    // Verify retry logic
    // Verify eventual success or fallback
}
```

### Error Scenarios

Test coverage for:
- All error types
- Retry logic
- Reconnection
- Fallback
- Error propagation

## Performance Impact

Error handling is optimized:
- Fast error path (no allocations)
- Minimal overhead in success case
- Efficient retry scheduling
- Lock-free error reporting

## Related Components

- [Connection Manager](../api/rust-api.md#connection-manager)
- [Fallback Handler](../api/rust-api.md#fallback-handler)
- [Logging](../guides/troubleshooting.md)
