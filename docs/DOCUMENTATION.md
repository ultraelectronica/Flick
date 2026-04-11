# Flick Player Documentation

## About Flick Player

**Flick Player** is a modern, high-performance music player application designed for audiophiles and casual listeners alike. Primarily running on Android, it bridges the gap between a beautiful, fluid user interface and a robust, low-level audio processing engine with advanced equalizer and effects capabilities.

The application leverages the power of **Flutter** for a responsive, animated frontend and **Rust** for a stable, efficient backend. Key features include a custom "Function Code" (Audio Engine) that handles playback independent of the OS media controls in some aspects, ensuring high-fidelity audio output, along with advanced EQ and FX processing capabilities. The engine supports multiple output paths including USB DAC bit-perfect playback, Android's internal high-resolution audio path (DAP), and standard Android audio output.

### Digital Audio Player (DAP) Support

Flick Player includes support for Digital Audio Player (DAP) functionality through Android's audio subsystem:

- **DAP Internal High-Res Mode**: When no USB DAC is connected, the app can utilize Android's internal DAC in high-resolution mode through Oboe/AAudio in exclusive mode when supported by the device
- **Device Qualification**: The app checks device capabilities (manufacturer, brand, model, and audio capabilities) to confirm bit-perfect support through the internal audio path
- **Sample Rate Handling**: Supports high sample rates up to the device's maximum capabilities
- **Exclusive Mode**: Attempts to open audio streams in exclusive mode for lower latency and better performance when available

#### Supported DAP Brands & Models

The application identifies and optimizes for several known DAP brands and model series:

- **Supported Brands**:
  - FiiO
  - iBasso (including special "Mango Mode" detection)
  - HiBy
  - Shanling
  - Astell&Kern / iRiver
  - Cayin
  - Sony (Walkman series)
- **Known Model Prefixes**:
  - FiiO: M-series (M11, M15, M17, M21, M23, M27), JM-series (JM21)
  - iBasso: DX-series (DX160 through DX340)
  - HiBy: R-series (R3 through R8), M-series (M300, M0 through M8)
  - Astell&Kern: SA, SP, SE, A& series
  - Sony: NW-A, NW-WM, NW-ZX series
  - Other: Any device with a recognized DAP model prefix, no telephony, and high-res internal audio (>= 88.2 kHz) is classified as a DAP and marked as confirmed bit-perfect.

### Engine Architecture

The core audio engine in `rust/src/audio/engine.rs` features a sophisticated architecture designed for high-performance audio processing:

- **Lock-Free Design**: Uses atomic operations and lock-free data structures in the audio callback to prevent audio glitches
- **Multiple Output Strategies**: Dynamically selects between USB Direct, DAP Native, Mixer Bit-Perfect, Mixer Matched, and Resampled Fallback based on device capabilities
- **Real-Time Processing Chain**: Implements a complete DSP chain including volume control, 10-band graphic equalizer, spatial/time FX, dynamics processing (compressor/limiter), playback speed control, and crossfading
- **Bit-Perfect Mode**: Includes a bit-perfect bypass that routes decoded audio directly to output when requested, skipping all DSP processing
- **Continuous Verification**: Constantly monitors and verifies that the actual output matches the requested format for quality assurance
- **Thread Safety**: Properly separates real-time audio processing (lock-free) from control operations (thread-safe)

#### Output Strategies

The engine implements five distinct output strategies:

1. **USB Direct (`UsbDirect`)**: Bit-perfect playback through external USB DACs using libusb isochronous transfers (requires UAC 2.0 feature)
2. **DAP Native (`DapNative`)**: High-resolution audio through device's internal DAC using Oboe/AAudio in exclusive mode
3. **Mixer Bit-Perfect (`MixerBitPerfect`)**: Android mixer path with bit-perfect format matching (Android 14+)
4. **Mixer Matched (`MixerMatched`)**: Android mixer path with sample rate conversion when needed
5. **Resampled Fallback (`ResampledFallback)**: Fallback path with resampling when exact format matching isn't possible

Each strategy is selected based on device capabilities and current playback requirements, with runtime verification ensuring the selected path meets quality expectations. The engine supports multiple output paths including USB DAC bit-perfect playback, Android's internal high-resolution audio path (DAP), and standard Android audio output.

## Planned Features

The current roadmap includes:

- DSD/DSF support
- MQA support
- Poweramp-style EQ filters, including low-pass
- Advanced audio controls such as balance, tempo, damp, filter, delays, size, and mix
- Themes and broader UI customization options
- Album art improvements
- Lyric clickability and sync
- Scrobble settings
- Crossfade and fade controls
- Resampler enhancements
- Advanced audio tweaks
- Visualizations
- Android audio settings
- Bluetooth audio settings
- Internal Hi-Res audio settings
- USB audio tweaks
- Further performance optimizations

## Code "Functions" (Core Architecture)

The application behaves as a hybrid system. Here is a breakdown of the key *Function Codes* (modules) that drive the application:

### 1. The Core Audio Engine (Rust)

Located in `rust/src/audio`, this is the heart of the application. It bypasses standard high-level players to give direct control over the audio stream.

- **Engine (`engine.rs`)**: The central coordinator featuring a lock-free architecture for real-time audio processing. It runs on a designated high-priority thread to ensure music never stutters, managing the flow of data from the file to the speakers. The engine implements multiple output strategies:
  - **USB Direct**: Bit-perfect playback through external USB DACs using libusb isochronous transfers
  - **Android Managed**: Standard audio playback through Oboe/AAudio or the Android mixer
  - **DAP Internal High-Res**: High-resolution audio through the device's internal DAC using Oboe/AAudio in exclusive mode

- **Decoder (`decoder.rs`)**: Uses `symphonia` to read various audio formats (MP3, FLAC, WAV, OGG) and decode them into raw sound waves (PCM).
  - **TODO**: ALAC and M4A files are not yet supported. These formats will not play any sound.
- **Resampler (`resampler.rs`)**: Uses `rubato` to change the audio quality on-the-fly. If a song is 44.1kHz but your speakers are 48kHz, this module smooths out the difference without losing quality.
- **Crossfader (`crossfader.rs`)**: Handles the smooth blending between songs, so there is no silence when one track ends and the next begins.
- **Equalizer (`equalizer.rs`)**: Implements a 10-band graphic equalizer for precise tonal control with parametric band support.
- **FX Processing (`fx.rs`)**: Implements spatial and time effects including balance, tempo, damp, filter, delay, size, mix, feedback, and width for creative audio processing.
- **Android Audio Processing (`android_audio_processing_service.dart`)**: On Android, uses JustAudioProcessingController for enhanced EQ and effects management with real-time processing capabilities.
- **Source Provider (`source.rs`)**: Manages the queue for **Gapless Playback**, ensuring there are no awkward pauses between tracks by pre-loading the next song before the current one finishes.
- **Dynamics Processing**: Includes compressor and limiter modules for dynamic range control when needed.
- **Output Verification**: Continuously verifies that the actual output matches the requested format for bit-perfect playback assurance.

### 2. EQ Preset Management

- **EQ Preset File Service (`eq_preset_file_service.dart`)**: Handles conversion of EQ presets between JSON and TXT formats for import/export functionality.
- **EQ Preset Service (`eq_preset_service.dart`)**: Manages EQ preset operations including saving, loading, and organizing presets.
- **Equalizer Service (`equalizer_service.dart`)**: Applies EQ and FX settings to the audio stream, integrating with both Rust engine and Android processing service.

### 3. The Interface (Flutter)

The visual layer that interacts with the user:

- **State Management (Riverpod)**: Keeps the UI in sync with the actual player state. If the song changes in the Rust engine, Riverpod updates the screen immediately.
- **Database (Isar)**: Stores the library information locally. Instead of re-scanning files every time, the app loads them instantly from this fast, local database.
- **Visuals**: Uses `Rive` for complex animations and `Skeletonizer` for loading states, ensuring the app feels "alive".
  - **Theme Selection**: Implemented with adaptive theming based on album artwork colors, featuring glassmorphism design elements.
  - **Equalizer Screen**: Enhanced UI for managing presets with import/export functionality, renaming, and saving capabilities.
  - **Player Screen**: Immersive mode support with conditional rendering of UI elements and improved lyrics display with tooltip guidance and line-seeking capability.
  - **Full Player Screen**: Optimized layout for various screen sizes with responsive design and high refresh rate support (90Hz/120Hz).

### 4. The Librarian (Scanner & Metadata)

Located in `rust/src/api/scanner.rs` and utilizing `lofty`:

- **Scanner**: Recursively searches user-defined folders for audio files. It uses `rayon` for parallel processing, making it extremely fast even for large libraries.
- **Metadata Parser**: Reads the ID3 tags, Vorbis comments, and covers from files so the UI displays the correct Artist, Album, and Art.

## Simplified Explanation

Think of **Flick Player** like a professional restaurant kitchen:

- **The UI (Flutter)** is the **Dining Room**. It's decorated (Styles/Animations), where you (the User) order what you want to hear (Songs/Playlists).
- **The Bridge (FRB)** is the **Waiter**. It takes your order from the dining room and rushes it to the kitchen.
- **The Rust Engine** is the **Chef**. It takes raw ingredients (Audio Files), chops and prepares them (Decoding), seasons them (Resampling/Effects), and cooks them perfectly (Playback).
- **The Scanner** is the **Inventory Manager**. It checks the storage (Hard Drive) to see what ingredients are available and writes them on the Menu (Library).
