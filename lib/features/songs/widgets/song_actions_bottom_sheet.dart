import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Bottom sheet with actions for a song (add to playlist, favorites, view metadata, etc.)
class SongActionsBottomSheet extends ConsumerWidget {
  final Song song;

  const SongActionsBottomSheet({super.key, required this.song});

  /// Show the song actions bottom sheet
  static Future<void> show(BuildContext context, Song song) {
    return GlassBottomSheet.show(
      context: context,
      maxHeightRatio: 0.7,
      content: SongActionsBottomSheet(song: song),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFavorite = ref.watch(isSongFavoriteProvider(song.id));

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppConstants.spacingSm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDragHandle(),
            const SizedBox(height: AppConstants.spacingMd),

            // Song header
            _buildSongHeader(context),
            const SizedBox(height: AppConstants.spacingLg),

            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Quick Actions',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: context.adaptiveTextSecondary,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),

            Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceLight.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Column(
                children: [
                  _buildActionTile(
                    context: context,
                    icon: LucideIcons.heart,
                    iconFilled: isFavorite,
                    label: isFavorite
                        ? 'Remove from Favorites'
                        : 'Add to Favorites',
                    subtitle: isFavorite
                        ? 'This song will be removed from your liked songs'
                        : 'Keep this song in your liked songs',
                    onTap: () async {
                      await ref
                          .read(favoritesProvider.notifier)
                          .toggleFavorite(song.id);
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    },
                  ),
                  _buildActionDivider(),
                  _buildActionTile(
                    context: context,
                    icon: LucideIcons.listPlus,
                    label: 'Add to Playlist',
                    subtitle: 'Choose one of your playlists',
                    onTap: () {
                      Navigator.pop(context);
                      _showAddToPlaylistSheet(context);
                    },
                  ),
                  _buildActionDivider(),
                  _buildActionTile(
                    context: context,
                    icon: LucideIcons.info,
                    label: 'View Metadata',
                    subtitle: 'See format, duration, and file details',
                    onTap: () {
                      Navigator.pop(context);
                      _showMetadataSheet(context);
                    },
                  ),
                  _buildActionDivider(),
                  _buildActionTile(
                    context: context,
                    icon: LucideIcons.folderOpen,
                    label: 'Show in Files',
                    subtitle: 'Show the current file path',
                    onTap: () {
                      Navigator.pop(context);
                      // TODO: Implement show in files functionality
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            song.filePath ?? 'File path not available',
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.glassBorder,
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        ),
      ),
    );
  }

  Widget _buildSongHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfaceLight.withValues(alpha: 0.65),
            AppColors.surface.withValues(alpha: 0.78),
          ],
        ),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            child: SizedBox(
              width: 56,
              height: 56,
              child: song.albumArt != null
                  ? CachedImageWidget(
                      imagePath: song.albumArt!,
                      fit: BoxFit.cover,
                      useThumbnail: true,
                      thumbnailWidth: 112,
                      thumbnailHeight: 112,
                    )
                  : const ColoredBox(
                      color: AppColors.surface,
                      child: Icon(
                        LucideIcons.music,
                        color: AppColors.textTertiary,
                        size: 24,
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextSecondary,
                  ),
                ),
                if (song.album != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    song.album!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    String? subtitle,
    bool iconFilled = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingMd,
            vertical: AppConstants.spacingMd,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(AppConstants.spacingSm),
                decoration: BoxDecoration(
                  color: iconFilled
                      ? AppColors.accent.withValues(alpha: 0.16)
                      : AppColors.surfaceLight.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: iconFilled
                      ? AppColors.accent
                      : context.adaptiveTextSecondary,
                ),
              ),
              const SizedBox(width: AppConstants.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: context.adaptiveTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextSecondary,
                        ),
                      ),
                    ],
                  ],
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

  Widget _buildActionDivider() {
    return Divider(height: 1, thickness: 1, color: AppColors.glassBorderStrong);
  }

  void _showAddToPlaylistSheet(BuildContext context) {
    GlassBottomSheet.show(
      context: context,
      title: 'Add to Playlist',
      maxHeightRatio: 0.6,
      content: Consumer(
        builder: (context, sheetRef, _) {
          final playlistsAsync = sheetRef.watch(playlistsProvider);
          return playlistsAsync.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(AppConstants.spacingXl),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(AppConstants.spacingXl),
              child: Text('Error loading playlists: $error'),
            ),
            data: (state) {
              if (state.playlists.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(AppConstants.spacingXl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.listMusic,
                        size: 48,
                        color: context.adaptiveTextTertiary.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      const SizedBox(height: AppConstants.spacingMd),
                      Text(
                        'No playlists yet',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: context.adaptiveTextSecondary),
                      ),
                      const SizedBox(height: AppConstants.spacingLg),
                      ElevatedButton.icon(
                        onPressed: () {
                          final rootContext = Navigator.of(
                            context,
                            rootNavigator: true,
                          ).context;
                          Navigator.pop(context);
                          _showCreatePlaylistDialog(rootContext);
                        },
                        icon: const Icon(LucideIcons.plus),
                        label: const Text('Create Playlist'),
                      ),
                    ],
                  ),
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Create new playlist option
                  _buildActionTile(
                    context: context,
                    icon: LucideIcons.plus,
                    label: 'Create New Playlist',
                    onTap: () {
                      final rootContext = Navigator.of(
                        context,
                        rootNavigator: true,
                      ).context;
                      Navigator.pop(context);
                      _showCreatePlaylistDialog(rootContext);
                    },
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: AppConstants.spacingSm),

                  // Existing playlists
                  ...state.playlists.map((playlist) {
                    return _buildActionTile(
                      context: context,
                      icon: LucideIcons.listMusic,
                      label: playlist.name,
                      onTap: () async {
                        await sheetRef
                            .read(playlistsProvider.notifier)
                            .addSongToPlaylist(playlist.id, song.id);
                        if (context.mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Added to ${playlist.name}'),
                            ),
                          );
                        }
                      },
                    );
                  }),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final controller = TextEditingController();
    final container = ProviderScope.containerOf(context, listen: false);

    showDialog(
      context: context,
      builder: (dialogContext) {
        Future<void> createAndAddSong(String value) async {
          final playlistName = value.trim();
          if (playlistName.isEmpty) return;

          final playlist = await container
              .read(playlistsProvider.notifier)
              .createPlaylist(playlistName);

          if (playlist == null) {
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(
                  content: Text('A playlist with this name already exists'),
                ),
              );
            }
            return;
          }

          if (!dialogContext.mounted) return;

          await container
              .read(playlistsProvider.notifier)
              .addSongToPlaylist(playlist.id, song.id);

          if (!dialogContext.mounted) return;

          Navigator.pop(dialogContext);
          ScaffoldMessenger.of(dialogContext).showSnackBar(
            SnackBar(content: Text('Created ${playlist.name} and added song')),
          );
        }

        return AlertDialog(
          title: const Text('Create Playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Playlist name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: createAndAddSong,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                await createAndAddSong(controller.text);
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  void _showMetadataSheet(BuildContext context) {
    GlassBottomSheet.show(
      context: context,
      title: 'Song Metadata',
      maxHeightRatio: 0.7,
      content: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppConstants.spacingMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildMetadataRow(context, 'Title', song.title),
            _buildMetadataRow(context, 'Artist', song.artist),
            if (song.album != null)
              _buildMetadataRow(context, 'Album', song.album!),
            if (song.albumArtist != null)
              _buildMetadataRow(context, 'Album Artist', song.albumArtist!),
            _buildMetadataRow(context, 'Duration', song.formattedDuration),
            _buildMetadataRow(context, 'Format', song.fileType.toUpperCase()),
            if (song.resolution != null)
              _buildMetadataRow(context, 'Resolution', song.resolution!),
            if (song.filePath != null)
              _buildMetadataRow(context, 'File Path', song.filePath!),
            if (song.dateAdded != null)
              _buildMetadataRow(
                context,
                'Date Added',
                '${song.dateAdded!.year}-${song.dateAdded!.month.toString().padLeft(2, '0')}-${song.dateAdded!.day.toString().padLeft(2, '0')}',
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AppConstants.spacingSm,
        horizontal: AppConstants.spacingMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.adaptiveTextPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
