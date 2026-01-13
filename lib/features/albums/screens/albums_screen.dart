import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/models/song.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';

/// Albums screen with masonry grid of album artwork.
class AlbumsScreen extends StatefulWidget {
  const AlbumsScreen({super.key});

  @override
  State<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends State<AlbumsScreen> {
  final SongRepository _songRepository = SongRepository();
  final PlayerService _playerService = PlayerService();
  Map<String, List<Song>> _albums = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // Defer data loading to avoid jank during navigation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAlbums();
    });
  }

  Future<void> _loadAlbums() async {
    final albums = await _songRepository.getSongsByAlbum();
    if (mounted) {
      setState(() {
        _albums = albums;
        _isLoading = false;
      });
    }
  }

  String? _getAlbumArt(List<Song> songs) {
    for (final song in songs) {
      if (song.albumArt != null && song.albumArt!.isNotEmpty) {
        return song.albumArt;
      }
    }
    return null;
  }

  void _openAlbumDetail(String albumName, List<Song> songs) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            _AlbumDetailScreen(
          albumName: albumName,
          songs: songs,
          albumArt: _getAlbumArt(songs),
          playerService: _playerService,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // Use SlideTransition for better performance
          const begin = Offset(0.0, 0.05);
          const end = Offset.zero;
          const curve = Curves.easeOutCubic;

          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: curve));

          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
        opaque: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            Expanded(
              child: _isLoading
                  ? _buildLoadingState()
                  : _albums.isEmpty
                  ? _buildEmptyState()
                  : _buildAlbumsGrid(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Row(
        children: [
          // Back button
          Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: IconButton(
              icon: Icon(
                LucideIcons.arrowLeft,
                color: context.adaptiveTextPrimary,
                size: context.responsiveIcon(AppConstants.iconSizeMd),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Albums',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                Text(
                  '${_albums.length} albums',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: CircularProgressIndicator(color: context.adaptiveTextSecondary),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.disc,
            size: context.responsiveIcon(AppConstants.containerSizeLg),
            color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Text(
            'No Albums Found',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: context.adaptiveTextSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Text(
            'Add music with album tags to see them here',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumsGrid() {
    final albumEntries = _albums.entries.toList();

    return GridView.builder(
      padding: EdgeInsets.only(
        left: AppConstants.spacingMd,
        right: AppConstants.spacingMd,
        bottom: AppConstants.navBarHeight + 120,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: context.gridColumns(compact: 2, phone: 2, tablet: 3),
        childAspectRatio: 0.85,
        crossAxisSpacing: AppConstants.spacingMd,
        mainAxisSpacing: AppConstants.spacingMd,
      ),
      itemCount: albumEntries.length,
      itemBuilder: (context, index) {
        final entry = albumEntries[index];
        return _AlbumCard(
          albumName: entry.key,
          songs: entry.value,
          albumArt: _getAlbumArt(entry.value),
          onTap: () => _openAlbumDetail(entry.key, entry.value),
        );
      },
    );
  }
}

class _AlbumCard extends StatefulWidget {
  final String albumName;
  final List<Song> songs;
  final String? albumArt;
  final VoidCallback onTap;

  const _AlbumCard({
    required this.albumName,
    required this.songs,
    required this.albumArt,
    required this.onTap,
  });

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _tiltAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.95,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _tiltAnimation = Tween<double>(
      begin: 0.0,
      end: 0.02,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(
              _scaleAnimation.value,
              _scaleAnimation.value,
              1.0,
            )..rotateZ(_tiltAnimation.value),
            child: child,
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: AppConstants.glassBlurSigmaLight,
              sigmaY: AppConstants.glassBlurSigmaLight,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.glassBackground,
                borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Album art
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.glassBackgroundStrong,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(AppConstants.radiusLg),
                        ),
                      ),
                      child: widget.albumArt != null
                          ? ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(AppConstants.radiusLg),
                              ),
                              child: Image.file(
                                File(widget.albumArt!),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    _buildPlaceholder(context),
                              ),
                            )
                          : _buildPlaceholder(context),
                    ),
                  ),
                  // Album info
                  Padding(
                    padding: const EdgeInsets.all(AppConstants.spacingSm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.albumName,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: context.adaptiveTextPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.songs.length} ${widget.songs.length == 1 ? 'song' : 'songs'}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: context.adaptiveTextTertiary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Center(
      child: Icon(
        LucideIcons.disc,
        size: context.responsiveIcon(AppConstants.containerSizeSm),
        color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
      ),
    );
  }
}

/// Album detail screen showing songs in the album.
class _AlbumDetailScreen extends StatelessWidget {
  final String albumName;
  final List<Song> songs;
  final String? albumArt;
  final PlayerService playerService;

  const _AlbumDetailScreen({
    required this.albumName,
    required this.songs,
    required this.albumArt,
    required this.playerService,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          // Collapsible app bar with album art
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
                  if (albumArt != null)
                    Image.file(
                      File(albumArt!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: AppColors.surface,
                        child: Icon(
                          LucideIcons.disc,
                          size: 80,
                          color: context.adaptiveTextTertiary,
                        ),
                      ),
                    )
                  else
                    Container(
                      color: AppColors.surface,
                      child: Icon(
                        LucideIcons.disc,
                        size: 80,
                        color: context.adaptiveTextTertiary,
                      ),
                    ),
                  // Gradient overlay
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          AppColors.background.withValues(alpha: 0.8),
                          AppColors.background,
                        ],
                      ),
                    ),
                  ),
                  // Album info at bottom
                  Positioned(
                    left: AppConstants.spacingLg,
                    right: AppConstants.spacingLg,
                    bottom: AppConstants.spacingLg,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          albumName,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: context.adaptiveTextPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${songs.length} songs',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: context.adaptiveTextSecondary),
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
                    final shuffled = List<Song>.from(songs)..shuffle();
                    playerService.play(shuffled.first, playlist: shuffled);
                  },
                ),
              ),
            ],
          ),
          // Songs list
          SliverPadding(
            padding: EdgeInsets.only(bottom: AppConstants.navBarHeight + 120),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final song = songs[index];
                return _SongTile(
                  song: song,
                  onTap: () async {
                    await playerService.play(song, playlist: songs);
                    if (context.mounted) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FullPlayerScreen(
                            heroTag: 'album_song_${song.id}',
                          ),
                        ),
                      );
                    }
                  },
                );
              }, childCount: songs.length),
            ),
          ),
        ],
      ),
    );
  }
}

class _SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _SongTile({required this.song, required this.onTap});

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
              // Album art thumbnail
              Container(
                width: context.scaleSize(AppConstants.containerSizeMd),
                height: context.scaleSize(AppConstants.containerSizeMd),
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
                            size: context.responsiveIcon(
                              AppConstants.iconSizeMd,
                            ),
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
              // Song info
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
              // Duration
              Text(
                song.formattedDuration,
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
