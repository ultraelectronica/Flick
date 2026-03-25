import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Bottom sheet with actions for a song (add to playlist, favorites, view metadata, etc.)
class SongActionsBottomSheet extends ConsumerWidget {
  final Song song;

  const SongActionsBottomSheet({super.key, required this.song});

  /// Show the song actions bottom sheet
  static Future<void> show(BuildContext context, Song song) {
    return showModalBottomSheet(
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
          padding: EdgeInsets.fromLTRB(
            AppConstants.spacingLg,
            AppConstants.spacingSm,
            AppConstants.spacingLg,
            MediaQuery.of(sheetContext).padding.bottom + AppConstants.spacingLg,
          ),
          child: SongActionsBottomSheet(song: song),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFavorite = ref.watch(isSongFavoriteProvider(song.id));

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDragHandle(),
          const SizedBox(height: AppConstants.spacingMd),
          _buildSongHeader(context),
          const SizedBox(height: AppConstants.spacingMd),
          _buildActionTile(
            context: context,
            icon: LucideIcons.heart,
            highlighted: isFavorite,
            label: isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
            onTap: () async {
              await ref
                  .read(favoritesProvider.notifier)
                  .toggleFavorite(song.id);
              if (context.mounted) {
                Navigator.pop(context);
              }
            },
          ),
          _buildActionTile(
            context: context,
            icon: LucideIcons.listPlus,
            label: 'Add to Playlist',
            onTap: () {
              Navigator.pop(context);
              _showAddToPlaylistSheet(context);
            },
          ),
          _buildActionTile(
            context: context,
            icon: LucideIcons.info,
            label: 'View Metadata',
            onTap: () {
              Navigator.pop(context);
              _showMetadataSheet(context);
            },
          ),
          _buildActionTile(
            context: context,
            icon: LucideIcons.folderOpen,
            label: 'Show in Files',
            onTap: () {
              Navigator.pop(context);
              // TODO: Implement show in files functionality
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(song.filePath ?? 'File path not available'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.glassBorderStrong,
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        ),
      ),
    );
  }

  Widget _buildSongHeader(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 68,
            height: 68,
            child: song.albumArt != null
                ? CachedImageWidget(
                    imagePath: song.albumArt!,
                    fit: BoxFit.cover,
                    useThumbnail: true,
                    thumbnailWidth: 136,
                    thumbnailHeight: 136,
                  )
                : const ColoredBox(
                    color: AppColors.surfaceLight,
                    child: Icon(
                      LucideIcons.music,
                      color: AppColors.textTertiary,
                      size: 24,
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
                  color: context.adaptiveTextPrimary,
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
                  color: context.adaptiveTextSecondary,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildInfoChip(context, song.formattedDuration),
                  _buildInfoChip(context, song.fileType.toUpperCase()),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoChip(BuildContext context, String value) {
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

  Widget _buildActionTile({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: highlighted
                      ? AppColors.accent.withValues(alpha: 0.16)
                      : AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: highlighted
                      ? AppColors.accent
                      : context.adaptiveTextSecondary,
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

  void _showAddToPlaylistSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.72;
        final bottomPadding =
            MediaQuery.of(sheetContext).padding.bottom + AppConstants.spacingLg;

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                border: Border.all(color: AppColors.glassBorder),
              ),
              padding: EdgeInsets.fromLTRB(
                AppConstants.spacingLg,
                AppConstants.spacingSm,
                AppConstants.spacingLg,
                bottomPadding,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDragHandle(),
                  const SizedBox(height: AppConstants.spacingMd),
                  Row(
                    children: [
                      Icon(
                        LucideIcons.listPlus,
                        color: sheetContext.adaptiveTextSecondary,
                        size: 20,
                      ),
                      const SizedBox(width: AppConstants.spacingSm),
                      Text(
                        'Add to Playlist',
                        style: TextStyle(
                          fontFamily: 'ProductSans',
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: sheetContext.adaptiveTextPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppConstants.spacingSm),
                  Flexible(
                    fit: FlexFit.loose,
                    child: Consumer(
                      builder: (context, sheetRef, _) {
                        final playlistsAsync = sheetRef.watch(
                          playlistsProvider,
                        );
                        return playlistsAsync.when(
                          loading: () => const Center(
                            child: Padding(
                              padding: EdgeInsets.all(AppConstants.spacingXl),
                              child: CircularProgressIndicator(),
                            ),
                          ),
                          error: (error, _) => Padding(
                            padding: const EdgeInsets.all(
                              AppConstants.spacingXl,
                            ),
                            child: Text('Error loading playlists: $error'),
                          ),
                          data: (state) {
                            if (state.playlists.isEmpty) {
                              return Padding(
                                padding: const EdgeInsets.all(
                                  AppConstants.spacingXl,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      LucideIcons.listMusic,
                                      size: 48,
                                      color: context.adaptiveTextTertiary
                                          .withValues(alpha: 0.5),
                                    ),
                                    const SizedBox(
                                      height: AppConstants.spacingMd,
                                    ),
                                    Text(
                                      'No playlists yet',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color:
                                                context.adaptiveTextSecondary,
                                          ),
                                    ),
                                    const SizedBox(
                                      height: AppConstants.spacingLg,
                                    ),
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

                            return ListView(
                              shrinkWrap: true,
                              children: [
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
                                Divider(
                                  height: 1,
                                  color: AppColors.glassBorderStrong,
                                ),
                                const SizedBox(height: AppConstants.spacingSm),
                                ...state.playlists.map((playlist) {
                                  return _buildActionTile(
                                    context: context,
                                    icon: LucideIcons.listMusic,
                                    label: playlist.name,
                                    onTap: () async {
                                      await sheetRef
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
                                              'Added to ${playlist.name}',
                                            ),
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
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final bottomPadding =
            MediaQuery.of(sheetContext).padding.bottom + AppConstants.spacingLg;
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.72;

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                border: Border.all(color: AppColors.glassBorder),
              ),
              padding: EdgeInsets.fromLTRB(
                AppConstants.spacingLg,
                AppConstants.spacingSm,
                AppConstants.spacingLg,
                bottomPadding,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDragHandle(),
                  const SizedBox(height: AppConstants.spacingMd),
                  Row(
                    children: [
                      Icon(
                        LucideIcons.info,
                        size: 20,
                        color: sheetContext.adaptiveTextSecondary,
                      ),
                      const SizedBox(width: AppConstants.spacingSm),
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
                  const SizedBox(height: AppConstants.spacingSm),
                  Flexible(
                    fit: FlexFit.loose,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildMetadataRow(sheetContext, 'Title', song.title),
                          _buildMetadataRow(
                            sheetContext,
                            'Artist',
                            song.artist,
                          ),
                          if (song.album != null)
                            _buildMetadataRow(
                              sheetContext,
                              'Album',
                              song.album!,
                            ),
                          if (song.albumArtist != null)
                            _buildMetadataRow(
                              sheetContext,
                              'Album Artist',
                              song.albumArtist!,
                            ),
                          _buildMetadataRow(
                            sheetContext,
                            'Duration',
                            song.formattedDuration,
                          ),
                          _buildMetadataRow(
                            sheetContext,
                            'Format',
                            song.fileType.toUpperCase(),
                          ),
                          if (song.resolution != null)
                            _buildMetadataRow(
                              sheetContext,
                              'Resolution',
                              song.resolution!,
                            ),
                          if (song.filePath != null)
                            _buildMetadataRow(
                              sheetContext,
                              'File Path',
                              song.filePath!,
                            ),
                          if (song.dateAdded != null)
                            _buildMetadataRow(
                              sheetContext,
                              'Date Added',
                              '${song.dateAdded!.year}-${song.dateAdded!.month.toString().padLeft(2, '0')}-${song.dateAdded!.day.toString().padLeft(2, '0')}',
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
}
