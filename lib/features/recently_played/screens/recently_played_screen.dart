import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';

/// Recently Played screen with timeline-style layout.
class RecentlyPlayedScreen extends StatefulWidget {
  const RecentlyPlayedScreen({super.key});

  @override
  State<RecentlyPlayedScreen> createState() => _RecentlyPlayedScreenState();
}

class _RecentlyPlayedScreenState extends State<RecentlyPlayedScreen> {
  final PlayerService _playerService = PlayerService();
  final RecentlyPlayedRepository _recentlyPlayedRepository =
      RecentlyPlayedRepository();

  bool _isLoading = true;
  Map<String, List<RecentlyPlayedEntry>> _groupedHistory = {};
  StreamSubscription<void>? _historySubscription;

  @override
  void initState() {
    super.initState();
    // Defer data loading to avoid jank during navigation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadHistory();
      _watchHistory();
    });
  }

  @override
  void dispose() {
    _historySubscription?.cancel();
    super.dispose();
  }

  void _watchHistory() {
    _historySubscription = _recentlyPlayedRepository.watchHistory().listen((_) {
      _loadHistory();
    });
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      final grouped = await _recentlyPlayedRepository.getGroupedHistory();
      if (mounted) {
        setState(() {
          _groupedHistory = grouped;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _groupedHistory = {};
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.glassBackgroundStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          side: BorderSide(color: AppColors.glassBorder),
        ),
        title: Text(
          'Clear History',
          style: TextStyle(color: context.adaptiveTextPrimary),
        ),
        content: Text(
          'Are you sure you want to clear your entire listening history? This cannot be undone.',
          style: TextStyle(color: context.adaptiveTextSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: context.adaptiveTextSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _recentlyPlayedRepository.clearHistory();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('History cleared')));
      }
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
                  : _groupedHistory.isEmpty
                  ? _buildEmptyState()
                  : _buildHistoryList(),
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
                  'Recently Played',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                Text(
                  'Your listening history',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (_groupedHistory.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: AppColors.glassBackground,
                borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: IconButton(
                icon: Icon(
                  LucideIcons.trash2,
                  color: context.adaptiveTextSecondary,
                  size: context.responsiveIcon(AppConstants.iconSizeMd),
                ),
                onPressed: _clearHistory,
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
            // Timeline illustration
            SizedBox(
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Timeline line
                  Container(
                    width: 3,
                    height: 100,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AppColors.glassBorder.withValues(alpha: 0),
                          AppColors.glassBorder,
                          AppColors.glassBorder.withValues(alpha: 0),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Center icon
                  Container(
                    width: context.scaleSize(AppConstants.containerSizeXl),
                    height: context.scaleSize(AppConstants.containerSizeXl),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.glassBackground,
                      border: Border.all(
                        color: AppColors.glassBorder,
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      LucideIcons.clock,
                      size: context.responsiveIcon(AppConstants.iconSizeXl),
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppConstants.spacingLg),
            Text(
              'No History Yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              'Songs you play will appear here',
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

  Widget _buildHistoryList() {
    // Define the order we want sections to appear
    const sectionOrder = [
      'Today',
      'Yesterday',
      'This Week',
      'Last Week',
      'This Month',
      'Earlier',
    ];

    // Sort sections according to our defined order
    final sortedSections = _groupedHistory.entries.toList()
      ..sort((a, b) {
        final aIndex = sectionOrder.indexOf(a.key);
        final bIndex = sectionOrder.indexOf(b.key);
        return aIndex.compareTo(bIndex);
      });

    return ListView.builder(
      padding: EdgeInsets.only(bottom: AppConstants.navBarHeight + 120),
      itemCount: sortedSections.length,
      itemBuilder: (context, sectionIndex) {
        final section = sortedSections[sectionIndex];
        return _buildTimeSection(section.key, section.value);
      },
    );
  }

  Widget _buildTimeSection(String title, List<RecentlyPlayedEntry> entries) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingLg,
            vertical: AppConstants.spacingSm,
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.adaptiveTextSecondary,
                ),
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: context.adaptiveTextSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${entries.length} ${entries.length == 1 ? 'song' : 'songs'}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: context.adaptiveTextTertiary,
                ),
              ),
            ],
          ),
        ),
        // Horizontal scrollable cards
        SizedBox(
          height: context.scaleSize(AppConstants.cardHeightMd),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: AppConstants.spacingMd,
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _RecentlyPlayedCard(
                song: entry.song,
                playedAt: entry.playedAt,
                onTap: () async {
                  await _playerService.play(entry.song);
                  if (context.mounted) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => FullPlayerScreen(
                          heroTag: 'recent_song_${entry.song.id}',
                        ),
                      ),
                    );
                  }
                },
              );
            },
          ),
        ),
        const SizedBox(height: AppConstants.spacingMd),
      ],
    );
  }
}

class _RecentlyPlayedCard extends StatelessWidget {
  final Song song;
  final DateTime playedAt;
  final VoidCallback onTap;

  const _RecentlyPlayedCard({
    required this.song,
    required this.playedAt,
    required this.onTap,
  });

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AppConstants.spacingSm),
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
                width: context.scaleSize(AppConstants.cardWidthMd),
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
                        child: song.albumArt != null
                            ? ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(AppConstants.radiusLg),
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
                    ),
                    // Song info
                    Padding(
                      padding: const EdgeInsets.all(AppConstants.spacingXs),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: context.adaptiveTextPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                LucideIcons.clock,
                                size: context.responsiveIcon(
                                  AppConstants.iconSizeXs,
                                ),
                                color: context.adaptiveTextTertiary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _formatTime(playedAt),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: context.adaptiveTextTertiary,
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
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Center(
      child: Icon(
        LucideIcons.music,
        color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
        size: context.responsiveIcon(AppConstants.iconSizeLg),
      ),
    );
  }
}
