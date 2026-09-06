//! HiBy DSD offload shim: framework-native DSD AudioTrack through the vendor's
//! public `libsmartaudioservice.so` (listed in `/system/etc/public.libraries.txt`,
//! loadable by any app). This is the same path stock HiBy Music uses — a C++
//! `AudioTrack` with `AUDIO_FORMAT_DSD_NATIVE` (0x1A000001) on the compressed
//! offload output, routed by audio policy to the internal DAC.
//!
//! ABI reverse-engineered from the R4 firmware (see
//! `docs/audio/dsd-native-dap-plan.md` §H):
//!
//! - `create_track(bit_rate, channels, fmt_type, 1) -> *mut SasObj` — a
//!   0x58-byte vtable object (null on OOM or if the initial track creation
//!   fails). fmt_type 5..10 selects DSD: the shim builds
//!   `AudioTrack(AUDIO_STREAM_MUSIC, wire_rate = bit_rate/32,
//!   AUDIO_FORMAT_DSD_NATIVE, stereo, COMPRESS_OFFLOAD)` where `bit_rate`
//!   is the DSD bit rate (5 644 800 for DSD128). Stock HiBy Music calls it
//!   as `(bit_rate, 2, 6, 1)` (logcat-verified on the R4).
//! - Vtable slots are PLT-stub fn pointers stored in the object (first arg =
//!   the object): `[0x00] write(buf, len) -> c_int` (blocking
//!   `AudioTrack::write`; re-runs the lazy track creation when needed and
//!   returns 0 then; on the direct path it returns `len` UNCONDITIONALLY,
//!   ignoring the real write result), `[0x18] start`, `[0x20] flush`,
//!   `[0x10] stop+teardown`, `[0x08] soft stop` (keeps the track),
//!   `[0x28] stopped` (returns 1 while the track is alive:
//!   `track ? !AudioTrack::stopped() : status != 4`), `[0x38] get_rate`,
//!   `[0x40] get_channels`, `[0x30] latency`, `[0x50]` = ctx ptr.
//! - `release_track(obj)` frees object + ctx.
//!
//! Wire data: stereo frames of two N-byte subslots (L then R), each subslot
//! packing 8*N consecutive DSD bits of one channel; wire rate = bit_rate/32.
//! N is runtime-selectable (`SasWireGrouping`): the audioserver opens the
//! DSD output at wire_rate with 4 B/frame (e.g. 176 500 Hz × 4 for DSD128)
//! = two 16-bit subslots, so U16 (LL|RR) is the evidence-backed default;
//! U32 (ALSA `DSD_U32_BE`-style) and U8 (byte-interleaved) remain selectable
//! for calibration. Bit order inside a subslot is covered by the four
//! runtime-selectable `SasWireVariant` codes. DSD silence byte is 0x69
//! (SACD convention; what stock's drain loop memsets before stop).

use std::sync::atomic::{AtomicU8, Ordering};

/// Active native transport, set by the backend so diagnostics can name it.
pub const TRANSPORT_NONE: u8 = 0;
pub const TRANSPORT_SAS_OFFLOAD: u8 = 1;
pub const TRANSPORT_ALSA_DIRECT: u8 = 2;

static ACTIVE_TRANSPORT: AtomicU8 = AtomicU8::new(TRANSPORT_NONE);

pub fn set_active_transport(transport: u8) {
    ACTIVE_TRANSPORT.store(transport, Ordering::Release);
}

pub fn native_transport_name() -> &'static str {
    match ACTIVE_TRANSPORT.load(Ordering::Acquire) {
        TRANSPORT_SAS_OFFLOAD => "dap-native-offload",
        TRANSPORT_ALSA_DIRECT => "dap-native-alsa",
        _ => "dap-native",
    }
}

/// Wire-packing variant inside each subslot. Which one a vendor HAL
/// expects is not observable without playback; combined with the grouping
/// it spans the packing space (bit order × byte order × subslot width).
///
/// 0 = Auto (RawBe), 1 = RawLe, 2 = BitRevBe, 3 = BitRevLe.
static WIRE_VARIANT: AtomicU8 = AtomicU8::new(0);

pub fn set_wire_variant(variant: u8) {
    WIRE_VARIANT.store(variant, Ordering::Relaxed);
}

pub fn wire_variant() -> u8 {
    WIRE_VARIANT.load(Ordering::Relaxed)
}

/// Bytes per channel subslot in a wire frame. The audioserver stream is
/// opened at `wire_rate` Hz with 4 bytes per stereo frame (logcat: DSD128 →
/// 176 400 Hz, channel mask 0x3). On-device calibration (R4, 2026-08-30)
/// picked plain byte interleaving LRLR — U8 is the default. U32 is the
/// legacy/ALSA `DSD_U32_BE` shape, U16 the 16-bit-subslot reading.
///
/// 0 = U32 (legacy), 1 = U16, 2 = U8 (default, calibrated).
static WIRE_GROUPING: AtomicU8 = AtomicU8::new(2);

pub fn set_wire_grouping(grouping: u8) {
    WIRE_GROUPING.store(grouping.min(2), Ordering::Relaxed);
}

pub fn wire_grouping() -> u8 {
    WIRE_GROUPING.load(Ordering::Relaxed)
}

/// Bytes per channel subslot for the active grouping (4 / 2 / 1).
pub fn wire_group_bytes() -> usize {
    match wire_grouping() {
        0 => 4,
        2 => 1,
        _ => 2,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SasWireVariant {
    /// Subslot bytes in DSD stream order: `[b0, b1, b2, b3]`.
    RawBe,
    /// Subslot bytes reversed: `[b3, b2, b1, b0]`.
    RawLe,
    /// Bit-reversed bytes in stream order (LSB-first DSD, `DSD_U32_LE`-style).
    BitRevBe,
    /// Bit-reversed bytes reversed.
    BitRevLe,
}

impl SasWireVariant {
    fn from_code(code: u8) -> Self {
        match code {
            1 => Self::RawLe,
            2 => Self::BitRevBe,
            3 => Self::BitRevLe,
            _ => Self::RawBe,
        }
    }

    fn bit_reversed(self) -> bool {
        matches!(self, Self::BitRevBe | Self::BitRevLe)
    }

    fn byte_reversed(self) -> bool {
        matches!(self, Self::RawLe | Self::BitRevLe)
    }
}

/// Packs frame-major interleaved DSD samples (DSD byte in the low 8 bits of
/// each f32, as produced by the engine's DSD pipeline) into shim wire frames:
/// `2 * g` bytes per frame = L subslot (g bytes, 8g DSD bits) + R subslot,
/// where `g = wire_group_bytes()`. Each f32 sample contributes exactly one
/// wire byte, so `samples.len()` must be a multiple of `2 * g` (stereo only;
/// the shim hardcodes stereo).
pub fn pack_wire_frames(samples: &[f32], channels: usize, out: &mut [u8]) {
    if channels != 2 {
        return;
    }
    let variant = SasWireVariant::from_code(wire_variant());
    let group = wire_group_bytes();
    let frame_samples = group * 2;
    let wire_frames = samples.len() / frame_samples;
    if out.len() < wire_frames * frame_samples {
        return;
    }
    for (j, out_chunk) in out[..wire_frames * frame_samples]
        .chunks_exact_mut(frame_samples)
        .enumerate()
    {
        // samples: L0 R0 L1 R1 ... — per wire frame we consume g L + g R bytes.
        let base = j * frame_samples;
        let (l_slot, r_slot) = out_chunk.split_at_mut(group);
        for k in 0..group {
            let lb = (samples[base + k * 2].to_bits() & 0xFF) as u8;
            let rb = (samples[base + k * 2 + 1].to_bits() & 0xFF) as u8;
            let pos = if variant.byte_reversed() {
                group - 1 - k
            } else {
                k
            };
            l_slot[pos] = if variant.bit_reversed() {
                lb.reverse_bits()
            } else {
                lb
            };
            r_slot[pos] = if variant.bit_reversed() {
                rb.reverse_bits()
            } else {
                rb
            };
        }
    }
}

#[cfg(target_os = "android")]
mod internal {
    use std::ffi::{c_void, CString};
    use std::sync::mpsc;
    use std::sync::OnceLock;
    use std::time::Duration;

    const SHIM_LIB: &str = "libsmartaudioservice.so";
    const FMT_TYPE_DSD: i32 = 6;
    /// Per-attempt timeout for the probe write ladder. A drain-paced write
    /// of the largest ladder size takes ~1.3 s, so 4 s has ample headroom.
    const PROBE_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(4);
    /// Write sizes probed in ascending order. The smallest size the
    /// framework AudioTrack accepts fully (in one call) becomes the render
    /// loop's write granularity. Rejected sizes return 0 immediately; each
    /// retry also re-runs the shim's lazy track creation, which covers the
    /// route-settling window after openOutput.
    const PROBE_LADDER: [usize; 4] = [32_768 * 8, 65_536 * 8, 131_072 * 8, 262_144 * 8];
    /// DSD silence: the SACD-convention 0x69 that stock's drain loop memsets
    /// before stop (RE-verified in libhibyservice.so). DC-free per byte
    /// (4 ones / 4 zeros).
    const DSD_SILENCE_BYTE: u8 = 0x69;

    type CreateTrackFn = unsafe extern "C" fn(i32, i32, i32, i32) -> *mut c_void;
    type ReleaseTrackFn = unsafe extern "C" fn(*mut c_void);
    type SlotStartFn = unsafe extern "C" fn(*mut c_void);
    type SlotWriteFn = unsafe extern "C" fn(*mut c_void, *const u8, usize) -> i32;
    type SlotFlushFn = unsafe extern "C" fn(*mut c_void);
    type SlotTeardownFn = unsafe extern "C" fn(*mut c_void);
    type SlotStoppedFn = unsafe extern "C" fn(*mut c_void) -> i32;

    struct ShimFns {
        create_track: CreateTrackFn,
        release_track: ReleaseTrackFn,
    }

    static SHIM: OnceLock<Result<ShimFns, String>> = OnceLock::new();

    fn shim() -> &'static Result<ShimFns, String> {
        SHIM.get_or_init(|| {
            // Public library: loadable from the app namespace (same SELinux
            // domain HiBy Music uses, so this cannot be policy-blocked).
            let name = CString::new(SHIM_LIB).unwrap();
            // Clear any stale dlerror state first.
            unsafe { libc::dlerror() };
            let handle = unsafe { libc::dlopen(name.as_ptr(), libc::RTLD_NOW) };
            if handle.is_null() {
                let err = unsafe {
                    let msg = libc::dlerror();
                    if msg.is_null() {
                        "unknown dlopen error".to_string()
                    } else {
                        std::ffi::CStr::from_ptr(msg).to_string_lossy().into_owned()
                    }
                };
                return Err(format!("dlopen {}: {}", SHIM_LIB, err));
            }
            macro_rules! dlsym {
                ($name:expr, $ty:ty) => {{
                    let sym = CString::new($name).unwrap();
                    let ptr = unsafe { libc::dlsym(handle, sym.as_ptr()) };
                    if ptr.is_null() {
                        return Err(format!("dlsym {} failed", $name));
                    }
                    unsafe { std::mem::transmute::<*mut c_void, $ty>(ptr) }
                }};
            }
            let create_track = dlsym!("create_track", CreateTrackFn);
            let release_track = dlsym!("release_track", ReleaseTrackFn);
            Ok(ShimFns {
                create_track,
                release_track,
            })
        })
    }

    /// Cheap availability check: dlopen + symbol resolution only. Creates no
    /// AudioTrack; real validation happens in `create_dsd_track`.
    pub fn probe_unavailable_reason() -> Option<String> {
        match shim() {
            Ok(_) => None,
            Err(reason) => Some(reason.clone()),
        }
    }

    pub struct SasTrack {
        obj: *mut c_void,
        release_track: ReleaseTrackFn,
        slot_write: SlotWriteFn,
        slot_flush: SlotFlushFn,
        slot_teardown: SlotTeardownFn,
        slot_stopped: SlotStoppedFn,
        bit_rate: u32,
        /// Probe-verified write granularity in bytes (accepted by the
        /// framework AudioTrack in a single call).
        write_size: usize,
    }

    unsafe impl Send for SasTrack {}

    impl SasTrack {
        pub fn bit_rate(&self) -> u32 {
            self.bit_rate
        }

        pub fn wire_rate(&self) -> u32 {
            wire_rate_for(self.bit_rate)
        }

        pub fn write_size(&self) -> usize {
            self.write_size
        }

        /// Blocking write of packed wire frames. Returns bytes written
        /// (== `data.len()`) or a value <= 0 on failure.
        pub fn write(&self, data: &[u8]) -> i32 {
            if data.is_empty() {
                return 0;
            }
            unsafe { (self.slot_write)(self.obj, data.as_ptr(), data.len()) }
        }

        pub fn flush(&self) {
            unsafe { (self.slot_flush)(self.obj) }
        }

        /// Stop + release the framework tracks; the shim object stays usable
        /// (its write re-creates the AudioTrack lazily).
        pub fn teardown(&self) {
            unsafe { (self.slot_teardown)(self.obj) }
        }

        /// Slot 0x28 returns 1 while the track is alive
        /// (`track ? !AudioTrack::stopped() : status != 4`).
        pub fn stopped(&self) -> bool {
            unsafe { (self.slot_stopped)(self.obj) == 0 }
        }

        /// Final cleanup: frees the shim object and ctx. Consumes self.
        pub fn release(self) {
            self.teardown();
            unsafe { (self.release_track)(self.obj) };
        }
    }

    pub fn wire_rate_for(bit_rate: u32) -> u32 {
        bit_rate / 32
    }

    /// Creates a DSD offload track and verifies it can actually take data:
    /// `create_track` returns the vtable object even when the framework
    /// AudioTrack failed to initialize (its write lazily re-creates the
    /// track and returns 0 while no track exists), so the probe starts the
    /// track and runs a write-size ladder under a watchdog. Each ladder
    /// write re-runs the lazy creation, which also covers the output route
    /// settling window. The probe thread owns the object until a full write
    /// succeeds; on failure or timeout it tears everything down itself.
    pub fn create_dsd_track(bit_rate: u32) -> Result<SasTrack, String> {
        let shim = shim().as_ref().map_err(|e| e.clone())?;

        if bit_rate % 32 != 0 || bit_rate < 282_240 {
            return Err(format!("invalid DSD bit rate {}", bit_rate));
        }

        // Stock-exact args (logcat on the R4 with HiBy Music, DSD128):
        // create_track(5644800, 2, 6, 1).
        let obj = unsafe { (shim.create_track)(bit_rate as i32, 2, FMT_TYPE_DSD, 1) };
        if obj.is_null() {
            return Err("sas create_track returned null (OOM)".to_string());
        }

        let slot = |offset: usize| unsafe {
            *((obj as *const u8 as *const *mut c_void).add(offset / 8))
        };
        // Vtable layout (PLT stubs resolved from the shim binary):
        // [0x00] write, [0x08] soft stop, [0x10] teardown (stop + release
        // track object), [0x18] start, [0x20] flush, [0x28] stopped,
        // [0x30] latency, [0x38] get_rate, [0x40] get_channels, [0x50] ctx.
        let slot_start: SlotStartFn =
            unsafe { std::mem::transmute::<*mut c_void, SlotStartFn>(slot(0x18)) };
        let slot_write: SlotWriteFn =
            unsafe { std::mem::transmute::<*mut c_void, SlotWriteFn>(slot(0x00)) };
        let slot_flush: SlotFlushFn =
            unsafe { std::mem::transmute::<*mut c_void, SlotFlushFn>(slot(0x20)) };
        let slot_teardown: SlotTeardownFn =
            unsafe { std::mem::transmute::<*mut c_void, SlotTeardownFn>(slot(0x10)) };
        let slot_stopped: SlotStoppedFn =
            unsafe { std::mem::transmute::<*mut c_void, SlotStoppedFn>(slot(0x28)) };

        // Introspection: read the framework AudioTrack members through the
        // shim ctx to see exactly what the HAL negotiated (offsets from the
        // R4's HiBy-patched libaudioclient.so: 0xa8 mTransfer, 0x208
        // mFrameSize, 0x210 mStatus, 0x348 isDirect).
        unsafe fn log_track_internals(obj: *mut c_void, phase: &str) {
            let obj_bytes = obj as *const u8;
            let ctx = *((obj_bytes).add(0x50) as *const *const u8);
            if ctx.is_null() {
                log::info!("[DSD-SAS] {}: shim ctx is null", phase);
                return;
            }
            let ctx_bytes = ctx as *const u8;
            let track = *(ctx_bytes.add(0x8) as *const *const u8);
            if track.is_null() {
                log::info!(
                    "[DSD-SAS] {}: framework track NOT created (lazy creation pending or failed)",
                    phase
                );
                return;
            }
            let tb = track as *const u8;
            let transfer = *(tb.add(0xa8) as *const u32);
            let frame_size = *(tb.add(0x208) as *const u64);
            let status = *(tb.add(0x210) as *const u32);
            let direct = *(tb.add(0x348) as *const u32);
            log::info!(
                "[DSD-SAS] {}: track={:p} transfer={} frameSize={} status={} direct={}",
                phase,
                track,
                transfer,
                frame_size,
                status,
                direct
            );
        }

        unsafe { log_track_internals(obj, "after create_track") };
        unsafe { slot_start(obj) };
        unsafe { log_track_internals(obj, "after start") };

        let probe_buf = vec![DSD_SILENCE_BYTE; *PROBE_LADDER.last().unwrap()];

        let (tx, rx) = mpsc::channel::<(usize, i32)>();
        // Raw pointers are not Send; pass the shim object as an address.
        let thread_obj_addr = obj as usize;
        let thread_release = shim.release_track;
        std::thread::Builder::new()
            .name("dsd-sas-probe".to_string())
            .spawn(move || {
                let thread_obj = thread_obj_addr as *mut c_void;
                // This thread owns obj until a full write succeeds; on any
                // failure (or a timeout abandon by the main thread) it tears
                // down and releases the track itself.
                let mut success = false;
                for &size in PROBE_LADDER.iter() {
                    let written = unsafe { slot_write(thread_obj, probe_buf.as_ptr(), size) };
                    log::info!("[DSD-SAS] probe write({} B) -> {}", size, written);
                    let full = written > 0 && written as usize == size;
                    if tx.send((size, written)).is_err() {
                        // Main thread gave up: clean up and stop.
                        unsafe { slot_teardown(thread_obj) };
                        unsafe { thread_release(thread_obj) };
                        return;
                    }
                    if full {
                        success = true;
                        break;
                    }
                    if written < 0 {
                        break;
                    }
                }
                if !success {
                    unsafe { slot_teardown(thread_obj) };
                    unsafe { thread_release(thread_obj) };
                }
            })
            .map_err(|e| {
                unsafe { slot_teardown(obj) };
                unsafe { (shim.release_track)(obj) };
                format!("failed to spawn probe thread: {}", e)
            })?;

        let mut write_size: usize = 0;
        let mut last: Option<(usize, i32)> = None;
        loop {
            match rx.recv_timeout(PROBE_ATTEMPT_TIMEOUT) {
                Ok((size, written)) => {
                    if written > 0 && written as usize == size {
                        write_size = size;
                        break;
                    }
                    last = Some((size, written));
                    if written < 0 {
                        break;
                    }
                }
                // Timeout or ladder exhausted (channel closed).
                Err(_) => break,
            }
        }

        if write_size > 0 {
            // Drop the probe silence so it never plays; hand obj back.
            unsafe { slot_flush(obj) };
            log::info!(
                "[DSD-SAS] DSD offload track verified: bit_rate={} Hz, wire {} Hz, write granularity {} B",
                bit_rate,
                wire_rate_for(bit_rate),
                write_size
            );
            Ok(SasTrack {
                obj,
                release_track: shim.release_track,
                slot_write,
                slot_flush,
                slot_teardown,
                slot_stopped,
                bit_rate,
                write_size,
            })
        } else {
            let (size, written) = last.unwrap_or((0, 0));
            Err(format!(
                "sas DSD write rejected: {} B write returned {} (no DSD output route)",
                size, written
            ))
        }
    }
}

// ── Public API ─────────────────────────────────────────────────────────────

#[cfg(target_os = "android")]
pub use internal::{create_dsd_track, probe_unavailable_reason, wire_rate_for, SasTrack};

#[cfg(target_os = "android")]
pub fn probe_available() -> bool {
    internal::probe_unavailable_reason().is_none()
}

#[cfg(not(target_os = "android"))]
pub fn probe_available() -> bool {
    false
}

#[cfg(not(target_os = "android"))]
pub fn probe_unavailable_reason() -> Option<String> {
    Some("SAS shim is Android-only".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// pack_wire_frames reads process-global atomics; serialize the tests
    /// that flip them.
    static PACKER_LOCK: Mutex<()> = Mutex::new(());

    fn dsd_sample(byte: u8) -> f32 {
        f32::from_bits(byte as u32)
    }

    fn interleave(l: [u8; 4], r: [u8; 4]) -> Vec<f32> {
        let mut v = Vec::with_capacity(8);
        for i in 0..4 {
            v.push(dsd_sample(l[i]));
            v.push(dsd_sample(r[i]));
        }
        v
    }

    #[test]
    fn wire_groupings_pack_expected_layouts() {
        let _guard = PACKER_LOCK.lock().unwrap();
        // Raw DSD byte streams: L = 01..04, R = 11..14 (hex), interleaved.
        let samples = interleave([0x01, 0x02, 0x03, 0x04], [0x11, 0x12, 0x13, 0x14]);

        // U32 (legacy): 8-byte frames, 4 L bytes then 4 R bytes.
        set_wire_grouping(0);
        set_wire_variant(0);
        let mut out = [0u8; 8];
        pack_wire_frames(&samples, 2, &mut out);
        assert_eq!(
            &out,
            &[0x01, 0x02, 0x03, 0x04, 0x11, 0x12, 0x13, 0x14][..]
        );

        // U16: 4-byte frames, 2 L bytes then 2 R bytes.
        set_wire_grouping(1);
        let mut out = [0u8; 8];
        pack_wire_frames(&samples, 2, &mut out);
        assert_eq!(&out, &[0x01, 0x02, 0x11, 0x12, 0x03, 0x04, 0x13, 0x14][..]);

        // U8: plain byte interleave, wire order == sample order.
        set_wire_grouping(2);
        let mut out = [0u8; 8];
        pack_wire_frames(&samples, 2, &mut out);
        assert_eq!(
            &out,
            &[0x01, 0x11, 0x02, 0x12, 0x03, 0x13, 0x04, 0x14][..]
        );

        set_wire_grouping(2);
    }

    #[test]
    fn variants_transform_subslots() {
        let _guard = PACKER_LOCK.lock().unwrap();
        // Raw DSD byte streams: L = 01..04, R = 11..14 (hex).
        let raw: [u8; 8] = [0x01, 0x02, 0x03, 0x04, 0x11, 0x12, 0x13, 0x14];
        let samples = interleave(
            [raw[0], raw[1], raw[2], raw[3]],
            [raw[4], raw[5], raw[6], raw[7]],
        );

        let mut out = [0u8; 8];
        set_wire_grouping(0); // 32-bit subslots for this test
        for (code, (swap, bitrev)) in [
            (0u8, (false, false)),
            (1, (true, false)),
            (2, (false, true)),
            (3, (true, true)),
        ] {
            set_wire_variant(code);
            pack_wire_frames(&samples, 2, &mut out);
            let expected: Vec<u8> = (0..8)
                .map(|i| {
                    let sub = i / 4; // 0 = L subslot, 1 = R subslot
                    let k = i % 4;
                    let pos = if swap { 3 - k } else { k };
                    let byte = raw[sub * 4 + pos];
                    if bitrev {
                        byte.reverse_bits()
                    } else {
                        byte
                    }
                })
                .collect();
            assert_eq!(&out[..], &expected[..], "variant {}", code);
        }
        set_wire_variant(0);
        set_wire_grouping(2);
    }

    #[test]
    fn silence_is_dc_free() {
        // 0x69 = SACD silence byte (what stock memsets before stop);
        // 4 ones / 4 zeros per byte, DC-free in either bit order.
        assert_eq!(0x69u8.count_ones(), 4);
        assert_eq!(0x69u8.reverse_bits(), 0x96);
        assert_eq!(0x96u8.count_ones(), 4);
    }

    #[test]
    fn non_android_stub_unavailable() {
        #[cfg(not(target_os = "android"))]
        {
            assert!(!probe_available());
            assert!(probe_unavailable_reason().is_some());
        }
    }
}
