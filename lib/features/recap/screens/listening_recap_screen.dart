import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flick/services/gallery_save_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Wrapped-style listening recap with daily, weekly, monthly, and yearly views.
class ListeningRecapScreen extends StatefulWidget {
  const ListeningRecapScreen({super.key});

  @override
  State<ListeningRecapScreen> createState() => _ListeningRecapScreenState();
}

class _ListeningRecapScreenState extends State<ListeningRecapScreen> {
  final RecentlyPlayedRepository _recentlyPlayedRepository =
      RecentlyPlayedRepository();
  final GallerySaveService _gallerySaveService = GallerySaveService();
  final GlobalKey _cardBoundaryKey = GlobalKey();

  ListeningRecapPeriod _selectedPeriod = ListeningRecapPeriod.daily;
  Map<ListeningRecapPeriod, ListeningRecap> _recaps = {};
  bool _isLoading = true;
  bool _isSaving = false;
  StreamSubscription<void>? _historySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRecaps();
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
      _loadRecaps(showLoadingState: false);
    });
  }

  Future<void> _loadRecaps({bool showLoadingState = true}) async {
    if (!mounted) return;

    if (showLoadingState) {
      setState(() => _isLoading = true);
    }

    try {
      final recaps = await _recentlyPlayedRepository.getListeningRecaps();
      if (!mounted) return;
      setState(() {
        _recaps = recaps;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recaps = {};
        _isLoading = false;
      });
    }
  }

  ListeningRecap _currentRecap() {
    return _recaps[_selectedPeriod] ??
        ListeningRecap.empty(
          _selectedPeriod,
          _selectedPeriod.rangeFor(DateTime.now()),
        );
  }

  Future<void> _saveCurrentRecap() async {
    if (_isSaving) return;

    final recap = _currentRecap();
    setState(() => _isSaving = true);

    try {
      final bytes = await _captureRecapPng(_cardBoundaryKey);
      if (bytes == null) {
        throw const GallerySaveException(
          'The recap card is not ready to capture yet.',
        );
      }

      await _gallerySaveService.saveImage(
        bytes: bytes,
        fileName: _buildRecapFileName(recap),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recap saved to your gallery')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_saveErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _openScreenshotView() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            _ListeningRecapPosterScreen(recap: _currentRecap()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recap = _currentRecap();

    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            const Positioned.fill(child: _RecapBackdrop()),
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _buildHeader(context),
                  _buildPeriodPicker(context),
                  const SizedBox(height: AppConstants.spacingSm),
                  Expanded(
                    child: _isLoading && _recaps.isEmpty
                        ? _buildLoadingState(context)
                        : RefreshIndicator(
                            onRefresh: _loadRecaps,
                            color: AppColors.textPrimary,
                            child: SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: EdgeInsets.fromLTRB(
                                AppConstants.spacingLg,
                                AppConstants.spacingMd,
                                AppConstants.spacingLg,
                                AppConstants.navBarHeight + 96,
                              ),
                              child: AnimatedSwitcher(
                                duration: AppConstants.animationNormal,
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                child: Column(
                                  key: ValueKey(_selectedPeriod),
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Center(
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: math.min(
                                            context.screenWidth -
                                                (AppConstants.spacingLg * 2),
                                            420,
                                          ),
                                        ),
                                        child: RepaintBoundary(
                                          key: _cardBoundaryKey,
                                          child: _ListeningRecapHeroCard(
                                            recap: recap,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(
                                      height: AppConstants.spacingMd,
                                    ),
                                    _buildActionRow(context),
                                    const SizedBox(
                                      height: AppConstants.spacingLg,
                                    ),
                                    if (recap.hasData) ...[
                                      _buildHighlightCards(context, recap),
                                      const SizedBox(
                                        height: AppConstants.spacingLg,
                                      ),
                                      _buildRankingSection(
                                        context,
                                        title: 'Top Songs',
                                        subtitle:
                                            'The tracks that defined this ${recap.period.label.toLowerCase()}',
                                        children: [
                                          for (
                                            var index = 0;
                                            index < recap.topSongs.length;
                                            index++
                                          )
                                            _RankingTile.song(
                                              rank: index + 1,
                                              item: recap.topSongs[index],
                                            ),
                                        ],
                                      ),
                                      const SizedBox(
                                        height: AppConstants.spacingLg,
                                      ),
                                      _buildRankingSection(
                                        context,
                                        title: 'Top Artists',
                                        subtitle:
                                            'Your most replayed voices and projects',
                                        children: [
                                          for (
                                            var index = 0;
                                            index < recap.topArtists.length;
                                            index++
                                          )
                                            _RankingTile.artist(
                                              rank: index + 1,
                                              item: recap.topArtists[index],
                                            ),
                                        ],
                                      ),
                                    ] else
                                      _buildEmptyDetailState(context, recap),
                                  ],
                                ),
                              ),
                            ),
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
                  'Flick Replay',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                Text(
                  'Your daily, weekly, monthly, and yearly listening recap',
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

  Widget _buildPeriodPicker(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.spacingLg),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final period = ListeningRecapPeriod.values[index];
          final isSelected = period == _selectedPeriod;

          return GestureDetector(
            onTap: () => setState(() => _selectedPeriod = period),
            child: AnimatedContainer(
              duration: AppConstants.animationFast,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(
                horizontal: AppConstants.spacingMd,
                vertical: AppConstants.spacingSm,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppConstants.radiusRound),
                gradient: isSelected
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFEDF6FF), Color(0xFF8AB7FF)],
                      )
                    : null,
                color: isSelected ? null : AppColors.glassBackground,
                border: Border.all(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.28)
                      : AppColors.glassBorder,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: const Color(
                            0xFF8AB7FF,
                          ).withValues(alpha: 0.25),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
                        ),
                      ]
                    : null,
              ),
              child: Center(
                child: Text(
                  period.label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isSelected ? AppColors.background : Colors.white,
                  ),
                ),
              ),
            ),
          );
        },
        separatorBuilder: (_, _) =>
            const SizedBox(width: AppConstants.spacingSm),
        itemCount: ListeningRecapPeriod.values.length,
      ),
    );
  }

  Widget _buildActionRow(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _RecapActionButton(
            icon: Icons.crop_free_rounded,
            label: 'Screenshot View',
            onTap: _openScreenshotView,
          ),
        ),
        const SizedBox(width: AppConstants.spacingSm),
        Expanded(
          child: _RecapActionButton(
            icon: Icons.download_rounded,
            label: _isSaving ? 'Saving...' : 'Save to Gallery',
            isPrimary: true,
            onTap: _isSaving ? null : _saveCurrentRecap,
          ),
        ),
      ],
    );
  }

  Widget _buildHighlightCards(BuildContext context, ListeningRecap recap) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isStacked = constraints.maxWidth < 640;
        final itemWidth = isStacked
            ? constraints.maxWidth
            : (constraints.maxWidth - 12) / 2;

        return Wrap(
          spacing: AppConstants.spacingSm,
          runSpacing: AppConstants.spacingSm,
          children: [
            SizedBox(
              width: itemWidth,
              child: _InsightCard(
                title: 'Top Artist',
                value: recap.topArtist?.artist ?? 'No data yet',
                detail: recap.topArtist == null
                    ? 'Start listening to unlock this card'
                    : '${recap.topArtist!.plays} plays · ${recap.topArtist!.uniqueSongs} songs',
                accent: const Color(0xFFFFD47A),
                icon: Icons.mic_rounded,
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: _InsightCard(
                title: 'Top Album',
                value: recap.topAlbum?.album ?? 'No data yet',
                detail: recap.topAlbum == null
                    ? 'Albums will show up here once you replay them'
                    : '${recap.topAlbum!.artist} · ${recap.topAlbum!.plays} plays',
                accent: const Color(0xFF7CD9FF),
                icon: LucideIcons.disc,
                imagePath: recap.topAlbum?.representativeSong.albumArt,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRankingSection(
    BuildContext context, {
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: context.adaptiveTextPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
          ),
          const SizedBox(height: AppConstants.spacingMd),
          ...children,
        ],
      ),
    );
  }

  Widget _buildEmptyDetailState(BuildContext context, ListeningRecap recap) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingLg),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          Icon(
            Icons.auto_awesome_motion_rounded,
            color: Colors.white.withValues(alpha: 0.85),
            size: context.responsiveIcon(30),
          ),
          const SizedBox(height: AppConstants.spacingMd),
          Text(
            recap.period.emptyMessage,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              height: 1.5,
              color: context.adaptiveTextSecondary,
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
}

class _ListeningRecapHeroCard extends StatelessWidget {
  final ListeningRecap recap;

  const _ListeningRecapHeroCard({required this.recap});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 0.72,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF08111D), Color(0xFF141925), Color(0xFF21161A)],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                top: -80,
                left: -20,
                child: _GlowOrb(
                  size: 220,
                  colors: const [Color(0xFF5A9BFF), Color(0x005A9BFF)],
                ),
              ),
              Positioned(
                bottom: -110,
                right: -10,
                child: _GlowOrb(
                  size: 260,
                  colors: const [Color(0xFFFFB35A), Color(0x00FFB35A)],
                ),
              ),
              Positioned(
                top: 24,
                right: 24,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppConstants.spacingSm,
                    vertical: AppConstants.spacingXs,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(
                      AppConstants.radiusRound,
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.16),
                    ),
                  ),
                  child: Text(
                    recap.period.label.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppConstants.spacingLg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppConstants.spacingSm,
                        vertical: AppConstants.spacingXs,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusRound,
                        ),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                      child: Text(
                        'Flick Replay',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Colors.white.withValues(alpha: 0.92),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    const SizedBox(height: AppConstants.spacingLg),
                    Text(
                      _heroHeadline(recap),
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        height: 0.92,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        fontSize: context.responsiveText(38),
                      ),
                    ),
                    const SizedBox(height: AppConstants.spacingSm),
                    Text(
                      _formatRecapRange(recap),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                    const Spacer(),
                    Align(
                      child: _HeroAlbumArt(
                        imagePath:
                            recap.topSong?.song.albumArt ??
                            recap.topAlbum?.representativeSong.albumArt,
                      ),
                    ),
                    const SizedBox(height: AppConstants.spacingMd),
                    if (recap.topSong != null) ...[
                      Text(
                        recap.topSong!.song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        recap.topSong!.song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ] else ...[
                      Text(
                        'No plays yet',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        recap.period.emptyMessage,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                    const SizedBox(height: AppConstants.spacingLg),
                    _RecapMetricGrid(recap: recap),
                    const SizedBox(height: AppConstants.spacingMd),
                    Text(
                      _heroClosingLine(recap),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.84),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListeningRecapPosterScreen extends StatefulWidget {
  final ListeningRecap recap;

  const _ListeningRecapPosterScreen({required this.recap});

  @override
  State<_ListeningRecapPosterScreen> createState() =>
      _ListeningRecapPosterScreenState();
}

class _ListeningRecapPosterScreenState
    extends State<_ListeningRecapPosterScreen> {
  final GlobalKey _posterBoundaryKey = GlobalKey();
  final GallerySaveService _gallerySaveService = GallerySaveService();
  bool _isSaving = false;

  Future<void> _savePoster() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final bytes = await _captureRecapPng(_posterBoundaryKey);
      if (bytes == null) {
        throw const GallerySaveException(
          'The recap poster is still rendering.',
        );
      }

      await _gallerySaveService.saveImage(
        bytes: bytes,
        fileName: _buildRecapFileName(widget.recap),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recap saved to your gallery')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_saveErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          const Positioned.fill(child: _RecapBackdrop()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppConstants.spacingLg),
              child: Column(
                children: [
                  Row(
                    children: [
                      _PosterActionIcon(
                        icon: LucideIcons.arrowLeft,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      _PosterActionIcon(
                        icon: _isSaving
                            ? Icons.hourglass_top_rounded
                            : Icons.download_rounded,
                        onTap: _isSaving ? null : _savePoster,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppConstants.spacingLg),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: math.min(context.screenWidth - 48, 420),
                        ),
                        child: RepaintBoundary(
                          key: _posterBoundaryKey,
                          child: _ListeningRecapHeroCard(recap: widget.recap),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppConstants.spacingMd),
                  Text(
                    'Use your device screenshot gesture here, or save the poster directly to your gallery.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecapBackdrop extends StatelessWidget {
  const _RecapBackdrop();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF040608), Color(0xFF0A0A0A)],
              ),
            ),
          ),
          Positioned(
            top: -160,
            left: -80,
            child: _GlowOrb(
              size: 360,
              colors: const [Color(0xFF1B3258), Color(0x001B3258)],
            ),
          ),
          Positioned(
            top: context.screenHeight * 0.28,
            right: -120,
            child: _GlowOrb(
              size: 320,
              colors: const [Color(0xFF4A2A1F), Color(0x004A2A1F)],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  final double size;
  final List<Color> colors;

  const _GlowOrb({required this.size, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: colors),
      ),
    );
  }
}

class _HeroAlbumArt extends StatelessWidget {
  final String? imagePath;

  const _HeroAlbumArt({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    final size = context.scaleSize(144);

    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x40FFFFFF), Color(0x08FFFFFF)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: imagePath == null || imagePath!.isEmpty
            ? Container(
                color: Colors.white.withValues(alpha: 0.08),
                child: Icon(
                  Icons.music_note_rounded,
                  size: context.responsiveIcon(48),
                  color: Colors.white.withValues(alpha: 0.76),
                ),
              )
            : CachedImageWidget(
                imagePath: imagePath,
                fit: BoxFit.cover,
                errorWidget: Container(
                  color: Colors.white.withValues(alpha: 0.08),
                  child: Icon(
                    Icons.music_note_rounded,
                    size: context.responsiveIcon(48),
                    color: Colors.white.withValues(alpha: 0.76),
                  ),
                ),
              ),
      ),
    );
  }
}

class _RecapMetricGrid extends StatelessWidget {
  final ListeningRecap recap;

  const _RecapMetricGrid({required this.recap});

  @override
  Widget build(BuildContext context) {
    final metrics = [
      _MetricData(label: 'Plays', value: '${recap.totalPlays}'),
      _MetricData(
        label: 'Listen Time',
        value: _formatCompactDuration(recap.totalListeningTime),
      ),
      _MetricData(label: 'Active Days', value: '${recap.activeDays}'),
      _MetricData(label: 'Peak Hour', value: _formatPeakHour(recap.peakHour)),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: AppConstants.spacingSm,
        mainAxisSpacing: AppConstants.spacingSm,
        childAspectRatio: 1.6,
      ),
      itemCount: metrics.length,
      itemBuilder: (context, index) => _RecapMetricTile(data: metrics[index]),
    );
  }
}

class _MetricData {
  final String label;
  final String value;

  const _MetricData({required this.label, required this.value});
}

class _RecapMetricTile extends StatelessWidget {
  final _MetricData data;

  const _RecapMetricTile({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingSm),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            data.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            data.label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.66),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  final String title;
  final String value;
  final String detail;
  final Color accent;
  final IconData icon;
  final String? imagePath;

  const _InsightCard({
    required this.title,
    required this.value,
    required this.detail,
    required this.accent,
    required this.icon,
    this.imagePath,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: 0.35),
                  accent.withValues(alpha: 0.08),
                ],
              ),
              border: Border.all(color: accent.withValues(alpha: 0.2)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppConstants.radiusMd - 1),
              child: imagePath == null || imagePath!.isEmpty
                  ? Icon(icon, color: accent)
                  : CachedImageWidget(imagePath: imagePath, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: context.adaptiveTextTertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  maxLines: 2,
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

class _RankingTile extends StatelessWidget {
  final int rank;
  final String title;
  final String subtitle;
  final String trailing;
  final String? imagePath;

  const _RankingTile({
    required this.rank,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.imagePath,
  });

  factory _RankingTile.song({
    required int rank,
    required RankedRecapSong item,
  }) {
    return _RankingTile(
      rank: rank,
      title: item.song.title,
      subtitle:
          '${item.song.artist} · ${_formatCompactDuration(item.listeningTime)}',
      trailing: _formatPlayCount(item.plays),
      imagePath: item.song.albumArt,
    );
  }

  factory _RankingTile.artist({
    required int rank,
    required RankedRecapArtist item,
  }) {
    return _RankingTile(
      rank: rank,
      title: item.artist,
      subtitle:
          '${item.uniqueSongs} songs · ${_formatCompactDuration(item.listeningTime)}',
      trailing: _formatPlayCount(item.plays),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: rank == 5 ? 0 : AppConstants.spacingSm),
      child: Container(
        padding: const EdgeInsets.all(AppConstants.spacingSm),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              alignment: Alignment.center,
              child: Text(
                '$rank',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: AppConstants.spacingSm),
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                color: Colors.white.withValues(alpha: 0.08),
              ),
              clipBehavior: Clip.antiAlias,
              child: imagePath == null || imagePath!.isEmpty
                  ? Icon(
                      Icons.music_note_rounded,
                      color: context.adaptiveTextSecondary,
                    )
                  : CachedImageWidget(imagePath: imagePath, fit: BoxFit.cover),
            ),
            const SizedBox(width: AppConstants.spacingSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: context.adaptiveTextPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppConstants.spacingSm),
            Text(
              trailing,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecapActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool isPrimary;

  const _RecapActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        child: Ink(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingMd,
            vertical: AppConstants.spacingMd,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            gradient: isPrimary
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFF5F7FF), Color(0xFF9CC4FF)],
                  )
                : null,
            color: isPrimary ? null : AppColors.glassBackground,
            border: Border.all(
              color: isPrimary
                  ? Colors.white.withValues(alpha: 0.26)
                  : AppColors.glassBorder,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: context.responsiveIcon(AppConstants.iconSizeMd),
                color: isPrimary ? AppColors.background : Colors.white,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isPrimary ? AppColors.background : Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PosterActionIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _PosterActionIcon({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.glassBackground,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }
}

Future<Uint8List?> _captureRecapPng(GlobalKey boundaryKey) async {
  await Future.delayed(const Duration(milliseconds: 32));

  final context = boundaryKey.currentContext;
  if (context == null) return null;

  final renderObject = context.findRenderObject();
  if (renderObject is! RenderRepaintBoundary) return null;

  final image = await renderObject.toImage(pixelRatio: 3);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) return null;

  return byteData.buffer.asUint8List();
}

String _buildRecapFileName(ListeningRecap recap) {
  final now = DateTime.now();
  return 'flick_${recap.period.label.toLowerCase()}_replay_${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}_${_twoDigits(now.hour)}${_twoDigits(now.minute)}${_twoDigits(now.second)}.png';
}

String _saveErrorMessage(Object error) {
  if (error is GallerySaveException) {
    return error.message;
  }
  return 'Failed to save the recap image.';
}

String _heroHeadline(ListeningRecap recap) {
  if (!recap.hasData) {
    return '${recap.period.label}\nwaiting';
  }

  final listens = recap.totalPlays == 1 ? 'play' : 'plays';
  return '${recap.totalPlays} $listens\nlocked in';
}

String _heroClosingLine(ListeningRecap recap) {
  if (!recap.hasData) {
    return recap.period.emptyMessage;
  }

  if (recap.topArtist != null && recap.topSong != null) {
    return '${recap.topArtist!.artist} led the rotation, and "${recap.topSong!.song.title}" finished as your most replayed track.';
  }

  if (recap.topSong != null) {
    return '"${recap.topSong!.song.title}" was the clear standout in this ${recap.period.label.toLowerCase()} recap.';
  }

  return 'Your listening pattern is starting to take shape.';
}

String _formatRecapRange(ListeningRecap recap) {
  final endInclusive = recap.endExclusive.subtract(const Duration(days: 1));
  switch (recap.period) {
    case ListeningRecapPeriod.daily:
      return '${_monthName(recap.start.month)} ${recap.start.day}, ${recap.start.year}';
    case ListeningRecapPeriod.weekly:
      return '${_monthName(recap.start.month)} ${recap.start.day} - ${_monthName(endInclusive.month)} ${endInclusive.day}, ${endInclusive.year}';
    case ListeningRecapPeriod.monthly:
      return '${_monthName(recap.start.month)} ${recap.start.year}';
    case ListeningRecapPeriod.yearly:
      return '${recap.start.year}';
  }
}

String _formatCompactDuration(Duration duration) {
  if (duration == Duration.zero) return '0m';

  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);

  if (hours > 0) {
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }
  return '${duration.inMinutes}m';
}

String _formatPeakHour(int? hour) {
  if (hour == null) return '--';
  final period = hour >= 12 ? 'PM' : 'AM';
  final normalizedHour = hour % 12 == 0 ? 12 : hour % 12;
  return '$normalizedHour $period';
}

String _formatPlayCount(int plays) {
  return plays == 1 ? '1 play' : '$plays plays';
}

String _monthName(int month) {
  const names = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return names[month - 1];
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
