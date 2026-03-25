import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/providers/playlist_provider.dart';
import 'package:flick/features/playlists/screens/playlist_detail_screen.dart';

class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context, ref),
            Expanded(
              child: playlistsAsync.when(
                loading: () => _buildLoadingState(context),
                error: (e, _) => _buildErrorState(context, e.toString()),
                data: (state) => state.playlists.isEmpty
                    ? _buildEmptyState(context)
                    : _buildPlaylistsList(context, ref, state.playlists),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _buildCreateButton(context, ref),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref) {
    final count = ref.watch(playlistsCountProvider);

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
                  'Playlists',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                Text(
                  count == 0
                      ? 'Your custom collections'
                      : '$count playlist${count == 1 ? '' : 's'}',
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

  Widget _buildLoadingState(BuildContext context) {
    return Center(
      child: CircularProgressIndicator(color: context.adaptiveTextSecondary),
    );
  }

  Widget _buildErrorState(BuildContext context, String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.info,
              size: context.responsiveIcon(AppConstants.iconSizeXl),
              color: context.adaptiveTextTertiary,
            ),
            const SizedBox(height: AppConstants.spacingMd),
            Text(
              'Error loading playlists',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: context.adaptiveTextSecondary,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              error,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.adaptiveTextTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: 120,
              width: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    top: 20,
                    child: Transform.rotate(
                      angle: 0.1,
                      child: _buildIllustrationCard(
                        context,
                        AppColors.glassBackground.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    child: Transform.rotate(
                      angle: -0.05,
                      child: _buildIllustrationCard(
                        context,
                        AppColors.glassBackground.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  _buildIllustrationCard(context, AppColors.glassBackground),
                ],
              ),
            ),
            const SizedBox(height: AppConstants.spacingXl),
            Text(
              'No Playlists Yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              'Create your first playlist to organize\nyour favorite songs',
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

  Widget _buildIllustrationCard(BuildContext context, Color color) {
    return Container(
      width: 100,
      height: 80,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.surfaceDark),
      ),
      child: Center(
        child: Icon(
          LucideIcons.listMusic,
          color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
          size: context.responsiveIcon(AppConstants.iconSizeXl),
        ),
      ),
    );
  }

  Widget _buildPlaylistsList(
    BuildContext context,
    WidgetRef ref,
    List playlists,
  ) {
    return ListView.builder(
      padding: EdgeInsets.only(bottom: AppConstants.navBarHeight + 120),
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        return _PlaylistCard(
          playlist: playlist,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => PlaylistDetailScreen(playlist: playlist),
              ),
            );
          },
          onDelete: () async {
            final confirm = await _showDeleteDialog(context, ref);
            if (confirm == true) {
              await ref
                  .read(playlistsProvider.notifier)
                  .deletePlaylist(playlist.id);
            }
          },
        );
      },
    );
  }

  Future<bool?> _showDeleteDialog(BuildContext context, WidgetRef ref) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        ),
        title: Text(
          'Delete Playlist',
          style: TextStyle(color: context.adaptiveTextPrimary),
        ),
        content: Text(
          'Are you sure you want to delete this playlist?',
          style: TextStyle(color: context.adaptiveTextTertiary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: context.adaptiveTextTertiary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateButton(BuildContext context, WidgetRef ref) {
    return FloatingActionButton.extended(
      onPressed: () => _showCreatePlaylistDialog(context, ref),
      backgroundColor: AppColors.surfaceLight,
      foregroundColor: context.adaptiveTextPrimary,
      elevation: 4,
      icon: const Icon(LucideIcons.plus),
      label: const Text(
        'Create Playlist',
        style: TextStyle(fontFamily: 'ProductSans'),
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        ),
        title: Text(
          'Create Playlist',
          style: TextStyle(color: context.adaptiveTextPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: context.adaptiveTextPrimary),
          decoration: InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: context.adaptiveTextTertiary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.glassBorder),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: context.adaptiveTextSecondary),
            ),
          ),
          onSubmitted: (value) =>
              _createPlaylist(context, ref, value, controller),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              'Cancel',
              style: TextStyle(color: context.adaptiveTextTertiary),
            ),
          ),
          TextButton(
            onPressed: () => _createPlaylist(
              context,
              ref,
              controller.text,
              controller,
              dialogContext: dialogContext,
            ),
            child: Text(
              'Create',
              style: TextStyle(color: context.adaptiveTextPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createPlaylist(
    BuildContext context,
    WidgetRef ref,
    String name,
    TextEditingController controller, {
    BuildContext? dialogContext,
  }) async {
    if (name.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a playlist name')),
      );
      return;
    }

    final playlist = await ref
        .read(playlistsProvider.notifier)
        .createPlaylist(name);

    if (playlist == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A playlist with this name already exists'),
          ),
        );
      }
      return;
    }

    if (dialogContext != null && dialogContext.mounted) {
      Navigator.pop(dialogContext);
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Playlist "${playlist.name}" created')),
      );
    }
  }
}

class _PlaylistCard extends StatelessWidget {
  final dynamic playlist;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PlaylistCard({
    required this.playlist,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingMd,
        vertical: AppConstants.spacingXs,
      ),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            child: Row(
              children: [
                Container(
                  width: context.scaleSize(56),
                  height: context.scaleSize(56),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    border: Border.all(color: AppColors.surfaceDark),
                  ),
                  child: Icon(
                    LucideIcons.music,
                    color: context.adaptiveTextSecondary,
                    size: context.responsiveIcon(AppConstants.iconSizeLg),
                  ),
                ),
                const SizedBox(width: AppConstants.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        playlist.name,
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
                        '${playlist.songIds.length} song${playlist.songIds.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(
                    LucideIcons.ellipsisVertical,
                    color: context.adaptiveTextTertiary,
                    size: context.responsiveIcon(AppConstants.iconSizeMd),
                  ),
                  color: AppColors.surface,
                  onSelected: (value) {
                    if (value == 'delete') {
                      onDelete();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(LucideIcons.trash2, color: Colors.red, size: 18),
                          const SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
