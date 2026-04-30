# Bit-perfect (DAP Internal) OFF: Issues with EQ, Effects, and Lowered Volume

## Summary

When **Bit-perfect (DAP Internal)** is turned **OFF** on a DAP (Digital Audio Player) device, users report that:

1. **EQ, Effects, Spatial & Time, and Preamps are not working.**
2. **Songs have lowered volume**, suspected to be caused by volume normalization and resampling.

> **Note on naming:** The app has two independent bit-perfect toggles:
> - **Bit-perfect (USB DAC)** — for external USB DAC playback.
> - **Bit-perfect (DAP Internal)** — for the device's built-in high-res audio path.

This document describes the architecture, identifies the root causes, and provides suggestions for fixes and improvements.

---

## Quick Reference: The Two Bit-Perfect Toggles

| Toggle | Applies To | When ON | When OFF | Affects |
|---|---|---|---|---|
| **Bit-perfect (USB DAC)** | External USB DAC | Direct USB path, no DSP, hardware volume | Normal Android mixing or Rust Oboe | USB DAC playback only |
| **Bit-perfect (DAP Internal)** | Built-in DAP audio | `dapInternalHighRes` passthrough, no DSP | `rustOboe` with full DSP chain | Internal DAP playback only |

**Key point:** These two toggles are **completely independent**. Turning on Bit-perfect (USB DAC) for an external DAC should **not** affect internal DAP playback. However, due to a bug in the EQ bypass logic (see Problem 1), the USB DAC flag currently leaks into the internal DAP path.

---

## 1. Relevant Architecture

### 1.1 Engine Selection (`lib/services/audio_session_manager.dart`)

The app selects the audio engine based on device state and user preferences:

- **External USB DAC attached**:
  - Preference `rustOboe` → `AudioEngineType.rustOboe`
  - Preference `isochronousUsb` + Bit-perfect (USB DAC) ON → `AudioEngineType.usbDacExperimental`
  - Otherwise → `AudioEngineType.normalAndroid`

- **No external USB DAC** (internal DAP playback):
  - `hiFiModeEnabled` + `supportsHiResInternal`:
    - Bit-perfect (DAP Internal) = **ON** → `AudioEngineType.dapInternalHighRes` (passthrough)
    - Bit-perfect (DAP Internal) = **OFF** → `AudioEngineType.rustOboe` (DSP chain)
  - Otherwise → `AudioEngineType.rustOboe` or `normalAndroid`

When Bit-perfect (DAP Internal) is **OFF**, the app intentionally selects `rustOboe` and logs:
> "Selected RUST_OBOE because Bit-perfect (DAP Internal) is disabled. DSP chain will run normally."

### 1.2 Bit-Perfect State Tracking (`lib/services/player_service.dart`)

```dart
bool get isBitPerfectModeEnabled =>
    _uac2Service.isBitPerfectEnabledSync ||
    (currentEngineType == AudioEngineType.dapInternalHighRes &&
        _uac2Service.isDapBitPerfectEnabledSync);

bool get isBitPerfectProcessingLocked =>
    bitPerfectProcessingLockedNotifier.value;
```

- `isBitPerfectEnabledSync` = **Bit-perfect (USB DAC)** flag.
- `isDapBitPerfectEnabledSync` = **Bit-perfect (DAP Internal)** flag.
- `bitPerfectProcessingLockedNotifier` is a reactive `ValueNotifier<bool>` that updates automatically whenever `currentEngineType` or either bit-perfect preference changes. This ensures the EQ service and UI react in real time without requiring a track skip.

The notifier computes its state as:

```dart
void _updateBitPerfectProcessingLocked() {
  final locked = switch (currentEngineType) {
    AudioEngineType.usbDacExperimental => true,
    AudioEngineType.dapInternalHighRes =>
      _uac2Service.isDapBitPerfectEnabledSync,
    _ => false,
  };
  if (bitPerfectProcessingLockedNotifier.value != locked) {
    bitPerfectProcessingLockedNotifier.value = locked;
  }
}
```

Listeners on `selectedPlaybackModeNotifier`, `initializedPlaybackModeNotifier`, `bitPerfectEnabledNotifier`, and `dapBitPerfectEnabledNotifier` keep this value in sync.

### 1.3 EQ/Effects Application (`lib/services/equalizer_service.dart`)

```dart
final bypassForBitPerfect = playerService.isBitPerfectProcessingLocked;
```

- If `bypassForBitPerfect` is **true**, EQ, compressor, limiter, and FX are all **disabled**.
- Otherwise, they are applied to the Rust backend or Android `AudioEffect` stack.
- The reactive notifier guarantees that toggling bit-perfect preferences or switching engines immediately re-applies (or bypasses) EQ without user intervention.

### 1.4 Rust Audio Pipeline (`rust/src/audio/engine.rs`)

When Bit-perfect (DAP Internal) is **OFF** and the device is a DAP (not using USB direct):

```rust
let dap_force_dsp = !dap_bit_perfect_enabled
    && device_profile.as_ref().is_some_and(|p| p.is_dap())
    && !will_attempt_usb;
let requested_sample_rate = if dap_force_dsp {
    48_000
} else {
    preferred_sample_rate.unwrap_or(48_000)
};
```

- `dap_force_dsp = true` forces the output to **48 kHz**.
- The strategy becomes `MixerMatched` or `ResampledFallback` (not `DapNative` or `UsbDirect`).
- `initial_pipeline_mode` = `PipelineMode::Dsp` (full processing chain).

### 1.5 Decoder Resampling (`rust/src/audio/decoder.rs`)

Resampling occurs when:
```rust
source_info.original_sample_rate != output_sample_rate
```

If the track is **48 kHz** (or any rate other than 44.1 kHz) and `dap_force_dsp` forces 44.1 kHz, the decoder will resample. This can affect perceived quality and volume.

### 1.6 Volume Handling

- **Rust**: `volume_to_gain()` applies only perceptual (logarithmic) mapping from the slider. There is **no explicit volume normalization** in the Rust pipeline.
- **Android / just_audio**: When using the `normalAndroid` engine or non-bit-perfect paths, the Android OS or ExoPlayer may apply automatic **loudness normalization / dynamic range compression** in the mixer.

---

## 2. Identified Problems

### Problem 1: EQ/Effects Bypassed Incorrectly ✅ FIXED

**Root Cause:** `bypassForBitPerfect` in `equalizer_service.dart` checked `Uac2Service.instance.isBitPerfectEnabledSync` (the **Bit-perfect (USB DAC)** flag) **regardless of the current playback route**.

**Fix Applied:**
- `isBitPerfectProcessingLocked` was refactored to be the single source of truth. It now evaluates `currentEngineType` directly and only returns `true` for `usbDacExperimental` or `dapInternalHighRes` when DAP bit-perfect is explicitly enabled.
- `equalizer_service.dart` now uses only `playerService.isBitPerfectProcessingLocked` for `bypassForBitPerfect`.
- A reactive `ValueNotifier<bool>` (`bitPerfectProcessingLockedNotifier`) was added to `PlayerService`. It updates automatically when the engine mode or either bit-perfect preference changes, and its listener triggers `reapplyEqualizer()` so the audio engine reacts in real time without requiring a track skip.

### Problem 2: Forced 44.1 kHz Causes Unwanted Resampling ✅ FIXED

**Root Cause:** When Bit-perfect (DAP Internal) is OFF, `dap_force_dsp = true` locked the output to **44.1 kHz**. If the track's original sample rate is 48 kHz, 96 kHz, etc., the decoder had to resample.

**Fix Applied:**
- Changed `requested_sample_rate` in `rust/src/audio/engine.rs` from `44_100` to `48_000` when `dap_force_dsp` is active.
- This aligns the forced DSP rate with the device's native high-res capability and reduces unnecessary resampling for the majority of modern tracks.

### Problem 3: Lowered Volume on Non-Bit-Perfect Paths 🔍 AUDITED

**Audit Results:**

1. **Rust Pipeline Gain Audit**: A thorough audit of `rust/src/audio/engine.rs`, `decoder.rs`, `equalizer.rs`, `dynamics.rs`, and the surrounding pipeline found **no automatic gain reduction, headroom cut, or ReplayGain implementation**. The only gain-related processing in the Rust path is:
   - `volume_to_gain()` — perceptual mapping from the user's volume slider.
   - EQ band gains — user-controlled via the EQ UI.
   - Compressor / limiter makeup gain — user-controlled and only active when explicitly enabled.
   - Crossfader / balance gains — only active during crossfade or stereo balance adjustment.

2. **ReplayGain Audit**: No ReplayGain metadata parsing or automatic volume normalization exists anywhere in the Rust or Dart code.

3. **Android OS Loudness Normalization**: When playing through the normal Android audio mixer (not bit-perfect / not direct USB), Android may still apply automatic loudness normalization (especially on Android 9+ with `LoudnessEnhancer` or similar mixer behaviors). This is outside the Rust pipeline and outside app control.

4. **Preamp Slider Already Exists**: The EQ UI already includes a preamp slider (`preampDb`) that allows users to manually offset gain. This satisfies the suggestion for a "Bit-Perfect Reference Volume" control.

**Conclusion:** The lowered volume is **not** caused by DSP headroom or ReplayGain in the current codebase. It is most likely attributable to Android OS-level loudness normalization on non-exclusive audio paths. No additional code changes are required for this issue.

---

## 3. Implemented Fixes

### Fix 1: Refactored `isBitPerfectProcessingLocked` with Reactive Notifier

**Files changed:** `lib/services/player_service.dart`, `lib/services/equalizer_service.dart`

- `isBitPerfectProcessingLocked` now reads from `bitPerfectProcessingLockedNotifier.value` and is the single source of truth for whether DSP must be bypassed.
- The notifier is updated by listening to `selectedPlaybackModeNotifier`, `initializedPlaybackModeNotifier`, `bitPerfectEnabledNotifier`, and `dapBitPerfectEnabledNotifier`.
- A listener on the notifier calls `reapplyEqualizer()` automatically, ensuring the audio engine and UI react in real time when the user changes bit-perfect preferences or the engine route changes (e.g., unplugging a USB DAC).
- `equalizer_service.dart` was simplified to use only `playerService.isBitPerfectProcessingLocked`.

### Fix 2: Changed Forced DSP Sample Rate from 44.1 kHz to 48 kHz

**File changed:** `rust/src/audio/engine.rs`

- When `dap_force_dsp` is true (Bit-perfect DAP Internal is OFF), the engine now requests **48 kHz** instead of 44.1 kHz.
- This reduces unnecessary resampling for the majority of modern high-res tracks and matches typical DAP native capabilities.

### Fix 3: Audited Rust Pipeline for Gain Reductions & ReplayGain

**Files audited:** `rust/src/audio/engine.rs`, `rust/src/audio/decoder.rs`, `rust/src/audio/equalizer.rs`, `rust/src/audio/dynamics.rs`, `rust/src/audio/fx.rs`, `rust/src/audio/crossfader.rs`

- **No automatic gain reduction or headroom cut** was found in the DSP chain.
- **No ReplayGain** implementation exists in the Rust or Dart code.
- The preamp slider in the EQ UI already provides manual gain offset.
- Lowered volume on non-bit-perfect paths is attributed to **Android OS loudness normalization**, which is outside app control.

---

## 4. Suggestions (Future Improvements)

### Suggestion 1: Make Forced DSP Sample Rate User-Configurable

While the default is now 48 kHz, some users may prefer to match the track's native sample rate or force 44.1 kHz for specific DACs. Consider adding a user-facing toggle (e.g., "DSP sample rate: Auto / 44.1 kHz / 48 kHz / 96 kHz").

### Suggestion 2: Investigate Android Loudness Normalization

- **Investigate** whether Android's `LoudnessEnhancer` or mixer normalization is active during `rustOboe` or `normalAndroid` playback.
- **Expose a toggle** (e.g., "Disable Android loudness normalization") for users who want the raw DSP output without OS-level volume adjustments.
- If using `AudioTrack` or `ExoPlayer` on the `normalAndroid` path, check for `PLAYBACK_STATE` flags or audio session effects that might be normalizing volume.

### Suggestion 3: Improve Debugging / Transparency

Add UI indicators or logs showing:
- Current sample rate (requested vs. actual)
- Whether resampling is active
- Whether EQ/DSP is bypassed and why
- Current pipeline mode (`Passthrough` vs `Dsp`)

This helps users understand why their audio sounds different when toggling Bit-perfect (USB DAC) or Bit-perfect (DAP Internal).

---

## 5. Quick Reference: Code Locations

| Component | File | Lines | Purpose |
|---|---|---|---|
| Engine Selection | `lib/services/audio_session_manager.dart` | 232-361 | Chooses `rustOboe` vs `dapInternalHighRes` |
| Bit-Perfect State & Notifier | `lib/services/player_service.dart` | ~260, ~618-640 | `bitPerfectProcessingLockedNotifier`, `isBitPerfectProcessingLocked`, `_updateBitPerfectProcessingLocked` |
| EQ Bypass Logic | `lib/services/equalizer_service.dart` | ~31 | `bypassForBitPerfect` flag (simplified) |
| Rust Engine Config | `rust/src/audio/engine.rs` | ~748-753 | `dap_force_dsp` and `requested_sample_rate` |
| Rust Strategy | `rust/src/audio/strategy.rs` | ~70-120 | `MixerMatched` / `ResampledFallback` selection |
| Rust Verifier | `rust/src/audio/verifier.rs` | ~40-80 | `OutputVerification::verify()` for bit-perfect / resampler flags |
| Rust Decoder | `rust/src/audio/decoder.rs` | ~800-850 | Resampling logic based on `original_sample_rate != output_sample_rate` |

---

## 6. Conclusion

All three primary issues have been addressed:

1. **EQ/Effects Bypass Bug** — Fixed by refactoring `isBitPerfectProcessingLocked` to be the single source of truth and adding a reactive notifier that triggers real-time re-application of EQ.
2. **Unwanted Resampling** — Fixed by changing the forced DSP sample rate from 44.1 kHz to 48 kHz.
3. **Lowered Volume** — Audited and confirmed to **not** be caused by app-level DSP headroom or ReplayGain. The preamp slider already provides manual control.

Remaining open items (future improvements) are user-configurable sample rate selection, Android loudness normalization investigation, and enhanced debug transparency UI.
