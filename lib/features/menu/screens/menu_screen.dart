import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flick/features/albums/screens/albums_screen.dart';
import 'package:flick/features/artists/screens/artists_screen.dart';
import 'package:flick/features/favorites/screens/favorites_screen.dart';
import 'package:flick/features/folders/screens/folders_screen.dart';
import 'package:flick/features/playlists/screens/playlist_detail_screen.dart';
import 'package:flick/features/playlists/screens/playlists_screen.dart';
import 'package:flick/features/queue/screens/queue_screen.dart';
import 'package:flick/features/recap/screens/listening_recap_screen.dart';
import 'package:flick/features/recently_played/screens/recently_played_screen.dart';
import 'package:flick/features/songs/screens/songs_screen.dart';
import 'package:flick/models/playlist.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';

/// Music-home menu screen inspired by streaming app landing pages.
class MenuScreen extends ConsumerStatefulWidget {
  /// Callback to navigate to a specific tab index in the main shell.
  final ValueChanged<int>? onNavigateToTab;

  const MenuScreen({super.key, this.onNavigateToTab});

  @override
  ConsumerState<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends ConsumerState<MenuScreen> {
  final RecentlyPlayedRepository _recentlyPlayedRepository =
      RecentlyPlayedRepository();
  final PlayerService _playerService = PlayerService();

  StreamSubscription<void>? _historySubscription;
  List<RecentlyPlayedEntry> _recentEntries = const [];
  Map<ListeningRecapPeriod, ListeningRecap> _recaps = const {};
  bool _isHistoryLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadHistoryData();
      _watchHistory();
    });
  }

  @override
  void dispose() {
    _historySubscription?.cancel();
    super.dispose();
  }

  void _watchHistory() {
    _historySubscription?.cancel();
    _historySubscription = _recentlyPlayedRepository.watchHistory().listen((_) {
      _loadHistoryData(showLoadingState: false);
    });
  }

  Future<void> _loadHistoryData({bool showLoadingState = true}) async {
    if (showLoadingState && mounted) {
      setState(() {
        _isHistoryLoading = true;
      });
    }

    try {
      final recentEntries = await _recentlyPlayedRepository.getRecentHistory(
        limit: 240,
      );
      final recaps = await _recentlyPlayedRepository.getListeningRecaps(
        periods: const [
          ListeningRecapPeriod.weekly,
          ListeningRecapPeriod.monthly,
          ListeningRecapPeriod.yearly,
        ],
      );

      if (!mounted) return;
      setState(() {
        _recentEntries = recentEntries;
        _recaps = recaps;
        _isHistoryLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recentEntries = const [];
        _recaps = const {};
        _isHistoryLoading = false;
      });
    }
  }

  Future<void> _refreshHome() async {
    ref.invalidate(songsProvider);
    ref.invalidate(favoritesProvider);
    ref.invalidate(playlistsProvider);
    await _loadHistoryData(showLoadingState: false);
  }

  void _navigateTo(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => screen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curvedAnimation = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );

          final slideAnimation = Tween<Offset>(
            begin: const Offset(0.06, 0.0),
            end: Offset.zero,
          ).animate(curvedAnimation);

          return FadeTransition(
            opacity: curvedAnimation,
            child: SlideTransition(position: slideAnimation, child: child),
          );
        },
        transitionDuration: AppConstants.animationNormal,
        reverseTransitionDuration: AppConstants.animationFast,
        opaque: true,
      ),
    );
  }

  Future<void> _playSongs(
    BuildContext context,
    List<Song> songs, {
    Song? initialSong,
    bool shuffle = false,
    required String heroSeed,
  }) async {
    if (songs.isEmpty) return;

    final playlist = List<Song>.from(songs);
    if (shuffle) {
      playlist.shuffle();
    }

    final songToPlay = initialSong ?? playlist.first;
    await _playerService.play(songToPlay, playlist: playlist);

    if (!context.mounted) return;
    await NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: '${heroSeed}_${songToPlay.id}',
    );
  }

  String _greetingForNow() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final songsAsync = ref.watch(songsProvider);
    final favoritesAsync = ref.watch(favoritesProvider);
    final playlistsAsync = ref.watch(playlistsProvider);
    final currentSong = ref.watch(currentSongProvider);

    final allSongs = songsAsync.value?.songs ?? const <Song>[];
    final favoriteSongs = favoritesAsync.value?.favoriteSongs ?? const <Song>[];
    final playlists = playlistsAsync.value?.playlists ?? const <Playlist>[];

    final homeData = _buildHomeData(
      allSongs: allSongs,
      favoriteSongs: favoriteSongs,
      playlists: playlists,
      recentEntries: _recentEntries,
      recaps: _recaps,
    );

    final isInitialLoading =
        allSongs.isEmpty &&
        favoriteSongs.isEmpty &&
        playlists.isEmpty &&
        _recentEntries.isEmpty &&
        (songsAsync.isLoading ||
            favoritesAsync.isLoading ||
            playlistsAsync.isLoading ||
            _isHistoryLoading);

    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            const Positioned.fill(child: _MenuBackdrop()),
            SafeArea(
              bottom: false,
              child: RefreshIndicator(
                onRefresh: _refreshHome,
                color: AppColors.accent,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    SliverToBoxAdapter(
                      child: _buildHeader(
                        context,
                        songCount: allSongs.length,
                        favoriteCount: favoriteSongs.length,
                        playlistCount: playlists.length,
                      ),
                    ),
                    if (isInitialLoading)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: _MenuLoadingState(),
                      )
                    else ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppConstants.spacingLg,
                            0,
                            AppConstants.spacingLg,
                            AppConstants.spacingMd,
                          ),
                          child: _buildHeroCard(
                            context,
                            currentSong: currentSong,
                            favoriteSongs: favoriteSongs,
                            recentEntries: _recentEntries,
                            homeData: homeData,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppConstants.spacingLg,
                            0,
                            AppConstants.spacingLg,
                            AppConstants.spacingLg,
                          ),
                          child: _buildQuickAccessGrid(
                            context,
                            homeData: homeData,
                            favoritesCount: favoriteSongs.length,
                            playlistCount: playlists.length,
                          ),
                        ),
                      ),
                      if (homeData.smartMixes.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            context,
                            title: 'Made For You',
                            subtitle:
                                'Generated from your listening habits, favorites, and newest additions.',
                            child: SizedBox(
                              height: 222,
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppConstants.spacingLg,
                                ),
                                scrollDirection: Axis.horizontal,
                                itemCount: homeData.smartMixes.length,
                                separatorBuilder: (_, _) => const SizedBox(
                                  width: AppConstants.spacingMd,
                                ),
                                itemBuilder: (context, index) {
                                  final mix = homeData.smartMixes[index];
                                  return _SmartMixCard(
                                    mix: mix,
                                    onTap: mix.songs.isEmpty
                                        ? null
                                        : () {
                                            _navigateTo(
                                              context,
                                              _SmartMixDetailScreen(mix: mix),
                                            );
                                          },
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      if (homeData.recentArtists.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            context,
                            title: 'Artists In Rotation',
                            subtitle:
                                'The names showing up again and again in your recent queue.',
                            child: SizedBox(
                              height: 172,
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppConstants.spacingLg,
                                ),
                                scrollDirection: Axis.horizontal,
                                itemCount: homeData.recentArtists.length,
                                separatorBuilder: (_, _) => const SizedBox(
                                  width: AppConstants.spacingMd,
                                ),
                                itemBuilder: (context, index) {
                                  final artist = homeData.recentArtists[index];
                                  return _ArtistShelfCard(
                                    artist: artist,
                                    onTap: () {
                                      _navigateTo(
                                        context,
                                        ArtistDetailScreen(
                                          artistName: artist.name,
                                          songs: artist.songs,
                                          artistArt: artist.artPath,
                                          playerService: _playerService,
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      if (homeData.recentTracks.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            context,
                            title: 'Recently Played',
                            subtitle:
                                'Pick up exactly where your last sessions left off.',
                            trailing: TextButton(
                              onPressed: () => _navigateTo(
                                context,
                                const RecentlyPlayedScreen(),
                              ),
                              child: const Text('See all'),
                            ),
                            child: SizedBox(
                              height: 212,
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppConstants.spacingLg,
                                ),
                                scrollDirection: Axis.horizontal,
                                itemCount: homeData.recentTracks.length,
                                separatorBuilder: (_, _) => const SizedBox(
                                  width: AppConstants.spacingMd,
                                ),
                                itemBuilder: (context, index) {
                                  final song = homeData.recentTracks[index];
                                  return _RecentTrackCard(
                                    song: song,
                                    onTap: () => _playSongs(
                                      context,
                                      homeData.recentTracks,
                                      initialSong: song,
                                      heroSeed: 'menu_recent',
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: _buildSection(
                          context,
                          title: 'Your Playlists',
                          subtitle: playlists.isEmpty
                              ? 'Create your first playlist or jump into your saved collections.'
                              : 'Saved playlists and quick jumps into your library organization.',
                          trailing: TextButton(
                            onPressed: () =>
                                _navigateTo(context, const PlaylistsScreen()),
                            child: Text(
                              playlists.isEmpty ? 'Create' : 'See all',
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppConstants.spacingLg,
                            ),
                            child: playlists.isEmpty
                                ? _EmptyShelfCard(
                                    title: 'No playlists yet',
                                    subtitle:
                                        'Create a playlist, import an M3U, or let the mixes above carry the session.',
                                    icon: LucideIcons.listMusic,
                                    onTap: () => _navigateTo(
                                      context,
                                      const PlaylistsScreen(),
                                    ),
                                  )
                                : SizedBox(
                                    height: 236,
                                    child: ListView.separated(
                                      scrollDirection: Axis.horizontal,
                                      itemCount:
                                          homeData.playlistPreviews.length,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(
                                            width: AppConstants.spacingMd,
                                          ),
                                      itemBuilder: (context, index) {
                                        final preview =
                                            homeData.playlistPreviews[index];
                                        return _PlaylistPreviewCard(
                                          preview: preview,
                                          onTap: () => _navigateTo(
                                            context,
                                            PlaylistDetailScreen(
                                              playlist: preview.playlist,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _buildSection(
                          context,
                          title: 'Browse More',
                          subtitle:
                              'Library views and utilities that still belong close to the music.',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppConstants.spacingLg,
                            ),
                            child: Wrap(
                              spacing: AppConstants.spacingSm,
                              runSpacing: AppConstants.spacingSm,
                              children: [
                                _BrowseChip(
                                  icon: LucideIcons.library,
                                  label: 'Library',
                                  onTap: () {
                                    if (widget.onNavigateToTab != null) {
                                      widget.onNavigateToTab!(1);
                                    } else {
                                      _navigateTo(context, const SongsScreen());
                                    }
                                  },
                                ),
                                _BrowseChip(
                                  icon: LucideIcons.disc,
                                  label: 'Albums',
                                  onTap: () => _navigateTo(
                                    context,
                                    const AlbumsScreen(),
                                  ),
                                ),
                                _BrowseChip(
                                  icon: LucideIcons.folder,
                                  label: 'Folders',
                                  onTap: () => _navigateTo(
                                    context,
                                    const FoldersScreen(),
                                  ),
                                ),
                                _BrowseChip(
                                  icon: LucideIcons.list,
                                  label: 'Queue',
                                  onTap: () =>
                                      _navigateTo(context, const QueueScreen()),
                                ),
                                _BrowseChip(
                                  icon: Icons.auto_graph_rounded,
                                  label: 'Flick Replay',
                                  onTap: () => _navigateTo(
                                    context,
                                    const ListeningRecapScreen(),
                                  ),
                                ),
                                _BrowseChip(
                                  icon: LucideIcons.users,
                                  label: 'Artists',
                                  onTap: () => _navigateTo(
                                    context,
                                    const ArtistsScreen(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(
                        child: SizedBox(
                          height: AppConstants.navBarHeight + 136,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context, {
    required int songCount,
    required int favoriteCount,
    required int playlistCount,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppConstants.spacingLg,
        AppConstants.spacingMd,
        AppConstants.spacingLg,
        AppConstants.spacingLg,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greetingForNow(),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: context.adaptiveTextPrimary,
                    height: 0.94,
                  ),
                ),
                const SizedBox(height: AppConstants.spacingXs),
                Text(
                  '$songCount tracks, $favoriteCount liked songs, $playlistCount playlists',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong,
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: IconButton(
              onPressed: _refreshHome,
              icon: Icon(
                LucideIcons.refreshCcw,
                color: context.adaptiveTextPrimary,
                size: context.responsiveIcon(AppConstants.iconSizeMd),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(
    BuildContext context, {
    required Song? currentSong,
    required List<Song> favoriteSongs,
    required List<RecentlyPlayedEntry> recentEntries,
    required _MenuHomeData homeData,
  }) {
    final featuredSong =
        currentSong ??
        recentEntries.firstOrNull?.song ??
        favoriteSongs.firstOrNull ??
        homeData.recentTracks.firstOrNull;
    final hasNowPlaying = currentSong != null;

    final title = hasNowPlaying
        ? 'Now Playing'
        : featuredSong != null
        ? 'Jump Back In'
        : 'Start Building Your Home';
    final subtitle = hasNowPlaying
        ? 'Keep the session moving or head straight back to the player.'
        : featuredSong != null
        ? 'Resume a familiar favorite or shuffle one of the mixes made from your listening.'
        : 'Play a few songs and this page will start filling with mixes, artists, and shortcuts.';

    final primaryLabel = hasNowPlaying
        ? 'Open Player'
        : featuredSong != null
        ? 'Play Again'
        : 'Open Library';

    final secondaryLabel = favoriteSongs.isNotEmpty
        ? 'Shuffle Favorites'
        : null;

    Future<void> handlePrimaryTap() async {
      if (hasNowPlaying && featuredSong != null) {
        await NavigationHelper.navigateToFullPlayer(
          context,
          heroTag: 'menu_now_playing_${featuredSong.id}',
        );
        return;
      }

      if (featuredSong != null) {
        await _playSongs(
          context,
          homeData.recentTracks.isNotEmpty
              ? homeData.recentTracks
              : [featuredSong],
          initialSong: featuredSong,
          heroSeed: 'menu_hero',
        );
        return;
      }

      if (widget.onNavigateToTab != null) {
        widget.onNavigateToTab!(1);
      } else {
        _navigateTo(context, const SongsScreen());
      }
    }

    final featureTile = _HeroFeatureTile(
      song: featuredSong,
      eyebrow: hasNowPlaying
          ? 'Streaming from queue'
          : featuredSong != null
          ? 'Last pick'
          : 'No playback yet',
    );

    final primaryButton = _HeroActionButton(
      label: primaryLabel,
      icon: hasNowPlaying ? LucideIcons.audioLines : LucideIcons.play,
      isPrimary: true,
      onTap: handlePrimaryTap,
    );

    final secondaryButton = secondaryLabel == null
        ? null
        : _HeroActionButton(
            label: secondaryLabel,
            icon: LucideIcons.shuffle,
            onTap: () => _playSongs(
              context,
              favoriteSongs,
              shuffle: true,
              heroSeed: 'menu_favorites',
            ),
          );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF194B68), Color(0xFF0C1624), Color(0xFF1D2A19)],
          stops: [0.0, 0.56, 1.0],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF08111B).withValues(alpha: 0.42),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            top: -34,
            right: -22,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF61B8FF).withValues(alpha: 0.18),
              ),
            ),
          ),
          Positioned(
            bottom: -56,
            left: -22,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF9CDD7C).withValues(alpha: 0.12),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppConstants.spacingLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppConstants.spacingXs),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.78),
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: AppConstants.spacingLg),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompactHero = constraints.maxWidth < 520;

                    if (isCompactHero) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          featureTile,
                          const SizedBox(height: AppConstants.spacingMd),
                          Wrap(
                            spacing: AppConstants.spacingSm,
                            runSpacing: AppConstants.spacingSm,
                            children: [
                              primaryButton,
                              if (secondaryButton != null) secondaryButton,
                            ],
                          ),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: featureTile),
                        const SizedBox(width: AppConstants.spacingMd),
                        Column(
                          children: [
                            primaryButton,
                            if (secondaryButton != null) ...[
                              const SizedBox(height: AppConstants.spacingSm),
                              secondaryButton,
                            ],
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAccessGrid(
    BuildContext context, {
    required _MenuHomeData homeData,
    required int favoritesCount,
    required int playlistCount,
  }) {
    final cards = [
      _QuickAccessItem(
        title: 'Favorite Songs',
        subtitle: favoritesCount == 0
            ? 'Liked songs live here'
            : '$favoritesCount tracks ready to revisit',
        icon: LucideIcons.heart,
        gradient: const [Color(0xFF4B153D), Color(0xFF862A62)],
        artPath: homeData.favoriteArtPath,
        onTap: () => _navigateTo(context, const FavoritesScreen()),
      ),
      _QuickAccessItem(
        title: 'Recently Played',
        subtitle: homeData.recentTracks.isEmpty
            ? 'Your session history'
            : '${homeData.recentTracks.length} recent picks on hand',
        icon: LucideIcons.clock3,
        gradient: const [Color(0xFF133858), Color(0xFF175F80)],
        artPath: homeData.recentTracks.firstOrNull?.albumArt,
        onTap: () => _navigateTo(context, const RecentlyPlayedScreen()),
      ),
      _QuickAccessItem(
        title: 'Artists',
        subtitle: homeData.recentArtists.isEmpty
            ? 'Browse your artist library'
            : '${homeData.recentArtists.first.name} and more in rotation',
        icon: LucideIcons.users,
        gradient: const [Color(0xFF1E4223), Color(0xFF416A2A)],
        artPath: homeData.recentArtists.firstOrNull?.artPath,
        onTap: () => _navigateTo(context, const ArtistsScreen()),
      ),
      _QuickAccessItem(
        title: 'Playlists',
        subtitle: playlistCount == 0
            ? 'Create a collection'
            : '$playlistCount saved collections',
        icon: LucideIcons.listMusic,
        gradient: const [Color(0xFF533116), Color(0xFF875214)],
        artPath: homeData.playlistPreviews.firstOrNull?.coverArtPath,
        onTap: () => _navigateTo(context, const PlaylistsScreen()),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 760 ? 4 : 2;
        final spacing = AppConstants.spacingSm;
        final width =
            (constraints.maxWidth - (spacing * (columns - 1))) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final card in cards)
              SizedBox(
                width: width,
                child: _QuickAccessCard(item: card),
              ),
          ],
        );
      },
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required String subtitle,
    required Widget child,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppConstants.spacingXl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppConstants.spacingLg,
              0,
              AppConstants.spacingLg,
              AppConstants.spacingMd,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: context.adaptiveTextPrimary,
                            ),
                      ),
                      const SizedBox(height: AppConstants.spacingXxs),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppConstants.spacingSm),
                  trailing,
                ],
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }

  _MenuHomeData _buildHomeData({
    required List<Song> allSongs,
    required List<Song> favoriteSongs,
    required List<Playlist> playlists,
    required List<RecentlyPlayedEntry> recentEntries,
    required Map<ListeningRecapPeriod, ListeningRecap> recaps,
  }) {
    final songById = {for (final song in allSongs) song.id: song};
    final songsByArtist = <String, List<Song>>{};

    for (final song in allSongs) {
      final artist = _normalizeArtist(song.artist);
      songsByArtist.putIfAbsent(artist, () => []).add(song);
    }

    final recentTracks = _dedupeSongs(
      recentEntries.map((entry) => entry.song),
    ).take(12).toList();

    final recentArtists = _buildRecentArtists(
      recentEntries: recentEntries,
      songsByArtist: songsByArtist,
    );

    final smartMixes = _buildSmartMixes(
      allSongs: allSongs,
      favoriteSongs: favoriteSongs,
      recentEntries: recentEntries,
      recaps: recaps,
      songById: songById,
    );

    final playlistPreviews = _buildPlaylistPreviews(
      playlists: playlists,
      songById: songById,
    );

    return _MenuHomeData(
      recentTracks: recentTracks,
      recentArtists: recentArtists,
      smartMixes: smartMixes,
      playlistPreviews: playlistPreviews,
      favoriteArtPath: favoriteSongs.firstOrNull?.albumArt,
    );
  }

  List<_ArtistSpotlight> _buildRecentArtists({
    required List<RecentlyPlayedEntry> recentEntries,
    required Map<String, List<Song>> songsByArtist,
  }) {
    final stats = <String, _ArtistSpotlightAccumulator>{};

    for (final entry in recentEntries.take(120)) {
      final artist = _normalizeArtist(entry.song.artist);
      stats
          .putIfAbsent(artist, () => _ArtistSpotlightAccumulator(name: artist))
          .add(entry.song);
    }

    final items =
        stats.values.map((accumulator) {
          final songs = songsByArtist[accumulator.name] ?? const <Song>[];
          return _ArtistSpotlight(
            name: accumulator.name,
            plays: accumulator.plays,
            uniqueSongs: accumulator.uniqueSongIds.length,
            artPath: accumulator.artPath,
            songs: songs,
          );
        }).toList()..sort((left, right) {
          final playCompare = right.plays.compareTo(left.plays);
          if (playCompare != 0) return playCompare;
          return left.name.compareTo(right.name);
        });

    return items.where((artist) => artist.songs.isNotEmpty).take(8).toList();
  }

  List<_SmartMix> _buildSmartMixes({
    required List<Song> allSongs,
    required List<Song> favoriteSongs,
    required List<RecentlyPlayedEntry> recentEntries,
    required Map<ListeningRecapPeriod, ListeningRecap> recaps,
    required Map<String, Song> songById,
  }) {
    final recentPlayCount = <String, int>{};
    final recentLastPlayedAt = <String, DateTime>{};
    final olderEntries = <RecentlyPlayedEntry>[];
    final afterHoursEntries = <RecentlyPlayedEntry>[];
    final rewindCutoff = DateTime.now().subtract(const Duration(days: 21));

    for (final entry in recentEntries) {
      recentPlayCount.update(
        entry.song.id,
        (count) => count + 1,
        ifAbsent: () {
          return 1;
        },
      );

      final previous = recentLastPlayedAt[entry.song.id];
      if (previous == null || entry.playedAt.isAfter(previous)) {
        recentLastPlayedAt[entry.song.id] = entry.playedAt;
      }

      if (entry.playedAt.isBefore(rewindCutoff)) {
        olderEntries.add(entry);
      }
      if (_isAfterHours(entry.playedAt)) {
        afterHoursEntries.add(entry);
      }
    }

    final recentRankedSongs = recentPlayCount.entries.toList()
      ..sort((left, right) {
        final playCompare = right.value.compareTo(left.value);
        if (playCompare != 0) return playCompare;

        final leftPlayed = recentLastPlayedAt[left.key];
        final rightPlayed = recentLastPlayedAt[right.key];
        if (leftPlayed != null && rightPlayed != null) {
          return rightPlayed.compareTo(leftPlayed);
        }

        return left.key.compareTo(right.key);
      });

    final rankedRecentSongs = recentRankedSongs
        .map((entry) => songById[entry.key])
        .whereType<Song>()
        .toList();

    final monthlyTop =
        recaps[ListeningRecapPeriod.monthly]?.topSongs
            .map((item) => item.song)
            .toList() ??
        const <Song>[];
    final weeklyTop =
        recaps[ListeningRecapPeriod.weekly]?.topSongs
            .map((item) => item.song)
            .toList() ??
        const <Song>[];
    final yearlyTop =
        recaps[ListeningRecapPeriod.yearly]?.topSongs
            .map((item) => item.song)
            .toList() ??
        const <Song>[];

    final onRepeatSongs = _takeDistinctSongs([
      ...monthlyTop,
      ...weeklyTop,
      ...rankedRecentSongs,
    ], 20);

    final currentRepeatIds = {
      for (final song in onRepeatSongs) song.id,
      for (final song in monthlyTop) song.id,
    };

    final rewindSongs = _takeDistinctSongs([
      ..._rankSongsFromEntries(olderEntries),
      ...yearlyTop.where((song) => !currentRepeatIds.contains(song.id)),
    ], 20);

    final favoritesByMomentum = List<Song>.from(favoriteSongs)
      ..sort((left, right) {
        final countCompare = (recentPlayCount[right.id] ?? 0).compareTo(
          recentPlayCount[left.id] ?? 0,
        );
        if (countCompare != 0) return countCompare;

        final leftPlayed = recentLastPlayedAt[left.id];
        final rightPlayed = recentLastPlayedAt[right.id];
        if (leftPlayed != null && rightPlayed != null) {
          return rightPlayed.compareTo(leftPlayed);
        }

        return left.title.compareTo(right.title);
      });

    final heavyRotationSongs = _takeDistinctSongs([
      ...favoritesByMomentum,
      ...weeklyTop,
      ...rankedRecentSongs,
    ], 20);

    final freshSongs = List<Song>.from(allSongs)
      ..sort((left, right) {
        final leftDate =
            left.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
        final rightDate =
            right.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
        return rightDate.compareTo(leftDate);
      });

    final freshAdditionsSongs = _takeDistinctSongs(
      freshSongs.where((song) => !currentRepeatIds.contains(song.id)).toList(),
      20,
    );

    final afterHoursSongs = _takeDistinctSongs([
      ..._rankSongsFromEntries(afterHoursEntries),
      ...heavyRotationSongs.where((song) => song.duration.inMinutes >= 3),
    ], 20);

    final mixes = <_SmartMix>[
      _SmartMix(
        title: 'On Repeat',
        subtitle: 'Your heaviest rotation right now',
        description: 'The tracks dominating your weekly and monthly recap.',
        icon: LucideIcons.repeat,
        colors: const [Color(0xFF5B1FA6), Color(0xFFB33EF5)],
        songs: onRepeatSongs,
      ),
      _SmartMix(
        title: 'Repeat Rewind',
        subtitle: 'Favorites you have not revisited lately',
        description:
            'Earlier standouts pulled back into view from your listening history.',
        icon: LucideIcons.history,
        colors: const [Color(0xFF15466A), Color(0xFF3BA6D6)],
        songs: rewindSongs,
      ),
      _SmartMix(
        title: 'Heavy Rotation',
        subtitle: 'Likes and replays blended together',
        description:
            'A tighter mix of favorites and the songs you keep circling back to.',
        icon: LucideIcons.radio,
        colors: const [Color(0xFF194F36), Color(0xFF66C56A)],
        songs: heavyRotationSongs,
      ),
      _SmartMix(
        title: 'Fresh Additions',
        subtitle: 'Latest arrivals from your library',
        description: 'Recently added tracks waiting for more play time.',
        icon: LucideIcons.sparkles,
        colors: const [Color(0xFF845114), Color(0xFFE1A53D)],
        songs: freshAdditionsSongs,
      ),
      _SmartMix(
        title: 'After Hours',
        subtitle: 'Pulled from your late-session plays',
        description:
            'Tracks that fit the quieter side of your listening habits.',
        icon: LucideIcons.moonStar,
        colors: const [Color(0xFF172145), Color(0xFF5561D6)],
        songs: afterHoursSongs,
      ),
    ];

    return mixes.where((mix) => mix.songs.isNotEmpty).toList();
  }

  List<_PlaylistPreview> _buildPlaylistPreviews({
    required List<Playlist> playlists,
    required Map<String, Song> songById,
  }) {
    final sortedPlaylists = List<Playlist>.from(playlists)
      ..sort((left, right) {
        final leftUpdated = left.updatedAt ?? left.createdAt;
        final rightUpdated = right.updatedAt ?? right.createdAt;
        return rightUpdated.compareTo(leftUpdated);
      });

    return sortedPlaylists.take(8).map((playlist) {
      final songs = playlist.songIds
          .map((songId) => songById[songId])
          .whereType<Song>()
          .toList();

      return _PlaylistPreview(
        playlist: playlist,
        coverArtPath: songs.firstOrNull?.albumArt,
        coverArtPaths: songs
            .map((song) => song.albumArt)
            .whereType<String>()
            .where((path) => path.isNotEmpty)
            .toSet()
            .take(4)
            .toList(),
        subtitle: _buildPlaylistSubtitle(songs),
        songCount: songs.length,
        updatedAt: playlist.updatedAt ?? playlist.createdAt,
      );
    }).toList();
  }

  String _buildPlaylistSubtitle(List<Song> songs) {
    final uniqueArtists = songs
        .map((song) => _normalizeArtist(song.artist))
        .toSet()
        .take(2)
        .toList();

    if (uniqueArtists.isEmpty) {
      return 'Personal playlist';
    }
    if (uniqueArtists.length == 1) {
      return uniqueArtists.first;
    }
    return '${uniqueArtists.first} + ${uniqueArtists.length - 1} more';
  }

  String _normalizeArtist(String rawArtist) {
    final trimmed = rawArtist.trim();
    return trimmed.isEmpty ? 'Unknown Artist' : trimmed;
  }

  List<Song> _dedupeSongs(Iterable<Song> songs) {
    final seenIds = <String>{};
    final unique = <Song>[];

    for (final song in songs) {
      if (seenIds.add(song.id)) {
        unique.add(song);
      }
    }

    return unique;
  }

  List<Song> _takeDistinctSongs(List<Song> songs, int limit) {
    return _dedupeSongs(songs).take(limit).toList();
  }

  List<Song> _rankSongsFromEntries(List<RecentlyPlayedEntry> entries) {
    final countBySongId = <String, int>{};
    final lastPlayedAt = <String, DateTime>{};
    final songById = <String, Song>{};

    for (final entry in entries) {
      countBySongId.update(
        entry.song.id,
        (count) => count + 1,
        ifAbsent: () {
          return 1;
        },
      );

      final previous = lastPlayedAt[entry.song.id];
      if (previous == null || entry.playedAt.isAfter(previous)) {
        lastPlayedAt[entry.song.id] = entry.playedAt;
      }
      songById[entry.song.id] = entry.song;
    }

    final ranked = countBySongId.entries.toList()
      ..sort((left, right) {
        final playCompare = right.value.compareTo(left.value);
        if (playCompare != 0) return playCompare;

        final leftPlayed = lastPlayedAt[left.key];
        final rightPlayed = lastPlayedAt[right.key];
        if (leftPlayed != null && rightPlayed != null) {
          return rightPlayed.compareTo(leftPlayed);
        }

        return left.key.compareTo(right.key);
      });

    return ranked
        .map((entry) => songById[entry.key])
        .whereType<Song>()
        .toList();
  }

  bool _isAfterHours(DateTime playedAt) {
    final hour = playedAt.hour;
    return hour >= 21 || hour <= 4;
  }
}

class _MenuBackdrop extends StatelessWidget {
  const _MenuBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF08111A), Color(0xFF111820), Color(0xFF16110E)],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -110,
            left: -70,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF227FAF).withValues(alpha: 0.18),
              ),
            ),
          ),
          Positioned(
            top: 180,
            right: -54,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFBF7C21).withValues(alpha: 0.12),
              ),
            ),
          ),
          Positioned(
            bottom: -90,
            left: 40,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF347A41).withValues(alpha: 0.11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuLoadingState extends StatelessWidget {
  const _MenuLoadingState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingLg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.glassBackgroundStrong,
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.6,
                color: AppColors.accent,
              ),
            ),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Text(
            'Building your music home',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: context.adaptiveTextPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppConstants.spacingXs),
          Text(
            'Loading favorites, recent sessions, generated mixes, and playlists.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextTertiary,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroFeatureTile extends StatelessWidget {
  final Song? song;
  final String eyebrow;

  const _HeroFeatureTile({required this.song, required this.eyebrow});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: 74,
              height: 74,
              child: song?.albumArt != null
                  ? CachedImageWidget(
                      imagePath: song!.albumArt!,
                      fit: BoxFit.cover,
                      useThumbnail: true,
                      thumbnailWidth: 160,
                      thumbnailHeight: 160,
                    )
                  : Container(
                      color: Colors.white.withValues(alpha: 0.06),
                      child: Icon(
                        LucideIcons.music4,
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.7),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: AppConstants.spacingXxs),
                Text(
                  song?.title ?? 'No featured track yet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppConstants.spacingXxs),
                Text(
                  song?.artist ?? 'Start playing to populate this space',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isPrimary;
  final VoidCallback onTap;

  const _HeroActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingMd,
            vertical: AppConstants.spacingSm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: isPrimary
                ? Colors.white
                : Colors.white.withValues(alpha: 0.09),
            border: Border.all(
              color: isPrimary
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.14),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: isPrimary ? AppColors.background : Colors.white,
              ),
              const SizedBox(width: AppConstants.spacingXs),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: isPrimary ? AppColors.background : Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAccessItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> gradient;
  final String? artPath;
  final VoidCallback onTap;

  const _QuickAccessItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.artPath,
    required this.onTap,
  });
}

class _QuickAccessCard extends StatelessWidget {
  final _QuickAccessItem item;

  const _QuickAccessCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          height: 132,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: item.gradient,
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            boxShadow: [
              BoxShadow(
                color: item.gradient.last.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Stack(
            children: [
              if (item.artPath != null)
                Positioned(
                  right: -10,
                  bottom: -14,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: SizedBox(
                      width: 82,
                      height: 82,
                      child: CachedImageWidget(
                        imagePath: item.artPath!,
                        fit: BoxFit.cover,
                        useThumbnail: true,
                        thumbnailWidth: 180,
                        thumbnailHeight: 180,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(AppConstants.spacingMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(item.icon, color: Colors.white, size: 18),
                    ),
                    const Spacer(),
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppConstants.spacingXxs),
                    Text(
                      item.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.76),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmartMixCard extends StatelessWidget {
  final _SmartMix mix;
  final VoidCallback? onTap;

  const _SmartMixCard({required this.mix, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Ink(
          width: 184,
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: mix.colors,
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(mix.icon, color: Colors.white, size: 20),
                  ),
                  const Spacer(),
                  Icon(
                    LucideIcons.chevronRight,
                    color: Colors.white.withValues(alpha: 0.72),
                    size: 18,
                  ),
                ],
              ),
              const Spacer(),
              Text(
                mix.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppConstants.spacingXxs),
              Text(
                mix.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${mix.songs.length} songs',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                  if (mix.coverArtPath != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 42,
                        height: 42,
                        child: CachedImageWidget(
                          imagePath: mix.coverArtPath!,
                          fit: BoxFit.cover,
                          useThumbnail: true,
                          thumbnailWidth: 120,
                          thumbnailHeight: 120,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistShelfCard extends StatelessWidget {
  final _ArtistSpotlight artist;
  final VoidCallback onTap;

  const _ArtistShelfCard({required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          width: 138,
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Column(
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: ClipOval(
                  child: artist.artPath != null
                      ? CachedImageWidget(
                          imagePath: artist.artPath!,
                          fit: BoxFit.cover,
                          useThumbnail: true,
                          thumbnailWidth: 180,
                          thumbnailHeight: 180,
                        )
                      : Container(
                          color: AppColors.glassBackgroundStrong,
                          child: Icon(
                            LucideIcons.user,
                            color: context.adaptiveTextSecondary,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppConstants.spacingXxs),
              Text(
                '${artist.plays} plays',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.adaptiveTextTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentTrackCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _RecentTrackCard({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          width: 152,
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: double.infinity,
                  height: 108,
                  child: song.albumArt != null
                      ? CachedImageWidget(
                          imagePath: song.albumArt!,
                          fit: BoxFit.cover,
                          useThumbnail: true,
                          thumbnailWidth: 240,
                          thumbnailHeight: 240,
                        )
                      : Container(
                          color: AppColors.glassBackgroundStrong,
                          child: Icon(
                            LucideIcons.music4,
                            color: context.adaptiveTextSecondary,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppConstants.spacingXxs),
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.adaptiveTextTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistPreviewCard extends StatelessWidget {
  final _PlaylistPreview preview;
  final VoidCallback onTap;

  const _PlaylistPreviewCard({required this.preview, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Ink(
          width: 188,
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: AppColors.glassBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  _PlaylistArtworkGrid(preview: preview),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.38),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                      child: const Icon(
                        LucideIcons.play,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Text(
                preview.playlist.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: AppConstants.spacingXxs),
              Text(
                preview.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.adaptiveTextTertiary,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppConstants.spacingXs,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackgroundStrong,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.glassBorder),
                    ),
                    child: Text(
                      '${preview.songCount} songs',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.adaptiveTextSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    preview.relativeUpdatedLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistArtworkGrid extends StatelessWidget {
  final _PlaylistPreview preview;

  const _PlaylistArtworkGrid({required this.preview});

  @override
  Widget build(BuildContext context) {
    final artPaths = preview.coverArtPaths;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: double.infinity,
        height: 136,
        child: artPaths.isEmpty
            ? Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF26313A), Color(0xFF141B20)],
                  ),
                ),
                child: Center(
                  child: Icon(
                    LucideIcons.listMusic,
                    color: context.adaptiveTextSecondary,
                    size: 28,
                  ),
                ),
              )
            : artPaths.length == 1
            ? CachedImageWidget(
                imagePath: artPaths.first,
                fit: BoxFit.cover,
                useThumbnail: true,
                thumbnailWidth: 260,
                thumbnailHeight: 260,
              )
            : GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                itemCount: artPaths.length.clamp(0, 4),
                itemBuilder: (context, index) {
                  return CachedImageWidget(
                    imagePath: artPaths[index],
                    fit: BoxFit.cover,
                    useThumbnail: true,
                    thumbnailWidth: 140,
                    thumbnailHeight: 140,
                  );
                },
              ),
      ),
    );
  }
}

class _EmptyShelfCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _EmptyShelfCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(AppConstants.spacingLg),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.glassBackgroundStrong,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: context.adaptiveTextPrimary, size: 22),
              ),
              const SizedBox(width: AppConstants.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: context.adaptiveTextPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppConstants.spacingXxs),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.adaptiveTextTertiary,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                color: context.adaptiveTextTertiary,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrowseChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _BrowseChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingMd,
            vertical: AppConstants.spacingSm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: AppColors.glassBackgroundStrong,
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: context.adaptiveTextSecondary),
              const SizedBox(width: AppConstants.spacingXs),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmartMixDetailScreen extends StatelessWidget {
  final _SmartMix mix;

  const _SmartMixDetailScreen({required this.mix});

  Future<void> _playSongs(
    BuildContext context, {
    required List<Song> songs,
    Song? initialSong,
    bool shuffle = false,
  }) async {
    if (songs.isEmpty) return;

    final playerService = PlayerService();
    final playlist = List<Song>.from(songs);
    if (shuffle) {
      playlist.shuffle();
    }

    final songToPlay = initialSong ?? playlist.first;
    await playerService.play(songToPlay, playlist: playlist);

    if (!context.mounted) return;
    await NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'menu_mix_detail_${mix.title}_${songToPlay.id}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              backgroundColor: AppColors.surface,
              leading: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                ),
                child: IconButton(
                  icon: Icon(
                    LucideIcons.arrowLeft,
                    color: context.adaptiveTextPrimary,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              flexibleSpace: FlexibleSpaceBar(
                background: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: mix.colors,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        top: -26,
                        right: -18,
                        child: Container(
                          width: 160,
                          height: 160,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.12),
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
                                Colors.transparent,
                                AppColors.background.withValues(alpha: 0.4),
                                AppColors.background.withValues(alpha: 0.88),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppConstants.spacingLg,
                          92,
                          AppConstants.spacingLg,
                          AppConstants.spacingLg,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: Icon(
                                mix.icon,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                            const SizedBox(height: AppConstants.spacingMd),
                            Text(
                              mix.title,
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(height: AppConstants.spacingXxs),
                            Text(
                              mix.description,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    height: 1.45,
                                  ),
                            ),
                            const SizedBox(height: AppConstants.spacingMd),
                            Row(
                              children: [
                                _InlineActionButton(
                                  label: 'Play',
                                  icon: LucideIcons.play,
                                  isPrimary: true,
                                  onTap: () =>
                                      _playSongs(context, songs: mix.songs),
                                ),
                                const SizedBox(width: AppConstants.spacingSm),
                                _InlineActionButton(
                                  label: 'Shuffle',
                                  icon: LucideIcons.shuffle,
                                  onTap: () => _playSongs(
                                    context,
                                    songs: mix.songs,
                                    shuffle: true,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppConstants.spacingLg,
                  AppConstants.spacingMd,
                  AppConstants.spacingLg,
                  AppConstants.spacingSm,
                ),
                child: Text(
                  '${mix.songs.length} songs generated from your library and listening history',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.only(
                left: AppConstants.spacingLg,
                right: AppConstants.spacingLg,
                bottom: AppConstants.navBarHeight + 128,
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final song = mix.songs[index];
                  return Padding(
                    padding: const EdgeInsets.only(
                      bottom: AppConstants.spacingSm,
                    ),
                    child: Material(
                      color: AppColors.surface.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(20),
                      child: InkWell(
                        onTap: () => _playSongs(
                          context,
                          songs: mix.songs,
                          initialSong: song,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.all(AppConstants.spacingMd),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: SizedBox(
                                  width: 60,
                                  height: 60,
                                  child: song.albumArt != null
                                      ? CachedImageWidget(
                                          imagePath: song.albumArt!,
                                          fit: BoxFit.cover,
                                          useThumbnail: true,
                                          thumbnailWidth: 140,
                                          thumbnailHeight: 140,
                                        )
                                      : Container(
                                          color:
                                              AppColors.glassBackgroundStrong,
                                          child: Icon(
                                            LucideIcons.music4,
                                            color:
                                                context.adaptiveTextSecondary,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(width: AppConstants.spacingMd),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: context.adaptiveTextPrimary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(
                                      height: AppConstants.spacingXxs,
                                    ),
                                    Text(
                                      '${song.artist} • ${song.fileType.toUpperCase()}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: context.adaptiveTextTertiary,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: AppConstants.spacingSm),
                              Icon(
                                LucideIcons.play,
                                color: context.adaptiveTextTertiary,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }, childCount: mix.songs.length),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isPrimary;
  final VoidCallback onTap;

  const _InlineActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingMd,
            vertical: AppConstants.spacingSm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: isPrimary
                ? Colors.white
                : Colors.white.withValues(alpha: 0.1),
            border: Border.all(
              color: isPrimary
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.14),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: isPrimary ? AppColors.background : Colors.white,
              ),
              const SizedBox(width: AppConstants.spacingXs),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: isPrimary ? AppColors.background : Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuHomeData {
  final List<Song> recentTracks;
  final List<_ArtistSpotlight> recentArtists;
  final List<_SmartMix> smartMixes;
  final List<_PlaylistPreview> playlistPreviews;
  final String? favoriteArtPath;

  const _MenuHomeData({
    required this.recentTracks,
    required this.recentArtists,
    required this.smartMixes,
    required this.playlistPreviews,
    required this.favoriteArtPath,
  });
}

class _ArtistSpotlight {
  final String name;
  final int plays;
  final int uniqueSongs;
  final String? artPath;
  final List<Song> songs;

  const _ArtistSpotlight({
    required this.name,
    required this.plays,
    required this.uniqueSongs,
    required this.artPath,
    required this.songs,
  });
}

class _ArtistSpotlightAccumulator {
  final String name;
  final Set<String> uniqueSongIds = <String>{};
  int plays = 0;
  String? artPath;

  _ArtistSpotlightAccumulator({required this.name});

  void add(Song song) {
    plays += 1;
    uniqueSongIds.add(song.id);
    artPath ??= song.albumArt;
  }
}

class _SmartMix {
  final String title;
  final String subtitle;
  final String description;
  final IconData icon;
  final List<Color> colors;
  final List<Song> songs;

  const _SmartMix({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.icon,
    required this.colors,
    required this.songs,
  });

  String? get coverArtPath => songs.firstOrNull?.albumArt;
}

class _PlaylistPreview {
  final Playlist playlist;
  final String? coverArtPath;
  final List<String> coverArtPaths;
  final String subtitle;
  final int songCount;
  final DateTime updatedAt;

  const _PlaylistPreview({
    required this.playlist,
    required this.coverArtPath,
    required this.coverArtPaths,
    required this.subtitle,
    required this.songCount,
    required this.updatedAt,
  });

  String get relativeUpdatedLabel {
    final now = DateTime.now();
    final difference = now.difference(updatedAt);

    if (difference.inDays <= 0) {
      return 'Today';
    }
    if (difference.inDays == 1) {
      return 'Yesterday';
    }
    if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    }
    if (difference.inDays < 30) {
      return '${(difference.inDays / 7).floor()}w ago';
    }
    if (difference.inDays < 365) {
      return '${(difference.inDays / 30).floor()}mo ago';
    }
    return '${(difference.inDays / 365).floor()}y ago';
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
