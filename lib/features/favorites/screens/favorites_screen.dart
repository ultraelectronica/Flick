import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';

/// Favorites screen showing liked songs with heart animations.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final PlayerService _playerService = PlayerService();
  final FavoritesService _favoritesService = FavoritesService();

  List<Song> _favorites = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final favorites = await _favoritesService.getFavorites();
    if (mounted) {
      setState(() {
        _favorites = favorites;
        _isLoading = false;
      });
    }
  }

  Future<void> _removeFavorite(Song song) async {
    // Optimistically remove from UI
    setState(() {
      _favorites.remove(song);
    });

    // Remove from storage
    await _favoritesService.removeFavorite(song.id);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed "${song.title}" from favorites'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              await _favoritesService.addFavorite(song.id);
              setState(() {
                _favorites.add(song);
              });
            },
          ),
        ),
      );
    }
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
                  : _favorites.isEmpty
                  ? _buildEmptyState()
                  : _buildFavoritesList(),
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
                size: 20,
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
                  'Favorites',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                Text(
                  '${_favorites.length} liked songs',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (_favorites.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: AppColors.glassBackground,
                borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: IconButton(
                icon: Icon(
                  LucideIcons.shuffle,
                  color: context.adaptiveTextPrimary,
                  size: 20,
                ),
                onPressed: () {
                  final shuffled = List<Song>.from(_favorites)..shuffle();
                  _playerService.play(shuffled.first, playlist: shuffled);
                },
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
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Animated heart illustration
            _HeartIllustration(),
            const SizedBox(height: AppConstants.spacingXl),
            Text(
              'No Favorites Yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              'Tap the heart icon on any song\nto add it to your favorites',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.adaptiveTextTertiary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoritesList() {
    return ListView.builder(
      padding: EdgeInsets.only(bottom: AppConstants.navBarHeight + 120),
      itemCount: _favorites.length,
      itemBuilder: (context, index) {
        final song = _favorites[index];
        return _FavoriteSongTile(
          song: song,
          onTap: () async {
            await _playerService.play(song, playlist: _favorites);
            if (context.mounted) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      FullPlayerScreen(heroTag: 'favorite_song_${song.id}'),
                ),
              );
            }
          },
          onRemove: () => _removeFavorite(song),
        );
      },
    );
  }
}

class _HeartIllustration extends StatefulWidget {
  @override
  State<_HeartIllustration> createState() => _HeartIllustrationState();
}

class _HeartIllustrationState extends State<_HeartIllustration>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(
      begin: 1.0,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _pulseAnimation.value,
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.glassBackground,
              border: Border.all(color: AppColors.glassBorder, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.2),
                  blurRadius: 20 * _pulseAnimation.value,
                  spreadRadius: 5 * (_pulseAnimation.value - 1),
                ),
              ],
            ),
            child: Icon(
              LucideIcons.heart,
              size: 48,
              color: Colors.red.withValues(alpha: 0.7),
            ),
          ),
        );
      },
    );
  }
}

class _FavoriteSongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FavoriteSongTile({
    required this.song,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key(song.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppConstants.spacingLg),
        color: Colors.red.withValues(alpha: 0.3),
        child: const Icon(LucideIcons.trash2, color: Colors.white),
      ),
      onDismissed: (_) => onRemove(),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppConstants.spacingMd,
          vertical: AppConstants.spacingXs,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: AppConstants.glassBlurSigmaLight,
                  sigmaY: AppConstants.glassBlurSigmaLight,
                ),
                child: Container(
                  padding: const EdgeInsets.all(AppConstants.spacingMd),
                  decoration: BoxDecoration(
                    color: AppColors.glassBackground,
                    borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: Row(
                    children: [
                      // Album art
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: AppColors.glassBackgroundStrong,
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusMd,
                          ),
                        ),
                        child: song.albumArt != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  AppConstants.radiusMd,
                                ),
                                child: Image.file(
                                  File(song.albumArt!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      _buildPlaceholder(context),
                                ),
                              )
                            : _buildPlaceholder(context),
                      ),
                      const SizedBox(width: AppConstants.spacingMd),
                      // Song info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: context.adaptiveTextPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              song.artist,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: context.adaptiveTextTertiary,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      // Heart icon
                      Icon(
                        LucideIcons.heart,
                        color: Colors.red.withValues(alpha: 0.8),
                        size: 20,
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
        LucideIcons.music,
        color: context.adaptiveTextTertiary,
        size: 24,
      ),
    );
  }
}
