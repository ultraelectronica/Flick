# Data Flow

This document describes how data flows through the UAC 2.0 system.

## Device Discovery Flow

```
USB Device Connected
        │
        ▼
┌───────────────────┐
│ Hot-plug Event    │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Enumerate Devices │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Filter UAC 2.0    │
│ (Class 0x01)      │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Parse Descriptors │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Extract           │
│ Capabilities      │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Classify Device   │
│ (DAC/AMP/Combo)   │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Register Device   │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Notify Flutter    │
└───────────────────┘
```

## Audio Streaming Flow

```
Audio Engine
     │
     │ PCM Audio Data
     ▼
┌─────────────────┐
│ Uac2AudioSink   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Format Check    │
│ (Match?)        │
└────┬────┬───────┘
     │    │
  Yes│    │No
     │    │
     │    ▼
     │  ┌─────────────────┐
     │  │ AudioPipeline   │
     │  │ (Convert)       │
     │  └────────┬────────┘
     │           │
     └───────────┘
         │
         ▼
┌─────────────────┐
│ RingBuffer      │
│ (Producer)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ RingBuffer      │
│ (Consumer)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ TransferBuffer  │
│ (Fill)          │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Isochronous     │
│ Transfer        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ USB Device      │
│ (DAC/AMP)       │
└─────────────────┘
```

## Control Request Flow

```
User Action (Volume Change)
        │
        ▼
┌───────────────────┐
│ Flutter UI        │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Uac2Service       │
└────────┬──────────┘
         │ FFI Call
         ▼
┌───────────────────┐
│ Rust API          │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Build Control     │
│ Request           │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ USB Control       │
│ Transfer          │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Device Response   │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Update State      │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Notify Flutter    │
└───────────────────┘
```

## Error Recovery Flow

```
Transfer Error
     │
     ▼
┌─────────────────┐
│ Error Detection │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Classify Error  │
└────┬────┬───────┘
     │    │
Retry│    │Fatal
     │    │
     │    ▼
     │  ┌─────────────────┐
     │  │ Fallback        │
     │  │ Handler         │
     │  └────────┬────────┘
     │           │
     │           ▼
     │         ┌─────────────────┐
     │         │ Switch to       │
     │         │ Default Audio   │
     │         └────────┬────────┘
     │                  │
     │                  ▼
     │                ┌─────────────────┐
     │                │ Notify User     │
     │                └─────────────────┘
     │
     ▼
┌─────────────────┐
│ Retry Transfer  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Success?        │
└────┬────┬───────┘
     │    │
  Yes│    │No (Max Retries)
     │    │
     │    └──> Fallback Handler
     │
     ▼
┌─────────────────┐
│ Resume Playback │
└─────────────────┘
```

## State Transition Flow

```
┌──────┐
│ Idle │
└───┬──┘
    │ connect()
    ▼
┌────────────┐
│ Connecting │
└─────┬──────┘
      │
      ├─> Success
      │   │
      │   ▼
      │ ┌───────────┐
      │ │ Connected │
      │ └─────┬─────┘
      │       │ start_stream()
      │       ▼
      │     ┌───────────┐
      │     │ Streaming │
      │     └─────┬─────┘
      │           │
      │           ├─> stop_stream()
      │           │   │
      │           │   └──> Connected
      │           │
      │           └─> disconnect()
      │               │
      │               └──> Idle
      │
      └─> Error
          │
          ▼
        ┌───────┐
        │ Error │
        └───┬───┘
            │ retry()
            │
            └──> Connecting
```

## Buffer Management Flow

```
Audio Engine Thread          USB Transfer Thread
        │                            │
        │ Write Audio Data           │
        ▼                            │
┌──────────────┐                    │
│ RingBuffer   │                    │
│ Producer     │                    │
└──────┬───────┘                    │
       │                             │
       │ Lock-free Write             │
       │                             │
       ▼                             │
┌──────────────┐                    │
│ Shared       │                    │
│ Memory       │◄───────────────────┤
└──────┬───────┘                    │
       │                             │
       │ Lock-free Read              │
       │                             │
       ▼                             ▼
┌──────────────┐            ┌──────────────┐
│ RingBuffer   │            │ Transfer     │
│ Consumer     │───────────>│ Buffer       │
└──────────────┘            └──────┬───────┘
                                   │
                                   │ Submit
                                   ▼
                            ┌──────────────┐
                            │ USB Device   │
                            └──────────────┘
```

## Format Negotiation Flow

```
Source Format              Device Capabilities
     │                            │
     │                            │
     └────────────┬───────────────┘
                  │
                  ▼
         ┌────────────────┐
         │ Compare Formats│
         └────────┬───────┘
                  │
                  ▼
         ┌────────────────┐
         │ Exact Match?   │
         └────┬───┬───────┘
              │   │
           Yes│   │No
              │   │
              │   ▼
              │ ┌────────────────┐
              │ │ Find Best      │
              │ │ Compatible     │
              │ └────────┬───────┘
              │          │
              └──────────┘
                  │
                  ▼
         ┌────────────────┐
         │ Conversion     │
         │ Needed?        │
         └────┬───┬───────┘
              │   │
           No │   │Yes
              │   │
              │   ▼
              │ ┌────────────────┐
              │ │ Configure      │
              │ │ Pipeline       │
              │ └────────┬───────┘
              │          │
              └──────────┘
                  │
                  ▼
         ┌────────────────┐
         │ Configure      │
         │ Stream         │
         └────────────────┘
```

## Hot-plug Event Flow

```
Device Connected/Disconnected
        │
        ▼
┌───────────────────┐
│ USB Event         │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ Connection        │
│ Manager           │
└────────┬──────────┘
         │
         ├─> Connected
         │   │
         │   ▼
         │ ┌───────────────────┐
         │ │ Enumerate Device  │
         │ └────────┬──────────┘
         │          │
         │          ▼
         │        ┌───────────────────┐
         │        │ Register Device   │
         │        └────────┬──────────┘
         │                 │
         │                 ▼
         │               ┌───────────────────┐
         │               │ Notify Flutter    │
         │               └───────────────────┘
         │
         └─> Disconnected
             │
             ▼
           ┌───────────────────┐
           │ Stop Streaming    │
           └────────┬──────────┘
                    │
                    ▼
                  ┌───────────────────┐
                  │ Unregister Device │
                  └────────┬──────────┘
                           │
                           ▼
                         ┌───────────────────┐
                         │ Fallback Handler  │
                         └────────┬──────────┘
                                  │
                                  ▼
                                ┌───────────────────┐
                                │ Notify Flutter    │
                                └───────────────────┘
```
