# Changelog

## Currently on Pre-release

Changes landing on top of the current pre-release are tracked here and folded into the release notes as they ship.

### Library Scanning & Permissions
- Optional **Full Library Access** (`MANAGE_EXTERNAL_STORAGE`) mode: when granted, library scans walk the filesystem directly via the Rust scanner on every volume (internal storage, SD cards, USB drives) — same approach as Poweramp/USB Audio Player PRO — so no file can hide behind an incomplete system media index. Degrades gracefully to MediaStore/SAF when not granted. Toggle + status in Settings → Library → Scan Settings.
- **DSD/DSF/WavPack now always scanned** even in scoped-storage mode: on devices whose media indexer skips DSD entirely (Xiaomi/MIUI, Vivo, Honor and similar), a stat-only reconciliation walk finds the missing `.dsf`/`.dff`/`.wv` files during every scan, plus a best-effort MediaStore re-index nudge; live-change watching now covers the Files collection too.
- **Fixed library wipe when switching scan engines** (e.g. after granting Full Library Access): each scan engine now only deletes rows in the URI space it can actually see — SAF `content://` rows are superseded by their raw-path equivalents (never dropped before the replacement exists), and Rust/MediaStore scans no longer feed SAF-keyed rows into filesystem deletion checks. Also protects periodic background deletion refreshes.
- **WavPack/DSD tags & album art everywhere**: Android's metadata reader cannot decode WavPack at all (and often not DSD), so `.wv`/`.dsf`/`.dff` tracks scanned via MediaStore/SAF used to land with no title, duration, or cover. Metadata enrichment now falls back to the app's own Rust parsers (lofty/dsf-meta/dff-meta) for those formats — including SAF locations, staged through the shared playback cache — and embedded covers are extracted the same way. Also fixes DSD bitrate being stored ~1000× too low in deep scans.
- **Fixed DFF/WavPack embedded covers**: WavPack stores its APE cover art as binary tag items (invisible to lofty's picture API) and dff-meta aborts on imperfect DFF ID3 chunks — covers for both now extract through a direct APE-item scan and a tolerant DSDIFF chunk walker, with DFF text tags recovered the same way when dff-meta gives up.
- **Fixed post-scan audio preload grinding invisibly**: the background decode pass (waveform/loudness) now runs as a single cancellable pass — cancelling or restarting a scan stops it, overlapping passes can no longer stack decoders or freeze artwork extraction, live progress with a Stop button appears on the scan-complete sheet, and undecodable formats (DSD/WavPack) are negative-cached instead of being re-probed on every pass.
- **Minimizable scan progress**: the scanning overlay (library scan, preload, ReplayGain) gains a Minimize button; a floating pill above the bottom bar keeps showing live progress (counts, current file, elapsed, Stop) while you keep using the app, and also surfaces post-scan preload passes running in the background.

### Headphone Crossfeed
- BS2B (Bauer stereophonic-to-binaural) 3-stage crossfeed with selectable presets — Default, Crossfeed (strong), and Crossfeed easy (gentle), plus Off. Blends a low-passed opposite-channel signal into each channel to reduce ear fatigue on headphones; runs in the native Rust DSP chain, bypassed on bit-perfect passthrough.
- Crossfeed level persists across engine recreation (e.g. sample-rate changes between tracks).

### ReplayGain
- ReplayGain playback (Track & Album modes) with pre-amp and clipping prevention — applied per source by the native engine and folded into the just_audio volume path.
- ReplayGain scanner in Library settings: analyzes loudness (EBU R128 / BS.1770), writes `REPLAYGAIN_*` tags back into files, and updates the library database.
- Library scans now read existing `REPLAYGAIN_*` tags (FLAC/Vorbis, MP3/ID3, MP4, WAV/AIFF, plus DSF/DFF ID3 tags).

### Folders
- Hierarchy (tree) view now available inside folders via the grid/list toggle — matches the root Folders screen; view mode persists across screens.

### Lyrics
- **Word Sync (karaoke) editing** in the Lyrics Sync Studio: play the song and tap along to stamp each word; fully stamped lines export as enhanced LRC (`<mm:ss.xx>` word tags) that drives the karaoke sweep. Word chips support per-word nudge/re-time/clear, a live karaoke preview shows the real sweep while editing, and existing word timings now survive editing — re-stamping a line shifts its words by the same delta instead of discarding them.
- **Video-style word timeline** in Advanced mode: each word renders as a clip whose length you control — drag a boundary to stretch or shrink the adjacent words (all edits snap to the 10ms LRC grid), drag the line-end boundary (or use Length ± buttons) to retime the next line, set exact start times numerically, and Auto-fill seeds evenly spaced words as a drag starting point. Words can also be split into separately timed syllables (tap-a-letter splitter) for slow-then-fast pacing inside a single word — saved as adjacent enhanced-LRC word tags.
- Embedded lyrics now read from MP4/M4A `©lyr` atoms (UTF-8 and UTF-16) and OGG/Opus Vorbis comments, joining existing ID3 (USLT/SYLT) and FLAC support.

## 0.21.0-beta.1 (2026-07-10)

Shipped while continuously keeping up with improvements and bug fixing across the app.

### Network Sources & Casting
- Stream from self-hosted servers: **Subsonic, Jellyfin/Emby, UPnP/DLNA, WebDAV, Tidal, and SMB2/3**.
- HTTP-first streaming with seek, gapless prefetch, and LRU download caching.
- Subsonic playlist sync — mirror playlists to/from your server; playlists removed with their server.
- Cast to **DLNA renderers and Chromecast**; Cast SDK optional for GMS-free devices.
- LAN media streaming — local files served to cast devices via embedded HTTP server.
- Server management with validation, failure banners, token error handling, password toggle.
- Jellyfin service timeout raised to 60s.

### Extended Volume (up to 200%)
- Volume boost via LoudnessEnhancer with toggle in Audio settings.
- Volume preserved across engine recreation; slider reflects boost range.
- Volume authority refactor — `isHardwareVolumeAuthority` routing.

### Parametric EQ & Audio
- Graphic EQ → **parametric EQ**: variable band types with RBJ coefficients, animated band add/remove.
- EQ survives engine recreation; reapplies on session changes; bypassed on bit-perfect output.
- Bit-perfect passthrough API — software gain removed from path.
- Autoplay on queue end (optional); stuttering HAL path skipped when bit-perfect off.
- Earpiece excluded from auto device selection; wake lock prevents sleep dropouts.
- Duck-on-interruption option for Android audio focus interruptions.
- Direct audio backends (audiotrack_direct, PcmAlsaBackend) with S32_LE/I32/I16 PCM paths.

### USB DAC Fixes
- Fosi Audio DS2 quirk (broken clock), 0 Hz readback fix, SkipClockValidation.
- UAC1 SET_CUR failures tolerated on host-driven clock endpoints; endpoint recipient prevents STALL.
- Sample-rate guards: no DAC-stored-rate overwrites or divide-by-zero.

### Bluetooth
- Hi-Res Direct no longer forces the `dapInternalHighRes` engine on BT routes — fixes volume loss (~35-40% cap) and 5-10s dropouts over A2DP.
- Output-mode toggles (Hi-Res Direct, Low-latency) now survive app restarts.
- Flags cached at startup; refined Hi-Res Direct codec selection; priority anchor keeps background playback alive.

### Player & UI
- Configurable action buttons: center, top-left/right, bottom — any slot hideable.
- Separate mini player from nav bar (toggle in settings).
- Compact layout for very short screens; resizable activity.
- Reusable `SurfaceIconButton` across screens; animated spinning refresh button.

### Library & Artwork
- Remove All Songs option; songs deleted when their folder is removed.
- Artwork survives cache prune and persists after scans.
- Corrupt cached images auto-recover; extraction freeze on rapid scroll fixed.
- Ambient background added across tabs with duplicate prevention.

### Reliability
- Auto-resume after interruptions; pending seek cleared after completion.
- Persistent WAV cache across restarts; HTTP audio source timeout.
- Network sync hardening: entity IDs resolved before bulk insert, Jellyfin fetches all audio tracks.
- Missing audio metrics handled for SMB/WebDAV songs; raw UTF-8 URI decoding fixed.

## 0.20.5-beta.6 (2026-07-06)

### Audio Preload & Analysis
- Single-pass audio analysis during library scan — BS.1770 loudness (integrated, short-term, momentary) and waveform peaks.
- `SongAudioCacheEntity` (Isar) stores cached waveform peaks and audio metrics.
- Audio preload service runs in background; FFI bindings for `analyze_audio_file`.
- Preload toggle in Library scan preferences with progress tracking.

### DSD ALSA Direct Output
- DSD bypasses AudioFlinger entirely via ALSA direct output on DAP devices.
- ALSA direct and JNI runtime DSD probes for capability detection.
- PCM payload audit, global stop signal, forced DsdDoP on mode switch.
- DSD format name helpers and improved debug logging.

### Detail Screen Art & Title Preferences
- Expanded header art and centered title options for album/playlist/artist detail screens.
- Configurable header art heights and gradient stops.
- Settings in Interface → UI Customization.

### Detail Screen Redesigns
- Playlist detail: redesigned action buttons with lossless indicator.
- Artist detail: redesigned layout and actions.
- Album detail: refactored layout with improved artwork extraction.

### Nav Bar Button Customization
- Hide/show individual bottom nav buttons from Settings → Interface → Bottom Bar.
- `NavBarConfig` with persisted hidden buttons set.

### Widget Text Scaling
- Configurable font scale for mini, flagship, and compact widgets.
- Compact widget text scales with widget width for responsive layouts.

### Pause on Connect
- USB DAC attach handler and Bluetooth connect pause.
- Device attached event stream with per-toggle preferences.

### Artwork Extraction Gate & Cache
- Refcounted artwork pause during preload/scroll with dedicated gate service.
- Cache staleness reduced to 30 days with 500-entry LRU cap.

### UI Polish & Fixes
- Speed control and sleep timer migrated to sliders.
- Back gesture edge width increased; drag handling improved.
- Milestone back button icon changed to chevron.
- Manual screen: ConsumerStatefulWidget with ambient background.
- Folder grid aspect ratio 0.70; AlbumFilterSheet sort state initialized.
- Impeller config moved to API 31 resource folder.
- MediaStore prioritized for removable deep scans before SAF.
- Text styles/icon sizes updated in scrobbling and library settings.
- Docs: network sources plan, CONTRIBUTING.md.

### Detail Screen Overlay Top Bar
- Detail screens migrated from `SliverAppBar` to custom overlay top bar with pinned positioning.
- Background rendering refined with art layer gradient seal.

### DSD & MediaStore Integration
- DSD and WavPack audio files now supported by OEM MediaScanners.
- Deletion guard prevents accidental removal of DSD/WavPack files.

### Logs Screen Enhancements
- Log upload and save-as-text options for sharing diagnostics.

### Slider & Scale Improvements
- `SliderSetting` gains edit icon and `onDisplayTap` for direct value entry.
- Text scale slider range expanded with manual input dialog.
- `scaledSp` upper bound increased to 30 for high-density screens.
- Album grid aspect ratio computed per device width.

### Bug Fixes
- Pause-on-disconnect respected in USB DAC fallback.
- Queue pill padding fixed in player song scene.
- Back gesture accounts for vertical distance during horizontal drag.

## 0.20.4-beta.5 (2026-07-03)

### Pitch Shifter (SoundTouch)
- Real-time pitch shifting via SoundTouch DSP library with lock-free bypass.
- Pitch shift semitones API with FFI bridge and notifier.
- Pitch control bottom sheet with semitone slider; option on song actions sheet.
- Pitch resets to 1.0× on playback stop.

### Android Audio API Preference
- Choose AAudio, OpenSL ES, or Auto for Android audio output.
- Persisted preference with instant apply.
- Exposed in UAC2 settings and Rust debug state.

### Blurred Backgrounds Everywhere
- `BlurredSongBackground` wraps all library screens for consistent glass look.
- Fade-only route transition keeps background stable between screens.

### Orbit Customization
- Dedicated orbital settings screen — geometry, sizing, depth, art resolution, visual toggles.
- `SongCard` sizing fully configurable; unused constants removed.

### Album Artwork Stretch
- Album artwork stretches to fill card — toggle in Library settings.

### Lyrics Performance
- In-memory cache with timeout; shared HTTP client.
- Exact and fuzzy searches run in parallel — first match wins.

### Streaks & Preference Controls
- Streaks can be disabled with reset; day streak hidden when disabled.
- "More from Artist" / "More Artists" toggles on album detail.
- Display preferences on artist sort sheet.

### Artwork Reliability
- Only cache confirmed-existing paths; prefer embedded art for fallback.

### UI Polish & Fixes
- Engine selector: glass bottom sheet with hero gradients.
- Responsive songs header, edge-drag guard, sort sheet margin fix.
- Docs: audio preload scan plan, scan details revamp.

### Animated Album Art & Scroll Fade
- Apple Music-style animated album art on album, artist, and playlist detail screens.
- `ScrollFadeWrapper` fades hero artwork behind the pinned app bar on scroll.
- Album art layer extracted into `AnimatedAlbumArt` with scroll-aware fade.
- Toggle in Settings → Interface → UI Customization.
- Tests for `ScrollFadeWrapper` and `AnimatedAlbumArt`.

### Engine Restart Overlay
- Full-screen restart overlay with animated gradient progress.
- Inline `EngineRestartNotice` widget replaces snackbar/toast prompts.
- Shared restart notice restyled alongside update notice.

### USB DAC Disconnect & UAC2 Redesign
- USB DAC disconnect pauses playback automatically.
- `DeviceDetachedEvent` stream for UI notifications.
- Pause-on-disconnect toggle in Settings → Audio → Bluetooth.
- UAC2 settings screen redesigned with gradient background and ambient artwork.

## 0.20.3-beta.4 (2026-06-30)

### Full Player Refactor & Widgets
- `FullPlayerScreen` refactored into composable widgets: `PlayerControls`, `PlayerActionButtonRow`, `AnimatedSongScene`, `AnimatedAlbumArt`.
- Multi-layout player support via the scene widget.
- Vinyl morph and rotation seek extracted into reusable `AnimatedAlbumArt`.
- Player action bottom sheets: song actions, volume control, playback speed, sleep timer, layout customization.
- `PlayerNavigation` class centralizes queue and navigation.
- `VisualizerArtBox` widget with frame and shadow styling.
- Shared duration formatting utility.
- Interactive seek lifecycle fix — suppresses writes during drag, cleans up on dispose.

### Lyrics Panel & Waveform
- **Inline lyrics panel** with synced and plain views — sing along without leaving the player.
- Lyrics mode waveform strip with swipe gesture and animated arrow.
- Waveform layer extracted for reusable progress bar styling.

### Multi-Artist Album Grouping
- Album grouping handles compilations with multiple artists per key.
- Album filtering narrowed to `albumArtist` field only.
- Unit tests for `SongRepository.resolveGroupArtist`.

### Artwork Performance
- Artwork extraction paused during scroll (debounced).
- Always decode at 2× art size to prevent OOM on fast fling.
- Path existence checks memoized.

### Widget Sync Fix
- Widget state synced when audio service is killed.
- `updateAllWidgets` helper for batch widget refresh.

### Queue Settings & Playlist Context
- Dedicated Queue Settings screen with wrap-around toggle.
- Playlist context passed from recently played and recently added songs.

## 0.20.2-beta.3 (2026-06-27)

### Bluetooth Codec Control
- **Bluetooth Hi-Res Direct mode** biases route selection toward a high-resolution engine path.
- Per-codec preference controls with persistence (AAC, aptX, LDAC, etc.).
- Codec preferences applied on Bluetooth init and connect.
- Device connection state tracking with codec configuration feedback.
- Bluetooth settings refactored with codec control, device filtering, and UI refinements.
- Developer mode toggle for advanced codec debugging.

### Glance Cards & Albums
- Glance card visibility toggle — show, hide, or minimize Quick Access cards.
- Per-card hidden/minimized preferences persisted.
- `AlbumsScreen` migrated to Riverpod with app preferences integration.
- Single-art and empty-art edge cases handled; album year on cards.
- `AlbumArtPickerBottomSheet` returns change status for reactive updates.
- Stale song provider prevented on in-place art updates.

### Streak & Milestone Polish
- Animated shimmer replaced with static tier-colored text for performance.
- Dynamic tier colors and glow effects on streak popup.
- Tier-based shimmer effect on streak popup background.
- Tier color/count helpers on `MilestoneCategoryX`.
- New tests for tier colors and counts.

### USB Audio Fixes
- Write-only USB clocks supported — trusts `SET_CUR` when readback unavailable.
- USB permission `PendingIntent` fixed for restrictive devices.

### Artwork Cache Improvements
- Embedded album art normalized before caching.
- Content-based cache keys replace path-based keys.

### Queue & Playback
- Playlist restart from end when wrap-around is enabled.
- Duplicate recently-played check removed.

### Debug & Developer
- Debug logging in audio strategy and decoder selection paths.
- Feature requests document added.

## 0.20.1-beta.2 (2026-06-24)

### AutoEQ Headphone Matching
- Browse and apply AutoEQ presets by headphone brand/model.
- AutoEQ brand catalog with searchable bottom sheet.
- Pre-bundled brand/model asset files.
- `AutoEqCatalogService` for preset lookup and JSON parsing.
- LSC/HSC band type codes mapped to low/high shelf filter types.

### App Logging System
- In-app log viewer screen (Settings → UAC2 → Developer → Logs).
- Singleton `AppLog` with change notifications.
- Log sink FFI bridging Rust debug output into Dart.
- Default error handler writes uncaught exceptions to log.
- Audio probe format via FFI for USB diagnostics.

### Library Warmup
- Background metadata extraction after first scan (album art, year, genre).
- `BackgroundMetadataService` as shared Riverpod provider.
- Snackbar notifications on warmup start/complete.
- `countIncompleteMetadataSongs` for progress tracking.

### Recently Added Screen
- New "Recently Added" screen with paginated song list.
- Accessible from Quick Access menu.
- `getRecentlyAddedSongs` with cursor-based pagination.

### Visualizer & Display Settings
- Refresh rate mode (auto, 60/90/120Hz).
- Visualizer on/off toggle with settings screen.
- `DisplayModeWrapper` migrated to Riverpod with multi-mode support.
- Disabled visualizer skips render pipeline.

### Floating Island Toggle
- Floating mini-player overlay can be toggled from Settings → Playback → Display.

### Wrap-Around Queue Playback
- Queue wraps from last track back to first.
- Toggle in Settings → Playback.

### Fingerprint Cache Reliability
- Cache cleared on DB incompatibility, folder removal, and DB rebuild.
- Orphaned entries filtered on reload.

### Performance
- Recently Played/Added screens pre-build row objects for ListView.
- Folder list uses SliverList for smooth infinite scroll.
- Album group computation memoized in artist detail screen.

### USB Audio & Engine Fixes
- Isochronous feedback polling enabled for USB output.
- AAudio exclusive mode guarded by API level check.
- Mid-stream USB fallback on Rust backend refusal.
- Unknown USB speed inferred from sysfs/sample rates.
- Custom CacheManager with configurable stale period for artwork.

### Lyrics & Share Cards
- Lyric share card with dynamic font sizing and font size controls.
- False lyrics scroll jump on transient position dips fixed.

### Polish & Cleanup
- Rotary knob drag precision improved.
- README rewritten with UAC 2.0 API docs and transparency section.
- Stale comments removed across codebase.

## 0.20.0-beta.2 (2026-06-21)

### Compact Home Widget
- New 2×2 compact widget with text and transport controls.
- Compact-specific preferences with dedicated settings tab.
- Widget settings screen with swipe gesture between tabs and animated transitions.
- Semi-transparent scrim overlay on mini player widget; visibility matches album art.

### Milestone Streaks & New Tiers
- **Day streak tracking** — consecutive listening days with flame icon popup and snooze.
- **Unique artist count milestone** — tracks distinct artists played over lifetime.
- **Emerald tier** added for new milestone thresholds.
- Streak popup with animated day-cell grid and motivational messages.
- Milestones grouped by category with collapsible sections.
- `MilestoneService` refactored with category-based current-value tracking.
- New tests for streak and unique-artist milestone logic.

### Audio Convolver — Impulse Response Reverb
- **Direct-time-domain convolver** processes impulse response files for convolution reverb.
- Offline IR loader supports standard WAV IR files.
- Full control API: enable/disable, dry/wet mix, load IR, clear.
- Integrated into equalizer service with persistent `ConvolverSettings`.
- Convolver section on the equalizer screen.
- Rust public API (`convolver_enable`, `convolver_mix`, `convolver_load_ir`, `convolver_clear`).

### Crossfade Engine (Rust)
- Crossfade between tracks in the Android audio engine via `CrossfadeCurve`.
- Pending crossfade configuration via atomics survives engine recreation.
- Applied automatically on audio state update.
- Dart FFI API for pending crossfade and DSD override options.
- Crossfade tests for the Android audio engine.

### DSD Transport Overrides
- Per-device DSD byte-order and subslot overrides for USB Direct transport.
- Unified quirk database drives subslot, bit order, and byte reversal settings.
- Override preferences synced to Rust engine before playback.
- 24-bit DSD over USB DoP with corrected bits-per-frame.
- DSD ring rate fix and payload integrity checks.
- UAC2 alt-settings probed for DSD/DoP capability before stream start.

### Removable Storage & SAF Scanning
- **Removable storage scanning** via Android SAF — SD cards and USB drives.
- Per-volume MediaStore support with `mediaStoreVolume` on `FolderEntity`.
- `FolderEntity` gains `isRemovable` and `volumeState` fields.
- Volume info resolved when adding a music folder; external status label on folder card.
- USB/removable status displayed inline during deep scans.
- Handles unmount events gracefully with instant SAF scan fallback.
- SAF tree walk refactored to `contentResolver.query` per directory.
- Tests for removable volume handling.

### Bluetooth Management
- **Bluetooth settings screen** with codec info (A2DP) and device management.
- Bluetooth service layer with device and codec DTOs.
- A2DP codec detection and battery level display.
- **Low-latency mode** preference — selects Rust Oboe for Bluetooth.
- **Pause-on-disconnect** setting.
- **Reconnect resume** — playback resumes on Bluetooth reconnect.
- Bluetooth connect permission for Android 12+.

### Metadata Editor Improvements
- Tag write verification with typed outcomes.
- Metadata validation before save with improved error reporting.
- Original file copied to temp before writing — safe rollback.
- SAF fallback for tag writes on scoped storage.
- Write URI permission requested and persisted.

### Albums & Search
- Album list view mode with multi-selection actions.
- Queue all songs button on album detail screen.
- Search playback mode preference.

### UI Polish & Cleanup
- Removed "Player" from app name — now simply "Flick". Google Play badge added to README.
- Lyric font size increased to 34, max lines to 4.
- "Flick Replay" browse chip highlighted with accent style.
- Scan settings animation replaced with `AnimatedSize`/`AnimatedOpacity`.
- "Show in Files" replaced with share. `SizeTransition` deprecation fixed.
- Unused imports, dead code, deprecated test file removed.
- Vendored/generated files excluded from static analysis.

## 0.19.1-beta.2 (2026-06-18)

### Home Widgets Redesigned
- **Mini player widget** redesigned with bitmap text rendering for RemoteViews font compatibility across Android versions.
- **WidgetTextRenderer** class extracts text-to-bitmap rendering, making widget labels crisp on all devices.
- **Flagship 2×2 widget** enabled — redesigned layout with transport controls, shuffle/repeat buttons, accent color support, and per-widget content settings.
- Widget art loading with max-pixel-dimension parameter for performance.
- Removed unused widget drawables, themes, progress drawable preferences, and dead layout code.

### Crossfade Fixes & Polish
- **Crossfade advance pending flag** prevents duplicate track advancement during crossfade transitions.
- Crossfade state tracking moved to `RustAudioService` for accurate lifecycle management.
- Crossfader diagnostics improved with stream restart on Oboe interruption.
- `rebind_sample_rate` preserves crossfader settings across sample rate changes.
- Prevent redundant crossfade re-queuing on duration-change events.
- Separate configured vs. active crossfade durations — fade clamps to half the track length.
- Crossfade forces DSP audio path; suppressed under 432 Hz tuning.
- Crossfade section tagged as experimental in settings.

### Help & Manual System
- **Manual screen** with search bar and collapsible sections covering all app features.
- Full manual data models with organized help content across the entire app.
- **Tutorial overlay** with dynamic spotlight positioning that highlights UI elements.
- Tutorial target registry and anchor widget for consistent tutorial UI.
- `TutorialStep` enum refactored with metadata (title, description, target).
- Help & Manual section added to Settings.
- Song search bar and sort button wrapped in tutorial targets.
- Nav bar and mini player wrapped in tutorial targets for guided onboarding.

### Songs Screen: Album Grid Mode
- Songs screen refactored from folder-based grouping to album-based grid mode.
- Album-based sorting replaces folder sort option.
- Folder sort option removed in favor of album sort.

### Folder Tree View
- New folder tree view mode with expandable hierarchy, glass styling, and guide lines.
- Toggle between grid and tree view for folder browsing.

### Nav Bar & Bottom Sheet Polish
- `FlickNavBar` converted to `StatefulWidget` with directional slide animation on item select/deselect.
- Removed sliding animation from nav bar items for simpler interaction.
- Bottom sheets dismiss on tap outside.
- Optional tag badge on `SettingsSectionHeader` for marking experimental features.

### Artwork Card Frame
- Optional glass frame around album art cards — toggle in Settings.
- `showArtworkCardFrame` preference with persistence.
- Artwork sizing adjusted to accommodate the frame.

### Audio Engine & UAC1
- **UAC1 sample rate handling** via endpoint SET_CUR requests for older UAC 1.0 devices.
- Audio engine defaults to `rustOboe` only when `exoPlayer` preference is selected.
- Refined DAP shared path logic and audio engine selection UI.

### UI Polish
- Milestone collection grid switched to list layout for cleaner scrolling.
- `AnimatedCrossFade` replaced with `AnimatedSize` for smoother section expansion in settings.
- Removed unused manual screen sections; extracted entry content widget.
- Tutorial overlay logic and state management refactored.

## 0.19.0-beta.1 (2026-06-15)

### ListenBrainz Scrobbling
- Full offline-safe ListenBrainz scrobbling with queued submissions via SharedPreferences persistence.
- **ListenBrainz API client** with rate-limit handling (respects retry-after headers).
- **ListenBrainzAuthService** for token validation and session management.
- **Freezed models** for session tokens and listen entries (track metadata, timestamps).
- Track-start and track-end scrobble events on app resume.
- Settings tile under Settings → Integrations.

### Floating Player Overlay
- Android floating mini-player overlay (SYSTEM_ALERT_WINDOW) with drag-to-move and tap-to-open.
- Lifecycle-aware pause/resume handlers integrated into audio service.
- "Keep Playing on Quit" setting prevents audio shutdown when exiting the app.
- Floating player toggle in Settings → Playback.
- Configurable mini-player swipe action (open visualizer, next track, etc.).
- Floating player integrated across all screens — albums, artists, playlists, folders, equalizer.
- Nav bar visibility enforced on every screen so the player is always reachable.

### Playback Modes Overhaul
- **AdvanceListOrder**: choose how playback advances — by album, artist, folder, playlist, or default.
- **ShuffleMode** categories: off, shuffle all, shuffle within source context.
- **PlaybackContext** model tracks the current playback source (album, artist, folder, playlist) for scoped shuffle and advance.
- A-B repeat mode for looping a section of a track.
- New loop modes: off, track, context, all.
- Long-press shuffle/loop buttons now open mode selection bottom sheets instead of cycling blindly. Snackbar feedback on change.
- Playback modes restored when resuming the last played song.
- Icons for each advance mode category.

### Experimental 432 Hz Tuning
- A4=432 Hz pitch tuning via Rust FFI, toggled from Settings → Audio → UAC2.
- Preference persisted across sessions with confirmation dialog before enabling.
- 432 Hz cache initialized alongside the audio session manager.
- Integration with bit-perfect mode defaults.

### Bass / Mid / Treble Tone Controls
- Three-band tone stack (bass, mid, treble) layered on top of the 31-band parametric EQ.
- Per-band offset affects the EQ graph rendering, hit detection, and parametric curve building.
- BMT fields added to `EqPreset` for preset import/export.
- Smooth animated transitions on equalizer `RotaryKnob` controls.
- Animated slider widget extracted for reuse across the EQ band editor.

### Opus Audio Codec
- Vendored **opus-sys** crate with full Opus 1.x sources — CELT + SILK codecs.
- Multi-architecture optimizations: SSE4.1, ARM NEON, ARM EDSP, MIPSr1.
- Opus decoder Rust bindings integrated into the audio pipeline.
- OGG container extension hints normalized; custom Opus decoder support for `.opus` files.
- Includes training scripts, fuzzers, and unit tests for SILK and CELT components.

### Recently Played Redesign
- Paginated loading replaces infinite scroll — smoother performance on large histories.
- Smart date grouping: entries grouped by Today, Yesterday, This Week, and older months.
- Reactive song info in bottom sheet actions updates without full rebuild.

### Developer Mode & Logging
- **Developer mode toggle** in Android `MainActivity` via JNI. When off, verbose logging is suppressed.
- `devLog` utility replaces all `debugPrint` calls across ~20 Dart services — output gated behind developer mode.
- `dev_eprintln!` macro replaces `eprintln!` in Rust for USB, audio debug, and DSD transport logging.
- Zero-cost logging path when developer mode is disabled.

### Vinyl Record & Animations
- Shared **VinylRecord** widget component — custom-painted radial-gradient disc with grooves and label area — replaces inline implementations across the player and milestone screens.
- Album art scope toggle: display vinyl from a single song's art or the whole album's art.
- Vinyl mode state tracked per-player to prevent gesture conflicts during rotation.
- Waveform seek bar and line seek bar now animate in on song change via `appearProgress`.
- Waveform layer nests its animation inside a consumer for reactive updates.
- Mini-player song changes animate with a directional slide transition.

### Scanner & Library UX
- Scanner backend migrated from `jwalk` to `walkdir` for simpler, more maintainable directory traversal.
- Scanning UI replaced bottom sheet with a fullscreen overlay and a scan-complete summary sheet.
- Pending-rescan flag prevents missed scanner events during concurrent processing.
- Auto library sync fires on app resume — keeps the database fresh without manual scans.

### Song Deletion & MediaStore
- Static `removeFromMediaStore` method for safe file removal from Android's MediaStore database.
- Song deleted from the Isar repository before the file is removed from disk.
- MediaStore removal fallback in `deleteDocumentViaSaf` for content URI files.
- Confirmation dialog before song deletion.

### USB Audio Improvements
- **UAC1 sampling frequency negotiation** added for older UAC 1.0 devices.
- USB volume preference check — falls back to bit-perfect default (-40 dB) when no saved volume exists.
- Long-press gesture on album art correctly handled without triggering an accidental tap.
- Audio interruption handling improved with duck-aware pause/resume logic.

### Code Formatting & Polish
- Mass Rust reformatting pass — 100-column limit, consistent struct initializers, organized imports.
- Consistent code style across the Android Direct USB module, audio engine, DSD decoder, and UAC2 APIs.
- Dismissible update notice with slide-fade animation on the menu screen.
- Reactive `FolderEntity` cached with `FutureBuilder` to avoid redundant deep-scan lookups.
- Album art bitmap cached to avoid redundant decoding per render frame.
- NaN guards on non-finite scale and opacity values in visualizer rendering.
- Auto-focus search field preference (Settings → Interface) — only auto-focuses the keyboard when enabled.
- Volume button added to player action buttons with a bottom-sheet volume control.
- Equalizer initialized on app start and reapplied across audio session changes.

## 0.18.0-beta.1 (2026-06-07)

### UAC 1.0 & 2.0 Descriptor Parsing
- USB Audio Class 1.0 and 2.0 descriptor parsing with version detection (header, unit, endpoint). Split version-specific structs and types.
- UAC 1.0/2.0 class constants for descriptors, controls, and requests.
- Active descriptor parsing via UAC2 interfaces with unified quirk database fallback.
- Generic USB audio device model for UAC2 compatibility.
- USB diagnostics refactored with UrbTransportInfo model for transport data isolation.

### DSD Bit Order & Native USB Direct
- **DsdBitOrder enum** (LSB/MSB) with per-source detection across all DSD format decoders (DSF, DFF, WavPack). Bit order normalization in the DSD output router.
- **Global DSD bit reverse override**: `set_dsd_bit_reverse_override()` FFI function exposing manual byte-order control to Flutter.
- **USB native DSD output**: `AndroidDirectUsbPlaybackFormat` now carries `dsd_bit_rate`. Multi-byte interleaved USB payload packing with configurable endianness.
- **DSD quirks table**: `KNOWN_DSD_QUIRKS` with per-device entries (vendor/product IDs, endianness, bit reversal, preferred subslot size). Includes MOONDROP Dawn Pro quirk.
- **DoP word building refactored** into reusable `build_dop_word()` method with I32 packing for integer streams.
- **Default DSD bit rate initialization** for newly configured USB playback formats.
- **UAC2 feature enabled by default**: Multi-byte DSD slots now active without opt-in.
- **Pipeline mode based on output strategy**: `PipelineMode::Dop` set for USB DSD Native and DSD DoP strategies (bit-perfect passthrough). `Passthrough` for PCM bit-perfect. `Dsp` for standard processing.
- **DAP flag in native DSD detection**: DSD Native mode now considered available on DAP devices even without explicit DSD encoding support.
- **Transport labels made descriptive**: Debug transport labels updated from short codes to `usb-native-dsd-u{subslot}x{bits}-bit`, `usb-dop-{bits}-bit`, `usb-pcm`.
- **`DsdBitOrder` passed through DSD decoder thread** to `DsdOutputRouter` for per-track byte normalization.

### Integer (I32) Stream Support
- **`AndroidManagedStreamKind` enum**: Replaces hardcoded f32 stream with `F32` and `I32` variants.
- **`AndroidOutputCallbackI32`**: Reads f32 from pipeline, extracts raw bit patterns via `f32::to_bits()`, writes i32 to AAudio — preserving DoP markers and DSD data intact.
- **`open_android_output_stream()`** gains `use_integer_format` parameter; opens i32 stream with format conversion disabled for DoP/native DSD on DAP.
- Fallback stream logic adapted to work with both f32 and i32 streams.

### Artist & Playlist Theming
- **ArtistEntity** (Isar collection): `id`, `name` (unique, case-insensitive), `artPath` (nullable). Auto-generated Isar bindings.
- **ArtistRepository**: `getByName()`, `setArt()`, `clearArt()` for persistent artist art path caching.
- **ArtistDetailScreen**: Migrated from `StatefulWidget` to `ConsumerStatefulWidget` (Riverpod). Dynamic color theming via `ColorExtractionService` from resolved album art. Full-bleed artist image background with animated tinted app bar. Removed old circular avatar + stat chips layout.
- **PlaylistDetailScreen**: Dynamic playlist color from most-played song's album art via `getMostPlayedSongAmong()`. `TweenAnimationBuilder` tinted background. Info chips (track count, total duration, created/updated dates). "Other Playlists" horizontal section. Back button repositioned to overlay. Removed 4-tile cover grid.
- **`getMostPlayedSongAmong()`** in `RecentlyPlayedRepository`: Returns most-played song from a given list for playlist color extraction.

### Vinyl Disc & Gesture Seeking
- **Vinyl disc morph animation**: Tap album art to morph into a spinning vinyl record. `_VinylDiscPainter` draws radial-gradient disc with grooves and highlight. `_morphController` (700ms) controls transition; `_spinController` (16s rotation) spins the disc. Album art shrinks to center label size. Song change resets to art mode. Haptic feedback on toggle.
- **Rotational gesture seek control** on album art with haptic feedback.
- **Vinyl outline animation** on single tap to enable rotation seeking.
- **Album color in visualizer preview**: `_buildVisualizerPreview()` reads `albumColorModeProvider` and passes album color when mode is not `off`.

### Navigation Bar Auto-Collapse
- FlickNavBar auto-collapse with animated transitions after idle timer.
- Configurable auto-collapse behavior and timer duration via preferences.
- Collapsed state with smooth animated reveal on interaction.

### Milestone Card Redesign & Collection
- Redesigned milestone celebration card with per-tier accent color (bronze / silver / gold / sapphire / amethyst), large hero icon, tinted border + glow, and a subtle "next milestone — N to go" hint line
- New achievement-style collection view (Settings → Milestones) listing all five tiers in a grid; unlocked tiles re-open the celebration card with the achieved date, locked tiles show a progress bottom sheet
- Settings → About → Milestones tile shows a live "X / 5 unlocked" counter
- Five new `AppColors` milestone tint constants and per-tier `tierIcon` / `tierColor` / `shortLabel` / `threshold` / `isTopTier` getters on `MilestoneTypeX`
- New `MilestoneService.getNextMilestone()` helper for "next unshown tier + remaining units" (used by the popup and the locked-tile sheet)
- `MilestoneService` constructor now accepts an optional `playCountOverride` for unit testing without Isar
- New test suite: `test/services/milestone_service_test.dart`

### What's New System
- What's New bottom sheet shown on first launch after update.
- Structured changelog data model with versioned entries and sections.
- Changelog-aware provider with `lastSeenChangelogVersion` preference.
- Version constants (`kAppVersion`, `kAppBuild`, `kAppVersionLabel`) in `app_constants.dart`.

### Ambient Background Removed
- Ambient background decoration removed from songs, albums, artists, playlists, favorites, and folders screens.
- Ambient background toggle removed from settings and playback display.
- Menu screen hero refactored to use `ColorExtractionService` instead of ambient background.

### Folder Browser Enhancements
- Pagination with configurable page size slider.
- Pinch-to-zoom gesture support with animated grid transitions.
- File type filter and sort options in folder browser.

### Build & Compatibility
- **minSdk stays at 26** (Android 8.0+). Core library desugaring enabled for Java 17 target.
- **Impeller rendering configurable** via bool resource, disabled on API 24/25, enabled on API 26+.
- **Isar bumped to 3.3.2** with MDBX_INCOMPATIBLE recovery: corrupt database files are deleted and the library database is recreated automatically.
- **V1 and V2 APK signing** enabled in release config.
- Notification channel creation guarded behind API 26 check.

### Updates & Distribution
- GitHub release update checks for non-Play Store builds with customized update messages.

### UI Polish & Fixes
- Play all and shuffle buttons styled as accent-colored pills with fixed width.
- Scroll-aware animated app bar actions on artist, playlist, and album detail screens.
- Song auto-added to player queue when added to a playlist.
- Audio info bottom sheet expanded to `ConsumerStatefulWidget` with swipeable page view.
- Library auto-sync refactored to event-driven with full rescan support.
- Equalizer initialized on app start and reapplied after audio session changes.
- Star animation overflow clamped; disc scale clamped to prevent zero/negative values.
- Ring buffer write logic fixed to handle full buffer gracefully; bluetooth devices handled more gracefully.
- Center logo Svg in app info settings screen.
- SmartMixDetailScreen back button moved to overlay position.

## 0.17.0-beta.1 (2026-05-31)

### Post-Release Additions

#### DSD Bit Order & Native USB Direct
- **DsdBitOrder enum** (LSB/MSB) with per-source detection across all DSD format decoders (DSF, DFF, WavPack). Bit order normalization in the DSD output router.
- **Global DSD bit reverse override**: `set_dsd_bit_reverse_override()` FFI function exposing manual byte-order control to Flutter.
- **USB native DSD output**: `AndroidDirectUsbPlaybackFormat` now carries `dsd_bit_rate`. Multi-byte interleaved USB payload packing with configurable endianness.
- **DSD quirks table**: `KNOWN_DSD_QUIRKS` with per-device entries (vendor/product IDs, endianness, bit reversal, preferred subslot size). Includes MOONDROP Dawn Pro quirk.
- **DoP word building refactored** into reusable `build_dop_word()` method with I32 packing for integer streams.
- **Default DSD bit rate initialization** for newly configured USB playback formats.

#### DSD Hardware Transport
- **UAC2 feature enabled by default**: Multi-byte DSD slots now active without opt-in.
- **Pipeline mode based on output strategy**: `PipelineMode::Dop` set for USB DSD Native and DSD DoP strategies (bit-perfect passthrough). `Passthrough` for PCM bit-perfect. `Dsp` for standard processing.
- **DAP flag in native DSD detection**: DSD Native mode now considered available on DAP devices even without explicit DSD encoding support.
- **Transport labels made descriptive**: Debug transport labels updated from short codes to `usb-native-dsd-u{subslot}x{bits}-bit`, `usb-dop-{bits}-bit`, `usb-pcm`.
- **`DsdBitOrder` passed through DSD decoder thread** to `DsdOutputRouter` for per-track byte normalization.

#### Integer (I32) Stream Support
- **`AndroidManagedStreamKind` enum**: Replaces hardcoded f32 stream with `F32` and `I32` variants.
- **`AndroidOutputCallbackI32`**: Reads f32 from pipeline, extracts raw bit patterns via `f32::to_bits()`, writes i32 to AAudio — preserving DoP markers and DSD data intact.
- **`open_android_output_stream()`** gains `use_integer_format` parameter; opens i32 stream with format conversion disabled for DoP/native DSD on DAP.
- Fallback stream logic adapted to work with both f32 and i32 streams.

#### Artist & Playlist Theming
- **ArtistEntity** (Isar collection): `id`, `name` (unique, case-insensitive), `artPath` (nullable). Auto-generated Isar bindings.
- **ArtistRepository**: `getByName()`, `setArt()`, `clearArt()` for persistent artist art path caching.
- **ArtistDetailScreen**: Migrated from `StatefulWidget` to `ConsumerStatefulWidget` (Riverpod). Dynamic color theming via `ColorExtractionService` from resolved album art. Full-bleed artist image background with animated tinted app bar. Removed old circular avatar + stat chips layout.
- **PlaylistDetailScreen**: Dynamic playlist color from most-played song's album art via `getMostPlayedSongAmong()`. `TweenAnimationBuilder` tinted background. Info chips (track count, total duration, created/updated dates). "Other Playlists" horizontal section. Back button repositioned to overlay. Removed 4-tile cover grid.
- **`getMostPlayedSongAmong()`** in `RecentlyPlayedRepository`: Returns most-played song from a given list for playlist color extraction.

#### Visualizer & Player
- **Vinyl disc morph animation**: Tap album art to morph into a spinning vinyl record. `_VinylDiscPainter` draws radial-gradient disc with grooves and highlight. `_morphController` (700ms) controls transition; `_spinController` (16s rotation) spins the disc. Album art shrinks to center label size. Song change resets to art mode. Haptic feedback on toggle.
- **Album color in visualizer preview**: `_buildVisualizerPreview()` reads `albumColorModeProvider` and passes album color when mode is not `off`.
- **SmartMixDetailScreen**: Back button moved from `SliverAppBar` leading to overlay position.
- **Playlist metadata helpers**: Total duration calculation and date formatting utilities.

### Milestone Card Redesign & Collection
- Redesigned milestone celebration card with per-tier accent color (bronze / silver / gold / sapphire / amethyst), large hero icon, tinted border + glow, and a subtle "next milestone — N to go" hint line
- New achievement-style collection view (Settings → Milestones) listing all five tiers in a grid; unlocked tiles re-open the celebration card with the achieved date, locked tiles show a progress bottom sheet
- Settings → About → Milestones tile shows a live "X / 5 unlocked" counter
- Five new `AppColors` milestone tint constants and per-tier `tierIcon` / `tierColor` / `shortLabel` / `threshold` / `isTopTier` getters on `MilestoneTypeX`
- New `MilestoneService.getNextMilestone()` helper for "next unshown tier + remaining units" (used by the popup and the locked-tile sheet)
- `MilestoneService` constructor now accepts an optional `playCountOverride` for unit testing without Isar
- New test suite: `test/services/milestone_service_test.dart`

### BitPerfect Capsule/Indicator
- BitPerfect status capsule displayed in the player UI showing active bit-perfect mode
- Visual indicator for bit-perfect audio path engagement

### Player Layout Settings
- Configurable player layout options
- Settings screen for customizing the player layout

### Equalizer Paged Layout
- Equalizer redesigned with a paged layout for better navigation across 31 bands
- Improved band browsing and adjustment workflow

### Folder Filter/Sort Controls
- Folder filtering controls for narrowing down folder listings
- Enhanced folder sort options with dedicated controls

## 0.16.0-beta.1 (2026-05-26)

### Audio Engine & DSD Playback
- **Native DSD playback**: JNI `AudioTrack` backend with `ENCODING_DSD` (encoding 29) for raw bitstream delivery to DACs
- **DoP (DSD over PCM)**: DSD64–DSD512 packed into 24/32-bit PCM frames with 0x05/0xFA markers
- **DSD Auto output mode**: Smart runtime probing (Native → DoP → PCM decimation) based on device capabilities
- **WavPack DSD detection**: Automatic `.wv` file routing to DSD or PCM decoder via WavPack mode flags
- **DSD format decoders**: DSF (Sony), DFF (Philips), WavPack DSD support via vendored `wavpack-sys` crate
- **WavPack PCM decoder**: Dedicated decoder thread with resampling and channel remixing
- **CIC filter**: State split into integer and fractional parts for improved precision at high decimation ratios
- **FIR filter**: Tuned to 256 taps with Kaiser beta 8.0 (from 512 taps, beta 12)
- **Sinc filter**: Formula corrected with frequency response test
- `SequentialBlocks` deinterleaving for DSD channel layout support
- `excluded_strategies` parameter for engine initialization
- DSD source rate and effective mode fields in debug state JSON
- `DsdOutputMode::Auto`, `DsdOutputMode::Native` variants
- DoP frame offset fix in packing logic
- DSD output sample rate fix for Native and Auto modes
- DSF: seek calculation corrected, sample counting fixed, data offset from metadata
- DSF/DFF/WavPack DSD metadata scanning and artwork extraction
- DSD rate label and quality badge in full player screen
- DSD playback architecture documentation

### Metadata Editor
- Full metadata tag editing (read/write) via Rust `lofty` backend
- Dart `MetadataEditorService` bridging Rust FFI
- Metadata editor screen: title, artist, album, album artist, year, genre, track number, comment
- SAF file writing via `writeFileBytesViaSaf` method channel
- `hasLocalEdits` field on `SongEntity` tracking locally modified metadata
- Scanner skips background metadata for locally edited songs
- Scanner preserves local edits when matching scanned songs to existing entries
- Year and genre fields added to `Song` model with sort support

### Parametric Equalizer
- Expanded from 10 to 31 bands at 1/3-octave ISO frequencies (20 Hz–20 kHz)
- Horizontal band editors with per-band gain/Q display
- Detail panel for precise band adjustments

### Song Sharing
- Four share card templates: album art, lyric, minimal, solid color
- Share bottom sheet with template selection
- Share via system share sheet or save to gallery
- `share_plus` integration

### Star Rating System
- 1–5 star rating on songs with animated star overlay
- `RatingService` for persistent rating storage
- `RatingProvider` for reactive state
- Customizable player action button slots (left/right)

### Flagship Home Widget v2
- New `FlagshipWidgetProvider` (Kotlin) with theme support
- Card layout: album art, progress bar, transport controls
- Split layout: art on one side, controls on the other
- Widget settings restructured with tabbed interface (mini player / flagship)
- Multi-widget support with per-widget theme preferences

### USB Volume Control
- `IsoVolumePopup` widget with slider and mute toggle
- Player action button integration
- UAC2 volume control preferences section

### Album and Folder Sorting
- Album sort sheet: sort by title, artist, duration, track count with persistence
- Folder sort sheet: sort by name, song count, duration with persistence
- Songs sorted by album before display

### Audio Engine Selector
- Engine selector card on main menu screen
- Toggle visibility from Settings > Interface > UI Customization
- `showEngineSelector` preference

### Lyrics Enhancements
- `[length:MM:SS.XX]` tag in synced LRC output
- Save location dialog for LRC file export
- Lyrics filename matching audio filename preference
- Lyrics settings screen
- Online lyrics search preview snippets with filtering
- Lyrics panel UI: accent-colored chips, improved empty state

### UAC2 / DAC Backend Refactor
- Scoring-based audio output strategy selection
- DAP detection refactored from brand enum to signature registry
- `AudioBackend` trait with `descriptor()` method
- USB DAC compatibility notice widget
- Device compatibility guide expanded (MOONDROP Dawn Pro)
- DAC/DAP extensibility guide documentation

### Library Scanner
- Per-folder deep scan override
- `useDeepScan` preference
- `FolderEntity.useDeepScan` field preserved on upsert
- Audio file extension filter removed

### UI / Navigation
- Nav bar overflow: animated overlay menu for excess items
- Nav bar labels wrapped with `FittedBox`
- Warning shown when >4 nav bar buttons enabled
- Programmatic navigation to disabled essential pages
- Album art candidates grid layout redesign
- Song card swipe overlay conditionally rendered
- Lyrics scroll animations chained sequentially
- Bottom sheet height constrained to 50% of screen

### Notifications
- Album artwork color extraction for notification background
- Color parameter added to notification service

### Fixes
- Crossfade engine correctly marks stopped when no next source
- `updateTrack` method added to Rust audio engine
- Rust backend path mismatch after track skip fixed
- Bit-perfect mode default volume set to -40 dB safety level
- Dynamic padding and header styling fix

### Milestone Tracking
- Achievement milestones: 100, 500, 1,000 songs played; 10, 50 hours listened
- `MilestoneService` with play count and accumulated listen time tracking
- `MilestoneType` enum with title, message, and achievement date
- `pendingMilestoneNotifier` in `PlayerService` for milestone dialog triggers
- Milestone dialog displayed from app shell when a new milestone is achieved

### Donation & Support
- In-app Support Flick screen with animated info tiles (solo dev, where money goes, Ko-fi link)
- Pulsing heart icon with support button in settings header
- Ko-fi support button and credit line on listening recap screen
- External Ko-fi link replaced with in-app screen

### Welcome Card
- Animated welcome card on menu screen introducing the app and soliciting support
- Dismiss-to-close with animated transition
- `welcomeCardDismissed` preference for persistent dismissal

### Audio Engine Fixes
- Audio session now activated for Rust engine on Android (fixes audio focus/ducking)
- Volume slider gain mapping refined: 0-20 dB linear mapping replaces steep 0-60 dB curve
- WAV conversion/staging skipped for normal Android engine (not USB)

### UI Performance
- Orbit scroll refactored to use `ValueNotifier` with cache size limit
- Card width cached once and reused; `RepaintBoundary` wrapper removed
- `SingleChildScrollView` wrapper removed from column in full player screen

### Gated
- Native DSD, DoP, and Auto output modes marked experimental — disabled by default

---

## 0.15.0-beta.1 (2026-05-22)

### Added
- Home screen mini player widget (album art, progress bar, transport controls)
- Online lyrics search via LRCLib.net (exact match + fuzzy fallback)
- Lyrics Sync Studio (Simple + Advanced timestamp editor, time-shift tools, file import)
- Visualizer customization (5 animation styles, 5 frequency modes, 3 movement modes)
- Queue management overhaul (Now Playing / Up Next / Manual queue, multi-select, drag reorder)
- Folder grid (paginated, 2-col phone / 3-col tablet, infinite scroll)
- Immersive full view (auto-hide controls, floating metadata card, visualizer-only mode)
- Swipe actions (left to queue, right to favorite, toggleable)
- Player layout customization (artwork scale, text size/placement, metadata visibility)
- Play Store in-app updates (automatic + manual)
- Bluetooth codec info reference display
- Multi-select in songs screen (long-press for bulk queue/favorite)
- CSV/TXT export for listening recaps
- Favorite removal mode setting
- Widget customization (background opacity, accent color, content toggles)

### Changed
- Migrated to `ConcatenatingAudioSource` for queue
- In-place shuffle (audio source sequence shuffled instead of full rebuild)
- Fast index scrolling (collapsible alphabetical overlay with auto-hide)
- Reorderable bottom nav bar with show/hide per button
- Mini player redesign with progress bar and smaller controls
- Double back press to exit replaces auto-full-player navigation
- Onboarding redesigned with animated orb system
- Blur cache module-level for shared album art blur

### Deprecated
- GitHub Releases are no longer deprecated and remain available for downloads

---

## 0.14.0-beta.1 (2026-05-09)

### Added
- MediaStore-based library scanning (~34x faster: 328ms vs 11–12s for 60GB/1,287 tracks)
- Home screen toggle customization (Quick Access, Smart Mixes, Recent Artists, etc.)
- Configurable nav bar (reorder buttons, show/hide labels, dedicated settings screen)
- Album color theming (dynamic palette extraction from album art)
- Crossfade engine (curve selection, duration control, gapless playback)
- USB audio device detection with connection notifications
- Playback desync detection with auto-sync notification
- Undo support for queue and favorites removals
- Debounced Search screen

### Changed
- Default loop mode changed from `off` to `all`
- Snackbar duration reduced from 3s to 2s
- Duplicate entries removed from Recently Played
- Sort and file-type filter persist via SharedPreferences
- Launcher icons updated across mipmap densities
- Fingerprint cache service avoids re-reading unchanged files

### Breaking
- Android minSdk raised to 26 (dropping API 21–25)

---

## Pre-0.14.0 (notable earlier releases)

### 0.12.0-beta.2
- Last git-tagged release
- Foundation: Rust engine, just_audio fallback, UAC 2.0 subsystem, Isar database
- Library management (songs, albums, artists, playlists, favorites)
- Equalizer and audio effects
- Cross-app playback via Moss ecosystem (Latch integration)
- Flick Replay listening recaps
- Last.fm scrobbling

### 0.9.0 – 0.12.0
- Initial Flutter + Rust architecture
- DAP device detection and bit-perfect profiles
- USB Audio Class 2.0 descriptor parsing and device enumeration
- Symphonia-based PCM decoding
- Content URI staging and ALAC/AIFF/M4A conversion
- Album art import from MusicBrainz, iTunes, Deezer
- EQ preset management with import/export
- Hardware volume control (three-tier)
