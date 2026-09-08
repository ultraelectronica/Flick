import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/duration_format.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/features/player/widgets/audio_visualizer.dart';
import 'package:flick/features/player/widgets/player_action_button_row.dart';
import 'package:flick/features/player/widgets/player_controls.dart';
import 'package:flick/features/player/widgets/player_layout_sheet.dart';
import 'package:flick/features/player/widgets/player_navigation.dart';
import 'package:flick/features/player/widgets/song_actions_sheet.dart';
import 'package:flick/features/player/widgets/song_stage.dart';
import 'package:flick/features/player/widgets/song_stage_carousel.dart';
import 'package:flick/features/player/widgets/lyrics_mode_waveform_strip.dart';
import 'package:flick/features/player/widgets/album_color_helpers.dart';
import 'package:flick/models/album_color_mode.dart';
import 'package:flick/models/player_screen_mode.dart';
import 'package:flick/models/player_action_button.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/external_playback_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/player_screen_mode_preference_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';
import 'package:flick/widgets/uac2/iso_volume_popup.dart';
import 'package:flick/widgets/uac2/uac2_error_notification.dart';
import 'package:flick/providers/providers.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/utils/app_haptics.dart';

class FullPlayerScreen extends ConsumerStatefulWidget {
  final Object heroTag;
  const FullPlayerScreen({super.key, this.heroTag = 'album_art_hero'});

  @override
  ConsumerState<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends ConsumerState<FullPlayerScreen>
    with TickerProviderStateMixin {
  final PlayerService _playerService = PlayerService();
  final ExternalPlaybackService _externalPlaybackService =
      ExternalPlaybackService();
  final FavoritesService _favoritesService = FavoritesService();
  final LyricsService _lyricsService = LyricsService();
  final PlayerScreenModePreferenceService _playerScreenModePreferenceService =
      PlayerScreenModePreferenceService();
  final SongRepository _songRepository = SongRepository();
  late final PlayerNavigation _navigation = PlayerNavigation(
    playerService: _playerService,
    songRepository: _songRepository,
  );

  void _close(BuildContext context) {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    Navigator.of(context).pop();
  }

  static const String _topBarTextFontFamily = 'ProductSans';
  static const FontWeight _topBarTextFontWeight = FontWeight.w500;

  late AnimationController _dragController;
  double _dragOffset = 0.0;
  DateTime _lastDragUpdate = DateTime.now();
  static const double _backGestureEdgeWidth = 32.0;

  late final ValueNotifier<Duration> _throttledPositionNotifier;
  final ValueNotifier<Duration> _zeroPosition = ValueNotifier(Duration.zero);
  Timer? _positionThrottleTimer;
  String? _cachedTopBarText;
  double? _cachedTopBarFontSize;
  bool _isLyricsMode = false;
  bool _isVinylRotationActive = false;
  bool _isVinylMode = false;
  bool _isVisualizationMode = false;
  bool _isImmersiveFullView = false;
  bool _isCarouselDragging = false;
  PlayerScreenMode _playerScreenMode = PlayerScreenMode.immersive;
  int _immersiveAutoFullViewDelaySeconds = 0;
  Timer? _immersiveFullViewTimer;
  final GlobalKey _usbVolumeButtonKey = GlobalKey();
  final GlobalKey<SongStageCarouselState> _carouselKey = GlobalKey();
  VoidCallback? _dismissVolumePopup;

  @override
  void initState() {
    super.initState();
    _immersiveAutoFullViewDelaySeconds = ref
        .read(appPreferencesProvider)
        .immersiveAutoFullViewSeconds;
    _dragController = AnimationController(
      vsync: this,
      duration: AppConstants.animationFast,
      lowerBound: 0.0,
      upperBound: 1000.0,
    );
    _dragController.value = 0.0;
    _throttledPositionNotifier = ValueNotifier(
      _playerService.positionNotifier.value,
    );
    _positionThrottleTimer = Timer.periodic(const Duration(milliseconds: 50), (
      timer,
    ) {
      if (mounted) {
        final newPosition = _playerService.positionNotifier.value;
        if (_throttledPositionNotifier.value != newPosition) {
          _throttledPositionNotifier.value = newPosition;
        }
      }
    });
    _playerService.currentSongNotifier.addListener(_handleCurrentSongChanged);
    _playerService.favoriteNotificationToggleNotifier.addListener(
      _handleFavoriteToggledFromNotification,
    );
    _updateTopBarTextMeasurement(_playerService.currentSongNotifier.value);
    _loadPlayerScreenMode();
    _refreshImmersiveFullViewTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateTopBarTextMeasurement(_playerService.currentSongNotifier.value);
  }

  @override
  void dispose() {
    _playerService.currentSongNotifier.removeListener(
      _handleCurrentSongChanged,
    );
    _playerService.favoriteNotificationToggleNotifier.removeListener(
      _handleFavoriteToggledFromNotification,
    );
    _positionThrottleTimer?.cancel();
    _immersiveFullViewTimer?.cancel();
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    _throttledPositionNotifier.dispose();
    _zeroPosition.dispose();
    _dragController.dispose();
    super.dispose();
  }

  void _handleCurrentSongChanged() {
    if (_playerService.currentSongNotifier.value == null) return;
    if (_isImmersiveFullView) {
      setState(() => _isImmersiveFullView = false);
    }
    _updateTopBarTextMeasurement(_playerService.currentSongNotifier.value);
    _refreshImmersiveFullViewTimer();
  }

  void _handleFavoriteToggledFromNotification() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPlayerScreenMode() async {
    final mode = await _playerScreenModePreferenceService.getMode();
    if (!mounted) return;
    if (_playerScreenMode != mode) {
      setState(() {
        _playerScreenMode = mode;
        if (mode != PlayerScreenMode.immersive) _isImmersiveFullView = false;
      });
    }
    _refreshImmersiveFullViewTimer();
  }

  Future<void> _setPlayerScreenMode(PlayerScreenMode mode) async {
    if (_playerScreenMode == mode) return;
    setState(() {
      _playerScreenMode = mode;
      if (mode != PlayerScreenMode.immersive) _isImmersiveFullView = false;
    });
    _refreshImmersiveFullViewTimer();
    await _playerScreenModePreferenceService.setMode(mode);
  }

  bool get _canUseImmersiveFullView =>
      _playerScreenMode == PlayerScreenMode.immersive && !_isLyricsMode;

  void _refreshImmersiveFullViewTimer() {
    _immersiveFullViewTimer?.cancel();
    if (!_canUseImmersiveFullView ||
        _isImmersiveFullView ||
        _immersiveAutoFullViewDelaySeconds <= 0) {
      return;
    }
    _immersiveFullViewTimer = Timer(
      Duration(seconds: _immersiveAutoFullViewDelaySeconds),
      () {
        if (!mounted || !_canUseImmersiveFullView || _isImmersiveFullView) {
          return;
        }
        setState(() => _isImmersiveFullView = true);
      },
    );
  }

  void _setImmersiveAutoFullViewDelaySeconds(int value) {
    if (_immersiveAutoFullViewDelaySeconds == value) return;
    _immersiveAutoFullViewDelaySeconds = value;
    _refreshImmersiveFullViewTimer();
  }

  void _setLyricsMode(bool value) {
    final nextVisualizationMode = value ? false : _isVisualizationMode;
    final nextImmersiveFullView = value ? false : _isImmersiveFullView;
    if (_isLyricsMode == value &&
        _isVisualizationMode == nextVisualizationMode &&
        _isImmersiveFullView == nextImmersiveFullView) {
      return;
    }
    setState(() {
      _isLyricsMode = value;
      _isVisualizationMode = nextVisualizationMode;
      _isImmersiveFullView = nextImmersiveFullView;
    });
    _refreshImmersiveFullViewTimer();
  }

  void _setVisualizationMode(bool value) {
    final nextLyricsMode = value ? false : _isLyricsMode;
    if (_isVisualizationMode == value && _isLyricsMode == nextLyricsMode)
      return;
    setState(() {
      _isVisualizationMode = value;
      _isLyricsMode = nextLyricsMode;
    });
    _refreshImmersiveFullViewTimer();
  }

  void _handleImmersiveSceneTap() {
    if (_playerScreenMode != PlayerScreenMode.immersive) return;
    if (_isLyricsMode) return;
    setState(() => _isImmersiveFullView = !_isImmersiveFullView);
    _refreshImmersiveFullViewTimer();
  }

  Future<void> _animateToNextSong() async {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    final carousel = _carouselKey.currentState;
    if (carousel != null && !_isVinylRotationActive) {
      await carousel.animateToNext();
    } else {
      await _playerService.next();
    }
  }

  Future<void> _animateToPreviousSong() async {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    // Button: restart if >3s, else slide to previous track
    if (_playerService.positionNotifier.value.inSeconds > 3) {
      await _playerService.previous(allowRestart: true);
      return;
    }
    final carousel = _carouselKey.currentState;
    if (carousel != null && !_isVinylRotationActive) {
      await carousel.animateToPrevious();
    } else {
      await _playerService.previous(allowRestart: false);
    }
  }

  Future<void> _handleCarouselNext() async {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    await _playerService.next();
  }

  Future<void> _handleCarouselPrevious() async {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    // Swipe/slide: always go to previous track, ignoring >3s restart rule
    await _playerService.previous(allowRestart: false);
  }

  void _updateTopBarTextMeasurement(Song? song) {
    if (!mounted || song == null) return;
    final text = '${song.title} - ${song.artist}';
    final fontSize = context.responsiveText(
      context.responsive(13.0, 14.0, 15.0),
    );
    if (_cachedTopBarText == text && _cachedTopBarFontSize == fontSize) return;
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _topBarTextFontFamily,
          fontSize: fontSize,
          fontWeight: _topBarTextFontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _cachedTopBarText = text;
    _cachedTopBarFontSize = fontSize;
    textPainter.width; // measure kept for future use
  }

  void _showUsbVolumePopup(BuildContext context) {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = showIsoVolumePopup(context, _usbVolumeButtonKey);
  }

  // ---------------------------------------------------------------------------
  // Background (static, not sliding)
  // ---------------------------------------------------------------------------

  Widget _buildBackground(
    BuildContext context,
    Song song,
    AlbumColorMode albumColorMode,
    Color? albumColor,
    bool visualizationMode,
    String visStyle,
    String visFreq,
    String visMove,
  ) {
    final bgBlend = albumColorMode.backgroundBlend;
    final hasAlbumTint = albumColor != null && bgBlend > 0;
    final scrimColor = hasAlbumTint
        ? Color.lerp(
            Colors.black,
            albumColor,
            (bgBlend * 1.2).clamp(0.0, 0.35),
          )!
        : Colors.black;
    return Stack(
      children: [
        Positioned.fill(
          child: _buildBaseBackground(
            context,
            song,
            albumColorMode,
            albumColor,
            visualizationMode,
            visStyle,
            visFreq,
            visMove,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: AppConstants.animationNormal,
              opacity: _isLyricsMode ? 1.0 : 0.0,
              child: AnimatedContainer(
                duration: AppConstants.animationNormal,
                color: scrimColor.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBaseBackground(
    BuildContext context,
    Song song,
    AlbumColorMode albumColorMode,
    Color? albumColor,
    bool visualizationMode,
    String visStyle,
    String visFreq,
    String visMove,
  ) {
    final bgBlend = albumColorMode.backgroundBlend;
    final hasAlbumTint = albumColor != null && bgBlend > 0;

    if (visualizationMode &&
        _playerScreenMode != PlayerScreenMode.artworkCard) {
      final overlayColor = hasAlbumTint
          ? albumSurface(albumColor, bgBlend * 0.5)
          : const Color(0xFF0A0A0A);
      return Stack(
        children: [
          Positioned.fill(
            child: AudioVisualizer(
              playerService: _playerService,
              animationStyle: visStyle,
              frequencyMode: visFreq,
              movementMode: visMove,
              albumColor: albumColor,
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    overlayColor.withValues(alpha: 0.7),
                    overlayColor.withValues(alpha: 0.35),
                    Colors.transparent,
                    Colors.transparent,
                    overlayColor.withValues(alpha: 0.3),
                    overlayColor.withValues(alpha: 0.75),
                  ],
                  stops: const [0.0, 0.12, 0.28, 0.62, 0.82, 1.0],
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (_playerScreenMode == PlayerScreenMode.artworkCard) {
      return Stack(
        children: [
          Positioned.fill(
            child: (song.albumArt != null || song.filePath != null)
                ? AmbientBackground(song: song)
                : Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF181818), AppColors.background],
                      ),
                    ),
                    child: const Center(
                      child: FlickArtworkPlaceholder(size: 96, opacity: 0.22),
                    ),
                  ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    (hasAlbumTint
                            ? albumSurface(albumColor, bgBlend)
                            : const Color(0xFF080808))
                        .withValues(alpha: 0.5),
                    (hasAlbumTint
                            ? albumSurface(albumColor, bgBlend * 0.6)
                            : const Color(0xFF0E0E0E))
                        .withValues(alpha: 0.32),
                    (hasAlbumTint
                            ? albumSurface(albumColor, bgBlend)
                            : const Color(0xFF0A0A0A))
                        .withValues(alpha: 0.94),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
        ],
      );
    }

    final gradientBase = hasAlbumTint
        ? albumSurface(albumColor, bgBlend)
        : const Color(0xFF121212);
    final gradientColors = _isImmersiveFullView
        ? [
            gradientBase.withValues(alpha: 0.3),
            gradientBase.withValues(alpha: 0.25),
            gradientBase.withValues(alpha: 0.2),
            gradientBase.withValues(alpha: 0.15),
            gradientBase.withValues(alpha: 0.08),
            Colors.transparent,
          ]
        : [
            gradientBase,
            gradientBase.withValues(alpha: 0.95),
            gradientBase.withValues(alpha: 0.85),
            gradientBase.withValues(alpha: 0.6),
            gradientBase.withValues(alpha: 0.3),
            Colors.transparent,
          ];
    return Stack(
      children: [
        Positioned.fill(
          child: CachedImageWidget(
            imagePath: song.albumArt,
            audioSourcePath: song.filePath,
            fit: BoxFit.cover,
            placeholder: Container(
              color: AppColors.background,
              child: const Center(
                child: FlickArtworkPlaceholder(size: 96, opacity: 0.35),
              ),
            ),
            errorWidget: Container(
              color: AppColors.background,
              child: const Center(
                child: FlickArtworkPlaceholder(size: 96, opacity: 0.35),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: AnimatedContainer(
            duration: AppConstants.animationNormal,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: gradientColors,
                stops: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Top chrome (pinned)
  // ---------------------------------------------------------------------------

  Widget _buildTopChrome(
    BuildContext context,
    Song song,
    Color? albumColor,
    AlbumColorMode albumColorMode,
    dynamic appPrefs,
  ) {
    final hideQueueBadge =
        PlayerActionButtonX.fromStorageValue(appPrefs.leftActionButton) ==
            PlayerActionButton.queue ||
        PlayerActionButtonX.fromStorageValue(appPrefs.rightActionButton) ==
            PlayerActionButton.queue ||
        PlayerActionButtonX.fromStorageValue(appPrefs.leftTopActionButton) ==
            PlayerActionButton.queue ||
        PlayerActionButtonX.fromStorageValue(appPrefs.rightTopActionButton) ==
            PlayerActionButton.queue;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.responsive(8.0, 12.0, 16.0),
        vertical: context.responsive(4.0, 6.0, 8.0),
      ),
      child: Row(
        children: [
          _buildChromeButton(
            context,
            icon: LucideIcons.chevronDown,
            albumColor: albumColor,
            albumColorMode: albumColorMode,
            onTap: () => _close(context),
          ),
          SizedBox(width: context.responsive(8.0, 10.0, 12.0)),
          Expanded(
            child: GestureDetector(
              onTap: song.isFromLocker
                  ? null
                  : () => _navigation.openQueue(context),
              onHorizontalDragEnd: song.isFromLocker
                  ? null
                  : (details) async {
                      if (details.primaryVelocity != null &&
                          details.primaryVelocity! < -400) {
                        await _navigation.queueSong(context, song);
                      }
                    },
              child: ValueListenableBuilder<List<Song>>(
                valueListenable: _playerService.upNextNotifier,
                builder: (context, upNext, _) {
                  final hasQueue = upNext.isNotEmpty;
                  final fromLocker = song.isFromLocker;
                  final nowPlayingContent = Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Now Playing',
                        style: TextStyle(
                          fontFamily: 'ProductSans',
                          fontSize: context.responsive(12.0, 13.0, 14.0),
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.9),
                          letterSpacing: 0.8,
                        ),
                      ),
                      if (fromLocker) ...[
                        SizedBox(height: context.responsive(2.0, 3.0, 4.0)),
                        Text(
                          'Opened from Locker',
                          style: TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: context.responsive(10.0, 10.5, 11.0),
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ],
                  );
                  final chip = AnimatedContainer(
                    duration: AppConstants.animationFast,
                    padding: EdgeInsets.fromLTRB(
                      context.responsive(12.0, 14.0, 16.0),
                      context.responsive(6.0, 7.0, 8.0),
                      (!fromLocker && !hideQueueBadge)
                          ? context.responsive(10.0, 11.0, 12.0)
                          : context.responsive(12.0, 14.0, 16.0),
                      context.responsive(6.0, 7.0, 8.0),
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212).withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: hasQueue
                            ? Colors.white.withValues(alpha: 0.18)
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        nowPlayingContent,
                        if (!fromLocker && !hideQueueBadge) ...[
                          SizedBox(width: context.responsive(8.0, 10.0, 12.0)),
                          _buildQueueSummaryBadge(
                            context,
                            count: upNext.length,
                            highlighted: hasQueue,
                          ),
                        ],
                      ],
                    ),
                  );
                  return Align(alignment: Alignment.center, child: chip);
                },
              ),
            ),
          ),
          SizedBox(width: context.responsive(8.0, 10.0, 12.0)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (song.isFromLocker) ...[
                _buildReturnToLockerButton(context),
                SizedBox(width: context.responsive(8.0, 10.0, 12.0)),
              ],
              _buildChromeButton(
                context,
                icon: Icons.more_vert,
                albumColor: albumColor,
                albumColorMode: albumColorMode,
                onTap: () => SongActionsSheet.show(
                  context,
                  playerService: _playerService,
                  song: song,
                  isVisualizationMode: _isVisualizationMode,
                  onShowLyrics: () => _setLyricsMode(true),
                  onToggleVisualization: (v) => _setVisualizationMode(v),
                  onShowPlayerLayout: (ctx) => PlayerLayoutSheet.show(
                    ctx,
                    playerService: _playerService,
                    currentMode: _playerScreenMode,
                    onModeChanged: _setPlayerScreenMode,
                    song: _playerService.currentSongNotifier.value,
                  ),
                  navigation: _navigation,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReturnToLockerButton(BuildContext context) {
    return GestureDetector(
      onTap: () {
        unawaited(
          _externalPlaybackService.returnToLocker().then((returned) {
            if (!returned && context.mounted) Navigator.of(context).pop();
          }),
        );
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.responsive(12.0, 14.0, 16.0),
          vertical: context.responsive(10.0, 11.0, 12.0),
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF121212).withValues(alpha: 0.76),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.undo2,
              size: context.responsive(14.0, 15.0, 16.0),
              color: Colors.white.withValues(alpha: 0.9),
            ),
            SizedBox(width: context.responsive(6.0, 7.0, 8.0)),
            Text(
              'Back to Locker',
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: context.responsive(11.0, 12.0, 13.0),
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.92),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueSummaryBadge(
    BuildContext context, {
    required int count,
    required bool highlighted,
  }) {
    return AnimatedContainer(
      duration: AppConstants.animationFast,
      padding: EdgeInsets.symmetric(
        horizontal: context.responsive(8.0, 9.0, 10.0),
        vertical: context.responsive(3.0, 4.0, 5.0),
      ),
      decoration: BoxDecoration(
        color: highlighted
            ? Colors.white.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlighted
              ? Colors.white.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.listMusic,
            size: context.responsive(12.0, 13.0, 14.0),
            color: Colors.white.withValues(alpha: highlighted ? 0.96 : 0.7),
          ),
          SizedBox(width: context.responsive(4.0, 5.0, 6.0)),
          Text(
            count > 0 ? 'Queue $count' : 'Queue',
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: context.responsive(10.0, 11.0, 12.0),
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: highlighted ? 0.96 : 0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChromeButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onTap,
    Color? albumColor,
    AlbumColorMode? albumColorMode,
  }) {
    final surfaceColor = (albumColor != null && albumColorMode != null)
        ? albumSurface(albumColor, albumColorMode.surfaceBlend)
        : const Color(0xFF121212);
    return Container(
      decoration: BoxDecoration(
        color: surfaceColor.withValues(alpha: 0.7),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: AppHaptics.wrap(onTap),
        padding: EdgeInsets.all(context.responsive(8.0, 10.0, 12.0)),
        constraints: const BoxConstraints(),
        icon: Icon(
          icon,
          color: Colors.white,
          size: context.responsive(20.0, 22.0, 24.0),
        ),
      ),
    );
  }

  /// Pinned waveform — stays fixed while carousel slides art+identity.
  /// Lazy-loads for current song only; peek stages no longer build waveforms.
  /// Always builds LyricsModeWaveformStrip so the WaveformLayer inside keeps
  /// its state (no re-appear animation / peaks reload) when lyrics toggle.
  Widget _buildPinnedWaveform(
    BuildContext context,
    Song song,
    PlayerScreenMode mode,
  ) {
    final isImmersive = mode == PlayerScreenMode.immersive;
    // Lyrics uses the strip for immersive (waveform + dismiss arrow) but the
    // time labels are now unified as a single pinned default for BOTH
    // immersive and artworkCard when lyrics are on. Hide strip's internal
    // labels and PlayerControls's labels; keep one under waveform.
    return LyricsModeWaveformStrip(
      playerService: _playerService,
      positionNotifier: _throttledPositionNotifier,
      currentSong: song,
      formatDuration: formatDuration,
      horizontalPadding: isImmersive
          ? context.responsive(18.0, 24.0, 30.0)
          : context.responsive(16.0, 20.0, 24.0),
      onSwipeUp: () => _setLyricsMode(false),
      showTimeLabels: false,
      showArrow: _isLyricsMode && isImmersive,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appPreferencesProvider, (previous, next) {
      _setImmersiveAutoFullViewDelaySeconds(next.immersiveAutoFullViewSeconds);
    });

    final appPrefs = ref.watch(appPreferencesProvider);
    final visStyle = appPrefs.visualizerAnimationStyle;
    final visFreq = appPrefs.visualizerFrequencyMode;
    final visMove = appPrefs.visualizerMovementMode;

    final colorMode = ref.watch(albumColorModeProvider);
    final dominantColor = ref.watch(albumDominantColorSyncProvider);
    final Color? albumColor =
        (colorMode != AlbumColorMode.off && dominantColor != null)
        ? dominantColor
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _close(context);
      },
      child: DisplayModeWrapper(
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: ValueListenableBuilder<Song?>(
            valueListenable: _playerService.currentSongNotifier,
            builder: (context, song, _) {
              if (song == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) Navigator.of(context).pop();
                });
                return const SizedBox.shrink();
              }

              final isShortHeight = MediaQuery.sizeOf(context).height < 620.0;
              final showImmersiveFullView =
                  _isImmersiveFullView &&
                  _playerScreenMode == PlayerScreenMode.immersive &&
                  !isShortHeight;
              final showVisualizerOnly =
                  _isVisualizationMode &&
                  appPrefs.visualizerEnabled &&
                  showImmersiveFullView;

              // Outer vertical-dismiss gesture (kept). Horizontal is now inside carousel.
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _handleImmersiveSceneTap,
                onVerticalDragStart: (details) {
                  if (_isVinylRotationActive || _isCarouselDragging) return;
                  final screenHeight = MediaQuery.sizeOf(context).height;
                  if (details.globalPosition.dy >=
                      screenHeight - _backGestureEdgeWidth) {
                    _dragOffset = 0.0;
                    return;
                  }
                  _dragController.stop();
                },
                onVerticalDragUpdate: (details) {
                  if (_isVinylRotationActive || _isCarouselDragging) return;
                  if (details.delta.dy > 0) {
                    final now = DateTime.now();
                    if (now.difference(_lastDragUpdate).inMilliseconds < 16) {
                      return;
                    }
                    _lastDragUpdate = now;
                    _dragOffset = (_dragOffset + details.delta.dy).clamp(
                      0.0,
                      1000.0,
                    );
                    _dragController.value = _dragOffset;
                  }
                },
                onVerticalDragEnd: (details) {
                  if (_isVinylRotationActive || _isCarouselDragging) return;
                  if (_dragOffset > 100 || details.primaryVelocity! > 500) {
                    _close(context);
                    return;
                  }
                  _dragOffset = 0.0;
                  _dragController.animateTo(0.0);
                },
                child: AnimatedBuilder(
                  animation: _dragController,
                  builder: (context, child) {
                    final offset = _dragController.value * 0.5;
                    return Transform.translate(
                      offset: Offset(0, offset),
                      child: child!,
                    );
                  },
                  child: _buildPlayerBody(
                    context,
                    song,
                    appPrefs,
                    colorMode,
                    albumColor,
                    visStyle,
                    visFreq,
                    visMove,
                    showImmersiveFullView,
                    showVisualizerOnly,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerBody(
    BuildContext context,
    Song song,
    dynamic appPrefs,
    AlbumColorMode colorMode,
    Color? albumColor,
    String visStyle,
    String visFreq,
    String visMove,
    bool showImmersiveFullView,
    bool showVisualizerOnly,
  ) {
    final visualizationMode =
        _isVisualizationMode && appPrefs.visualizerEnabled;

    // Shared file-info builder for stages; also drawn pinned (overlay) so the
    // left/right buttons don't slide with the carousel.
    Widget fileInfoBuilder(Song s, bool lm, PlayerScreenMode mode) {
      return PlayerActionButtonRow(
        song: s,
        lyricsMode: lm,
        isVisualizationMode: _isVisualizationMode,
        playerScreenMode: mode,
        albumColor: albumColor,
        albumColorMode: colorMode,
        leftTopAction: PlayerActionButtonX.fromStorageValue(
          appPrefs.leftTopActionButton,
        ),
        leftAction: PlayerActionButtonX.fromStorageValue(
          appPrefs.leftActionButton,
        ),
        rightTopAction: PlayerActionButtonX.fromStorageValue(
          appPrefs.rightTopActionButton,
        ),
        rightAction: PlayerActionButtonX.fromStorageValue(
          appPrefs.rightActionButton,
        ),
        playerService: _playerService,
        favoritesService: _favoritesService,
        onToggleLyrics: () => setState(() => _isLyricsMode = !lm),
        onToggleVisualization: (v) => _setVisualizationMode(v),
        onOpenQueue: (ctx) => _navigation.openQueue(ctx),
        usbVolumeButtonKey: _usbVolumeButtonKey,
        onShowUsbVolumePopup: (ctx) => _showUsbVolumePopup(ctx),
      );
    }

    // Overlay shows over the stage's reserved invisible row slot.
    final showPinnedActionRow = _playerScreenMode == PlayerScreenMode.immersive
        ? (appPrefs.immersiveShowFileInfo && !_isLyricsMode)
        : appPrefs.artworkCardShowFileInfo;
    // Match the stage's own row padding so the overlay lines up exactly.
    final pinnedActionRowPadding =
        _playerScreenMode == PlayerScreenMode.immersive
        ? context.responsive(12.0, 16.0, 20.0)
        : (MediaQuery.sizeOf(context).width < 360
              ? 16.0
              : context.responsive(20.0, 28.0, 36.0));

    // Background is always behind
    final background = _buildBackground(
      context,
      song,
      colorMode,
      albumColor,
      visualizationMode,
      visStyle,
      visFreq,
      visMove,
    );

    if (showVisualizerOnly) {
      // Full-bleed visualizer, tap to exit full-view
      return Stack(
        children: [
          Positioned.fill(child: background),
          // keep top chrome hidden in full-view; still allow tap to exit
        ],
      );
    }

    if (showImmersiveFullView) {
      // Minimal bottom card — no top chrome, no pinned controls
      return Stack(
        children: [
          Positioned.fill(child: background),
          SafeArea(
            child: ValueListenableBuilder<List<Song>>(
              valueListenable: _playerService.upNextNotifier,
              builder: (context, upNext, _) {
                return ValueListenableBuilder<int>(
                  valueListenable: _playerService.currentIndexNotifier,
                  builder: (context, idx, _) {
                    final prev = _playerService.peekPrevious;
                    final next = _playerService.peekNext;
                    return SongStageCarousel(
                      key: _carouselKey,
                      currentSong: song,
                      prevSong: prev,
                      nextSong: next,
                      enabled: !_isVinylRotationActive,
                      onDragStateChanged: (v) => _isCarouselDragging = v,
                      onNext: _handleCarouselNext,
                      onPrevious: _handleCarouselPrevious,
                      stageBuilder: (s) {
                        final isCurrent = s.id == song.id;
                        return SongStage(
                          song: s,
                          lyricsMode: _isLyricsMode,
                          visualizationMode: visualizationMode,
                          immersiveFullView: true,
                          playerScreenMode: _playerScreenMode,
                          albumColorMode: colorMode,
                          albumColor: albumColor,
                          playerService: _playerService,
                          lyricsService: _lyricsService,
                          positionNotifier: isCurrent
                              ? _throttledPositionNotifier
                              : _zeroPosition,
                          formatDuration: formatDuration,
                          onNavigateToArtistDetail: (s) =>
                              _navigation.openArtistFromSong(context, s),
                          onNavigateToAlbumDetail: (s) =>
                              _navigation.openAlbumFromSong(context, s),
                          buildFileInfoRow: fileInfoBuilder,
                          visualizerAnimationStyle: visStyle,
                          visualizerFrequencyMode: visFreq,
                          visualizerMovementMode: visMove,
                          artworkCardArtworkScale:
                              appPrefs.artworkCardArtworkScale,
                          artworkCardTextScale: appPrefs.artworkCardTextScale,
                          artworkCardVerticalOffset:
                              appPrefs.artworkCardVerticalOffset,
                          artworkCardShowTitle: appPrefs.artworkCardShowTitle,
                          artworkCardShowArtist: appPrefs.artworkCardShowArtist,
                          artworkCardShowAlbum: appPrefs.artworkCardShowAlbum,
                          artworkCardShowFileInfo:
                              appPrefs.artworkCardShowFileInfo,
                          artworkCardShowFrame: appPrefs.artworkCardShowFrame,
                          immersiveTextScale: appPrefs.immersiveTextScale,
                          immersiveVerticalOffset:
                              appPrefs.immersiveVerticalOffset,
                          immersiveFullViewScale:
                              appPrefs.immersiveFullViewScale,
                          immersiveShowTitle: appPrefs.immersiveShowTitle,
                          immersiveShowArtist: appPrefs.immersiveShowArtist,
                          immersiveShowFileInfo: appPrefs.immersiveShowFileInfo,
                          onRotationEnabledChanged: (enabled) {
                            _isVinylRotationActive = enabled;
                          },
                          vinylMode: _isVinylMode,
                          onVinylChanged: (v) => _isVinylMode = v,
                          onToggleLyrics: () => _setLyricsMode(!_isLyricsMode),
                          showWaveform: false,
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      );
    }

    // Default: pinned top chrome + sliding stage + pinned controls
    return Stack(
      children: [
        Positioned.fill(child: background),
        SafeArea(
          child: Column(
            children: [
              const Uac2ErrorNotification(),
              _buildTopChrome(context, song, albumColor, colorMode, appPrefs),
              SizedBox(height: context.responsive(8.0, 10.0, 12.0)),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ValueListenableBuilder<List<Song>>(
                        valueListenable: _playerService.upNextNotifier,
                        builder: (context, upNext, _) {
                          return ValueListenableBuilder<int>(
                            valueListenable:
                                _playerService.currentIndexNotifier,
                            builder: (context, idx, _) {
                              final prev = _playerService.peekPrevious;
                              final next = _playerService.peekNext;
                              // Precache adjacent artwork for buttery peek
                              final nextArt = next?.albumArt;
                              if (nextArt != null) {
                                precacheImage(
                                  FileImage(File(nextArt)),
                                  context,
                                  onError: (_, __) {},
                                );
                              }
                              return SongStageCarousel(
                                key: _carouselKey,
                                currentSong: song,
                                prevSong: prev,
                                nextSong: next,
                                enabled: !_isVinylRotationActive,
                                onDragStateChanged: (v) =>
                                    _isCarouselDragging = v,
                                onNext: _handleCarouselNext,
                                onPrevious: _handleCarouselPrevious,
                                stageBuilder: (s) {
                                  return SongStage(
                                    song: s,
                                    lyricsMode: _isLyricsMode,
                                    visualizationMode: visualizationMode,
                                    immersiveFullView: false,
                                    playerScreenMode: _playerScreenMode,
                                    albumColorMode: colorMode,
                                    albumColor: albumColor,
                                    playerService: _playerService,
                                    lyricsService: _lyricsService,
                                    positionNotifier: _zeroPosition,
                                    formatDuration: formatDuration,
                                    onNavigateToArtistDetail: (s) => _navigation
                                        .openArtistFromSong(context, s),
                                    onNavigateToAlbumDetail: (s) => _navigation
                                        .openAlbumFromSong(context, s),
                                    buildFileInfoRow: fileInfoBuilder,
                                    fileInfoRowVisible: false,
                                    visualizerAnimationStyle: visStyle,
                                    visualizerFrequencyMode: visFreq,
                                    visualizerMovementMode: visMove,
                                    artworkCardArtworkScale:
                                        appPrefs.artworkCardArtworkScale,
                                    artworkCardTextScale:
                                        appPrefs.artworkCardTextScale,
                                    artworkCardVerticalOffset:
                                        appPrefs.artworkCardVerticalOffset,
                                    artworkCardShowTitle:
                                        appPrefs.artworkCardShowTitle,
                                    artworkCardShowArtist:
                                        appPrefs.artworkCardShowArtist,
                                    artworkCardShowAlbum:
                                        appPrefs.artworkCardShowAlbum,
                                    artworkCardShowFileInfo:
                                        appPrefs.artworkCardShowFileInfo,
                                    artworkCardShowFrame:
                                        appPrefs.artworkCardShowFrame,
                                    immersiveTextScale:
                                        appPrefs.immersiveTextScale,
                                    immersiveVerticalOffset:
                                        appPrefs.immersiveVerticalOffset,
                                    immersiveFullViewScale:
                                        appPrefs.immersiveFullViewScale,
                                    immersiveShowTitle:
                                        appPrefs.immersiveShowTitle,
                                    immersiveShowArtist:
                                        appPrefs.immersiveShowArtist,
                                    immersiveShowFileInfo:
                                        appPrefs.immersiveShowFileInfo,
                                    onRotationEnabledChanged: (enabled) {
                                      _isVinylRotationActive = enabled;
                                    },
                                    vinylMode: _isVinylMode,
                                    onVinylChanged: (v) => _isVinylMode = v,
                                    onToggleLyrics: () =>
                                        _setLyricsMode(!_isLyricsMode),
                                    showWaveform: false,
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                    if (showPinnedActionRow)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: pinnedActionRowPadding,
                          ),
                          child: fileInfoBuilder(
                            song,
                            _isLyricsMode,
                            _playerScreenMode,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Pinned waveform — not sliding, lazy-loads current song only.
              // Mirrors the gap SongStage previously had before its waveform.
              Builder(
                builder: (context) {
                  final isImmersive =
                      _playerScreenMode == PlayerScreenMode.immersive;
                  double topGap;
                  if (_isLyricsMode && isImmersive) {
                    topGap = context.responsive(10.0, 12.0, 14.0);
                  } else if (isImmersive) {
                    topGap = context.responsive(12.0, 14.0, 16.0);
                  } else {
                    // artworkCard gap before waveform (playbackSpacing)
                    final isVeryShort = MediaQuery.sizeOf(context).height < 540;
                    topGap = appPrefs.artworkCardShowFileInfo
                        ? (isVeryShort
                              ? 10.0
                              : context.responsive(14.0, 16.0, 18.0))
                        : context.responsive(8.0, 10.0, 12.0);
                  }
                  final timeLabelsPadding = isImmersive
                      ? context.responsive(18.0, 24.0, 30.0)
                      : context.responsive(16.0, 20.0, 24.0);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOut,
                        height: topGap,
                      ),
                      _buildPinnedWaveform(context, song, _playerScreenMode),
                      // Unified default: when lyrics are on, keep single time
                      // labels under waveform for BOTH immersive and artworkCard.
                      // This replaces the duplicated labels previously inside
                      // PlayerControls and (for immersive) inside the strip.
                      // AnimatedSize so the waveform lowers/raises smoothly.
                      AnimatedSize(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOut,
                        alignment: Alignment.topCenter,
                        child: _isLyricsMode
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    height: context.responsive(
                                      8.0,
                                      10.0,
                                      12.0,
                                    ),
                                  ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: timeLabelsPadding,
                                    ),
                                    child: ValueListenableBuilder<Duration>(
                                      valueListenable:
                                          _playerService.positionNotifier,
                                      builder: (context, position, _) {
                                        return ValueListenableBuilder<Duration>(
                                          valueListenable:
                                              _playerService.durationNotifier,
                                          builder: (context, engineDuration, _) {
                                            final duration =
                                                engineDuration.inMilliseconds > 0
                                                ? engineDuration
                                                : (song.duration);
                                            return PlaybackTimeLabels(
                                              position: position,
                                              duration: duration,
                                              formatDuration: formatDuration,
                                              horizontalPadding:
                                                  timeLabelsPadding,
                                            );
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  );
                },
              ),
              // Gap between pinned waveform/time-labels and controls.
              // When lyrics are open we keep only the one under the waveform,
              // so tighten the gap and hide the duplicate inside PlayerControls.
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
                height: _isLyricsMode
                    ? context.responsive(10.0, 12.0, 14.0)
                    : context.responsive(14.0, 16.0, 18.0),
              ),
              // Pinned controls — do not slide. Deduplicate time labels:
              // immersive lyrics keeps strip's labels, artworkCard lyrics keeps
              // the pinned labels just above (under waveform). Hide duplicate
              // inside PlayerControls when lyrics are open.
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: _playerScreenMode == PlayerScreenMode.immersive
                      ? context.responsive(18.0, 24.0, 30.0)
                      : context.responsive(16.0, 20.0, 24.0),
                ),
                child: PlayerControls(
                  playerService: _playerService,
                  formatDuration: formatDuration,
                  currentSong: song,
                  onPrevious: _animateToPreviousSong,
                  onNext: _animateToNextSong,
                  timelineHorizontalPadding:
                      _playerScreenMode == PlayerScreenMode.immersive
                      ? context.responsive(18.0, 24.0, 30.0)
                      : context.responsive(16.0, 20.0, 24.0),
                  albumColorMode: colorMode,
                  albumColor: albumColor,
                  showTimeLabels: !_isLyricsMode,
                ),
              ),
              // Original bottom spacing: immersive 24-40, artworkCard directorySpacing 24-40
              SizedBox(height: context.responsive(24.0, 32.0, 40.0)),
            ],
          ),
        ),
      ],
    );
  }
}
