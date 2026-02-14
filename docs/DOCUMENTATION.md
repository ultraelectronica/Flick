# Flick Player Documentation

## About Flick Player

**Flick Player** is a modern, high-performance music player application designed for audiophiles and casual listeners alike. Typically running on Linux (and other desktop platforms), it bridges the gap between a beautiful, fluid user interface and a robust, low-level audio processing engine.

The application leverages the power of **Flutter** for a responsive, animated frontend and **Rust** for a stable, efficient backend. Key features include a custom "Function Code" (Audio Engine) that handles playback independent of the OS media controls in some aspects, ensuring high-fidelity audio output.

## Code "Functions" (Core Architecture)

The application behaves as a hybrid system. Here is a breakdown of the key *Function Codes* (modules) that drive the application:

### 1. The Core Audio Engine (Rust)

Located in `rust/src/audio`, this is the heart of the application. It bypasses standard high-level players to give direct control over the audio stream.

- **Engine (`engine.rs`)**: The central coordinator. It runs on a designated high-priority thread to ensure music never stutters, managing the flow of data from the file to the speakers.
- **Decoder (`decoder.rs`)**: Uses `symphonia` to read various audio formats (MP3, FLAC, WAV, OGG) and decode them into raw sound waves (PCM).
- **Resampler (`resampler.rs`)**: Uses `rubato` to change the audio quality on-the-fly. If a song is 44.1kHz but your speakers are 48kHz, this module smooths out the difference without losing quality.
- **Crossfader (`crossfader.rs`)**: Handles the smooth blending between songs, so there is no silence when one track ends and the next begins.
- **Source Provider (`source.rs`)**: Manages the queue for **Gapless Playback**, ensuring there are no awkward pauses between tracks by pre-loading the next song before the current one finishes.

### 2. The Librarian (Scanner & Metadata)

Located in `rust/src/api/scanner.rs` and utilizing `lofty`:

- **Scanner**: Recursively searches user-defined folders for audio files. It uses `rayon` for parallel processing, making it extremely fast even for large libraries.
- **Metadata Parser**: Reads the ID3 tags, Vorbis comments, and covers from files so the UI displays the correct Artist, Album, and Art.

### 3. The Interface (Flutter)

The visual layer that interacts with the user:

- **State Management (Riverpod)**: Keeps the UI in sync with the actual player state. If the song changes in the Rust engine, Riverpod updates the screen immediately.
- **Database (Isar)**: Stores the library information locally. Instead of re-scanning files every time, the app loads them instantly from this fast, local database.
- **Visuals**: Uses `Rive` for complex animations and `Skeletonizer` for loading states, ensuring the app feels "alive".

## Simplified Explanation

Think of **Flick Player** like a professional restaurant kitchen:

- **The UI (Flutter)** is the **Dining Room**. It's decorated beautifully (Styles/Animations), where you (the User) order what you want to hear (Songs/Playlists).
- **The Bridge (FRB)** is the **Waiter**. It takes your order from the dining room and rushes it to the kitchen.
- **The Rust Engine** is the **Chef**. It takes raw ingredients (Audio Files), chops and prepares them (Decoding), seasons them (Resampling/Effects), and cooks them perfectly (Playback).
- **The Scanner** is the **Inventory Manager**. It checks the storage (Hard Drive) to see what ingredients are available and writes them on the Menu (Library).
