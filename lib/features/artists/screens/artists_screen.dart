import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';

/// Artists screen with circular avatar cards.
class ArtistsScreen extends StatefulWidget {
  const ArtistsScreen({super.key});

  @override
  State<ArtistsScreen> createState() => _ArtistsScreenState();
}

class _ArtistsScreenState extends State<ArtistsScreen> {
  final SongRepository _songRepository = SongRepository();
  final PlayerService _playerService = PlayerService();
  Map<String, List<Song>> _artists = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadArtists();
  }

  Future<void> _loadArtists() async {
    final artists = await _songRepository.getSongsByArtist();
    if (mounted) {
      setState(() {
        _artists = artists;
        _isLoading = false;
      });
    }
  }

  String? _getArtistArt(List<Song> songs) {
    for (final song in songs) {
      if (song.albumArt != null && song.albumArt!.isNotEmpty) {
        return song.albumArt;
      }
    }
    return null;
  }

  String _getArtistInitials(String name) {
    final words = name.split(' ');
    if (words.length >= 2) {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    } else if (name.isNotEmpty) {
      return name[0].toUpperCase();
    }
    return '?';
  }

  void _openArtistDetail(String artistName, List<Song> songs) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            _ArtistDetailScreen(
              artistName: artistName,
              songs: songs,
              artistArt: _getArtistArt(songs),
              playerService: _playerService,
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
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
                  : _artists.isEmpty
                  ? _buildEmptyState()
                  : _buildArtistsList(),
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
                  'Artists',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                Text(
                  '${_artists.length} artists',
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
            LucideIcons.users,
            size: 64,
            color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Text(
            'No Artists Found',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: context.adaptiveTextSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Text(
            'Add music with artist tags to see them here',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArtistsList() {
    final artistEntries = _artists.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return ListView.builder(
      padding: EdgeInsets.only(bottom: AppConstants.navBarHeight + 120),
      itemCount: artistEntries.length,
      itemBuilder: (context, index) {
        final entry = artistEntries[index];
        return _ArtistCard(
          artistName: entry.key,
          songs: entry.value,
          artistArt: _getArtistArt(entry.value),
          initials: _getArtistInitials(entry.key),
          onTap: () => _openArtistDetail(entry.key, entry.value),
        );
      },
    );
  }
}

class _ArtistCard extends StatelessWidget {
  final String artistName;
  final List<Song> songs;
  final String? artistArt;
  final String initials;
  final VoidCallback onTap;

  const _ArtistCard({
    required this.artistName,
    required this.songs,
    required this.artistArt,
    required this.initials,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final uniqueAlbums = songs.map((s) => s.album ?? 'Unknown').toSet().length;

    return Padding(
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
                    // Circular avatar
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.glassBackgroundStrong,
                        border: Border.all(
                          color: AppColors.glassBorder,
                          width: 2,
                        ),
                      ),
                      child: artistArt != null
                          ? ClipOval(
                              child: Image.file(
                                File(artistArt!),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    _buildInitials(context),
                              ),
                            )
                          : _buildInitials(context),
                    ),
                    const SizedBox(width: AppConstants.spacingMd),
                    // Artist info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            artistName,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: context.adaptiveTextPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${songs.length} songs • $uniqueAlbums albums',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: context.adaptiveTextTertiary),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      LucideIcons.chevronRight,
                      color: context.adaptiveTextTertiary,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInitials(BuildContext context) {
    return Center(
      child: Text(
        initials,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: context.adaptiveTextSecondary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Artist detail screen showing songs by the artist.
class _ArtistDetailScreen extends StatelessWidget {
  final String artistName;
  final List<Song> songs;
  final String? artistArt;
  final PlayerService playerService;

  const _ArtistDetailScreen({
    required this.artistName,
    required this.songs,
    required this.artistArt,
    required this.playerService,
  });

  @override
  Widget build(BuildContext context) {
    // Group songs by album
    final albumGroups = <String, List<Song>>{};
    for (final song in songs) {
      final album = song.album ?? 'Unknown Album';
      albumGroups.putIfAbsent(album, () => []).add(song);
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          // App bar with artist info
          SliverAppBar(
            expandedHeight: 200,
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
                  if (artistArt != null)
                    ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                      child: Image.file(
                        File(artistArt!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            Container(color: AppColors.surface),
                      ),
                    )
                  else
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
                  // Artist info centered
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 40),
                        // Circular avatar
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.glassBackgroundStrong,
                            border: Border.all(
                              color: AppColors.glassBorder,
                              width: 3,
                            ),
                          ),
                          child: artistArt != null
                              ? ClipOval(
                                  child: Image.file(
                                    File(artistArt!),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Icon(
                                      LucideIcons.user,
                                      size: 40,
                                      color: context.adaptiveTextTertiary,
                                    ),
                                  ),
                                )
                              : Icon(
                                  LucideIcons.user,
                                  size: 40,
                                  color: context.adaptiveTextTertiary,
                                ),
                        ),
                        const SizedBox(height: AppConstants.spacingMd),
                        Text(
                          artistName,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: context.adaptiveTextPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${songs.length} songs • ${albumGroups.length} albums',
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
          // Songs grouped by album
          SliverPadding(
            padding: EdgeInsets.only(bottom: AppConstants.navBarHeight + 120),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final albumEntry = albumGroups.entries.toList()[index];
                return _AlbumSection(
                  albumName: albumEntry.key,
                  songs: albumEntry.value,
                  playerService: playerService,
                );
              }, childCount: albumGroups.length),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumSection extends StatelessWidget {
  final String albumName;
  final List<Song> songs;
  final PlayerService playerService;

  const _AlbumSection({
    required this.albumName,
    required this.songs,
    required this.playerService,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingLg,
            vertical: AppConstants.spacingSm,
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.disc,
                size: 16,
                color: context.adaptiveTextTertiary,
              ),
              const SizedBox(width: 8),
              Text(
                albumName,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: context.adaptiveTextSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        ...songs.map(
          (song) => _SongTile(
            song: song,
            onTap: () async {
              await playerService.play(song, playlist: songs);
              if (context.mounted) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        FullPlayerScreen(heroTag: 'artist_song_${song.id}'),
                  ),
                );
              }
            },
          ),
        ),
        const SizedBox(height: AppConstants.spacingMd),
      ],
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
              Container(
                width: 44,
                height: 44,
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
                            size: 18,
                          ),
                        ),
                      )
                    : Icon(
                        LucideIcons.music,
                        color: context.adaptiveTextTertiary,
                        size: 18,
                      ),
              ),
              const SizedBox(width: AppConstants.spacingMd),
              Expanded(
                child: Text(
                  song.title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
