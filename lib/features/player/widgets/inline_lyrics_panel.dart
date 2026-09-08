import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fading_marquee_widget/fading_marquee_widget.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/models/song.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/features/player/widgets/lyrics_alignment.dart';
import 'package:flick/features/player/screens/lyrics_sync_screen.dart';
import 'package:flick/features/player/widgets/online_lyrics_search_sheet.dart';
import 'package:flick/features/player/widgets/synced_lyrics_view.dart';
import 'package:flick/providers/app_preferences_provider.dart';
class InlineLyricsPanel extends ConsumerStatefulWidget {
  final PlayerService playerService;
  final LyricsService lyricsService;
  final Song song;
  final Color? albumColor;

  const InlineLyricsPanel({super.key,
    required this.playerService,
    required this.lyricsService,
    required this.song,
    this.albumColor,
  });

  @override
  ConsumerState<InlineLyricsPanel> createState() => _InlineLyricsPanelState();
}

class _InlineLyricsPanelState extends ConsumerState<InlineLyricsPanel> {
  final ScrollController _scrollController = ScrollController();
  LyricsData? _lyricsData;
  bool _isLoading = true;
  bool _hasManualLyricsSelection = false;
  bool _isMetaCollapsed = false;

  @override
  void initState() {
    super.initState();
    _loadLyricsForSong(widget.song);
  }

  @override
  void didUpdateWidget(covariant InlineLyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _loadLyricsForSong(widget.song);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLyricsForSong(Song song) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _lyricsData = null;
    });

    final loaded = await widget.lyricsService.loadLyricsForSong(
      song,
      forceRefresh: true,
    );
    final manualSource = await widget.lyricsService.getManualLyricsPathForSong(
      song,
    );
    if (!mounted) return;
    if (widget.song.id != song.id) return;

    setState(() {
      _lyricsData = loaded;
      _hasManualLyricsSelection =
          manualSource != null && manualSource.isNotEmpty;
      _isLoading = false;
    });
  }

  String? _lyricsSourceLabel(String? source) {
    if (source == null || source.isEmpty) return null;
    final normalized = source.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _openLyricsEditor() async {
    final result = await LyricsSyncScreen.open(
      context: context,
      song: widget.song,
      playerService: widget.playerService,
      lyricsService: widget.lyricsService,
      initialLyrics: _lyricsData,
    );
    if (!mounted || result == null) return;
    _showMessage(result.message);
    await _loadLyricsForSong(widget.song);
  }

  Future<void> _importLyricsFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['lrc', 'txt', 'xml'],
        withData: true,
      );
      final pickedFile = result?.files.single;
      if (pickedFile == null) return;

      final content = await readTextFromPickedLyricsFile(pickedFile);
      if (content == null || content.trim().isEmpty) {
        _showMessage('Could not read the selected lyrics file.');
        return;
      }

      await widget.lyricsService.importLyricsForSong(
        song: widget.song,
        fileName: pickedFile.name,
        content: content,
      );
      if (!mounted) return;
      await _loadLyricsForSong(widget.song);
      _showMessage('Linked "${pickedFile.name}" to this song.');
    } catch (_) {
      _showMessage('Could not use the selected lyrics file.');
    }
  }

  Future<void> _resetManualLyricsSource() async {
    await widget.lyricsService.clearManualLyricsPathForSong(widget.song);
    if (!mounted) return;
    await _loadLyricsForSong(widget.song);
    if (!mounted) return;
    _showMessage('Switched back to the automatic lyrics source.');
  }

  Future<void> _searchOnlineLyrics() async {
    final result = await OnlineLyricsSearchSheet.show(
      context: context,
      song: widget.song,
      lyricsService: widget.lyricsService,
    );
    if (result == true && mounted) {
      await _loadLyricsForSong(widget.song);
      _showMessage('Lyrics saved from LRCLib.');
    }
  }

  Widget _buildActionButtons() {
    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
      bool emphasized = false,
    }) {
      final fillColor = emphasized
          ? Colors.white.withValues(alpha: 0.16)
          : Colors.white.withValues(alpha: 0.08);
      return TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          backgroundColor: fillColor,
          foregroundColor: Colors.white.withValues(alpha: 0.92),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
          ),
        ),
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: const TextStyle(
            fontFamily: 'ProductSans',
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          action(
            icon: LucideIcons.pencilLine,
            label: _lyricsData == null ? 'Create Lyrics' : 'Edit & Sync',
            onPressed: () => unawaited(_openLyricsEditor()),
            emphasized: true,
          ),
          action(
            icon: LucideIcons.filePlus,
            label: 'Use Existing File',
            onPressed: () => unawaited(_importLyricsFile()),
          ),
          action(
            icon: LucideIcons.globe,
            label: 'Search Online',
            onPressed: () => unawaited(_searchOnlineLyrics()),
          ),
          if (_hasManualLyricsSelection)
            action(
              icon: LucideIcons.refreshCcw,
              label: 'Use Auto Source',
              onPressed: () => unawaited(_resetManualLyricsSource()),
            ),
        ],
      ),
    );
  }

  Widget _buildLyricsMeta(LyricsData lyrics) {
    final sourceLabel = _lyricsSourceLabel(lyrics.source);
    final textColor = Colors.white.withValues(alpha: 0.82);

    Widget chip(
      IconData icon,
      String label, {
      bool accent = false,
      bool marqueeLabel = false,
    }) {
      final labelStyle = TextStyle(
        fontFamily: 'ProductSans',
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: accent ? AppColors.accent : textColor,
      );
      final labelWidget = marqueeLabel
          ? SizedBox(
              width: 132,
              child: FadingMarqueeWidget(
                id: label,
                gap: 20,
                delay: const Duration(milliseconds: 1200),
                pause: const Duration(milliseconds: 800),
                duration: const Duration(seconds: 6),
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: labelStyle,
                ),
              ),
            )
          : Text(label, style: labelStyle);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: accent
              ? AppColors.accent.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: accent
                ? AppColors.accent.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: accent ? AppColors.accent : textColor),
            const SizedBox(width: 6),
            labelWidget,
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => setState(() => _isMetaCollapsed = !_isMetaCollapsed),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                chip(
                  lyrics.isSynchronized
                      ? LucideIcons.clock3
                      : LucideIcons.fileText,
                  lyrics.isSynchronized ? 'Synced' : 'Plain',
                  accent: lyrics.isSynchronized,
                ),
                const SizedBox(width: 8),
                if (sourceLabel != null) ...[
                  chip(LucideIcons.badgeInfo, sourceLabel, marqueeLabel: true),
                  const SizedBox(width: 8),
                ],
                AnimatedRotation(
                  turns: _isMetaCollapsed ? 0.0 : 0.5,
                  duration: AppConstants.animationFast,
                  child: Icon(
                    LucideIcons.chevronDown,
                    size: 14,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: AppConstants.animationFast,
          crossFadeState: _isMetaCollapsed
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: _buildActionButtons(),
        ),
      ],
    );
  }

  Widget _buildPlainLyricsView(LyricsData lyrics) {
    final alignment = resolveLyricsAlignment(
      ref.watch(appPreferencesProvider).lyricsTextAlign,
    );
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      child: SizedBox(
        width: double.infinity,
        child: Text(
          lyrics.lines.map((line) => line.text).join('\n'),
          textAlign: alignment.textAlign,
          style: TextStyle(
            fontFamily: 'ProductSans',
            fontSize: 18,
            height: 1.9,
            color: Colors.white.withValues(alpha: 0.92),
          ),
        ),
      ),
    );
  }

  Widget _buildSynchronizedLyricsView(LyricsData lyrics) {
    return Expanded(
      child: SyncedLyricsView(
        playerService: widget.playerService,
        lyricsService: widget.lyricsService,
        lyrics: lyrics,
        albumColor: widget.albumColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildBody(context);
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }

    final lyrics = _lyricsData;
    if (lyrics == null || lyrics.lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Icon(
                  LucideIcons.fileText,
                  size: 24,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'No lyrics yet',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Search online, create your own synced lyrics, or import an existing file.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: 13,
                  height: 1.5,
                  color: Colors.white.withValues(alpha: 0.56),
                ),
              ),
              _buildActionButtons(),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildLyricsMeta(lyrics),
        if (lyrics.isSynchronized)
          _buildSynchronizedLyricsView(lyrics)
        else
          Expanded(child: _buildPlainLyricsView(lyrics)),
      ],
    );
  }
}
