# USB DAC Architecture Audit

## Scope

This document audits Flick's Android playback architecture for:

- external USB DAC playback
- sample-rate behavior
- app-only or exclusive playback behavior
- bit-perfect claims

The goal is technical accuracy. "Exclusive" in this document means the app has taken direct responsibility for the USB device path and is no longer relying on Android's shared mixer for that path. It does not mean Android publicly guarantees universal, system-wide hardware exclusivity on every device.

## Executive Summary

Before this refactor, Flick behaved as a broken hybrid:

- the app had a real Rust/libusb direct USB backend on Android
- the app also had an Android-managed Rust/Oboe path and a normal `just_audio` path
- the product-level state model collapsed those paths into a binary `android` vs `usb` decision
- direct USB startup depended on a playback-format side channel that could arrive too late
- if that format registration missed or mismatched, Rust could silently open the Android-managed Oboe path instead of the direct USB path
- Kotlin route reporting could still label the route as USB because a preferred DAC was attached, even when Android was not actually reporting USB as the current shared output route

That combination meant Flick could look like it "owned" the DAC while still depending on Android-managed output. That should not be called verified bit-perfect playback or guaranteed exclusive DAC ownership.

After this refactor, the playback architecture is explicit and mutually exclusive:

- `NORMAL_ANDROID`
- `USB_DAC_EXPERIMENTAL`
- `DAP_INTERNAL_HIGH_RES`

The app now prepares the direct USB path before engine startup, refuses silent USB-direct mismatches, tears down direct USB runtime state when leaving that mode, and surfaces diagnostics that distinguish Android-managed playback from the Rust direct USB backend.

## Mode Classification

### Before Refactor

Flick was effectively in **Mode D: broken hybrid** at the product level.

Reason:

- a true direct USB backend existed in Rust
- an Android-managed Rust path also existed
- the app could request "USB" while still falling back into `android-shared:*`
- the UI and route reporting could still imply direct USB

### Current Codebase After Refactor

Flick now exposes three explicit modes:

1. `NORMAL_ANDROID`
   - `just_audio` / ExoPlayer / AudioTrack style playback
   - Android-managed and mixer-managed

2. `USB_DAC_EXPERIMENTAL`
   - Rust direct USB path through libusb isochronous transfers
   - Android audio focus is requested on the host side
   - USB streaming interfaces can be held across playback sessions
   - still marked experimental because compatibility and hardware verification are not universal

3. `DAP_INTERNAL_HIGH_RES`
   - Rust engine through Oboe / AAudio
   - Android-managed low-latency or high-res attempt
   - not equivalent to direct USB ownership

## Current Pipeline

### Pipeline Diagram

```text
Flutter UI
  -> PlayerService
    -> AudioSessionManager
      -> NORMAL_ANDROID
         -> AndroidAudioEngine
         -> just_audio / ExoPlayer
         -> Android shared output path

      -> USB_DAC_EXPERIMENTAL
         -> Uac2Service.prepareAndroidExperimentalUsbPlayback()
         -> MainActivity.activateDirectUsb()
         -> RustAudioEngine
         -> Rust audio engine
         -> libusb isochronous transfers
         -> USB DAC

      -> DAP_INTERNAL_HIGH_RES
         -> RustAudioEngine
         -> Rust audio engine
         -> Oboe / AAudio
         -> Android-managed internal output path
```

### Actual DAC Path Used Today

The direct USB path is only active when diagnostics report all of the following:

- playback mode is `USB_DAC_EXPERIMENTAL`
- Rust output signature starts with `android-uac2:`
- the Android host reports the direct USB device is registered
- the Rust direct USB debug state reports an active stream or an idle interface lock

If diagnostics instead show:

- `android-shared:*`
- `NORMAL_ANDROID`
- `DAP_INTERNAL_HIGH_RES`

then playback is still Android-managed, even if a USB DAC is attached.

## What the Audit Found

### 1. Where DAC Playback Is Initialized

Relevant entry points:

- Flutter playback routing: `lib/services/player_service.dart`
- session ownership and mode selection: `lib/services/audio_session_manager.dart`
- Android host DAC registration and audio focus: `android/app/src/main/kotlin/com/ultraelectronica/flick/MainActivity.kt`
- Rust direct USB backend: `rust/src/uac2/android_direct.rs`
- Rust Android-managed Oboe path: `rust/src/audio/engine.rs`

### 2. Whether Flick Still Uses Android Shared Audio Paths

Yes, in two cases:

- `NORMAL_ANDROID` is fully Android-managed
- `DAP_INTERNAL_HIGH_RES` is still Android-managed through Oboe / AAudio

Only `USB_DAC_EXPERIMENTAL` bypasses the Android mixer path, and only when the active Rust output signature is `android-uac2:*`.

### 3. Whether USB DAC Mode Is Truly Separate

Now: yes, at the app architecture level.

The refactor now prevents:

- normal Android engine startup in parallel with USB experimental mode
- hidden direct USB runtime state remaining active when switching back to normal or DAP mode
- silent fallback from a requested USB direct path into an Android-managed Rust path when the sample-rate preparation mismatches

### 4. Race Conditions Found

Before refactor, the main race was:

1. Flutter chose the Rust "USB" engine.
2. Rust engine creation used the probed track sample rate.
3. Direct USB backend selection required a pre-registered Android playback format.
4. That format was being pushed later through `syncPlaybackStatus()`.
5. Rust could therefore create `android-shared:*` instead of `android-uac2:*`.

That race is now addressed by preparing the direct USB path before engine startup.

## Why the DAC Could Look Locked at 384 kHz

The most plausible causes in the old architecture were:

1. The app was actually using an Android-managed route.
   - Android or device policy can keep the USB output stream fixed at a preferred or maximum route rate.

2. Direct USB preparation could miss startup.
   - If the direct USB playback format was absent or mismatched, Rust chose `android-shared:*`.

3. Route reporting was optimistic.
   - A preferred DAC being attached could make the UI look USB-centric even when the actual output path was still Android-managed.

Current behavior after refactor:

- `USB_DAC_EXPERIMENTAL` now prepares the USB format before engine init.
- if the direct USB format does not match the actual probed track rate, Rust now rejects the direct request instead of silently creating an Android-managed Rust stream.
- if metadata is not available early enough to prepare the direct USB mode honestly, the app falls back to `NORMAL_ANDROID` instead of pretending direct USB is active.

This improves truthfulness and prevents the broken hybrid. It does not guarantee that Android-managed routes will switch rates per track.

## Why Other Apps Were Still Audible

### On Android-managed routes

Other apps can still be audible because:

- `just_audio` / ExoPlayer uses Android's shared output stack
- Oboe / AAudio with exclusive-sharing requests is still not equivalent to public, universal hardware ownership
- Android audio focus is advisory for app behavior; it is not the same thing as USB hardware ownership

### On the direct USB experimental path

Flick now does two things:

- requests audio focus on the Android host side
- claims USB audio streaming interfaces through the Rust/libusb backend, including an idle lock when enabled

That is stronger than audio focus alone. It is still not enough to claim universal UAPP-level exclusivity across all Android devices because public Android APIs do not provide a standard proof that every competing app is blocked from every possible hardware path.

## Does Flick Own the DAC Directly?

### Honest Answer

Sometimes, conditionally.

Flick only owns the USB DAC directly when:

- `USB_DAC_EXPERIMENTAL` is active
- the Rust engine reports `android-uac2:*`
- the Rust direct USB state reports the USB interfaces are claimed or the stream is active

Outside that state, Flick does not own the DAC directly and should be considered Android-managed.

## Can Flick Honestly Claim Bit-Perfect Playback?

### Current Answer

No verified bit-perfect claim should be made for Android playback in this codebase.

Reasons:

- `NORMAL_ANDROID` and `DAP_INTERNAL_HIGH_RES` are still Android-managed
- the direct USB path avoids Android's shared mixer, but verified bit-perfect playback still depends on the selected alternate setting, the advertised USB transport format, successful clock programming, and end-to-end device-specific behavior
- metadata gaps can require fallback before direct USB is even attempted

The internal capability flag `supportsVerifiedBitPerfect` should therefore remain false on Android.

## Gap Analysis vs UAPP-Like Behavior

What Flick now has:

- explicit direct USB experimental mode
- USB interface claiming in Rust
- optional idle USB lock between tracks
- Android audio focus integration
- deterministic teardown when leaving USB mode
- diagnostics that show whether the path is Android-managed or direct-managed

What Flick still does not prove:

- universal system-wide hardware exclusivity across all Android devices
- guaranteed rerouting or silencing of every other app
- verified bit-perfect delivery
- guaranteed per-track sample-rate switching on Android-managed paths

## Android USB Prompt Reality

The Android chooser dialog with wording like:

- "Use this app for the connected USB device"
- "Always open when this USB device is connected"

is not something Flick can guarantee for every DAC.

Reason:

- Android matches `USB_DEVICE_ATTACHED` manifest filters against the USB device descriptor
- many DACs expose audio class information only on their interfaces, while the device descriptor itself is class `0`
- a generic manifest filter cannot match those interface-only descriptors

What Flick can do reliably:

- enumerate `UsbManager.deviceList`
- identify likely DAC candidates at runtime
- call `UsbManager.requestPermission()` directly once the app is running

What Flick cannot honestly promise:

- a universal UAPP-style auto-launch chooser for every external DAC model using only a generic manifest filter

## Runtime Capability Rules

The refactor adds runtime-derived capability rules:

- `supportsExclusiveUsbOwnership`
  - true only when the direct USB experimental path is active and the USB interfaces are claimed

- `supportsDirectSampleRateSwitching`
  - true only when the direct USB experimental path is active and the reported output sample rate matches the requested track rate

- `supportsVerifiedBitPerfect`
  - false on Android in the current codebase

- `supportsAndroidManagedHighResOnly`
  - true when `DAP_INTERNAL_HIGH_RES` is active

- `supportsInternalDapPathOnly`
  - true when the app is in `DAP_INTERNAL_HIGH_RES` without an attached USB DAC

These are computed from runtime mode selection plus diagnostics, not from optimistic route labels.

## What Is Technically Achievable Now

Achievable in the current codebase:

- honest separation of Android-managed playback from experimental direct USB playback
- deterministic startup and teardown between normal, USB experimental, and DAP internal modes
- per-track direct USB preparation when track format metadata is available before startup
- refusal of silent direct-USB mismatches
- truthful diagnostics for active backend, mixer management, audio focus, and USB claim state
- direct USB diagnostics now expose the selected alternate setting, endpoint, transport subslot / bit resolution, clock request, clock readback, and the last direct USB worker error
- on the direct USB path, the app should treat the engine sample rate as configured intent only; hardware-reported sample rate is only considered known when a USB clock readback succeeds

## What Is Impossible or Unproven

The following should not be claimed without further proof:

- guaranteed hardware exclusivity equivalent to UAPP on every Android device
- guaranteed bit-perfect Android playback
- guaranteed per-track sample-rate switching on Android-managed routes
- proof that `AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE` alone prevents every other app from using the DAC

## Files That Matter Most

- `lib/services/player_service.dart`
- `lib/services/audio_session_manager.dart`
- `lib/services/uac2_service.dart`
- `android/app/src/main/kotlin/com/ultraelectronica/flick/MainActivity.kt`
- `rust/src/audio/engine.rs`
- `rust/src/uac2/android_direct.rs`

## Bottom Line

Before this refactor, Flick could request USB playback while still landing on an Android-managed path and presenting that as if it were direct DAC playback.

After this refactor:

- playback modes are explicit
- engine ownership is singular and deterministic
- direct USB startup is prepared before engine creation
- silent USB-direct mismatches are blocked
- diagnostics now say whether playback is Android-managed or direct-managed

That is materially better and much more honest.

It is still not correct to advertise verified bit-perfect Android playback or guaranteed UAPP-level exclusivity from this codebase alone.
