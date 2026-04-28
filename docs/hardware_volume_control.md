# Hardware Volume Control — Implementation Status

## Summary

Three-tier volume control for the Rust UAC2 isochronous USB DAC path:

| Tier | Mechanism | When |
|------|-----------|------|
| 1 (primary) | UAC2 Feature Unit SET_CUR + GET_CUR verify | `VolumeTier.hardware` — DAC has hardware volume, engine pinned at 1.0 |
| 2 (fallback) | Rust engine software f32 multiply | `VolumeTier.software` — DAC lacks hardware volume, or not on direct USB path |
| 3 (system) | Android AudioManager / just_audio | `VolumeTier.system` — non-direct-USB (shared mode) path, or when no Rust backend |

## VolumeTier State Machine

```
                ┌─────────────────────────────┐
                │        VolumeTier.system      │
                │  (default; non-USB engines)  │
                └──────────────┬───────────────┘
                               │ engine switch to USB DAC
                ┌──────────────▼───────────────┐
                │       VolumeTier.software     │
                │  (_hwVolumeCap == unknown ||  │
                │         unsupported)           │
                └──────────────┬───────────────┘
                 SET CUR ok ▲  │  SET_CUR fail
                            │  │  or capability unsupported
                ┌──────────┘  ▼
                │  VolumeTier.hardware   │
                │  (_hwVolumeCap ==      │
                │       supported)       │
                └───────────────────────┘
```

- `_determineCurrentTier()` fresh-evaluates the tier from `_isDirectUsbPath`, `isBitPerfectModeEnabled`, `_hwVolumeCap`, and `_usingRustBackend`
- `_reconcileVolumeForTier()` is the **single point** that sets the engine volume — called after ANY tier change
- `_activeTier` tracks the current tier for quick reference (e.g., in `_mirrorUsbHardwareVolumeFromUac2Status`)

### Tier transition triggers

| Trigger | Effect |
|---------|--------|
| `setVolume()` | Calls `_determineCurrentTier()`, dispatches to tier-specific logic. On `hardware` tier with `_shouldAttemptHardwareVolume()`, attempts SET_CUR and calls `_onHwVolumeResult()` which may transition tier |
| `_onHwVolumeResult(false)` | Sets `_hwVolumeCap = unsupported` → tier transitions to `software` → `_reconcileVolumeForTier(software)` sets engine to `_currentVolume` |
| `_onHwVolumeResult(true)` | Sets `_hwVolumeCap = supported` → tier transitions to `hardware` → `_reconcileVolumeForTier(hardware)` pins engine to 1.0 |
| UAC2 status null (device disconnect) | `_mirrorUsbHardwareVolumeFromUac2Status(null)` resets `_hwVolumeCap = unknown` → `_reconcileVolumeForTier()` resets for next device |
| `_handleBitPerfectPreferenceChanged()` | Calls `_applyRustPlaybackProcessingPolicy()` which calls `_reconcileVolumeForTier(_determineCurrentTier())` |
| Engine switch | `_handleEngineSwitch()` calls `await _reconcileVolumeForTier(_determineCurrentTier())` after setting `_usingRustBackend` |

## How It Works

### Tier 1: DAC has hardware volume (optimistic attempt)

```
UI slider → player_service.setVolume()
  → tier = _determineCurrentTier() == VolumeTier.hardware
  → _shouldAttemptHardwareVolume() == true  (cache: unknown or supported)
  → uac2_service.setVolume()            (platform channel)
  → Kotlin setRouteVolume()
  → nativeSetRustDirectUsbHardwareVolume()
  → android_direct_set_hardware_volume()     (Rust)
  → open_transient_usb_handle(device_fd)     (separate libusb, no interface claim)
  → quantize_hardware_volume()               (f64 target → i16 raw)
  → write_feature_unit_i16_control()         (SET_CUR → DAC)
  → refresh_android_usb_hardware_volume_snapshot_with_handle()  (GET_CUR readback)
  → quantize_then_normalize(volume, &control)  (expected value)
  → compare readback vs expected (resolution-aware tolerance)
  → if OK: _onHwVolumeResult(true) → _hwVolumeCap=supported,_activeTier=hardware; engine=1.0
  → if mismatch/STALL: _onHwVolumeResult(false) → _hwVolumeCap=unsupported,_activeTier=software; engine=_currentVolume
```

Key details:
- **Optimistic attempt**: No pre-check on `_uac2Service.currentDeviceStatus`. The first volume call on an unknown DAC attempts SET_CUR directly. A STALL or error returns in ~1ms on non-supporting DACs — deterministic and fast. The result is cached in `HwVolumeCapability` (`unknown` → `supported`/`unsupported`).
- **Cache reset**: `_hwVolumeCap` resets to `unknown` when UAC2 status becomes null (device disconnect), so a new DAC is always probed.
- Transient handle does **not** claim/release the AudioControl interface — control transfers on endpoint 0 don't need interface claims on Android, and claiming could conflict with the streaming handle.
- Post-SET_CUR GET_CUR verification compares the readback normalized volume against the expected quantize-then-denormalize result. Tolerance is `(resolution_raw / span) * 0.6` with a 1e-6 floor.
- Resolution-aware quantization ensures the written i16 value is the closest step to the requested f64 volume.

### Tier 2: DAC lacks hardware volume / hardware SET_CUR failed

```
UI slider → player_service.setVolume()
  → tier = _determineCurrentTier() == VolumeTier.software
  → _rustAudioService.setVolume(clampedVolume)
  → FFI → AudioCommand::SetVolume
  → callback_data.set_volume()            (AtomicU32, lock-free)
  → audio_callback() applies *sample *= volume
```

Bypasses EQ/dynamics/crossfade. Single f32 multiply on the output buffer. At f32 precision this is audibly transparent.

### Tier 3: Android system volume (shared mode)

```
UI slider → player_service.setVolume()
  → tier = _determineCurrentTier() == VolumeTier.system
  → just_audio player.setVolume(clampedVolume)
  → OR _rustAudioService.setVolume(clampedVolume) if Rust backend available
```

## Volume State Architecture

Five state variables:

| Variable | File:Line | Contents |
|----------|-----------|----------|
| `_currentVolume` | `player_service.dart:266` | Dart mirror of UI slider. Written by `setVolume()` and `_mirrorUsbHardwareVolumeFromUac2Status()` |
| `_hwVolumeCap` | `player_service.dart:267` | `HwVolumeCapability` cache: `unknown` (fresh/reset), `supported` (Tier 1 verified), `unsupported` (SET_CUR failed/not available) |
| `_activeTier` | `player_service.dart:268` | `VolumeTier` — explicit tracking of which volume path is active (`hardware`, `software`, `system`) |
| `callback_data.volume` (`AtomicU32`) | `engine.rs:63` | f32 bit pattern. Applied in `audio_callback()`. Pinned to 1.0 during Tier 1, holds real value during Tier 2 |
| DAC hardware register (i16 raw) | USB device | Written by `android_direct_set_hardware_volume()`. Read back by GET_CUR for verification |

### Synchronization — Single Reconciliation Point

**`_reconcileVolumeForTier(VolumeTier tier)`** is the only method that sets the engine volume after a tier transition. Every tier change flows through it:

| Caller | When | Reconciliation |
|--------|------|----------------|
| `setVolume()` | User drags slider | `_determineCurrentTier()` → dispatches to tier logic. Hardware tier: attempts SET_CUR, `_onHwVolumeResult()` → `_reconcileVolumeForTier()`. Software/System tiers: set engine volume inline. |
| `_onHwVolumeResult()` | SET_CUR result arrives | Updates `_hwVolumeCap`, then `_reconcileVolumeForTier(_determineCurrentTier())` rechecks tier |
| `_mirrorUsbHardwareVolumeFromUac2Status(null)` | Device disconnect | Resets `_hwVolumeCap = unknown`, `_reconcileVolumeForTier(_determineCurrentTier())` |
| `_mirrorUsbHardwareVolumeFromUac2Status(status)` | DAC knob turn | Updates `_currentVolume`. If `_activeTier == software`, propagates to engine (side-channel update). If `_activeTier == hardware`, engine stays at 1.0 (no propagation needed). |
| `_applyRustPlaybackProcessingPolicy()` | Mode switch | `_reconcileVolumeForTier(_determineCurrentTier())` sets correct engine volume |
| `_handleEngineSwitch()` | Engine change | `await _reconcileVolumeForTier(_determineCurrentTier())` after backend change |

This eliminates drift: each tier transition atomically updates `_activeTier` and sets the engine to the correct volume for that tier.

## Resolved Issues

### ~~1. `_hasBitPerfectUsbHardwareVolumeControl()` timing~~ — **FIXED**

Replaced by optimistic Tier 1 attempt with `HwVolumeCapability` cache. The old gate checked `_uac2Service.currentDeviceStatus` which updates asynchronously — a stale/null status caused false routing to Tier 2. The new approach:
- `_shouldAttemptHardwareVolume()` returns `true` for `unknown` and `supported`, `false` only for `unsupported`
- `_onHwVolumeResult()` caches the result of each SET_CUR attempt
- Cache resets to `unknown` on device disconnect (`_mirrorUsbHardwareVolumeFromUac2Status` receives null status)
- No async status propagation in the critical path — SET_CUR itself fails deterministically (~1ms STALL) on non-supporting DACs

### ~~2. `_currentVolume` vs engine volume drift~~ — **FIXED**

Replaced implicit "which tier am I on?" logic with explicit `VolumeTier` tracking and `_reconcileVolumeForTier()` as a single reconciliation point. Every tier transition (SET_CUR result, device disconnect, bit-perfect toggle, engine switch) flows through `_reconcileVolumeForTier()`, which atomically sets `_activeTier` and the engine volume. `_mirrorUsbHardwareVolumeFromUac2Status()` now checks `_activeTier` to decide whether to propagate DAC knob changes to the engine.

## Current Known Issues / Desynchronization Sources

### 1. `bit_perfect` flag not set

`engine.rs:71` `AtomicBool` defaults to `false`. Only set to `true` when `verification.bit_perfect` passes (engine.rs:~857). If clock verification fails or rate mismatch occurs, callback runs full DSP path (EQ/dynamics/crossfade) instead of the lightweight bit-perfect path. Volume is still applied at end of DSP chain.

### 2. GET_CUR verification on transient handle

`refresh_android_usb_hardware_volume_snapshot_with_handle()` reads back volume via GET_CUR from the **transient** handle (separate libusb context, same kernel FD). If the transient handle's kernel state diverges from the streaming handle's, the readback could pass while the DAC actually missed the SET_CUR. Low-risk — both handles share the same FD.

### 3. `volumeControlWritable` gate in non-hardware modes

`uac2_service.dart:927-930`. When `hasVolumeControl=true` and `volumeControlWritable=false`, `setVolume()` returns `false` without making the platform channel call. Route status parsing (`uac2_service.dart:1338-1347`) overrides this for `Uac2VolumeMode.software` (forces both flags true), so this gate only fires when hardware volume mode is improperly configured — which correctly triggers the Tier 2 software fallback in player_service. Note: this false return will also cache `_hwVolumeCap` as `unsupported`, which is correct behavior since the cache resets on device disconnect.

## Current Logging

### player_service.dart — setVolume()
```dart
debugPrint('[VolFlow] HW path: uac2 setVolume($clampedVolume)');
// After SET_CUR result, _onHwVolumeResult logs tier change
```

### uac2_service.dart — setVolume() (lines 924-951)
```dart
debugPrint('[VolFlow] uac2 setVolume($volume) '
    'status=${_currentDeviceStatus?.hasVolumeControl} '
    'writable=${_currentDeviceStatus?.volumeControlWritable}');
```

### android_direct.rs — android_direct_set_hardware_volume() (lines 2512-2567)
```rust
eprintln!("[VolFlow] min={} max={} res={} -> raw={target_raw}", ...);
eprintln!("[VolFlow] write_feature_unit failed: {e}");
eprintln!("[VolFlow] refresh_snapshot failed: {e}");
eprintln!("[VolFlow] post-SET_CUR volume mismatch: expected={} got={}", ...);
eprintln!("[VolFlow] SET_CUR OK: normalized={}", ...);
```

### engine.rs — audio_callback (lines 1383-1404)
```rust
if volume != 1.0 {
    log::trace!("[VolFlow] callback applying soft vol={volume:.4}");
}
```

## Key Files

| File:Line | Role |
|-----------|------|
| `lib/services/player_service.dart:30` | `HwVolumeCapability` enum: `unknown`, `supported`, `unsupported` |
| `lib/services/player_service.dart:32` | `VolumeTier` enum: `hardware`, `software`, `system` |
| `lib/services/player_service.dart:266` | `_currentVolume` — UI slider mirror |
| `lib/services/player_service.dart:267` | `_hwVolumeCap` — hardware volume capability cache |
| `lib/services/player_service.dart:268` | `_activeTier` — current volume tier |
| `lib/services/player_service.dart:896` | `_shouldAttemptHardwareVolume()` — uses cache, returns false only for `unsupported` |
| `lib/services/player_service.dart:906` | `_isDirectUsbPath` — checks if on direct USB path |
| `lib/services/player_service.dart:910` | `_onHwVolumeResult()` — updates cache + reconciles tier |
| `lib/services/player_service.dart:924` | `_determineCurrentTier()` — fresh evaluation from state |
| `lib/services/player_service.dart:938` | `_reconcileVolumeForTier()` — single point for engine volume after tier change |
| `lib/services/player_service.dart:3133` | `setVolume()` — tier-dispatched volume control |
| `lib/services/player_service.dart:367` | `_mirrorUsbHardwareVolumeFromUac2Status()` — DAC change mirror + cache reset on disconnect |
| `lib/services/player_service.dart:2182` | `_applyRustPlaybackProcessingPolicy()` — reconciles volume on mode switch |
| `lib/services/uac2_service.dart:20` | `Uac2VolumeMode` enum: `system`, `hardware`, `software`, `unavailable` |
| `lib/services/uac2_service.dart:924` | `setVolume()` — platform channel call + `volumeControlWritable` gate |
| `lib/services/uac2_service.dart:1338` | Route status parsing — `Uac2VolumeMode.software` override |
| `rust/src/uac2/android_direct.rs:2512` | `android_direct_set_hardware_volume()` — SET_CUR + GET_CUR verify |
| `rust/src/uac2/android_direct.rs:2081` | `open_transient_usb_handle()` — no interface claim, empty `claimed_interfaces` |
| `rust/src/uac2/android_direct.rs:2197` | `write_feature_unit_i16_control()` — SET_CUR on feature unit |
| `rust/src/uac2/android_direct.rs:2461` | `refresh_android_usb_hardware_volume_snapshot_with_handle()` — GET_CUR readback |
| `rust/src/uac2/android_direct.rs:2569` | `android_direct_set_hardware_mute()` — same pattern as volume |
| `rust/src/audio/engine.rs:63` | `AudioCallbackData.volume` (`AtomicU32`) — lock-free f32 volume |
| `rust/src/audio/engine.rs:71` | `AudioCallbackData.bit_perfect` (`AtomicBool`) — bypass DSP flag |
| `rust/src/audio/engine.rs:1383` | Audio callback bit-perfect path — volume applied as `*sample *= volume` |
| `rust/src/audio/engine.rs:1672` | `AudioCommand::SetVolume` handler |

## Design History

- **Transient handle claim/release removed** (commit `2781fc2`): `android_direct_set_hardware_volume` and `android_direct_set_hardware_mute` previously called `ensure_interface_claimed`/`release_claimed_interfaces` on the transient handle. Since both handles share the same Android USB FD, the release could tear down the AudioControl interface claim from under the streaming handle. Control transfers on endpoint 0 don't require interface claims on Android, so these calls were removed entirely.
- **GET_CUR post-write verification** (commit `2781fc2`): After SET_CUR, a GET_CUR readback compares normalized volume to the expected value. Mismatch beyond resolution-aware tolerance returns an error, triggering Tier 2 software fallback.
- **`Uac2VolumeMode.software`** (commit `9a8b053`): Added to distinguish DAC hardware volume from Rust engine software fallback in route status. When a direct USB DAC is registered but no hardware volume controls are reported, the route parser overrides to `software` mode with `hasVolumeControl=true` and `volumeControlWritable=true`, enabling the correct Dart-side routing.
- **Optimistic Tier 1 with capability cache**: Replaced `_hasBitPerfectUsbHardwareVolumeControl()` (which checked async status that could be stale/null) with `HwVolumeCapability` cache (`unknown`/`supported`/`unsupported`). Default is `unknown` → always attempts SET_CUR on first call. Cache resets on device disconnect. SET_CUR STALL on non-supporting DACs is fast (~1ms) and deterministic. `_shouldAttemptHardwareVolume()` only returns `false` for `unsupported` (cached from a previous failed attempt), skipping the USB transfer entirely for known-unsupported DACs.
- **VolumeTier state machine with reconciliation**: Replaced implicit tier routing (scattered `_hasBitPerfectUsbHardwareVolumeControl()` checks + `_currentVolume` drift) with explicit `VolumeTier` tracking and `_reconcileVolumeForTier()` as the single point that sets engine volume after any tier transition. `_determineCurrentTier()` fresh-evaluates from state. `_activeTier` tracks the current volume path. `_mirrorUsbHardwareVolumeFromUac2Status()` checks `_activeTier` to decide whether to propagate DAC knob changes to the engine.