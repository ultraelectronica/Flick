# Native DSD on DAP Internal DAC (HiBy R4) — Phased Plan

Goal: make DSF / DFF / WavPack-DSD play as **pure native DSD** through the DAP's
internal DAC — matching what the stock HiBy Music player achieves — not DoP,
not PCM decimation.

**Approach (decided after Phase 0 recon):** HiBy's firmware ships a **public
native shim library** (`libsmartaudioservice.so`, listed in
`/system/etc/public.libraries.txt` → loadable by any app including
untrusted_app) that creates framework `AudioTrack`s with
`AUDIO_FORMAT_DSD_NATIVE`. Stock HiBy Music uses exactly this path. Flick will
`dlopen` the same shim from Rust and drive it — no SELinux fight, no
`/dev/snd`, no Kotlin/JNI needed.

**Direct ALSA is dead on the R4**: SELinux `permissive=0` denies
`untrusted_app` read/search on `/dev/snd` (`audio_device` label). The
original ALSA-based phases (probe via HW_REFINE, per-DAP ALSA hints, ALSA
settings UI) are obsolete; kept in git history and summarized in §G/H.

Companion docs: `docs/DSD_ARCHITECTURE.md` (current architecture),
`docs/audio/usb-dsd-bitperfect-plan.md` (USB `UsbDsdNative` — complete, shipped
v0.20.4-beta.5+), `docs/DSD_CPP_NATIVE_OUTPUT_PLAN.md` (superseded C++/tinyalsa
draft).

**Failure policy** (decided): when DSD output mode is `native` and native fails,
fall back to DoP **and surface the exact failure reason** in diagnostics.

---

## A. Already exists and verified (no reimplementation)

| Area | Where | Why it's right |
|------|-------|----------------|
| DSD decode (DSF/DFF/WavPack) | `rust/src/audio/dsd_engine/` (`OPEN_DSD_NATIVE`) | Working — already feeds DoP and USB-native paths. |
| DSD byte stream access | `dsd_engine/output/mod.rs` | The engine already emits raw DSD bytes for DoP/USB-native; the shim backend re-packs them into 32-bit wire subslots. |
| Native f32 packing | `dsd_engine/output/mod.rs:185` `pack_native_dsd_f32` | Interleaved frame-major f32s, DSD byte in low 8 bits, per-byte bit-order normalize (`DSD_BIT_REVERSE_OVERRIDE` global). Used by old `DsdNativeBackend`; the shim backend reuses the same normalize plumbing. |
| USB native DSD packer | `uac2/android_direct.rs` `encode_usb_pcm_slots` | Existing 32-bit-slot packer (BE/LE/bit-reverse variants) — the model for the shim wire packer. |
| USB native DSD | `uac2/android_direct.rs` (`UsbDsdNative`) | Complete incl. `KNOWN_DSD_QUIRKS`; proves the render-thread + ring + fallback architecture. |
| Old direct-ALSA DSD ioctl engine | `dsd_alsa_direct.rs` | Kept for rooted/friendly devices (desktops, some ROMs); not usable on the R4 (SELinux). |
| DSD output mode plumbing | Dart `uac2_preferences_service.dart:12` → `rust_audio_service.dart:315` → `audio_api.rs:59-66` | Enum `{auto, forcePcm, forceDop, native}` already exists end-to-end; `native` option present in UI (`uac2_preferences_screen.dart:1553`). |

## B. Why the R4 currently falls back to DoP (traced)

Two candidate paths both produce the observed log
(`strategy=DSD DoP`, `dsdTransport=dap-dop`,
`verifyReason="Native DSD unavailable on this device."` — engine.rs:2030):

1. **Probe said no.** `device.rs:191-238` `classify_device`:
   `supports_native_dsd = audio_caps ‖ ENCODING_DSD runtime probe ‖ dsd_alsa_probe()`.
   The ENCODING_DSD probe (`dsd_native_jni.rs`) fails on the R4 HAL;
   `dsd_alsa_probe()` finds `/dev/snd` nodes but **opening them is SELinux-denied**.
2. **Open failed.** Native attempted; `DsdNativeBackend::start` errored → engine
   returns `Err("DSD_NATIVE_FALLBACK:<reason>")` (engine.rs:1834) →
   `audio_api.rs:994-1007` catches, retries with `DsdNative` excluded → DoP.

Strategy scoring (`strategy.rs`): `UsbDsdNative 115 > DsdNative 110 >
DapNative 100 > DsdDoP 90`; engine.rs:1510-1522 forces DoP when effective mode is
DoP; rate overrides at engine.rs:1528-1565.

The fallback reason is currently invisible to Dart diagnostics (needs logcat
`[DSD-ALSA]` / `[DSD-STRATEGY]`) — gap G3 still applies to the new backend.

## C. Confirmed gaps

| # | Gap | Severity | Location |
|---|-----|----------|----------|
| G1 | No true capability probe for the shim path: `supports_native_dsd` must now mean "shim `create_track` succeeded (or is likely to)". Probe = dlopen + create + first write; results not cached per-device with reasons. | High | new `dsd_sas_shim.rs`, `device.rs:191` |
| G2 | No per-DAP wire hints (bit order, slot endianness) — only USB has a quirk table. Bit order on the R4's DAC is unknown. | High | shim packer |
| G3 | Native failure reason (`DSD_NATIVE_FALLBACK:<reason>`) never reaches Dart diagnostics — log shows `refusal=none, lastError=none`. | High | `engine.rs:1834`, `audio_api.rs:994` |
| G4 | Audio-focus/interruption handling on the shim render loop (stop/flush on focus loss, resume on regain). | Med | new backend |
| G5 | DSD bit order on the R4 DAC unknown; `DSD_BIT_REVERSE_OVERRIDE` is a global, not per-playback. Wrong order ⇒ loud noise. | High | `dsd_engine/output/mod.rs` |
| G6 | Which DSD rates the shim/HAL accepts (policy table says DSD64..DSD1024 wire rates 88 200..1 411 200) — must be verified per-rate at runtime, not assumed. | Med | shim probe |
| U0 | **Resolved by Phase 0** — see §G. | — | — |

## D. Phases

### Phase 0 — Device recon  ✅ complete (findings in §G, artifacts in /tmp/opencode/)

SELinux kills direct ALSA; HiBy Music itself runs as `untrusted_app` and uses a
public shim; full wire protocol + shim ABI reverse-engineered from
`libsmartaudioservice.so` (see §G.3, §H).

### Phase 1 — Rust shim backend (new transport)  ✅ complete (see §H for corrected ABI)

`rust/src/audio/dsd_sas_shim.rs` — implemented, compiled, verified on device:

- `dlopen("libsmartaudioservice.so")` (public lib — allowed for untrusted_app),
  `dlsym` `create_track` / `release_track`; `probe_unavailable_reason()` feeds
  `classify_device`.
- ABI corrections vs the initial RE (§H): **write is slot `[0x00]`** (slot 0x08
  is a soft-stop — calling it as write silently kills the track), vtable slots
  are PLT stubs, the write wrapper **returns `len` unconditionally** when a
  track exists (real `AudioTrack::write` result is discarded), and
  `create_track` returns **NULL** if the initial track creation fails.
- Packer: `pack_wire_frames` — stereo wire frames of `2×g` B (L+R g-byte
  subslots; `g` = runtime grouping 4/2/1, default **U8** byte-interleaved,
  calibrated on the R4), 4 runtime bit-order variants (`SasWireVariant`),
  default `RawBe` (MSB-first). Phase 3 calibrated both axes.
- Render loop (`dsd_native_backend.rs::dsd_sas_render_loop`): one HAL period
  per write — 32 768 wire frames = 262 144 B, matching HiBy's golden write
  granularity; chunk size derived from the probe-verified `write_size`.
- Probe: create + start + silence (0x69) write ladder
  (262 144 → 524 288 → 1 048 576 → 2 097 152 B) on a watchdog thread
  (4 s attempt timeout). Full write ⇒ verified; teardown + DoP fallback reason
  otherwise. On the R4 the first rung (262 144 B) already succeeds.
- Verified track internals on R4 (log_track_internals): `transfer=3`
  (TRANSFER_SHARED — HiBy patched `AudioTrack::write` to accept SHARED on
  offload tracks), `frameSize=1` (set() forces 1 for non-proportional formats),
  `status=0`, flags `0x11` DIRECT|COMPRESS_OFFLOAD.

### Phase 2 — Strategy / engine integration  ✅ complete

- Transport selected inside `DsdNativeBackend::start` (SAS offload first, ALSA
  direct fallback); strategy stays `DsdNative` (score 110 > DoP 90).
- `device.rs classify_device`: `supports_native_dsd |= sas_shim_available()`.
- Engine rate override: byte rate (= DSD rate/8) as before; wire rate = /32.
- `dsd_transport` diagnostic string: `dap-native-offload`
  (via `native_transport_name()`).
- **G3 fix done**: `DSD_NATIVE_FALLBACK:<reason>` recorded in
  `audio_api.rs` (`last_dsd_native_failure`) and surfaced in Dart
  diagnostics via `verifyReason`.
- Logging fixes: `assert_android_debug_logging()` re-asserts
  `log::set_max_level(Debug)` at `audio_init`/`audio_play`/`audio_queue_next`
  (FRB's bundled android_logger 0.15 clobbers the global max level after
  init, killing all Rust logs ~0.6 s after boot); `DSD_OUTPUT_MODE` static
  defaults to Auto so an unsync'd engine cannot silently decimate.

### Phase 3 — Wire-format calibration (G5, G2)  ◐ in progress

- Runtime-selectable packer variant (`SasWireVariant`: RawBe/RawLe/BitRevBe/
  BitRevLe, default RawBe) implemented; **FRB/Dart exposure shipped
  2026-08-30** — `audio_set_sas_wire_variant(variant: u8)` → preference
  `DsdWireVariant` (`dsd_wire_variant`) synced in
  `_syncDsdTransportOverrides`, plus Settings → Experimental → DSD →
  **DAP Native Bit Order** (Auto/BE-MSB/LE-MSB/BE-LSB/LE-LSB). The packer
  reads the variant per wire write, so changes apply live while playing.
- 2026-08-30 wired-HP A/B: **all four bit-order variants hiss** while stock
  HiBy Music is silent on the same DSD128 + headphones → the defect is
  ABOVE bit order (grouping/packing level). Deep RE of `libhibyservice.so`
  (pulled from the APK) settled it:
  - Stock logcat: `create_track(5644800, 2, 6, 1)` — same fmt 6 as ours, and
    the engine write path (`0x4450d8`) is a verbatim `memcpy` (no byte
    transform anywhere; zero `rbit` in the lib) → wire bytes = decoder
    output, so the packing difference is ours alone.
  - Engine drain loop (`0x42bd20`) memsets **0x69** (SACD silence) before
    stop — our 0x55 was wrong.
  - Audioserver arithmetic: DSD output opens at `bit_rate/32` Hz with
    channel mask 0x3 and **4 B per stereo frame** (705 600 B/s for DSD128)
    = two 16-bit subslots → **U16 (LL|RR) grouping**, not the U32
    (LLLL|RRRR) we shipped. Grouping is orthogonal to the 4 bit-order
    variants, which is exactly why all four hissed.
- Fix shipped 2026-08-30: runtime grouping (`SasWireGrouping` U32/U16/U8)
  alongside the bit order — `audio_set_sas_wire_grouping` → preference
  `DsdWireGrouping` (`dsd_wire_grouping`) + Settings → Experimental → DSD →
  **DAP Native Byte Grouping** (Auto/U32/U16/U8); silence byte 0x69;
  stock-exact `create_track(bit_rate, 2, 6, 1)`; corrected vtable slot for
  stopped (0x28, not 0x40 — see §H).
- **Calibration result (2026-08-30, wired HP):** U8 grouping + MSB-first
  (LE-MSB ≡ BE-MSB at 1-byte subslots) = **clean playback with a light
  continuous crackle**; every other combo (U8+LSB, all U16, all U32) =
  loud hiss. So the wire format is plain byte-interleaved LRLR, MSB-first
  — the audioserver's 4 B/frame @ wire_rate is 4 interleaved bytes, not
  two 16-bit subslots (the U16 inference above was wrong).
- **Crackle root cause + fix (2026-08-30):** `audio_callback`'s
  silence fills (pause, short ring reads, `try_lock` misses) emit `0.0`,
  which packs to wire byte `0x00` = sustained DC = pops. Ring headroom is
  thin (SOURCE_BUFFER_SIZE 480k samples vs 262 144-sample write chunks),
  so partial reads are routine. Fix: `AudioCallbackData.dsd_wire_silence`
  flag (set by the DSD native backend around its render thread) makes
  `fill_silence()` emit `f32::from_bits(0x69)` — the SACD silence byte —
  on the paused/DoP/passthrough fill paths. PCM outputs keep 0.0.
- **Defaults baked (2026-08-30):** grouping auto → U8 (Rust
  `WIRE_GROUPING` default 2, Dart auto→2), bit order auto → BE/MSB.
- Also 2026-08-30: the diagnostics sheet's "Output rate" row now shows
  the DSD bit rate (e.g. 2.82 MHz, matching the R4's own indicator)
  instead of the ÷8/÷16/÷32 transport rate, and matches against any
  valid transport domain.
- **Residual-crackle round 2 (2026-08-30):** 0x69 fill improved clarity
  (zero-fill DC confirmed as a contributor) but a light crackle remained.
  Two more fixes shipped:
  1. **DSF/DFF short-read bug (primary):** `read_dsd_bytes` did a single
     `file.read(buf)`; FUSE storage routinely returns short reads, and a
     short read not a multiple of the DSF macro block (8192 B) had its
     tail silently dropped by `deinterleave_sequential_blocks` → channel
     skew + periodic ticks. Both decoders now loop-read to buffer-full
     or EOF (dsf_decoder.rs, dff_decoder.rs).
  2. **Lock-miss full-chunk silence:** the RT callback's plain
     `sources.try_lock()` missed whenever Dart polled progress → a whole
     262 144-sample chunk of 0x69 = one pop. `lock_sources_rt()` now
     yield-retries (≤64) first; both passthrough and DoP branches count
     `dsd_lock_misses` / `dsd_starved_samples` (AtomicU64) and the SAS
     render loop logs warn-on-change telemetry
     (`[DSD-NATIVE] starvation telemetry: …`) so any remaining audibility
     has a paper trail.
- **UI readouts fixed (2026-08-30):** UAC2 screens showed the transport
  domain ("705.6kHz / 8-bit" for a 5.6 MHz DSD128). `Uac2AudioFormat`
  gained DSD-aware getters (`isDsdStream`, `dsdBitRateHz`, `dsdRateLabel`,
  `displayRateLabel`, `compactRateLabel`, `bitDepthLabel`); the settings
  screen rows, preferences subtitle, player-status chips/badges and the
  status indicator chip now render "5.6 MHz · DSD128" / "1-bit (DSD)".
  Also: `supportsVerifiedBitPerfect` was missing the `dsd_native` /
  `dsd_dop` strategies → verified capsule/indicator never lit on the DSD
  path (fixed in player_service.dart).

### Phase 4 — Settings  ✅ complete (2026-08-30)

- `DsdOutputMode.native` already in UI.
- Bit-order override shipped: Settings → Experimental → DSD → DAP Native
  Bit Order (Auto/BE-MSB/LE-MSB/BE-LSB/LE-LSB), persisted via
  `uac2_preferences_service.dart` (`dsd_wire_variant`), synced via
  `rust_audio_service.dart` `_syncDsdTransportOverrides` beside the DSD
  output mode; applies immediately to the next wire write for live A/B.
- Byte-grouping override shipped 2026-08-30: DAP Native Byte Grouping
  (Auto/U32/U16/U8, `dsd_wire_grouping`), same live-apply plumbing.

### Phase 5 — Verification  ◐ in progress

2026-08-30 first native-DSD stream ACHIEVED (speaker route): our client track
(pid Flick) visible in `dumpsys media.audio_flinger` — fmt `1A000001`,
srate 176400, FrmCnt 32768, offload thread, Active — byte-identical to HiBy's
golden capture. Playback looped (LoopMode.all) across track end with a clean
engine rebuild; transient `Resampled fallback` diagnostics line during the
rebuild window is normal, final state `strategy=DSD native … dsdTransport=
dap-native-offload … bitPerfect=true`.

**Open issue (routing):** with no wired headphones plugged, policy routes the
offload output to SPEAKER (0x2) and the HAL does NOT throttle — the frames
counter advances ~5.4 M fps (30× real time), the ring drains at decoder speed
(song of 326 956 ms "finished" in ~208 s) and audio is discarded/garbage.
Golden capture proves the WIRED_HEADPHONE (0x8) route paces exactly
176 400 fps. ~~Next: plug headphones, re-verify pacing + audibility.~~
2026-08-30: wired-HP route re-verified — pacing correct, HiBy's rate
indicator shows 5.6 MHz (native DSD128 confirmed end-to-end); remaining
defect is the wire packing (hiss on all four bit-order variants →
grouping-level, see Phase 3).

Remaining: E.2 with headphones, E.3 bit order, E.4 regression matrix.

## E. Verification procedures

### E.1 Framework-state readback (primary)

`/proc/asound` is SELinux-blocked, so verify via framework dumps:

```sh
D="-s 764b099f"
adb $D shell dumpsys media.audio_flinger   # expect track fmt 1A000001, srate=bitrate/32, FrmCnt 32768 on offload thread (AudioOut_18B5)
adb $D shell dumpsys media.audio_policy    # expect routing to compressed_offload output
adb $D logcat -d -s audio_hw:V audioflinger:V
```

Success = our track row matches HiBy's golden capture (§G.3): format
`0x1A000001`, rate `bit_rate/32`, offload thread, wired-HP device.

### E.2 Golden-reference A/B

1. Play Chiquitita DSD128 in HiBy Music → `dumpsys media.audio_flinger`
   (golden: AudioOut_18B5, fmt 1A000001 srate 176400 FrmCnt 32768).
2. Same file in Flick, native mode → same capture.
3. Identical fmt + srate + thread type ⇒ driving the DAC exactly like the
   vendor player. Bit order only affects audible correctness → E.3.

### E.3 Bit-order sanity

Kernel/HAL accepts any bit order; wrong order = loud static. Quiet solo piano
DSD64; flip variant if noisy; confirm silence floor A/B vs stock player.
Remaining: confirm the short-read + lock-retry fixes remove the residual
light crackle on U8+MSB (watch for `starvation telemetry` warns in logcat —
growth mid-track marks any remaining starve/lock-miss source).

### E.4 Regressions

- DoP fallback still engages (`forceDop` mode + induced shim failure).
- PCM paths unaffected. USB `UsbDsdNative` unaffected (shim backend only
  active for DAP internal route).
- `cargo check` host + `aarch64-linux-android` (or `--target` used by
  build script), `flutter analyze`.
- HiBy Music must still play after our track is released (no device leak).

## F. Command sheet (adb, what actually works on the R4)

```sh
D="-s 764b099f"                     # HiBy R4 (USB transport)
adb $D shell dumpsys media.audio_policy     # output profiles incl. DSD_NATIVE rates
adb $D shell dumpsys media.audio_flinger    # per-thread HAL formats + track rows
adb $D logcat -d | grep -i -e dsd -e audio_hw -e AudioFlinger
# blocked for shell/app (SELinux): /proc/asound/*, /dev/snd/*
# public native lib (pullable via shell):
adb $D pull /system/lib64/libsmartaudioservice.so
adb $D shell cat /system/etc/public.libraries.txt
# drive Flick via intent (UI has no uiautomator semantics):
adb $D shell am start -a android.intent.action.VIEW \
  -d content://media/external/audio/media/<id> -t audio/dsd \
  -n com.mossapps.flick/.MainActivity
```

## G. Phase 0 findings (recon complete)

| Item | Value |
|------|-------|
| Device | HiBy R4, Android 12, kernel 4.14.190-perf aarch64, SELinux **Enforcing**, no root. `adb -s 764b099f`. |
| `/proc/asound`, `/dev/snd` for apps | **DENIED** (`untrusted_app` vs `audio_device`, permissive=0). Direct ALSA impossible from any app incl. HiBy Music (uid 10077, also `untrusted_app`). |
| HiBy Music native DSD mechanism | Framework offload AudioTrack: fmt `0x1A000001` `AUDIO_FORMAT_DSD_NATIVE` @ wire rate = DSD/32 (176 400 for DSD128), stereo, frame count 32 768, client flags **plain 0x0** (policy routes by format+rate), offload thread `AudioOut_18B5`, HAL flags 0x31, device WIRED_HEADPHONE (id 2156, tag h2w). Wire frame = 8 B = 2×32-bit subslots (proven by frames-written math). |
| Policy DSD support | `compressed_offload` output: `AUDIO_FORMAT_DSD_NATIVE` @ 88 200 / 176 400 / 352 800 / 705 600 / 1 411 200 (= DSD64/128/256/512/1024), stereo. Also `dsd_compress_passthrough` output with `AUDIO_FORMAT_DSD` @ bit-rate domain (2 822 400/5 644 800). |
| Java/framework | `framework.jar` has **no** DSD AudioFormat constants — Java cannot construct DSD tracks; HiBy's track creation is 100% native C++ via the shim. |
| Shim | `/system/lib64/libsmartaudioservice.so` — public (in `public.libraries.txt`), 19.7 KB, dlopens `libaudioclient.so`, creates the real `AudioTrack`. Full ABI: §H. All `sas_*` exports are no-op stubs. |
| HAL param probe | HiBy HAL exposes `get_dsd_modes` audio parameter (string in `libhibyservice.so`); R4 reports dsdMode bitmask (e.g. `00000004`), `hb_get_current_device_supported_dsd_modes dsdmods 5`. |
| Flick today | Plays DoP on `androidManagedLowLatency` (managed path); `PcmAlsaBackend` direct-ALSA PCM bypass NOT actually usable on R4 (SELinux — earlier "works on R4" log showed managed path; presumably another device/firmware). |
| Recon artifacts | `/tmp/opencode/`: `ap_dump.txt` (policy), `af_full.txt`/`af_live.txt` (flinger), `hiby_play_log.txt` (logcat), `apc.xml`, `libsmartaudioservice.so`, `libaudioclient.so`, `framework.jar`, `hiby_music.apk`, `hiby_src/` (jadx), `hiby_libs/`. |
| Test media on device | MediaStore id 621 = Keane DSD64 `.dsf`; 644/646/647 = ClariS DSD256 `.dff`; 351 = Police DSD64; **1727 = ABBA Chiquitita DSD128 `.dsf` (duration 326 956 ms), primary test track**. |
| First native stream (2026-08-30) | Flick debug build via shim: our client track fmt `1A000001` srate 176400 FrmCnt 32768 Active on offload thread — matches golden. Probe write 262 144 B → full. Track internals transfer=3 frameSize=1 flags 0x11. |
| Route caveat | Speaker route (no HP plugged): HAL does not throttle — frames counter ~5.4 M fps (30×), ring drains at decoder speed, audio discarded. Wired-HP route paces exactly 176 400 fps (golden). Native DSD verification/A-B requires headphones plugged. |
| Logging gotchas | FRB bundles android_logger 0.15 which clobbers global max_level after init (all Rust logs die ~0.6 s post-boot) → `assert_android_debug_logging()` re-assert at audio_init/play/queue_next. `dev_eprintln!` never reaches logcat — use `log::info!`. `logcat` rotates fast (Uac2Service polls ~10 lines/s) — capture evidence promptly. |

## H. libsmartaudioservice.so ABI (reverse-engineered, device-verified)

```
create_track(p0=bit_rate: i32, p1: i32, p2=format_type: i32, p3: i32) -> *mut SasTrack
  - fmtType 1..3 → PCM variants; fmtType 5..10 → DSD: format 0x1A000001,
    wire_rate = (bit_rate + 31) >> 5 (i.e. /32, rounding), channel mask 3,
    flags 0x10 COMPRESS_OFFLOAD, streamType MUSIC, frameCount 0 (→32768),
    TRANSFER_DEFAULT(shared), 64-byte offload_info template.
  - Returns 0x58-B vtable object; ctx (0x58 B) at obj[0x50];
    ctx[+0x1c]=bit_rate, ctx[+0x24]=fmt_type, ctx[+0x28]=state,
    mutex at ctx+0x2c, track sp<> at ctx[+0x8].
  - ensure_track(ctx) runs BEFORE mutex/vtable init; NEGATIVE result →
    free(obj+ctx) → returns NULL (a null create_track = real failure, not OOM).
  - Property sys.audio.uac.bluetooth=="true" switches a BT format table (ignore).

SasTrack vtable (slots hold PLT STUB addresses; first arg = obj):
  obj[0x00] write(obj, buf: *u8, len: usize) -> i32   # → AudioTrack::write(…, blocking=true);
                                                       # returns len UNCONDITIONALLY when a track
                                                       # exists (real result discarded!); 0 only
                                                       # when ensure_track failed
  obj[0x18] start(obj)                                # AudioTrack::start
  obj[0x20] flush(obj)                                # AudioTrack::flush
  obj[0x10] teardown(obj)                             # stop + release tracks (obj reusable)
  obj[0x08] soft-stop(obj)                            # stop, KEEPS track — do not confuse with write!
  obj[0x28] stopped(obj) -> bool                      # 1 while ALIVE: track ? !AudioTrack::stopped()
                                                       #                : (ctx state != 4)  [0x2a10]
  obj[0x38] get_rate(obj) -> i32                      # returns bit_rate
  obj[0x40] get_channels(obj) -> i32                  # returns create_track arg p1
  obj[0x30] latency(obj) -> i32
  obj[0x50] ctx pointer
  release_track(obj)                                  # frees obj + ctx

Flick call recipe (DSD128; stock-exact args per logcat):
  let t = create_track(5_644_800, 2, 6, 1);           // null → fail
  start(t); write(t, packed_wire_buf, 262_144);        // one HAL period per write
  flush(t) on seek; teardown(t); release_track(t);

Framework internals that matter (R4 libaudioclient.so, HiBy-patched):
  - write() accepts mTransfer ∈ {3 SHARED, 5 SYNC_NOTIF} (vanilla: 4/5) —
    set() maps TRANSFER_DEFAULT+no sharedBuffer+no cbf → SHARED (vanilla: SYNC).
  - set() mFrameSize for non-proportional formats (DSD) = 1 → any write size
    works; pacing must come from blocking obtainBuffer.
  - Verified live: track transfer=3 frameSize=1 status=0 flags 0x11.
```

Packing (RE + audioserver arithmetic + on-device calibration, 2026-08-30):
the DSD output stream runs at `bit_rate/32` Hz with channel mask 0x3 and
4 B per stereo frame (705 600 B/s for DSD128). On-ear calibration picked
**U8 byte-interleaved LRLR, MSB-first** (clean; the 4 B/frame are four
interleaved bytes, not two 16-bit subslots — the earlier U16 reading
hissed). U32 LLLL|RRRR and U16 LL|RR remain selectable for other DAPs.
Stock's engine write path (`libhibyservice.so 0x4450d8`) is a verbatim
memcpy — no byte transform, zero `rbit` in the whole lib — so wire bytes =
decoder output. Bit order in subslot + slot endianness covered by the 4
packer variants (default BE/MSB-first). DSD silence byte = **0x69** (what
stock's drain loop memsets before stop; SACD convention) — also used for
pause/gap/underrun fills via `AudioCallbackData::fill_silence`.

## I. History — why the ALSA phases died (superseded)

Original plan: probe `/dev/snd/pcmC*D*p` with HW_REFINE DSD sweeps
(`FMT_DSD_U8=56/U16_LE=57/U32_LE=58`), per-DAP hint table, negotiated open.
Killed by recon: SELinux `untrusted_app` cannot even *search* `/dev/snd` on
this ROM (`avc: denied { read search } tcontext=u:object_r:audio_device:s0
permissive=0`), so no ioctl is reachable — and stock HiBy Music (also
`untrusted_app`) proves the vendor route is the framework, not ALSA.
`dsd_alsa_direct.rs` stays for environments where it does work (rooted
devices, desktops).
