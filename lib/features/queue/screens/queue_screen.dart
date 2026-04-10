import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(playerProvider.select((state) => state.queue));
    final currentSong = ref.watch(
      playerProvider.select((state) => state.currentSong),
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              queueCount: queue.length,
              canClear: queue.isNotEmpty,
              onClear: () async {
                await ref.read(playerProvider.notifier).clearQueue();
              },
            ),
            Expanded(
              child: queue.isEmpty && currentSong == null
                  ? const _EmptyQueue()
                  : CustomScrollView(
                      slivers: [
                        if (currentSong != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                AppConstants.spacingLg,
                                0,
                                AppConstants.spacingLg,
                                AppConstants.spacingMd,
                              ),
                              child: _NowPlayingCard(song: currentSong),
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppConstants.spacingLg,
                              0,
                              AppConstants.spacingLg,
                              AppConstants.spacingSm,
                            ),
                            child: Text(
                              queue.isEmpty ? 'Up next' : 'Next in queue',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: context.adaptiveTextSecondary,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        ),
                        if (queue.isEmpty)
                          const SliverToBoxAdapter(child: _EmptyUpcomingState())
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(
                              AppConstants.spacingLg,
                              0,
                              AppConstants.spacingLg,
                              AppConstants.navBarHeight + 120,
                            ),
                            sliver: SliverReorderableList(
                              itemCount: queue.length,
                              onReorder: (oldIndex, newIndex) async {
                                final targetIndex = newIndex > oldIndex
                                    ? newIndex - 1
                                    : newIndex;
                                await ref
                                    .read(playerProvider.notifier)
                                    .moveQueueItem(oldIndex, targetIndex);
                              },
                              itemBuilder: (context, index) {
                                final song = queue[index];
                                return _QueueTile(
                                  key: ValueKey('${song.id}-$index'),
                                  song: song,
                                  index: index,
                                  onTap: () async {
                                    await ref
                                        .read(playerProvider.notifier)
                                        .playFromQueueIndex(index);
                                  },
                                  onRemove: () async {
                                    await ref
                                        .read(playerProvider.notifier)
                                        .removeFromQueue(index);
                                  },
                                  onMoveToNext: index == 0
                                      ? null
                                      : () async {
                                          await ref
                                              .read(playerProvider.notifier)
                                              .moveQueueItemToNext(index);
                                        },
                                );
                              },
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final int queueCount;
  final bool canClear;
  final Future<void> Function() onClear;

  const _Header({
    required this.queueCount,
    required this.canClear,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
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
                  'Queue',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                Text(
                  '$queueCount upcoming song${queueCount == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (canClear)
            TextButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.listMusic,
              size: 52,
              color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: AppConstants.spacingLg),
            Text(
              'Queue is empty',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              'Add songs from the player or song actions menu.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.adaptiveTextTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyUpcomingState extends StatelessWidget {
  const _EmptyUpcomingState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppConstants.spacingLg),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Row(
          children: [
            Icon(
              LucideIcons.sparkles,
              color: context.adaptiveTextTertiary,
              size: 20,
            ),
            const SizedBox(width: AppConstants.spacingSm),
            Expanded(
              child: Text(
                'No upcoming queue items yet.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.adaptiveTextSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  final Song song;

  const _NowPlayingCard({required this.song});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfaceLight.withValues(alpha: 0.92),
            AppColors.surface.withValues(alpha: 0.98),
          ],
        ),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          _Artwork(song: song),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Now playing',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextSecondary,
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

class _QueueTile extends StatelessWidget {
  final Song song;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback? onMoveToNext;

  const _QueueTile({
    required super.key,
    required this.song,
    required this.index,
    required this.onTap,
    required this.onRemove,
    required this.onMoveToNext,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: AppConstants.spacingSm),
      child: Dismissible(
        key: ValueKey('queue-dismiss-$index-${song.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            color: Colors.redAccent.withValues(alpha: 0.18),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35)),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingLg,
          ),
          alignment: Alignment.centerRight,
          child: const Icon(LucideIcons.trash2, color: Colors.redAccent),
        ),
        onDismissed: (_) => onRemove(),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppConstants.spacingMd,
                vertical: AppConstants.spacingSm,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.surfaceLight.withValues(alpha: 0.7),
                    AppColors.surface.withValues(alpha: 0.82),
                  ],
                ),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        right: AppConstants.spacingSm,
                      ),
                      child: Icon(
                        LucideIcons.gripVertical,
                        color: context.adaptiveTextTertiary,
                        size: 18,
                      ),
                    ),
                  ),
                  _Artwork(song: song),
                  const SizedBox(width: AppConstants.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: context.adaptiveTextPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: context.adaptiveTextSecondary),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<_QueueAction>(
                    onSelected: (action) {
                      switch (action) {
                        case _QueueAction.playNext:
                          onMoveToNext?.call();
                          break;
                        case _QueueAction.remove:
                          onRemove();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      if (onMoveToNext != null)
                        const PopupMenuItem(
                          value: _QueueAction.playNext,
                          child: Text('Play next'),
                        ),
                      const PopupMenuItem(
                        value: _QueueAction.remove,
                        child: Text('Remove'),
                      ),
                    ],
                    icon: Icon(
                      LucideIcons.ellipsisVertical,
                      color: context.adaptiveTextTertiary,
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
}

class _Artwork extends StatelessWidget {
  final Song song;

  const _Artwork({required this.song});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppConstants.radiusMd),
      child: SizedBox(
        width: 48,
        height: 48,
        child: CachedImageWidget(
          imagePath: song.albumArt,
          audioSourcePath: song.filePath,
          fit: BoxFit.cover,
          useThumbnail: true,
          thumbnailWidth: 96,
          thumbnailHeight: 96,
          placeholder: const ColoredBox(
            color: AppColors.surface,
            child: Icon(
              LucideIcons.music,
              color: AppColors.textTertiary,
              size: 18,
            ),
          ),
          errorWidget: const ColoredBox(
            color: AppColors.surface,
            child: Icon(
              LucideIcons.music,
              color: AppColors.textTertiary,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

enum _QueueAction { playNext, remove }
