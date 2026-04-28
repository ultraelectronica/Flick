# Hardware Volume Control — Implementation Status

## Summary

Three-tier volume control for the Rust UAC2 isochronous USB DAC path:

| Tier | Mechanism | When |
|------|-----------|------|
| 1 (primary) | UAC2 Feature Unit SET_CUR | DAC reports Feature Unit with volume control selector |
| 2 (fallback) | Rust engine software volume | DAC lacks Feature Unit volume; applied in bit-perfect callback |
| 3 (system) | Android AudioManager.setStreamVolume | Non-direct-USB (shared mode) path only |

## How It Works (Intended)

### Tier 1: DAC has hardware volume

```
UI slider → player_service.setVolume()
  → _hasBitPerfectUsbHardwareVolumeControl() == true
  → uac2_service.setVolume()          (platform channel)
  → Kotlin setRouteVolume()
  → nativeSetRustDirectUsbHardwareVolume()
  → android_direct_set_hardware_volume()   (Rust)
  → open_transient_usb_handle(device_fd)   (re-opens USB)
  → write_feature_unit_i16_control()       (SET_CUR → DAC)
  → Rust engine volume forced to 1.0       (*1.0 = no-op in callback)
```

PCM samples pass through untouched. DAC chip handles analog attenuation.

### Tier 2: DAC lacks hardware volume (software fallback)

```
UI slider → player_service.setVolume()
  → _hasBitPerfectUsbHardwareVolumeControl() == false
  → _rustAudioService.setVolume(clampedVolume)
  → FFI → AudioCommand::SetVolume
  → callback_data.set_volume()            (AtomicU32, lock-free)
  → audio_callback() applies *volume       (bit-perfect path, line ~1368)
```

Still bypasses EQ/dynamics/crossfade. Only a single f32 multiply touches the data.
At f32 precision this is audibly transparent.

### Tier 3: Android system volume (shared mode, non-direct USB)

Falls through to `audioManager.setStreamVolume(STREAM_MUSIC)` in Kotlin.
Not relevant to the USB direct path.

## Current Known Issues / Desynchronization Sources

### 1. transient handle failure during streaming

`open_transient_usb_handle()` (android_direct.rs:2081) opens the USB device via the
Android file descriptor. This creates a **separate** libusb context and handle.
If the streaming path has already claimed the AudioControl interface, the transient
handle's `ensure_interface_claimed()` call logs an error but continues.

The `write_feature_unit_i16_control()` then attempts the SET_CUR on an unclaimed
(or partially claimed) interface. On some USB stacks this silently fails.

**Result:** SET_CUR never reaches the DAC. Volume stays unchanged.
**Fallback:** The Dart `setVolume()` now detects the failure (`hwOk == false`)
and falls back to software volume (Tier 2). If the fallback is not being triggered,
check whether `_hasBitPerfectUsbHardwareVolumeControl()` is returning `true` when
the SET_CUR actually failed (the wrapper in Kotlin may return `success=true` even
if the Rust side returned an error).

### 2. volumeControlWritable gate

`uac2_service.dart:923-926` — if `hasVolumeControl` is true but
`volumeControlWritable` is false, `setVolume()` returns `false` before making
the platform channel call. Check the Kotlin `buildRouteStatus()` output.
After the recent fix, hardware volume mode should always have `volumeControlWritable=true`.

### 3. _currentVolume vs engine volume drift

Two separate volume states exist:
- `_currentVolume` (Dart, player_service.dart:264) — mirrors UI slider
- `callback_data.volume` (Rust, engine.rs:63, AtomicU32) — applied in audio callback

When hardware volume is active, the Rust engine is pinned to 1.0. But if
`_applyRustPlaybackProcessingPolicy()` hasn't been called yet (or was called before
the route status was determined), the engine might be at a stale value ≠ 1.0.

The `_mirrorUsbHardwareVolumeFromUac2Status()` function (player_service.dart:361)
updates `_currentVolume` from DAC hardware changes but never propagates to the
Rust engine. This is correct for the hardware volume path (engine stays at 1.0)
but could desync if switching between modes.

### 4. bit_perfect flag not set

The `bit_perfect` flag on `AudioCallbackData` (engine.rs:69) is only set to `true`
when `verification.bit_perfect` passes (engine.rs:857-860). If clock verification
fails or rate mismatch occurs, `bit_perfect` stays `false` and the callback runs
the full DSP path (which also applies volume — not necessarily a bug, but the
behavior differs from the intended Tier 1/2 paths).

### 5. _hasBitPerfectUsbHardwareVolumeControl timing

This getter (player_service.dart:873) checks `_uac2Service.currentDeviceStatus`
which is updated asynchronously via platform channel. There's a window where
the route status is stale/null and `_hasBitPerfectUsbHardwareVolumeControl()`
returns `false`, causing the code to take the software path even though the
DAC supports hardware volume.

## Debug Logging Recommendations

To identify where the desync occurs, add logs at each junction:

### Dart — player_service.dart setVolume()
```dart
debugPrint('[VolFlow] setVolume($clampedVolume) bp=$isBitPerfectModeEnabled '
    'hwVol=${_hasBitPerfectUsbHardwareVolumeControl()} '
    'rust=$_usingRustBackend');
```

### Dart — uac2_service.dart setVolume()
```dart
debugPrint('[VolFlow] uac2 setVolume($volume) '
    'status=${_currentDeviceStatus?.hasVolumeControl} '
    'writable=${_currentDeviceStatus?.volumeControlWritable}');
```

### Kotlin — setRouteVolume()
```kotlin
Log.d("VolFlow", "setRouteVolume($volume) hwVol=${hasDirectUsbHardwareVolume()}")
```

### Rust — android_direct_set_hardware_volume()
```rust
log::info!("[VolFlow] target_raw={target_raw} min={} max={} res={}",
    control.min_volume_raw, control.max_volume_raw, control.resolution_raw);
```

### Rust — audio_callback volume application
```rust
// After volume=1.0 no-op check:
if volume != 1.0 {
    log::trace!("[VolFlow] callback applying soft vol={volume:.4}");
}
```

## Files Changed

| File | Change |
|------|--------|
| `rust/src/audio/engine.rs` | Bit-perfect path now applies volume scaling |
| `android/.../MainActivity.kt` | Removed live-streaming volume block; removed dead functions |
| `lib/services/player_service.dart` | `setVolume()` + `_applyRustPlaybackProcessingPolicy()` handle software fallback |
| `lib/services/uac2_service.dart` | Added `Uac2VolumeMode.software`; overrides `hasVolumeControl` for software mode |
| `rust/src/uac2/android_direct.rs` | Volume/mute SET_CUR no longer claims/releases AudioControl interface on transient handle; adds GET_CUR verification after write |

## Fix Applied: Transient handle claim/release removed

The transient USB handle in `android_direct_set_hardware_volume` and
`android_direct_set_hardware_mute` was calling `ensure_interface_claimed`
and `release_claimed_interfaces`. Since both the streaming handle and
transient handle share the same Android USB FD:

1. `ensure_interface_claimed` could succeed (same FD == same kernel claim),
   then `release_claimed_interfaces` would release the AudioControl
   interface from under the streaming handle.
2. Even when the claim failed, the control transfer SET_CUR could silently
   not reach the DAC.

Control transfers use endpoint 0 and do not require interface claims on
Android, so the claim/release calls were removed entirely.

A post-SET_CUR GET_CUR verification was added: the readback normalized
volume is compared to the expected value (quantize+denormalize of the
requested volume). If it mismatches beyond resolution-aware tolerance,
the function returns an error, triggering the Dart-side Tier 2 software
volume fallback in `player_service.dart:setVolume()`.
