import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/models/song.dart';
import 'package:flick/models/playlist.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/providers/playlist_provider.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  final PlayerService _playerService = PlayerService();
  final SongRepository _songRepository = SongRepository();
  List<Song> _songs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSongs();
    });
  }

  Playlist get _currentPlaylist {
    return ref.watch(playlistProvider(widget.playlist.id)) ?? widget.playlist;
  }

  Future<void> _loadSongs() async {
    final playlist = _currentPlaylist;
    if (playlist.songIds.isEmpty) {
      if (mounted) {
        setState(() {
          _songs = [];
          _isLoading = false;
        });
      }
      return;
    }

    final allSongs = await _songRepository.getAllSongs();
    final playlistSongs = allSongs
        .where((song) => playlist.songIds.contains(song.id))
        .toList();

    playlistSongs.sort((a, b) {
      final indexA = playlist.songIds.indexOf(a.id);
      final indexB = playlist.songIds.indexOf(b.id);
      return indexA.compareTo(indexB);
    });

    if (mounted) {
      setState(() {
        _songs = playlistSongs;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _currentPlaylist;

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
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: AppColors.surface),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            AppColors.background.withValues(alpha: 0.9),
                            AppColors.background,
                          ],
                        ),
                      ),
                    ),
                    Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 40),
                          _buildPlaylistCover(),
                          const SizedBox(height: AppConstants.spacingMd),
                          Text(
                            playlist.name,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: context.adaptiveTextPrimary,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_songs.length} songs',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: context.adaptiveTextSecondary,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.glassBackground,
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                  ),
                  child: IconButton(
                    icon: Icon(
                      LucideIcons.shuffle,
                      color: context.adaptiveTextPrimary,
                    ),
                    onPressed: () {
                      if (_songs.isNotEmpty) {
                        final shuffled = List<Song>.from(_songs)..shuffle();
                        _playerService.play(shuffled.first, playlist: shuffled);
                      }
                    },
                  ),
                ),
              ],
            ),
            if (_isLoading)
              SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(
                    color: context.adaptiveTextSecondary,
                  ),
                ),
              )
            else if (_songs.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        LucideIcons.music,
                        size: context.responsiveIcon(AppConstants.iconSizeXl),
                        color: context.adaptiveTextTertiary.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      const SizedBox(height: AppConstants.spacingMd),
                      Text(
                        'No songs in this playlist',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: context.adaptiveTextSecondary),
                      ),
                      const SizedBox(height: AppConstants.spacingSm),
                      Text(
                        'Add songs from the player menu',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: AppConstants.navBarHeight + 120,
                ),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final song = _songs[index];
                    return _SongTile(
                      song: song,
                      onTap: () async {
                        await _playerService.play(song, playlist: _songs);
                        if (context.mounted) {
                          await NavigationHelper.navigateToFullPlayer(
                            context,
                            heroTag: 'playlist_song_${song.id}',
                          );
                        }
                      },
                      onRemove: () async {
                        await ref
                            .read(playlistsProvider.notifier)
                            .removeSongFromPlaylist(
                              widget.playlist.id,
                              song.id,
                            );
                        _loadSongs();
                      },
                    );
                  }, childCount: _songs.length),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistCover() {
    return FutureBuilder<List<Song>>(
      future: _getFirstFourSongs(),
      builder: (context, snapshot) {
        final songs = snapshot.data ?? [];
        return Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            border: Border.all(color: AppColors.glassBorder, width: 3),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg - 2),
            child: songs.isEmpty
                ? Container(
                    color: AppColors.surfaceLight,
                    child: Icon(
                      LucideIcons.music,
                      size: 48,
                      color: context.adaptiveTextTertiary,
                    ),
                  )
                : Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            _buildCoverImage(songs, 0),
                            _buildCoverImage(songs, 1),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Row(
                          children: [
                            _buildCoverImage(songs, 2),
                            _buildCoverImage(songs, 3),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildCoverImage(List<Song> songs, int index) {
    if (index < songs.length && songs[index].albumArt != null) {
      return Expanded(
        child: Image.file(
          File(songs[index].albumArt!),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            color: AppColors.surfaceLight,
            child: Icon(
              LucideIcons.music,
              color: context.adaptiveTextTertiary,
              size: 20,
            ),
          ),
        ),
      );
    }
    return Expanded(
      child: Container(
        color: AppColors.surfaceLight,
        child: Icon(
          LucideIcons.music,
          color: context.adaptiveTextTertiary,
          size: 20,
        ),
      ),
    );
  }

  Future<List<Song>> _getFirstFourSongs() async {
    final playlist = _currentPlaylist;
    if (playlist.songIds.isEmpty) return [];

    final allSongs = await _songRepository.getAllSongs();
    final firstFourIds = playlist.songIds.take(4).toList();
    return allSongs.where((song) => firstFourIds.contains(song.id)).toList()
      ..sort((a, b) {
        final indexA = firstFourIds.indexOf(a.id);
        final indexB = firstFourIds.indexOf(b.id);
        return indexA.compareTo(indexB);
      });
  }
}

class _SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _SongTile({
    required this.song,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingLg,
            vertical: AppConstants.spacingSm,
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: song.albumArt != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusSm,
                        ),
                        child: Image.file(
                          File(song.albumArt!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(
                            LucideIcons.music,
                            color: context.adaptiveTextTertiary,
                            size: 20,
                          ),
                        ),
                      )
                    : Icon(
                        LucideIcons.music,
                        color: context.adaptiveTextTertiary,
                        size: 20,
                      ),
              ),
              const SizedBox(width: AppConstants.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: context.adaptiveTextPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artist,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.adaptiveTextTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    song.formattedDuration,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackground,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      song.fileType.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.adaptiveTextTertiary,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                icon: Icon(
                  LucideIcons.ellipsisVertical,
                  color: context.adaptiveTextTertiary,
                  size: context.responsiveIcon(AppConstants.iconSizeSm),
                ),
                color: AppColors.surface,
                onSelected: (value) {
                  if (value == 'remove') {
                    onRemove();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: [
                        Icon(LucideIcons.trash2, color: Colors.red, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Remove from playlist',
                          style: TextStyle(color: Colors.red),
                        ),
                      ],
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
