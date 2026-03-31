import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/models/song.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';

/// Albums screen with masonry grid of album artwork.
class AlbumsScreen extends StatefulWidget {
  const AlbumsScreen({super.key});

  @override
  State<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends State<AlbumsScreen> {
  final SongRepository _songRepository = SongRepository();
  final PlayerService _playerService = PlayerService();
  List<AlbumGroup> _albums = [];
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
    final albums = await _songRepository.getAlbumGroups();
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

  String? _getArtworkSourcePath(List<Song> songs) {
    for (final song in songs) {
      final filePath = song.filePath;
      if (filePath != null && filePath.isNotEmpty) {
        return filePath;
      }
    }
    return null;
  }

  int get _totalTracks =>
      _albums.fold(0, (count, album) => count + album.songs.length);

  void _openAlbumDetail(AlbumGroup album) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            AlbumDetailScreen(
              albumName: album.albumName,
              albumArtist: album.albumArtist,
              songs: album.songs,
              albumArt: _getAlbumArt(album.songs),
              albumArtSourcePath: _getArtworkSourcePath(album.songs),
              playerService: _playerService,
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // Use SlideTransition for better performance
          const begin = Offset(0.0, 0.05);
          const end = Offset.zero;
          const curve = Curves.easeOutCubic;

          final tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));

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
    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            _buildAmbientBackground(),
            SafeArea(
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
          ],
        ),
      ),
    );
  }

  Widget _buildAmbientBackground() {
    return Stack(
      children: [
        Positioned(
          top: -120,
          right: -80,
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.accent.withValues(alpha: 0.16),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 120,
          left: -110,
          child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.surfaceLight.withValues(alpha: 0.22),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppConstants.spacingLg,
        AppConstants.spacingMd,
        AppConstants.spacingLg,
        AppConstants.spacingLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
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
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontWeight: FontWeight.w700,
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
          const SizedBox(height: AppConstants.spacingLg),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppConstants.spacingLg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConstants.radiusXl),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.surfaceLight.withValues(alpha: 0.86),
                  AppColors.surface.withValues(alpha: 0.96),
                ],
              ),
              border: Border.all(color: AppColors.glassBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 22,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your collection at a glance',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppConstants.spacingXs),
                Text(
                  'Browse by artwork, open any album, and jump straight into the tracklist.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextSecondary,
                  ),
                ),
                const SizedBox(height: AppConstants.spacingMd),
                Wrap(
                  spacing: AppConstants.spacingSm,
                  runSpacing: AppConstants.spacingSm,
                  children: [
                    _buildInfoChip(
                      context,
                      icon: LucideIcons.disc3,
                      label: '${_albums.length} albums',
                    ),
                    _buildInfoChip(
                      context,
                      icon: LucideIcons.music4,
                      label: '$_totalTracks tracks',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingMd,
        vertical: AppConstants.spacingSm,
      ),
      decoration: BoxDecoration(
        color: AppColors.glassBackgroundStrong,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.accent),
          const SizedBox(width: AppConstants.spacingXs),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.adaptiveTextPrimary,
              fontWeight: FontWeight.w600,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppConstants.spacingLg,
            0,
            AppConstants.spacingLg,
            AppConstants.spacingMd,
          ),
          child: Text(
            'Collection',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: context.adaptiveTextSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.only(
              left: AppConstants.spacingLg,
              right: AppConstants.spacingLg,
              bottom: AppConstants.navBarHeight + 120,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: context.gridColumns(
                compact: 2,
                phone: 2,
                tablet: 3,
              ),
              childAspectRatio: 0.78,
              crossAxisSpacing: AppConstants.spacingMd,
              mainAxisSpacing: AppConstants.spacingLg,
            ),
            itemCount: _albums.length,
            itemBuilder: (context, index) {
              final album = _albums[index];
              return _AlbumCard(
                albumName: album.albumName,
                albumArtist: album.albumArtist,
                songs: album.songs,
                albumArt: _getAlbumArt(album.songs),
                albumArtSourcePath: _getArtworkSourcePath(album.songs),
                onTap: () => _openAlbumDetail(album),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AlbumCard extends StatefulWidget {
  final String albumName;
  final String albumArtist;
  final List<Song> songs;
  final String? albumArt;
  final String? albumArtSourcePath;
  final VoidCallback onTap;

  const _AlbumCard({
    required this.albumName,
    required this.albumArtist,
    required this.songs,
    required this.albumArt,
    required this.albumArtSourcePath,
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
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final cardWidth = context.scaleSize(AppConstants.cardWidthMd);
    final artworkTargetWidth = (cardWidth * devicePixelRatio).round();
    final artworkTargetHeight = artworkTargetWidth;

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
        child: RepaintBoundary(
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                child: SizedBox(
                  width: cardWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Album art
                      AspectRatio(
                        aspectRatio: 1,
                        child: Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceLight,
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(AppConstants.radiusLg),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 18,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(AppConstants.radiusLg),
                                ),
                                child: CachedImageWidget(
                                  imagePath: widget.albumArt,
                                  audioSourcePath: widget.albumArtSourcePath,
                                  fit: BoxFit.cover,
                                  useThumbnail: true,
                                  thumbnailWidth: artworkTargetWidth,
                                  thumbnailHeight: artworkTargetHeight,
                                  placeholder: _buildPlaceholder(context),
                                  errorWidget: _buildPlaceholder(context),
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
                                        Colors.black.withValues(alpha: 0.1),
                                        Colors.black.withValues(alpha: 0.45),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: AppConstants.spacingSm,
                                bottom: AppConstants.spacingSm,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppConstants.spacingSm,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.12,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    '${widget.songs.length} tracks',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Album info
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppConstants.spacingSm,
                          AppConstants.spacingMd,
                          AppConstants.spacingSm,
                          AppConstants.spacingSm,
                        ),
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
                              widget.albumArtist,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: context.adaptiveTextSecondary,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
class AlbumDetailScreen extends StatelessWidget {
  final String albumName;
  final String albumArtist;
  final List<Song> songs;
  final String? albumArt;
  final String? albumArtSourcePath;
  final PlayerService playerService;

  const AlbumDetailScreen({
    super.key,
    required this.albumName,
    required this.albumArtist,
    required this.songs,
    required this.albumArt,
    required this.albumArtSourcePath,
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
                  CachedImageWidget(
                    imagePath: albumArt,
                    audioSourcePath: albumArtSourcePath,
                    fit: BoxFit.cover,
                    placeholder: Container(
                      color: AppColors.surface,
                      child: Icon(
                        LucideIcons.disc,
                        size: 80,
                        color: context.adaptiveTextTertiary,
                      ),
                    ),
                    errorWidget: Container(
                      color: AppColors.surface,
                      child: Icon(
                        LucideIcons.disc,
                        size: 80,
                        color: context.adaptiveTextTertiary,
                      ),
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
                          '$albumArtist • ${songs.length} songs',
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
                      await NavigationHelper.navigateToFullPlayer(
                        context,
                        heroTag: 'album_song_${song.id}',
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                  child: CachedImageWidget(
                    imagePath: song.albumArt,
                    audioSourcePath: song.filePath,
                    fit: BoxFit.cover,
                    placeholder: Icon(
                      LucideIcons.music,
                      color: context.adaptiveTextTertiary,
                      size: context.responsiveIcon(AppConstants.iconSizeMd),
                    ),
                    errorWidget: Icon(
                      LucideIcons.music,
                      color: context.adaptiveTextTertiary,
                      size: context.responsiveIcon(AppConstants.iconSizeMd),
                    ),
                  ),
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
