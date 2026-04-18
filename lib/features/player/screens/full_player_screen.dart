import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/albums/screens/albums_screen.dart';
import 'package:flick/features/artists/screens/artists_screen.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/models/player_screen_mode.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/player_screen_mode_preference_service.dart';
import 'package:flick/providers/playlist_provider.dart';
import 'package:flick/features/player/widgets/waveform_seek_bar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/widgets/uac2/uac2_error_notification.dart';

class FullPlayerScreen extends StatefulWidget {
  final Object heroTag;
  const FullPlayerScreen({super.key, this.heroTag = 'album_art_hero'});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {
  final PlayerService _playerService = PlayerService();
  final FavoritesService _favoritesService = FavoritesService();
  final LyricsService _lyricsService = LyricsService();
  final PlayerScreenModePreferenceService _playerScreenModePreferenceService =
      PlayerScreenModePreferenceService();
  final SongRepository _songRepository = SongRepository();
  static const String _topBarTextFontFamily = 'ProductSans';
  static const FontWeight _topBarTextFontWeight = FontWeight.w500;

  // Animation controller for drag offset (replaces setState)
  late AnimationController _dragController;

  // Track current drag offset (updated directly, no setState)
  double _dragOffset = 0.0;

  // Last drag update time for throttling
  DateTime _lastDragUpdate = DateTime.now();

  // Notifier for throttled position – only _WaveformLayer listens, so no setState needed.
  late final ValueNotifier<Duration> _throttledPositionNotifier;
  Timer? _positionThrottleTimer;
  String? _cachedTopBarText;
  double? _cachedTopBarFontSize;
  double _cachedTopBarTextWidth = 0;
  bool _isLyricsMode = false;
  int _songTransitionDirection = 1;
  PlayerScreenMode _playerScreenMode = PlayerScreenMode.immersive;

  @override
  void initState() {
    super.initState();

    // Initialize drag animation controller for smooth return animation
    _dragController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      lowerBound: 0.0,
      upperBound: 1000.0, // Max drag distance
    );
    _dragController.value = 0.0;

    // Initialize notifier with current position
    _throttledPositionNotifier = ValueNotifier(
      _playerService.positionNotifier.value,
    );
    // Throttled position tick: only mutates the notifier – never calls setState.
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
    _updateTopBarTextMeasurement(_playerService.currentSongNotifier.value);
    _loadPlayerScreenMode();
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
    _positionThrottleTimer?.cancel();
    _throttledPositionNotifier.dispose();
    _dragController.dispose();
    super.dispose();
  }

  void _handleCurrentSongChanged() {
    if (_playerService.currentSongNotifier.value == null) {
      return;
    }
    _updateTopBarTextMeasurement(_playerService.currentSongNotifier.value);
  }

  Future<void> _loadPlayerScreenMode() async {
    final mode = await _playerScreenModePreferenceService.getMode();
    if (!mounted || _playerScreenMode == mode) return;
    setState(() {
      _playerScreenMode = mode;
    });
  }

  Future<void> _setPlayerScreenMode(PlayerScreenMode mode) async {
    if (_playerScreenMode == mode) return;
    setState(() {
      _playerScreenMode = mode;
    });
    await _playerScreenModePreferenceService.setMode(mode);
  }

  Future<void> _animateToNextSong() async {
    _songTransitionDirection = 1;
    await _playerService.next();
  }

  Future<void> _animateToPreviousSong() async {
    _songTransitionDirection = -1;
    await _playerService.previous();
  }

  void _updateTopBarTextMeasurement(Song? song) {
    if (!mounted || song == null) return;

    final text = '${song.title} - ${song.artist}';
    final fontSize = context.responsiveText(
      context.responsive(13.0, 14.0, 15.0),
    );

    if (_cachedTopBarText == text && _cachedTopBarFontSize == fontSize) {
      return;
    }

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
    _cachedTopBarTextWidth = textPainter.width;
  }

  // For nice time formatting (mm:ss)
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  void _showSpeedBottomSheet(BuildContext context) {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppColors.glassBorder),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  LucideIcons.gauge,
                  color: AppColors.accent,
                  size: 24,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Playback Speed',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ValueListenableBuilder<double>(
              valueListenable: _playerService.playbackSpeedNotifier,
              builder: (context, currentSpeed, _) {
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: speeds.map((speed) {
                    final isSelected = speed == currentSpeed;
                    return GestureDetector(
                      onTap: () {
                        _playerService.setPlaybackSpeed(speed);
                        Navigator.pop(context);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.accent
                              : AppColors.glassBackground,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.accent
                                : AppColors.glassBorder,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          '${speed}x',
                          style: TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 16,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected
                                ? Colors.white
                                : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showSleepTimerBottomSheet(BuildContext context) {
    final timerOptions = [
      (const Duration(minutes: 15), '15 min'),
      (const Duration(minutes: 30), '30 min'),
      (const Duration(minutes: 45), '45 min'),
      (const Duration(hours: 1), '1 hour'),
      (const Duration(hours: 2), '2 hours'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppColors.glassBorder),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(
                      LucideIcons.moonStar,
                      color: AppColors.accent,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Sleep Timer',
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                if (_playerService.isSleepTimerActive)
                  TextButton(
                    onPressed: () {
                      _playerService.cancelSleepTimer();
                      Navigator.pop(context);
                    },
                    child: const Text(
                      'Cancel Timer',
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        color: Colors.redAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<Duration?>(
              valueListenable: _playerService.sleepTimerRemainingNotifier,
              builder: (context, remaining, _) {
                if (remaining != null) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.accent.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            LucideIcons.timer,
                            color: AppColors.accent,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Stopping in ${_formatDuration(remaining)}',
                            style: const TextStyle(
                              fontFamily: 'ProductSans',
                              fontSize: 14,
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: timerOptions.map((option) {
                return GestureDetector(
                  onTap: () {
                    _playerService.setSleepTimer(option.$1);
                    Navigator.pop(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackground,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.glassBorder,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      option.$2,
                      style: const TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 16,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showPlayerLayoutBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppColors.glassBorder),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dashboard_customize_rounded,
                  size: 20,
                  color: sheetContext.adaptiveTextSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  'Player Layout',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: sheetContext.adaptiveTextPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _PlayerLayoutOptionTile(
              title: PlayerScreenMode.immersive.label,
              subtitle: PlayerScreenMode.immersive.description,
              icon: Icons.fit_screen_rounded,
              isSelected: _playerScreenMode == PlayerScreenMode.immersive,
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _setPlayerScreenMode(PlayerScreenMode.immersive);
              },
            ),
            const SizedBox(height: 12),
            _PlayerLayoutOptionTile(
              title: PlayerScreenMode.artworkCard.label,
              subtitle: PlayerScreenMode.artworkCard.description,
              icon: Icons.rounded_corner_rounded,
              isSelected: _playerScreenMode == PlayerScreenMode.artworkCard,
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _setPlayerScreenMode(PlayerScreenMode.artworkCard);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  LucideIcons.listPlus,
                  color: AppColors.accent,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Text(
                  'Add to Playlist',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Consumer(
              builder: (context, ref, _) {
                final playlistsAsync = ref.watch(playlistsProvider);
                return playlistsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Text(
                    'Error loading playlists',
                    style: TextStyle(color: context.adaptiveTextTertiary),
                  ),
                  data: (state) {
                    if (state.playlists.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'No playlists yet.\nCreate one in the Playlists tab.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: context.adaptiveTextTertiary,
                              fontFamily: 'ProductSans',
                            ),
                          ),
                        ),
                      );
                    }
                    return ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.4,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: state.playlists.length,
                        itemBuilder: (context, index) {
                          final playlist = state.playlists[index];
                          final isAlreadyAdded = playlist.songIds.contains(
                            song.id,
                          );
                          return ListTile(
                            leading: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceLight,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                LucideIcons.music,
                                color: context.adaptiveTextSecondary,
                              ),
                            ),
                            title: Text(
                              playlist.name,
                              style: TextStyle(
                                color: context.adaptiveTextPrimary,
                                fontFamily: 'ProductSans',
                              ),
                            ),
                            subtitle: Text(
                              '${playlist.songIds.length} songs',
                              style: TextStyle(
                                color: context.adaptiveTextTertiary,
                                fontFamily: 'ProductSans',
                              ),
                            ),
                            trailing: isAlreadyAdded
                                ? Icon(
                                    LucideIcons.check,
                                    color: AppColors.accent,
                                  )
                                : null,
                            onTap: isAlreadyAdded
                                ? null
                                : () async {
                                    await ref
                                        .read(playlistsProvider.notifier)
                                        .addSongToPlaylist(
                                          playlist.id,
                                          song.id,
                                        );
                                    if (context.mounted) {
                                      Navigator.pop(context);
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Added to "${playlist.name}"',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _queueSong(BuildContext context, Song song) async {
    await _playerService.addToQueue(song);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Queued "${song.title}"'),
        action: SnackBarAction(
          label: 'View queue',
          onPressed: () {
            NavigationHelper.navigateToQueue(context);
          },
        ),
      ),
    );
  }

  Future<void> _openQueue(BuildContext context) async {
    await NavigationHelper.navigateToQueue(context);
  }

  void _showSongActionsBottomSheet(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: AppColors.glassBorder),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.glassBorderStrong,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 68,
                      height: 68,
                      child: CachedImageWidget(
                        imagePath: song.albumArt,
                        audioSourcePath: song.filePath,
                        fit: BoxFit.cover,
                        useThumbnail: true,
                        thumbnailWidth: 136,
                        thumbnailHeight: 136,
                        placeholder: Container(
                          color: AppColors.surfaceLight,
                          child: const Icon(
                            LucideIcons.music,
                            color: AppColors.textTertiary,
                            size: 24,
                          ),
                        ),
                        errorWidget: Container(
                          color: AppColors.surfaceLight,
                          child: const Icon(
                            LucideIcons.music,
                            color: AppColors.textTertiary,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: sheetContext.adaptiveTextPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 14,
                            color: sheetContext.adaptiveTextSecondary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _buildSongInfoChip(
                              sheetContext,
                              song.formattedDuration,
                            ),
                            _buildSongInfoChip(
                              sheetContext,
                              song.fileType.toUpperCase(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildSongActionTile(
                context: sheetContext,
                icon: LucideIcons.listPlus,
                label: 'Add to Queue',
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _queueSong(context, song);
                },
              ),
              _buildSongActionTile(
                context: sheetContext,
                icon: LucideIcons.listMusic,
                label: 'Add to Playlist',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showAddToPlaylistDialog(context, song);
                },
              ),
              _buildSongActionTile(
                context: sheetContext,
                icon: LucideIcons.info,
                label: 'View Metadata',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showSongMetadataBottomSheet(context, song);
                },
              ),
              _buildSongActionTile(
                context: sheetContext,
                icon: LucideIcons.fileText,
                label: 'Lyrics',
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (mounted) {
                    setState(() {
                      _isLyricsMode = true;
                    });
                  }
                },
              ),
              _buildSongActionTile(
                context: sheetContext,
                icon: LucideIcons.user,
                label: 'Go to Artist',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openArtistFromSong(context, song);
                },
              ),
              _buildSongActionTile(
                context: sheetContext,
                icon: LucideIcons.disc,
                label: 'Go to Album',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openAlbumFromSong(context, song);
                },
              ),
              _buildSongActionTile(
                context: sheetContext,
                icon: Icons.dashboard_customize_rounded,
                label: 'Player Layout',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showPlayerLayoutBottomSheet(context);
                },
              ),
              _buildSongActionTile(
                context: sheetContext,
                icon: LucideIcons.gauge,
                label: 'Playback Speed',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showSpeedBottomSheet(context);
                },
              ),
              _buildSongActionTile(
                context: sheetContext,
                icon: LucideIcons.moonStar,
                label: 'Sleep Timer',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showSleepTimerBottomSheet(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSongInfoChip(BuildContext context, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontFamily: 'ProductSans',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.adaptiveTextSecondary,
        ),
      ),
    );
  }

  Widget _buildSongActionTile({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: context.adaptiveTextSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: context.adaptiveTextTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSongMetadataBottomSheet(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppColors.glassBorder),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.info,
                  size: 20,
                  color: sheetContext.adaptiveTextSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  'Song Metadata',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: sheetContext.adaptiveTextPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildMetadataRow(sheetContext, 'Title', song.title),
            _buildMetadataRow(sheetContext, 'Artist', song.artist),
            if (song.album != null)
              _buildMetadataRow(sheetContext, 'Album', song.album!),
            _buildMetadataRow(sheetContext, 'Duration', song.formattedDuration),
            _buildMetadataRow(
              sheetContext,
              'Format',
              song.fileType.toUpperCase(),
            ),
            if (song.resolution != null)
              _buildMetadataRow(sheetContext, 'Resolution', song.resolution!),
            if (song.filePath != null)
              _buildMetadataRow(sheetContext, 'File Path', song.filePath!),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.adaptiveTextSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 13,
                color: context.adaptiveTextPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openArtistFromSong(BuildContext context, Song song) async {
    final artistName = song.artist.trim();
    if (artistName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Artist is not available for this song')),
      );
      return;
    }

    final artistMap = await _songRepository.getSongsByArtist();
    final artistSongs = artistMap[artistName];
    if (!mounted) return;

    if (artistSongs == null || artistSongs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load artist songs')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailScreen(
          artistName: artistName,
          songs: artistSongs,
          artistArt: _firstArt(artistSongs),
          artistArtSourcePath: _firstSourcePath(artistSongs),
          playerService: _playerService,
        ),
      ),
    );
  }

  Future<void> _openAlbumFromSong(BuildContext context, Song song) async {
    final albumGroup = await _songRepository.getAlbumGroupForSong(song);
    if (!mounted) return;

    if (albumGroup == null || albumGroup.songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load album songs')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumDetailScreen(
          albumName: albumGroup.albumName,
          albumArtist: albumGroup.albumArtist,
          songs: albumGroup.songs,
          albumArt: _firstArt(albumGroup.songs),
          albumArtSourcePath: _firstSourcePath(albumGroup.songs),
          playerService: _playerService,
        ),
      ),
    );
  }

  String? _firstArt(List<Song> songs) {
    for (final item in songs) {
      final art = item.albumArt;
      if (art != null && art.isNotEmpty) {
        return art;
      }
    }
    return null;
  }

  String? _firstSourcePath(List<Song> songs) {
    for (final item in songs) {
      final filePath = item.filePath;
      if (filePath != null && filePath.isNotEmpty) {
        return filePath;
      }
    }
    return null;
  }

  Widget _buildFileInfoRow(
    BuildContext context,
    Song song, {
    required bool lyricsMode,
    required PlayerScreenMode playerScreenMode,
  }) {
    final immersiveActions = playerScreenMode == PlayerScreenMode.immersive;
    final actionPadding = immersiveActions
        ? EdgeInsets.all(context.responsive(8.0, 9.0, 10.0))
        : EdgeInsets.all(context.responsive(6.0, 7.0, 8.0));
    final actionRadius = immersiveActions ? 12.0 : 10.0;
    final actionIconSize = context.responsive(18.0, 20.0, 22.0);
    final favoriteIconSize = immersiveActions
        ? context.responsive(18.0, 20.0, 22.0)
        : context.responsive(16.0, 17.0, 18.0);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Tooltip(
          message: lyricsMode ? 'Hide lyrics' : 'Show lyrics',
          child: GestureDetector(
            onTap: () {
              setState(() {
                _isLyricsMode = !lyricsMode;
              });
            },
            child: Container(
              padding: actionPadding,
              decoration: BoxDecoration(
                color: lyricsMode
                    ? AppColors.accent.withValues(alpha: 0.28)
                    : Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(actionRadius),
                border: Border.all(
                  color: lyricsMode
                      ? AppColors.accent.withValues(alpha: 0.45)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Icon(
                lyricsMode
                    ? Icons.keyboard_arrow_down_rounded
                    : LucideIcons.fileText,
                color: Colors.white.withValues(alpha: 0.96),
                size: actionIconSize,
              ),
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.responsive(4.0, 5.0, 6.0),
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                song.fileType,
                style: TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: context.responsive(9.0, 10.0, 11.0),
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            if (song.resolution != null) ...[
              SizedBox(width: context.responsive(5.0, 6.0, 7.0)),
              Text(
                song.resolution!,
                style: TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: context.responsive(9.0, 10.0, 11.0),
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
        FutureBuilder<bool>(
          future: _favoritesService.isFavorite(song.id),
          builder: (context, snapshot) {
            final isFavorite = snapshot.data ?? false;
            return GestureDetector(
              onTap: () async {
                final newState = await _favoritesService.toggleFavorite(
                  song.id,
                );
                setState(() {});
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        newState
                            ? 'Added to favorites'
                            : 'Removed from favorites',
                      ),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }
              },
              child: Container(
                padding: actionPadding,
                decoration: BoxDecoration(
                  color: isFavorite
                      ? Colors.red.withValues(alpha: 0.25)
                      : Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(actionRadius),
                ),
                child: Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: isFavorite
                      ? Colors.red
                      : Colors.white.withValues(alpha: 0.9),
                  size: favoriteIconSize,
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildDirectoryInfo(
    BuildContext context,
    Song song, {
    required bool compact,
  }) {
    if (song.filePath == null) return const SizedBox.shrink();

    String dirText = '';
    final filePath = song.filePath!;
    final parts = filePath.split(RegExp(r'[/\\]'));
    if (parts.length > 1) {
      parts.removeLast();
      final startIndex = parts.length > 2 ? parts.length - 2 : 0;
      final folders = parts.sublist(startIndex);
      dirText = folders.join('/');
    }
    if (dirText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(
        left: context.responsive(12.0, 16.0, 20.0),
        right: context.responsive(12.0, 16.0, 20.0),
        top: compact ? context.responsive(8.0, 10.0, 12.0) : 0,
        bottom: compact ? 0 : context.responsive(16.0, 20.0, 24.0),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.folder,
            size: context.responsive(11.0, 12.0, 13.0),
            color: Colors.white.withValues(alpha: 0.7),
          ),
          SizedBox(width: context.responsive(4.0, 5.0, 6.0)),
          Flexible(
            child: Text(
              dirText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: context.responsive(10.0, 11.0, 12.0),
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: ValueListenableBuilder<Song?>(
          valueListenable: _playerService.currentSongNotifier,
          builder: (context, song, _) {
            if (song == null) {
              // Should usually close the screen if song becomes null or error
              WidgetsBinding.instance.addPostFrameCallback((_) {
                Navigator.of(context).pop();
              });
              return const SizedBox.shrink();
            }

            return GestureDetector(
              onVerticalDragStart: (_) {
                _dragController.stop();
              },
              onVerticalDragUpdate: (details) {
                // Only track downward drag
                if (details.delta.dy > 0) {
                  // Throttle updates to every 16ms (~60fps) to avoid excessive updates
                  final now = DateTime.now();
                  if (now.difference(_lastDragUpdate).inMilliseconds < 16) {
                    return;
                  }
                  _lastDragUpdate = now;

                  // Update drag offset directly (no setState)
                  _dragOffset = (_dragOffset + details.delta.dy).clamp(
                    0.0,
                    1000.0,
                  );
                  // Update controller value for AnimatedBuilder
                  _dragController.value = _dragOffset;
                }
              },
              onVerticalDragEnd: (details) {
                // If dragged down enough or with enough velocity, dismiss
                if (_dragOffset > 100 || details.primaryVelocity! > 500) {
                  Navigator.of(context).pop();
                  return;
                }

                // Animate back to 0
                _dragOffset = 0.0;
                _dragController.animateTo(0.0);
              },
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity! < -500) {
                  // Swipe Left -> Next
                  _animateToNextSong();
                } else if (details.primaryVelocity! > 500) {
                  // Swipe Right -> Previous
                  _animateToPreviousSong();
                }
              },
              child: AnimatedBuilder(
                animation: _dragController,
                builder: (context, child) {
                  // Use Transform.translate during drag (lightweight)
                  // Only use animation when releasing
                  final offset = _dragController.value * 0.5;
                  return Transform.translate(
                    offset: Offset(0, offset),
                    child: child!,
                  );
                },
                child: _AnimatedSongScene(
                  key: ValueKey(song.id),
                  song: song,
                  lyricsMode: _isLyricsMode,
                  playerScreenMode: _playerScreenMode,
                  transitionDirection: _songTransitionDirection,
                  topBarTextFontFamily: _topBarTextFontFamily,
                  topBarTextFontWeight: _topBarTextFontWeight,
                  cachedTopBarTextWidth: _cachedTopBarTextWidth,
                  playerService: _playerService,
                  lyricsService: _lyricsService,
                  throttledPositionNotifier: _throttledPositionNotifier,
                  formatDuration: _formatDuration,
                  onClose: () => Navigator.of(context).pop(),
                  onOpenQueue: () => _openQueue(context),
                  onToggleLyrics: () {
                    setState(() {
                      _isLyricsMode = !_isLyricsMode;
                    });
                  },
                  onQueueSwipe: () => _queueSong(context, song),
                  onShowSongActions: () =>
                      _showSongActionsBottomSheet(context, song),
                  onPrevious: _animateToPreviousSong,
                  onNext: _animateToNextSong,
                  buildFileInfoRow: (song, lyricsMode, mode) =>
                      _buildFileInfoRow(
                        context,
                        song,
                        lyricsMode: lyricsMode,
                        playerScreenMode: mode,
                      ),
                  buildDirectoryInfo: (song) =>
                      _buildDirectoryInfo(context, song, compact: false),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AnimatedSongScene extends StatelessWidget {
  final Song song;
  final bool lyricsMode;
  final PlayerScreenMode playerScreenMode;
  final int transitionDirection;
  final String topBarTextFontFamily;
  final FontWeight topBarTextFontWeight;
  final double cachedTopBarTextWidth;
  final PlayerService playerService;
  final LyricsService lyricsService;
  final ValueNotifier<Duration> throttledPositionNotifier;
  final String Function(Duration) formatDuration;
  final VoidCallback onClose;
  final VoidCallback onOpenQueue;
  final VoidCallback onToggleLyrics;
  final Future<void> Function() onQueueSwipe;
  final VoidCallback onShowSongActions;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Widget Function(Song song, bool lyricsMode, PlayerScreenMode mode)
  buildFileInfoRow;
  final Widget Function(Song song) buildDirectoryInfo;

  const _AnimatedSongScene({
    super.key,
    required this.song,
    required this.lyricsMode,
    required this.playerScreenMode,
    required this.transitionDirection,
    required this.topBarTextFontFamily,
    required this.topBarTextFontWeight,
    required this.cachedTopBarTextWidth,
    required this.playerService,
    required this.lyricsService,
    required this.throttledPositionNotifier,
    required this.formatDuration,
    required this.onClose,
    required this.onOpenQueue,
    required this.onToggleLyrics,
    required this.onQueueSwipe,
    required this.onShowSongActions,
    required this.onPrevious,
    required this.onNext,
    required this.buildFileInfoRow,
    required this.buildDirectoryInfo,
  });

  @override
  Widget build(BuildContext context) {
    final direction = transitionDirection >= 0 ? 1.0 : -1.0;
    final sceneKey = ValueKey('${song.id}_${playerScreenMode.storageValue}');

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren,
            ...?currentChild == null ? null : [currentChild],
          ],
        );
      },
      transitionBuilder: (child, animation) {
        final offsetAnimation = Tween<Offset>(
          begin: Offset(direction * 0.08, 0),
          end: Offset.zero,
        ).animate(animation);
        final outgoingOffsetAnimation = Tween<Offset>(
          begin: Offset.zero,
          end: Offset(-direction * 0.05, 0),
        ).animate(animation);
        final isIncoming = child.key == sceneKey;

        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: isIncoming ? offsetAnimation : outgoingOffsetAnimation,
            child: child,
          ),
        );
      },
      child: RepaintBoundary(
        key: sceneKey,
        child: Stack(
          children: [
            Positioned.fill(child: _buildBackground(context)),
            SafeArea(
              child: Column(
                children: [
                  const Uac2ErrorNotification(),
                  _buildTopChrome(context),
                  SizedBox(height: context.responsive(8.0, 10.0, 12.0)),
                  Expanded(
                    child: playerScreenMode == PlayerScreenMode.artworkCard
                        ? _buildArtworkCardLayout(context)
                        : _buildImmersiveLayout(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackground(BuildContext context) {
    if (playerScreenMode == PlayerScreenMode.artworkCard) {
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
                    child: Icon(
                      LucideIcons.music,
                      size: 120,
                      color: AppColors.textTertiary.withValues(alpha: 0.2),
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
                    const Color(0xFF080808).withValues(alpha: 0.62),
                    const Color(0xFF101010).withValues(alpha: 0.42),
                    const Color(0xFF0A0A0A).withValues(alpha: 0.9),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: CachedImageWidget(
            imagePath: song.albumArt,
            audioSourcePath: song.filePath,
            fit: BoxFit.cover,
            placeholder: Container(
              color: AppColors.background,
              child: Icon(
                LucideIcons.music,
                size: 120,
                color: AppColors.textTertiary.withValues(alpha: 0.3),
              ),
            ),
            errorWidget: Container(
              color: AppColors.background,
              child: Icon(
                LucideIcons.music,
                size: 120,
                color: AppColors.textTertiary.withValues(alpha: 0.3),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  const Color(0xFF121212),
                  const Color(0xFF121212).withValues(alpha: 0.95),
                  const Color(0xFF121212).withValues(alpha: 0.85),
                  const Color(0xFF121212).withValues(alpha: 0.6),
                  const Color(0xFF121212).withValues(alpha: 0.3),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTopChrome(BuildContext context) {
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
            onTap: onClose,
          ),
          SizedBox(width: context.responsive(8.0, 10.0, 12.0)),
          Expanded(
            child: GestureDetector(
              onTap: onOpenQueue,
              onHorizontalDragEnd: (details) async {
                if (details.primaryVelocity != null &&
                    details.primaryVelocity! < -400) {
                  await onQueueSwipe();
                }
              },
              child: ValueListenableBuilder<List<Song>>(
                valueListenable: playerService.queueNotifier,
                builder: (context, queue, _) {
                  final hasQueue = queue.isNotEmpty;
                  final chip = AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: EdgeInsets.symmetric(
                      horizontal: context.responsive(16.0, 18.0, 20.0),
                      vertical: context.responsive(8.0, 9.0, 10.0),
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
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
                          
                          ],
                        ),
                      ],
                    ),
                  );

                  if (playerScreenMode != PlayerScreenMode.immersive) {
                    return chip;
                  }

                  return Align(
                    alignment: Alignment.center,
                    widthFactor: 1.0,
                    child: chip,
                  );
                },
              ),
            ),
          ),
          SizedBox(width: context.responsive(8.0, 10.0, 12.0)),
          _buildChromeButton(
            context,
            icon: Icons.more_vert,
            onTap: onShowSongActions,
          ),
        ],
      ),
    );
  }

  Widget _buildQueueSummaryBadge(
    BuildContext context, {
    required int count,
    required bool highlighted,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
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
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF121212).withValues(alpha: 0.7),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: onTap,
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

  Widget _buildImmersiveLayout(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren,
            ...?currentChild == null ? null : [currentChild],
          ],
        );
      },
      transitionBuilder: (child, animation) {
        final isLyricsChild =
            child.key == const ValueKey('immersive-lyrics-layout');
        final offsetAnimation = Tween<Offset>(
          begin: isLyricsChild ? const Offset(0, -0.04) : const Offset(0, 0.05),
          end: Offset.zero,
        ).animate(animation);

        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offsetAnimation, child: child),
        );
      },
      child: lyricsMode
          ? KeyedSubtree(
              key: const ValueKey('immersive-lyrics-layout'),
              child: Column(
                children: [
                  SizedBox(height: context.responsive(8.0, 10.0, 12.0)),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.responsive(20.0, 28.0, 36.0),
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: _InlineLyricsPanel(
                              song: song,
                              playerService: playerService,
                              lyricsService: lyricsService,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: context.responsive(10.0, 12.0, 14.0)),
                  _LyricsModeWaveformStrip(
                    playerService: playerService,
                    positionNotifier: throttledPositionNotifier,
                    currentSong: song,
                    formatDuration: formatDuration,
                    horizontalPadding: context.responsive(18.0, 24.0, 30.0),
                    onSwipeUp: onToggleLyrics,
                  ),
                ],
              ),
            )
          : KeyedSubtree(
              key: const ValueKey('immersive-default-layout'),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.responsive(12.0, 16.0, 20.0),
                    ),
                    child: _buildImmersiveSongHeader(context),
                  ),
                  SizedBox(height: context.responsive(10.0, 12.0, 14.0)),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.responsive(12.0, 16.0, 20.0),
                    ),
                    child: buildFileInfoRow(song, lyricsMode, playerScreenMode),
                  ),
                  SizedBox(height: context.responsive(12.0, 14.0, 16.0)),
                  _buildPlaybackStack(context),
                  SizedBox(height: context.responsive(16.0, 20.0, 24.0)),
                  buildDirectoryInfo(song),
                ],
              ),
            ),
    );
  }

  Widget _buildImmersiveSongHeader(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: context.responsiveText(
                    context.responsive(22.0, 24.0, 28.0),
                  ),
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.08,
                ),
              ),
              SizedBox(height: context.responsive(10.0, 12.0, 14.0)),
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: context.responsiveText(
                    context.responsive(13.0, 14.0, 16.0),
                  ),
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.82),
                ),
              ),
              SizedBox(height: context.responsive(10.0, 12.0, 14.0)),
            ],
          ),
        ),
        _buildQueueButton(context),
      ],
    );
  }

  Widget _buildQueueButton(BuildContext context) {
    return GestureDetector(
      onTap: onOpenQueue,
      child: Container(
        padding: EdgeInsets.all(context.responsive(8.0, 9.0, 10.0)),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          LucideIcons.listMusic,
          color: Colors.white.withValues(alpha: 0.92),
          size: context.responsive(18.0, 20.0, 22.0),
        ),
      ),
    );
  }

  Widget _buildArtworkCardLayout(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isShortHeight = constraints.maxHeight < 620;
        final isVeryShortHeight = constraints.maxHeight < 540;
        final horizontalPadding = constraints.maxWidth < 360
            ? 16.0
            : context.responsive(20.0, 28.0, 36.0);
        final topPadding = isVeryShortHeight
            ? 6.0
            : context.responsive(10.0, 12.0, 16.0);
        final maxArtworkSize = context.responsive(320.0, 360.0, 400.0);
        final artworkSize = math
            .min(
              constraints.maxWidth - (horizontalPadding * 2),
              isVeryShortHeight
                  ? constraints.maxHeight * 0.34
                  : isShortHeight
                  ? constraints.maxHeight * 0.38
                  : constraints.maxHeight * 0.44,
            )
            .clamp(isVeryShortHeight ? 180.0 : 200.0, maxArtworkSize)
            .toDouble();
        final artworkSpacing = isVeryShortHeight
            ? 14.0
            : isShortHeight
            ? 18.0
            : context.responsive(24.0, 28.0, 32.0);
        final identitySpacing = isVeryShortHeight
            ? 10.0
            : isShortHeight
            ? 14.0
            : context.responsive(20.0, 22.0, 24.0);
        final lyricsSpacing = isVeryShortHeight
            ? 12.0
            : context.responsive(16.0, 18.0, 20.0);
        final playbackSpacing = isVeryShortHeight
            ? 10.0
            : context.responsive(14.0, 16.0, 18.0);
        final directorySpacing = isVeryShortHeight
            ? 8.0
            : isShortHeight
            ? 12.0
            : context.responsive(14.0, 18.0, 22.0);

        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            topPadding,
            horizontalPadding,
            0,
          ),
          child: Column(
            children: [
              if (lyricsMode) ...[
                Expanded(
                  child: _InlineLyricsPanel(
                    song: song,
                    playerService: playerService,
                    lyricsService: lyricsService,
                  ),
                ),
                SizedBox(height: lyricsSpacing),
              ] else
                Expanded(
                  child: Column(
                    mainAxisAlignment: isVeryShortHeight
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.center,
                    children: [
                      Flexible(
                        flex: isVeryShortHeight ? 5 : 7,
                        child: Center(
                          child: _AlbumArtBox(song: song, size: artworkSize),
                        ),
                      ),
                      SizedBox(height: artworkSpacing),
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isVeryShortHeight ? 8.0 : 0.0,
                        ),
                        child: _buildSongIdentity(
                          context,
                          compact: isShortHeight,
                          veryCompact: isVeryShortHeight,
                        ),
                      ),
                      SizedBox(height: identitySpacing),
                    ],
                  ),
                ),
              buildFileInfoRow(song, lyricsMode, playerScreenMode),
              SizedBox(height: playbackSpacing),
              _buildPlaybackStack(context),
              SizedBox(height: directorySpacing),
              buildDirectoryInfo(song),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSongIdentity(
    BuildContext context, {
    bool compact = false,
    bool veryCompact = false,
  }) {
    final titleSize = veryCompact
        ? context.responsive(19.0, 21.0, 24.0)
        : compact
        ? context.responsive(21.0, 24.0, 27.0)
        : context.responsive(24.0, 26.0, 29.0);
    final artistSize = veryCompact
        ? context.responsive(12.0, 13.0, 14.0)
        : compact
        ? context.responsive(13.0, 14.0, 15.0)
        : context.responsive(14.0, 15.0, 16.0);
    final titleToArtistSpacing = veryCompact
        ? 6.0
        : context.responsive(8.0, 9.0, 10.0);
    final artistToAlbumSpacing = veryCompact
        ? 8.0
        : compact
        ? 10.0
        : context.responsive(12.0, 14.0, 16.0);
    final albumHorizontalPadding = veryCompact
        ? 10.0
        : context.responsive(12.0, 14.0, 16.0);
    final albumVerticalPadding = veryCompact
        ? 5.0
        : context.responsive(6.0, 7.0, 8.0);
    final albumFontSize = veryCompact
        ? context.responsive(10.0, 11.0, 12.0)
        : context.responsive(11.0, 12.0, 13.0);

    return Column(
      children: [
        Text(
          song.title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'ProductSans',
            fontSize: context.responsiveText(titleSize),
            fontWeight: FontWeight.w700,
            color: Colors.white,
            height: 1.08,
          ),
        ),
        SizedBox(height: titleToArtistSpacing),
        Text(
          song.artist,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'ProductSans',
            fontSize: context.responsiveText(artistSize),
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.82),
          ),
        ),
        if (song.album != null && song.album!.trim().isNotEmpty) ...[
          SizedBox(height: artistToAlbumSpacing),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: albumHorizontalPadding,
              vertical: albumVerticalPadding,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Text(
              song.album!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: context.responsiveText(albumFontSize),
                color: Colors.white.withValues(alpha: 0.74),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPlaybackStack(BuildContext context) {
    final immersivePlaybackPadding =
        playerScreenMode == PlayerScreenMode.immersive
        ? context.responsive(18.0, 24.0, 30.0)
        : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: immersivePlaybackPadding),
          child: _WaveformLayer(
            playerService: playerService,
            positionNotifier: throttledPositionNotifier,
            currentSong: song,
          ),
        ),
        SizedBox(height: context.responsive(2.0, 3.0, 4.0)),
        _PlayerControls(
          playerService: playerService,
          formatDuration: formatDuration,
          currentSong: song,
          isShuffleNotifier: playerService.isShuffleNotifier,
          onPrevious: onPrevious,
          onNext: onNext,
          timelineHorizontalPadding: immersivePlaybackPadding,
        ),
      ],
    );
  }
}

class _AlbumArtBox extends StatelessWidget {
  final Song song;
  final double? size;

  const _AlbumArtBox({required this.song, this.size});

  @override
  Widget build(BuildContext context) {
    final double resolvedSize = size ?? context.responsive(280.0, 320.0, 360.0);
    final framePadding = resolvedSize < 220 ? 4.0 : 6.0;
    final outerRadius = resolvedSize < 220 ? 26.0 : 32.0;
    final innerRadius = math.max(outerRadius - 6.0, 18.0);
    final iconSize = math.max(52.0, resolvedSize * 0.24);
    final shadowBlur = resolvedSize < 220 ? 24.0 : 30.0;
    final shadowOffsetY = resolvedSize < 220 ? 12.0 : 16.0;

    return Center(
      child: Container(
        width: resolvedSize,
        height: resolvedSize,
        padding: EdgeInsets.all(framePadding),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(outerRadius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.2),
              Colors.white.withValues(alpha: 0.04),
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: shadowBlur,
              offset: Offset(0, shadowOffsetY),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(innerRadius),
          child: CachedImageWidget(
            imagePath: song.albumArt,
            audioSourcePath: song.filePath,
            fit: BoxFit.cover,
            placeholder: Container(
              color: Colors.white.withValues(alpha: 0.08),
              child: Icon(
                LucideIcons.music,
                size: iconSize,
                color: Colors.white.withValues(alpha: 0.68),
              ),
            ),
            errorWidget: Container(
              color: Colors.white.withValues(alpha: 0.08),
              child: Icon(
                LucideIcons.music,
                size: iconSize,
                color: Colors.white.withValues(alpha: 0.68),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerLayoutOptionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _PlayerLayoutOptionTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: isSelected
                ? AppColors.accent.withValues(alpha: 0.14)
                : AppColors.surfaceLight,
            border: Border.all(
              color: isSelected
                  ? AppColors.accent.withValues(alpha: 0.6)
                  : AppColors.glassBorder,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: isSelected
                      ? AppColors.accent
                      : context.adaptiveTextSecondary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: context.adaptiveTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 13,
                        height: 1.4,
                        color: context.adaptiveTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                isSelected ? Icons.radio_button_checked : Icons.circle_outlined,
                color: isSelected
                    ? AppColors.accent
                    : context.adaptiveTextTertiary,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineLyricsPanel extends StatefulWidget {
  final PlayerService playerService;
  final LyricsService lyricsService;
  final Song song;

  const _InlineLyricsPanel({
    required this.playerService,
    required this.lyricsService,
    required this.song,
  });

  @override
  State<_InlineLyricsPanel> createState() => _InlineLyricsPanelState();
}

class _InlineLyricsPanelState extends State<_InlineLyricsPanel> {
  static const double _lineHeight = 92;

  final ScrollController _scrollController = ScrollController();
  LyricsData? _lyricsData;
  bool _isLoading = true;
  int _activeLineIndex = -1;
  int _lastScrolledIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.playerService.positionNotifier.addListener(_onPositionChanged);
    _loadLyricsForSong(widget.song);
  }

  @override
  void didUpdateWidget(covariant _InlineLyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _loadLyricsForSong(widget.song);
    }
  }

  @override
  void dispose() {
    widget.playerService.positionNotifier.removeListener(_onPositionChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onPositionChanged() {
    final data = _lyricsData;
    if (data == null || !data.isSynchronized || data.lines.isEmpty) return;

    final position = widget.playerService.positionNotifier.value;
    final newIndex = widget.lyricsService.findCurrentLineIndex(data, position);
    if (newIndex == _activeLineIndex) return;

    setState(() {
      _activeLineIndex = newIndex;
    });
    _scrollToActiveLine(newIndex);
  }

  Future<void> _loadLyricsForSong(Song song) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _lyricsData = null;
      _activeLineIndex = -1;
      _lastScrolledIndex = -1;
    });

    final loaded = await widget.lyricsService.loadLyricsForSong(song);
    if (!mounted) return;
    if (widget.song.id != song.id) return;

    setState(() {
      _lyricsData = loaded;
      _isLoading = false;
    });

    _onPositionChanged();
  }

  void _scrollToActiveLine(int index) {
    if (!_scrollController.hasClients ||
        index < 0 ||
        index == _lastScrolledIndex) {
      return;
    }

    final viewportHeight = _scrollController.position.viewportDimension;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final target = (index * _lineHeight) - (viewportHeight * 0.35);
    final clampedTarget = target.clamp(0.0, maxScroll);

    _lastScrolledIndex = index;

    final delta = (_scrollController.offset - clampedTarget).abs();
    if (delta < 8) return;

    if (delta < _lineHeight * 0.75) {
      _scrollController.jumpTo(clampedTarget);
      return;
    }

    _scrollController.animateTo(
      clampedTarget,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _seekToLyricLine(int index) async {
    final lyrics = _lyricsData;
    if (lyrics == null || !lyrics.isSynchronized || index < 0) return;

    final target = lyrics.lines[index].timestamp;
    widget.playerService.positionNotifier.value = target;

    if (mounted && _activeLineIndex != index) {
      setState(() {
        _activeLineIndex = index;
      });
    }

    _scrollToActiveLine(index);
    await widget.playerService.seek(target);
  }

  String? _lyricsSourceLabel(String? source) {
    if (source == null || source.isEmpty) return null;
    final normalized = source.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  Widget _buildLyricsMeta(LyricsData lyrics) {
    final sourceLabel = _lyricsSourceLabel(lyrics.source);
    final textColor = Colors.white.withValues(alpha: 0.82);

    Widget chip(IconData icon, String label) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          chip(LucideIcons.fileText, 'Lyrics'),
          chip(
            lyrics.isSynchronized ? LucideIcons.clock3 : Icons.notes_rounded,
            lyrics.isSynchronized ? 'Tap a line to seek' : 'Static lyrics',
          ),
          if (sourceLabel != null) chip(LucideIcons.badgeInfo, sourceLabel),
        ],
      ),
    );
  }

  Widget _buildPlainLyricsView(LyricsData lyrics) {
    return Align(
      alignment: Alignment.center,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        child: Text(
          lyrics.lines.map((line) => line.text).join('\n'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'ProductSans',
            fontSize: 18,
            height: 1.9,
            color: Colors.white.withValues(alpha: 0.92),
          ),
        ),
      ),
    );
  }

  double _lyricOpacityForIndex(int index) {
    if (_activeLineIndex < 0) return 0.72;

    final distance = (index - _activeLineIndex).abs();
    switch (distance) {
      case 0:
        return 1;
      case 1:
        return 0.56;
      case 2:
        return 0.36;
      case 3:
        return 0.24;
      default:
        return 0.18;
    }
  }

  TextStyle _lyricTextStyle(bool isActive, double opacity) {
    return TextStyle(
      fontFamily: 'ProductSans',
      fontSize: isActive ? 22 : 17,
      height: isActive ? 1.18 : 1.24,
      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
      color: Colors.white.withValues(alpha: opacity),
    );
  }

  StrutStyle _lyricStrutStyle(bool isActive) {
    return StrutStyle(
      fontFamily: 'ProductSans',
      fontSize: isActive ? 22 : 17,
      height: isActive ? 1.18 : 1.24,
      forceStrutHeight: true,
    );
  }

  Widget _buildSynchronizedLyricsView(LyricsData lyrics) {
    return Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final centerPadding = constraints.maxHeight * 0.35;
          return ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(10, centerPadding, 10, centerPadding),
            cacheExtent: _lineHeight * 8,
            itemCount: lyrics.lines.length,
            itemExtent: _lineHeight,
            itemBuilder: (context, index) {
              final line = lyrics.lines[index];
              final isActive = index == _activeLineIndex;
              final lineOpacity = _lyricOpacityForIndex(index);

              return RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: () => unawaited(_seekToLyricLine(index)),
                      child: Center(
                        child: isActive
                            ? AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOutCubic,
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(22),
                                  color: Colors.white.withValues(alpha: 0.16),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.22),
                                  ),
                                ),
                                child: Text(
                                  line.text,
                                  maxLines: 2,
                                  overflow: TextOverflow.fade,
                                  textAlign: TextAlign.center,
                                  style: _lyricTextStyle(true, lineOpacity),
                                  strutStyle: _lyricStrutStyle(true),
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Text(
                                  line.text,
                                  maxLines: 2,
                                  overflow: TextOverflow.fade,
                                  textAlign: TextAlign.center,
                                  style: _lyricTextStyle(false, lineOpacity),
                                  strutStyle: _lyricStrutStyle(false),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildBody(context);
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }

    final lyrics = _lyricsData;
    if (lyrics == null || lyrics.lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'No lyrics file found.\nAdd an .lrc or .txt file with the same name as the song.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 14,
              height: 1.5,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildLyricsMeta(lyrics),
        if (lyrics.isSynchronized)
          _buildSynchronizedLyricsView(lyrics)
        else
          Expanded(child: _buildPlainLyricsView(lyrics)),
      ],
    );
  }
}

/// Extracted waveform layer widget.
/// Owns a ValueListenableBuilder on [positionNotifier] so that 50ms position
/// ticks **never** cause the parent [_FullPlayerScreenState] to rebuild.
class _WaveformLayer extends StatefulWidget {
  final PlayerService playerService;
  final ValueNotifier<Duration> positionNotifier;
  final Song? currentSong;

  const _WaveformLayer({
    required this.playerService,
    required this.positionNotifier,
    required this.currentSong,
  });

  @override
  State<_WaveformLayer> createState() => _WaveformLayerState();
}

class _WaveformLayerState extends State<_WaveformLayer> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.playerService.durationNotifier,
      builder: (context, engineDuration, _) {
        final duration = engineDuration.inMilliseconds > 0
            ? engineDuration
            : (widget.currentSong?.duration ?? Duration.zero);

        if (duration.inMilliseconds == 0) {
          return const SizedBox();
        }

        return ValueListenableBuilder<Duration>(
          valueListenable: widget.positionNotifier,
          builder: (context, position, _) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: RepaintBoundary(
                child: WaveformSeekBar(
                  barCount: 60,
                  position: position,
                  duration: duration,
                  onChanged: (newPos) {
                    widget.positionNotifier.value = newPos;
                    unawaited(widget.playerService.seek(newPos));
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Extracted player controls widget to reduce nesting and improve performance
class _PlayerControls extends StatelessWidget {
  final PlayerService playerService;
  final String Function(Duration) formatDuration;
  final Song? currentSong;
  final ValueNotifier<bool> isShuffleNotifier;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final double timelineHorizontalPadding;

  const _PlayerControls({
    required this.playerService,
    required this.formatDuration,
    required this.currentSong,
    required this.isShuffleNotifier,
    required this.onPrevious,
    required this.onNext,
    this.timelineHorizontalPadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playerService.positionNotifier,
        builder: (context, position, _) {
          return ValueListenableBuilder<Duration>(
            valueListenable: playerService.durationNotifier,
            builder: (context, engineDuration, _) {
              // Use engine duration if available, otherwise fallback to song duration
              final duration = engineDuration.inMilliseconds > 0
                  ? engineDuration
                  : (currentSong?.duration ?? Duration.zero);

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PlaybackTimeLabels(
                    position: position,
                    duration: duration,
                    formatDuration: formatDuration,
                    horizontalPadding: timelineHorizontalPadding,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Shuffle
                      ValueListenableBuilder<bool>(
                        valueListenable: isShuffleNotifier,
                        builder: (context, isShuffle, _) {
                          return Container(
                            width: context.responsive(40.0, 44.0, 48.0),
                            height: context.responsive(40.0, 44.0, 48.0),
                            decoration: BoxDecoration(
                              color: isShuffle
                                  ? AppColors.accent.withValues(alpha: 0.25)
                                  : const Color(
                                      0xFF121212,
                                    ).withValues(alpha: 0.6),
                              shape: BoxShape.circle,
                              border: isShuffle
                                  ? Border.all(
                                      color: AppColors.accent.withValues(
                                        alpha: 0.6,
                                      ),
                                      width: 1.5,
                                    )
                                  : null,
                            ),
                            child: IconButton(
                              onPressed: () => playerService.toggleShuffle(),
                              iconSize: context.responsive(18.0, 20.0, 22.0),
                              padding: EdgeInsets.zero,
                              icon: Icon(
                                LucideIcons.shuffle,
                                color: isShuffle
                                    ? AppColors.accent
                                    : Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                          );
                        },
                      ),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Previous
                      Container(
                        width: context.responsive(40.0, 44.0, 48.0),
                        height: context.responsive(40.0, 44.0, 48.0),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212).withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: onPrevious,
                          iconSize: context.responsive(18.0, 20.0, 22.0),
                          padding: EdgeInsets.zero,
                          icon: Icon(LucideIcons.skipBack, color: Colors.white),
                        ),
                      ),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Play/Pause - separate widget to minimize rebuilds
                      _PlayPauseButton(playerService: playerService),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Next
                      Container(
                        width: context.responsive(40.0, 44.0, 48.0),
                        height: context.responsive(40.0, 44.0, 48.0),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212).withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: onNext,
                          iconSize: context.responsive(18.0, 20.0, 22.0),
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            LucideIcons.skipForward,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Repeat/Loop
                      ValueListenableBuilder<LoopMode>(
                        valueListenable: playerService.loopModeNotifier,
                        builder: (context, loopMode, _) {
                          IconData icon = LucideIcons.repeat;
                          Color color = Colors.white.withValues(alpha: 0.7);
                          if (loopMode == LoopMode.all) {
                            color = AppColors.accent;
                          }
                          if (loopMode == LoopMode.one) {
                            icon = LucideIcons.repeat1;
                            color = AppColors.accent;
                          }
                          return Container(
                            width: context.responsive(40.0, 44.0, 48.0),
                            height: context.responsive(40.0, 44.0, 48.0),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF121212,
                              ).withValues(alpha: 0.6),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              onPressed: () => playerService.toggleLoopMode(),
                              iconSize: context.responsive(18.0, 20.0, 22.0),
                              padding: EdgeInsets.zero,
                              icon: Icon(icon, color: color),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _PlaybackTimeRow extends StatelessWidget {
  final PlayerService playerService;
  final String Function(Duration) formatDuration;
  final Song? currentSong;
  final double horizontalPadding;

  const _PlaybackTimeRow({
    required this.playerService,
    required this.formatDuration,
    required this.currentSong,
    this.horizontalPadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: playerService.positionNotifier,
      builder: (context, position, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: playerService.durationNotifier,
          builder: (context, engineDuration, _) {
            final duration = engineDuration.inMilliseconds > 0
                ? engineDuration
                : (currentSong?.duration ?? Duration.zero);

            return _PlaybackTimeLabels(
              position: position,
              duration: duration,
              formatDuration: formatDuration,
              horizontalPadding: horizontalPadding,
            );
          },
        );
      },
    );
  }
}

class _LyricsModeWaveformStrip extends StatefulWidget {
  final PlayerService playerService;
  final ValueNotifier<Duration> positionNotifier;
  final Song? currentSong;
  final String Function(Duration) formatDuration;
  final double horizontalPadding;
  final VoidCallback onSwipeUp;

  const _LyricsModeWaveformStrip({
    required this.playerService,
    required this.positionNotifier,
    required this.currentSong,
    required this.formatDuration,
    required this.horizontalPadding,
    required this.onSwipeUp,
  });

  @override
  State<_LyricsModeWaveformStrip> createState() =>
      _LyricsModeWaveformStripState();
}

class _LyricsModeWaveformStripState extends State<_LyricsModeWaveformStrip> {
  Offset? _pointerDownPosition;
  bool _didTriggerSwipe = false;

  void _resetPointerTracking() {
    _pointerDownPosition = null;
    _didTriggerSwipe = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final start = _pointerDownPosition;
    if (start == null || _didTriggerSwipe) {
      return;
    }

    final delta = event.position - start;
    final isSwipeUp = delta.dy <= -28;
    final isPrimarilyVertical = delta.dy.abs() > (delta.dx.abs() * 1.2);

    if (isSwipeUp && isPrimarilyVertical) {
      _didTriggerSwipe = true;
      widget.onSwipeUp();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _pointerDownPosition = event.position;
        _didTriggerSwipe = false;
      },
      onPointerMove: _handlePointerMove,
      onPointerUp: (_) => _resetPointerTracking(),
      onPointerCancel: (_) => _resetPointerTracking(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.keyboard_double_arrow_up_rounded,
            color: Colors.white.withValues(alpha: 0.72),
            size: context.responsive(18.0, 20.0, 22.0),
          ),
          SizedBox(height: context.responsive(2.0, 4.0, 6.0)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
            child: _WaveformLayer(
              playerService: widget.playerService,
              positionNotifier: widget.positionNotifier,
              currentSong: widget.currentSong,
            ),
          ),
          SizedBox(height: context.responsive(4.0, 6.0, 8.0)),
          _PlaybackTimeRow(
            playerService: widget.playerService,
            formatDuration: widget.formatDuration,
            currentSong: widget.currentSong,
            horizontalPadding: widget.horizontalPadding,
          ),
          SizedBox(height: context.responsive(14.0, 18.0, 22.0)),
        ],
      ),
    );
  }
}

class _PlaybackTimeLabels extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final String Function(Duration) formatDuration;
  final double horizontalPadding;

  const _PlaybackTimeLabels({
    required this.position,
    required this.duration,
    required this.formatDuration,
    this.horizontalPadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            formatDuration(position),
            style: const TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 12,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            formatDuration(duration),
            style: const TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 12,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Extracted play/pause button to minimize rebuilds when only play state changes
class _PlayPauseButton extends StatelessWidget {
  final PlayerService playerService;

  const _PlayPauseButton({required this.playerService});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<bool>(
        valueListenable: playerService.isPlayingNotifier,
        builder: (context, isPlaying, _) {
          final buttonSize = context.responsive(58.0, 64.0, 68.0);
          final iconSize = context.responsive(26.0, 28.0, 30.0);

          return Container(
            width: buttonSize,
            height: buttonSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF121212).withValues(alpha: 0.6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.4),
                  blurRadius: context.responsive(14.0, 18.0, 22.0),
                  offset: Offset(0, context.responsive(5.0, 6.0, 7.0)),
                ),
              ],
            ),
            child: IconButton(
              onPressed: () => playerService.togglePlayPause(),
              iconSize: iconSize,
              padding: EdgeInsets.zero,
              icon: Icon(
                isPlaying ? LucideIcons.pause : LucideIcons.play,
                color: Colors.white,
              ),
            ),
          );
        },
      ),
    );
  }
}
