import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flick/widgets/common/flick_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/features/player/widgets/karaoke_lyric_line.dart';
import 'package:flick/features/player/widgets/lyrics_editor_model.dart';
import 'package:flick/features/player/widgets/lyrics_word_timeline.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum LyricsEditorViewMode { simple, wordSync, advanced }

class LyricsEditorResult {
  final String message;
  final LyricsData lyricsData;

  const LyricsEditorResult({required this.message, required this.lyricsData});
}

class LyricsEditorBottomSheet extends StatefulWidget {
  final Song song;
  final PlayerService playerService;
  final LyricsService lyricsService;
  final LyricsData? initialLyrics;

  const LyricsEditorBottomSheet({
    super.key,
    required this.song,
    required this.playerService,
    required this.lyricsService,
    this.initialLyrics,
  });

  static Future<LyricsEditorResult?> show({
    required BuildContext context,
    required Song song,
    required PlayerService playerService,
    required LyricsService lyricsService,
    LyricsData? initialLyrics,
  }) {
    return showModalBottomSheet<LyricsEditorResult>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => AppBottomSheetSurface(
        maxHeightRatio: 0.94,
        child: LyricsEditorBottomSheet(
          song: song,
          playerService: playerService,
          lyricsService: lyricsService,
          initialLyrics: initialLyrics,
        ),
      ),
    );
  }

  @override
  State<LyricsEditorBottomSheet> createState() =>
      _LyricsEditorBottomSheetState();
}

class _LyricsEditorBottomSheetState extends State<LyricsEditorBottomSheet> {
  final TextEditingController _lyricsTextController = TextEditingController();
  final TextEditingController _currentTimeController = TextEditingController();
  final TextEditingController _boundaryTimeController = TextEditingController();
  final FocusNode _boundaryFocus = FocusNode();

  LyricsEditorViewMode _viewMode = LyricsEditorViewMode.simple;
  LyricsEditorModel _model = const LyricsEditorModel([
    EditableLyricLine(text: '', timestamp: null),
  ]);
  int _selectedLineIndex = 0;
  int? _selectedWordIndex;
  bool _autoAdvance = true;
  bool _isSaving = false;
  Duration _currentPosition = Duration.zero;

  List<EditableLyricLine> get _lines => _model.lines;

  @override
  void initState() {
    super.initState();
    _currentPosition = widget.playerService.positionNotifier.value;
    _model = LyricsEditorModel.fromLyrics(widget.initialLyrics);
    _syncEditorFromLines();
    _updateCurrentTimeField();
    _lyricsTextController.addListener(_handleLyricsTextChanged);
    widget.playerService.positionNotifier.addListener(_handlePositionChanged);
  }

  @override
  void dispose() {
    _lyricsTextController.removeListener(_handleLyricsTextChanged);
    widget.playerService.positionNotifier.removeListener(
      _handlePositionChanged,
    );
    _lyricsTextController.dispose();
    _currentTimeController.dispose();
    _boundaryTimeController.dispose();
    _boundaryFocus.dispose();
    super.dispose();
  }

  void _handlePositionChanged() {
    final nextPosition = widget.playerService.positionNotifier.value;
    if (_currentPosition == nextPosition) return;
    setState(() {
      _currentPosition = nextPosition;
    });
    _updateCurrentTimeField();
  }

  void _updateCurrentTimeField() {
    final value = widget.lyricsService.formatTimestamp(_currentPosition);
    if (_currentTimeController.text == value) return;
    _currentTimeController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _syncEditorFromLines() {
    final text = _lines.map((line) => line.text).join('\n');
    _lyricsTextController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _handleLyricsTextChanged() {
    setState(() {
      _model = _model.reflowText(_lyricsTextController.text);
      if (_selectedLineIndex >= _lines.length) {
        _selectedLineIndex = _lines.length - 1;
      }
      if (_selectedLineIndex < 0) {
        _selectedLineIndex = 0;
      }
      _selectedWordIndex = null;
    });
  }

  int get _stampedLineCount => _model.stampedLineCount;

  int get _usableLineCount => _model.usableLineCount;

  Future<void> _seekBy(Duration delta) async {
    final duration =
        widget.playerService.durationNotifier.value.inMilliseconds > 0
        ? widget.playerService.durationNotifier.value
        : widget.song.duration;
    final next = _currentPosition + delta;
    final clampedMs = next.inMilliseconds.clamp(
      0,
      duration.inMilliseconds > 0
          ? duration.inMilliseconds
          : next.inMilliseconds,
    );
    final target = Duration(milliseconds: clampedMs);
    await widget.playerService.seek(target);
  }

  Future<void> _togglePlayPause() async {
    if (widget.playerService.isPlayingNotifier.value) {
      await widget.playerService.pause();
    } else {
      await widget.playerService.resume();
    }
  }

  void _selectLine(int index) {
    if (index < 0 || index >= _lines.length) return;
    setState(() {
      _selectedLineIndex = index;
      _selectedWordIndex = null;
    });
  }

  void _stampSelectedLine({required bool advance}) {
    if (_selectedLineIndex < 0 || _selectedLineIndex >= _lines.length) return;
    final current = _lines[_selectedLineIndex];
    if (current.text.trim().isEmpty) return;

    setState(() {
      _model = _model.setLineTimestamp(
        _selectedLineIndex,
        _currentPosition,
      );
      if (advance && _selectedLineIndex < _lines.length - 1) {
        _selectedLineIndex += 1;
        _selectedWordIndex = null;
      }
    });
  }

  void _clearSelectedTimestamp() {
    if (_selectedLineIndex < 0 || _selectedLineIndex >= _lines.length) return;
    setState(() {
      _model = _model.setLineTimestamp(_selectedLineIndex, null);
      _selectedWordIndex = null;
    });
  }

  void _shiftAll(Duration delta) {
    setState(() {
      _model = _model.shiftAll(delta);
    });
  }

  void _applyTimestampText(int index, String value) {
    final normalized = value.replaceAll('[', '').replaceAll(']', '').trim();
    if (normalized.isEmpty) {
      setState(() {
        _model = _model.setLineTimestamp(index, null);
      });
      return;
    }

    final parsed = widget.lyricsService.parseTimestamp(normalized);
    if (parsed == null) return;

    setState(() {
      _model = _model.setLineTimestamp(index, parsed);
    });
  }

  EditableLyricLine? get _selectedLine =>
      _selectedLineIndex >= 0 && _selectedLineIndex < _lines.length
      ? _lines[_selectedLineIndex]
      : null;

  void _stampNextWord() {
    final line = _selectedLine;
    if (line == null || line.tokens.isEmpty) return;

    setState(() {
      final (model, stamped) = _model.stampNextWord(
        _selectedLineIndex,
        _currentPosition,
      );
      _model = model;
      if (stamped != null &&
          _autoAdvance &&
          stamped == line.segmentCount - 1 &&
          _selectedLineIndex < _lines.length - 1) {
        _selectedLineIndex += 1;
        _selectedWordIndex = null;
      } else if (stamped != null) {
        _selectedWordIndex = stamped;
      }
    });
  }

  void _undoLastWordStamp() {
    setState(() {
      _model = _model.undoLastWordStamp(_selectedLineIndex);
      _selectedWordIndex = null;
    });
  }

  void _clearWords() {
    setState(() {
      _model = _model.clearWords(_selectedLineIndex);
      _selectedWordIndex = null;
    });
  }

  void _nudgeSelectedWord(Duration delta) {
    final wordIndex = _selectedWordIndex;
    if (wordIndex == null) return;
    setState(() {
      _model = _model.nudgeWord(_selectedLineIndex, wordIndex, delta);
    });
  }

  void _setSelectedWordToNow() {
    final wordIndex = _selectedWordIndex;
    if (wordIndex == null) return;
    setState(() {
      _model = _model.setWord(
        _selectedLineIndex,
        wordIndex,
        _currentPosition,
      );
    });
  }

  void _clearSelectedWord() {
    final wordIndex = _selectedWordIndex;
    if (wordIndex == null) return;
    final starts = _selectedLine?.wordStarts;
    if (starts == null ||
        wordIndex >= starts.length ||
        starts[wordIndex] == null) {
      return;
    }
    setState(() {
      _model = _model.clearWord(_selectedLineIndex, wordIndex);
      _selectedWordIndex = null;
    });
  }

  void _setWordBoundary(int wordIndex, Duration proposed) {
    setState(() {
      _model = _model.setWordBoundary(_selectedLineIndex, wordIndex, proposed);
    });
  }

  void _setLineEndBoundary(Duration proposed) {
    setState(() {
      _model = _model.setLineEndBoundary(_selectedLineIndex, proposed);
    });
  }

  void _autoFillWords() {
    setState(() {
      _model = _model.autoFillWords(_selectedLineIndex);
    });
  }

  void _toggleSegmentBreak(int tokenIndex, int charOffset) {
    setState(() {
      _model = _model.toggleSegmentBreak(
        _selectedLineIndex,
        tokenIndex,
        charOffset,
      );
      _selectSegmentAt(tokenIndex, charOffset);
    });
  }

  /// Points the selection at the segment containing [charOffset] of
  /// [tokenIndex] (the newly created or merged one after a toggle).
  void _selectSegmentAt(int tokenIndex, int charOffset) {
    final layout = _selectedLine?.segmentLayout ?? const [];
    for (var i = 0; i < layout.length; i++) {
      final entry = layout[i];
      if (entry.tokenIndex == tokenIndex &&
          charOffset >= entry.charStart &&
          charOffset < entry.charEnd) {
        _selectedWordIndex = i;
        return;
      }
    }
    _selectedWordIndex = null;
  }

  /// Nudges the selected word's right edge (the next word's start, or the
  /// line end for the final word), stretching or shrinking the word.
  void _nudgeSelectedWordLength(Duration delta) {
    final line = _selectedLine;
    final wordIndex = _selectedWordIndex;
    final starts = line?.wordStarts;
    if (line == null ||
        wordIndex == null ||
        starts == null ||
        wordIndex >= starts.length ||
        starts[wordIndex] == null) {
      return;
    }
    final windows = _model.wordWindows(_selectedLineIndex);
    if (windows == null || wordIndex >= windows.length) return;
    final end = windows[wordIndex].end;
    if (wordIndex + 1 < starts.length) {
      _setWordBoundary(wordIndex + 1, end + delta);
    } else {
      _setLineEndBoundary(end + delta);
    }
  }

  void _setSelectedBoundaryToNow() {
    final wordIndex = _selectedWordIndex;
    if (wordIndex == null) return;
    _setWordBoundary(wordIndex, _currentPosition);
  }

  void _applyBoundaryText(String value) {
    final wordIndex = _selectedWordIndex;
    if (wordIndex == null) return;
    final normalized = value.replaceAll('[', '').replaceAll(']', '').trim();
    final parsed = widget.lyricsService.parseTimestamp(normalized);
    if (parsed == null) {
      _showMessage('Use mm:ss.cc, e.g. 01:23.45');
      return;
    }
    setState(() {
      _model = _model.setWordBoundary(_selectedLineIndex, wordIndex, parsed);
    });
    _boundaryFocus.unfocus();
  }

  /// Keeps the boundary text field mirroring the selected word unless the
  /// user is typing in it.
  void _syncBoundaryTimeField() {
    final line = _selectedLine;
    final wordIndex = _selectedWordIndex;
    final starts = line?.wordStarts;
    if (line == null ||
        wordIndex == null ||
        starts == null ||
        wordIndex >= starts.length ||
        starts[wordIndex] == null) {
      return;
    }
    if (_boundaryFocus.hasFocus) return;
    final text = widget.lyricsService
        .formatTimestamp(starts[wordIndex]!)
        .replaceAll('[', '')
        .replaceAll(']', '');
    if (_boundaryTimeController.text == text) return;
    _boundaryTimeController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  LyricsData? _previewCache;
  LyricsEditorModel? _previewCacheSource;

  /// Memoized so playback position ticks do not rebuild the LyricsData —
  /// a fresh instance every frame made the karaoke preview blink.
  LyricsData? _buildPreviewLyricsData() {
    if (!identical(_previewCacheSource, _model)) {
      _previewCacheSource = _model;
      final normalized = _model.normalizeForSave();
      _previewCache = normalized.isEmpty
          ? null
          : LyricsData(
              lines: normalized,
              isSynchronized: true,
              rawContent: '',
            );
    }
    return _previewCache;
  }

  List<LyricsLine> _buildNormalizedLyricsLines() {
    return _model.normalizeForSave();
  }

  Future<void> _save() async {
    final normalizedLines = _buildNormalizedLyricsLines();
    if (normalizedLines.isEmpty) {
      _showMessage('Add at least one lyric line first.');
      return;
    }

    final lrcContent = widget.lyricsService.buildLrcContent(
      lines: normalizedLines,
      song: widget.song,
      length: widget.song.duration,
    );
    final sidecarPath = widget.lyricsService.suggestSidecarLrcPath(widget.song);

    final choice = await showFlickDialog<String>(
      context: context,
      barrierLabel: 'Save LRC File',
      builder: (ctx) => FlickDialog(
        title: 'Save LRC File',
        content: const Text('Where should the .lrc file be saved?'),
        actions: [
          FlickDialogButton(
            label: 'Choose location\u2026',
            onPressed: () => Navigator.pop(ctx, 'custom'),
          ),
          if (sidecarPath != null)
            FlickDialogButton(
              label: 'Beside the song',
              onPressed: () => Navigator.pop(ctx, 'beside'),
            ),
          FlickDialogButton(
            label: 'Save in Flick',
            style: FlickDialogButtonStyle.primary,
            onPressed: () => Navigator.pop(ctx, 'managed'),
          ),
        ],
      ),
    );

    if (choice == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      late final LyricsSaveResult result;

      if (choice == 'custom') {
        final safeStem = widget.song.title.isNotEmpty
            ? widget.song.title
            : 'lyrics';
        final savePath = await FilePicker.saveFile(
          dialogTitle: 'Save LRC file',
          fileName: '$safeStem.lrc',
          type: FileType.custom,
          allowedExtensions: const ['lrc'],
          bytes: Uint8List.fromList(utf8.encode(lrcContent)),
        );
        if (savePath == null) {
          if (mounted) setState(() => _isSaving = false);
          return;
        }
        result = await widget.lyricsService.saveLyricsToPath(
          song: widget.song,
          content: lrcContent,
          path: savePath,
        );
      } else if (choice == 'managed') {
        result = await widget.lyricsService.saveLyricsToManaged(
          song: widget.song,
          content: lrcContent,
        );
      } else {
        result = await widget.lyricsService.saveLyricsForSong(
          song: widget.song,
          content: lrcContent,
        );
      }

      if (!mounted) return;
      final message = choice == 'custom'
          ? 'Saved lyrics to the chosen location.'
          : result.savedBesideSong
              ? 'Saved lyrics beside the song as an `.lrc` file.'
              : 'Saved lyrics and linked them to this song.';
      Navigator.of(context).pop(
        LyricsEditorResult(
          message: message,
          lyricsData: result.data,
        ),
      );
    } catch (_) {
      _showMessage('Could not save the lyrics file.');
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _showInstructions() async {
    await showFlickDialog<void>(
      context: context,
      barrierLabel: 'Lyrics Sync Help',
      builder: (dialogContext) => FlickDialog(
        title: 'Lyrics Sync Help',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Simple mode',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '1. Paste or type one lyric line per row.\n'
              '2. Play the song.\n'
              '3. Select the current lyric line.\n'
              '4. Tap "Stamp & Next" when you hear that line.\n'
              '5. Save when done.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Word Sync mode (karaoke)',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '1. Pick a lyric line and press play.\n'
              '2. Tap the big "Tap Word" button as you hear each word — the first tap also stamps the line.\n'
              '3. Tap a word chip to nudge, re-time, or clear it.\n'
              '4. Lines with every word stamped save with per-word karaoke timing.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Advanced mode',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '1. Edit timestamps directly for each line.\n'
              '2. Use "Use Current Time" to capture the live playback time.\n'
              '3. In the word timeline, drag a boundary to stretch or shrink the segment before it — edits snap to 10ms.\n'
              '4. Tap letters in the inspector to split a word into separately timed syllables (slow-then-fast pacing), then drag their boundaries.\n'
              '5. Drag the last boundary (or use Length ±) to retime the next line. Use Auto-fill to seed evenly spaced words.\n'
              '6. Use the shift controls to move all stamped lyrics together.\n'
              '7. Save to generate the final `.lrc` file.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Tips',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '- "Use Existing File" links an `.lrc`, `.txt`, or `.xml` file.\n'
              '- If some lines are not stamped, Flick fills their times automatically.\n'
              '- Save writes beside the song when possible, otherwise Flick stores a linked copy.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
          ],
        ),
        actions: [
          FlickDialogButton(
            label: 'Got it',
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncBoundaryTimeField();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Lyrics Sync Studio',
                    style: TextStyle(
                      color: context.adaptiveTextPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.song.title,
                    style: TextStyle(
                      color: context.adaptiveTextSecondary,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
            IconButton(
              onPressed: _isSaving ? null : _showInstructions,
              icon: const Icon(Icons.help_outline_rounded),
              tooltip: 'Instructions',
            ),
          ],
        ),
        const SizedBox(height: AppConstants.spacingMd),
        _buildModePicker(context),
        const SizedBox(height: AppConstants.spacingMd),
        _buildStatusCards(context),
        const SizedBox(height: AppConstants.spacingMd),
        Flexible(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLyricsTextEditor(context),
                const SizedBox(height: AppConstants.spacingMd),
                if (_viewMode == LyricsEditorViewMode.simple)
                  _buildSimpleSyncView(context)
                else if (_viewMode == LyricsEditorViewMode.wordSync)
                  _buildWordSyncView(context)
                else
                  _buildAdvancedSyncView(context),
                const SizedBox(height: AppConstants.spacingMd),
                _buildSaveNotice(context),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppConstants.spacingMd),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: AppConstants.spacingSm),
            Expanded(
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.save),
                label: Text(_isSaving ? 'Saving...' : 'Save LRC'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildModePicker(BuildContext context) {
    String labelFor(LyricsEditorViewMode mode) {
      switch (mode) {
        case LyricsEditorViewMode.simple:
          return 'Simple Mode';
        case LyricsEditorViewMode.wordSync:
          return 'Word Sync';
        case LyricsEditorViewMode.advanced:
          return 'Advanced Mode';
      }
    }

    return Wrap(
      spacing: 8,
      children: LyricsEditorViewMode.values.map((mode) {
        final selected = mode == _viewMode;
        return ChoiceChip(
          selected: selected,
          onSelected: (_) {
            setState(() {
              _viewMode = mode;
            });
          },
          label: Text(labelFor(mode)),
        );
      }).toList(),
    );
  }

  Widget _buildStatusCards(BuildContext context) {
    Widget card(IconData icon, String label, String value) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(AppConstants.spacingSm),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: context.adaptiveTextSecondary),
              const SizedBox(height: 8),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: context.adaptiveTextSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        card(Icons.format_list_bulleted_rounded, 'Lines', '$_usableLineCount'),
        const SizedBox(width: AppConstants.spacingSm),
        card(LucideIcons.clock3, 'Stamped', '$_stampedLineCount'),
        const SizedBox(width: AppConstants.spacingSm),
        card(
          LucideIcons.mic,
          'Words',
          '${_model.capturedWordCount}/${_model.totalWordCount}',
        ),
        const SizedBox(width: AppConstants.spacingSm),
        card(LucideIcons.timer, 'Now', _currentTimeController.text),
      ],
    );
  }

  Widget _buildLyricsTextEditor(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Lyrics Text',
          style: TextStyle(
            color: context.adaptiveTextPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'One line per lyric row. The sync tools below attach timestamps to these lines.',
          style: TextStyle(color: context.adaptiveTextSecondary, fontSize: 12),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _lyricsTextController,
          minLines: 6,
          maxLines: 10,
          decoration: InputDecoration(
            hintText: 'Paste or type the song lyrics here',
            filled: true,
            fillColor: AppColors.surfaceLight,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSimpleSyncView(BuildContext context) {
    final selectedLine =
        _selectedLineIndex >= 0 && _selectedLineIndex < _lines.length
        ? _lines[_selectedLineIndex]
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Sync',
          style: TextStyle(
            color: context.adaptiveTextPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        _buildPlaybackTools(context),
        const SizedBox(height: AppConstants.spacingSm),
        Container(
          padding: const EdgeInsets.all(AppConstants.spacingSm),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: _selectedLineIndex > 0
                        ? () => _selectLine(_selectedLineIndex - 1)
                        : null,
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          'Selected line ${_selectedLineIndex + 1} of ${_lines.length}',
                          style: TextStyle(
                            color: context.adaptiveTextSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          selectedLine?.text.trim().isNotEmpty == true
                              ? selectedLine!.text
                              : 'Pick a lyric line from the list below.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.adaptiveTextPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (selectedLine?.timestamp != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            widget.lyricsService.formatTimestamp(
                              selectedLine!.timestamp!,
                            ),
                            style: TextStyle(
                              color: context.adaptiveTextSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _selectedLineIndex < _lines.length - 1
                        ? () => _selectLine(_selectedLineIndex + 1)
                        : null,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: selectedLine?.text.trim().isNotEmpty == true
                        ? () => _stampSelectedLine(advance: _autoAdvance)
                        : null,
                    icon: const Icon(LucideIcons.clock3),
                    label: Text(_autoAdvance ? 'Stamp & Next' : 'Stamp Now'),
                  ),
                  OutlinedButton.icon(
                    onPressed: selectedLine?.timestamp != null
                        ? _clearSelectedTimestamp
                        : null,
                    icon: const Icon(LucideIcons.eraser),
                    label: const Text('Clear Stamp'),
                  ),
                  FilterChip(
                    selected: _autoAdvance,
                    onSelected: (value) {
                      setState(() {
                        _autoAdvance = value;
                      });
                    },
                    label: const Text('Auto Advance'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppConstants.spacingSm),
        _buildShiftTools(context),
        const SizedBox(height: AppConstants.spacingSm),
        _buildLinePickerList(context, compact: false),
      ],
    );
  }

  Widget _buildWordSyncView(BuildContext context) {
    final line = _selectedLine;
    final tokens = line?.tokens ?? const <String>[];
    final segmentCount = line?.segmentCount ?? tokens.length;
    final starts = line?.wordStarts;
    final nextWordIndex = starts == null || starts.length != segmentCount
        ? 0
        : starts.indexWhere((start) => start == null);
    final captured = line?.capturedWordCount ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Word Sync',
          style: TextStyle(
            color: context.adaptiveTextPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Tap along with the song to stamp each word. Fully stamped lines save with karaoke timing.',
          style: TextStyle(color: context.adaptiveTextSecondary, fontSize: 12),
        ),
        const SizedBox(height: 10),
        _buildPlaybackTools(context),
        const SizedBox(height: AppConstants.spacingSm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppConstants.spacingSm),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: _selectedLineIndex > 0
                        ? () => _selectLine(_selectedLineIndex - 1)
                        : null,
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Line ${_selectedLineIndex + 1} of ${_lines.length}'
                        '  ·  $captured/$segmentCount words',
                        style: TextStyle(
                          color: context.adaptiveTextSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _selectedLineIndex < _lines.length - 1
                        ? () => _selectLine(_selectedLineIndex + 1)
                        : null,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppConstants.spacingXs),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: tokens.isNotEmpty && nextWordIndex >= 0
                      ? _stampNextWord
                      : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  icon: const Icon(LucideIcons.mic),
                  label: Text(
                    tokens.isEmpty
                        ? 'Pick a line with lyrics'
                        : nextWordIndex < 0
                        ? 'All words stamped'
                        : 'Tap: "${line?.segmentLabel(nextWordIndex) ?? tokens[nextWordIndex].trim()}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: captured > 0 ? _undoLastWordStamp : null,
                    icon: const Icon(LucideIcons.undo2, size: 16),
                    label: const Text('Undo'),
                  ),
                  OutlinedButton.icon(
                    onPressed: (line?.hasAnyWords ?? false)
                        ? _clearWords
                        : null,
                    icon: const Icon(LucideIcons.eraser, size: 16),
                    label: const Text('Clear Words'),
                  ),
                  FilterChip(
                    selected: _autoAdvance,
                    onSelected: (value) {
                      setState(() {
                        _autoAdvance = value;
                      });
                    },
                    label: const Text('Auto Advance'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppConstants.spacingSm),
        _buildWordChips(context),
        const SizedBox(height: AppConstants.spacingSm),
        _buildWordNudgeTools(context),
        const SizedBox(height: AppConstants.spacingSm),
        _buildKaraokePreview(context),
        const SizedBox(height: AppConstants.spacingSm),
        _buildLinePickerList(context, compact: true),
      ],
    );
  }

  Widget _buildWordChips(BuildContext context) {
    final line = _selectedLine;
    if (line == null || line.tokens.isEmpty) {
      return const SizedBox.shrink();
    }
    final segmentCount = line.segmentCount;
    var starts = line.wordStarts;
    if (starts == null || starts.length != segmentCount) {
      starts = List<Duration?>.filled(segmentCount, null);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingSm),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < segmentCount; i++)
            _buildWordChip(context, i, line.segmentLabel(i), starts[i]),
        ],
      ),
    );
  }

  Widget _buildWordChip(
    BuildContext context,
    int wordIndex,
    String token,
    Duration? start,
  ) {
    final selected = _selectedWordIndex == wordIndex;
    final captured = start != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        onTap: () {
          setState(() {
            _selectedWordIndex = selected ? null : wordIndex;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.surfaceLight.withValues(alpha: 0.95)
                : AppColors.surfaceDark,
            borderRadius: BorderRadius.circular(AppConstants.radiusSm),
            border: Border.all(
              color: selected
                  ? AppColors.accentDim
                  : captured
                  ? AppColors.glassBorderStrong
                  : AppColors.glassBorder,
            ),
          ),
          child: Column(
            children: [
              Text(
                token.trim(),
                style: TextStyle(
                  color: captured
                      ? context.adaptiveTextPrimary
                      : context.adaptiveTextSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                start == null
                    ? '—'
                    : widget.lyricsService
                          .formatTimestamp(start)
                          .replaceAll('[', '')
                          .replaceAll(']', ''),
                style: TextStyle(
                  color: captured
                      ? context.adaptiveTextSecondary
                      : AppColors.textTertiary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWordNudgeTools(BuildContext context) {
    final wordIndex = _selectedWordIndex;
    if (wordIndex == null) return const SizedBox.shrink();
    final line = _selectedLine;
    final segmentCount = line?.segmentCount ?? 0;
    if (line == null || wordIndex >= segmentCount) {
      return const SizedBox.shrink();
    }

    final starts = _selectedLine?.wordStarts;
    final captured = starts != null &&
        wordIndex < starts.length &&
        starts[wordIndex] != null;

    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingSm),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.accentDim),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Word ${wordIndex + 1} · "${line.segmentLabel(wordIndex)}"',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.adaptiveTextPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: captured
                    ? () => _nudgeSelectedWord(
                        const Duration(milliseconds: -100),
                      )
                    : null,
                child: const Text('-100ms'),
              ),
              OutlinedButton(
                onPressed: captured
                    ? () => _nudgeSelectedWord(const Duration(milliseconds: 100))
                    : null,
                child: const Text('+100ms'),
              ),
              OutlinedButton.icon(
                onPressed: _setSelectedWordToNow,
                icon: const Icon(LucideIcons.clock3, size: 14),
                label: const Text('Set to Now'),
              ),
              OutlinedButton.icon(
                onPressed: captured ? _clearSelectedWord : null,
                icon: const Icon(LucideIcons.eraser, size: 14),
                label: const Text('Clear Word'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKaraokePreview(BuildContext context) {
    final previewData = _buildPreviewLyricsData();
    final previewIndex = _model.indexOfNormalizedLine(_selectedLineIndex);
    if (previewData == null ||
        previewIndex < 0 ||
        previewIndex >= previewData.lines.length) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          Text(
            'Karaoke Preview',
            style: TextStyle(
              color: context.adaptiveTextSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          KaraokeLyricLine(
            key: ValueKey('word-sync-preview-$previewIndex'),
            playerService: widget.playerService,
            lyricsService: widget.lyricsService,
            lyrics: previewData,
            lineIndex: previewIndex,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              height: 1.4,
            ),
            sungColor: AppColors.textPrimary,
            unsungColor: AppColors.textTertiary,
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedSyncView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Advanced Sync',
          style: TextStyle(
            color: context.adaptiveTextPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        _buildPlaybackTools(context),
        const SizedBox(height: AppConstants.spacingSm),
        _buildShiftTools(context),
        const SizedBox(height: AppConstants.spacingSm),
        _buildWordTimelineSection(context),
        const SizedBox(height: AppConstants.spacingSm),
        _buildKaraokePreview(context),
        const SizedBox(height: AppConstants.spacingSm),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _lines.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final line = _lines[index];
            final timestampText = line.timestamp == null
                ? ''
                : widget.lyricsService
                      .formatTimestamp(line.timestamp!)
                      .replaceAll('[', '')
                      .replaceAll(']', '');
            return Container(
              padding: const EdgeInsets.all(AppConstants.spacingSm),
              decoration: BoxDecoration(
                color: index == _selectedLineIndex
                    ? AppColors.surfaceLight.withValues(alpha: 0.95)
                    : AppColors.surfaceDark,
                borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                border: Border.all(
                  color: index == _selectedLineIndex
                      ? AppColors.accentDim
                      : AppColors.glassBorder,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Line ${index + 1}',
                        style: TextStyle(
                          color: context.adaptiveTextSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          _selectLine(index);
                          _stampSelectedLine(advance: false);
                        },
                        icon: const Icon(LucideIcons.clock3, size: 14),
                        label: const Text('Use Current Time'),
                      ),
                    ],
                  ),
                  Text(
                    line.text.isEmpty ? '(Empty line)' : line.text,
                    style: TextStyle(
                      color: context.adaptiveTextPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: timestampText,
                    onTap: () => _selectLine(index),
                    onChanged: (value) => _applyTimestampText(index, value),
                    decoration: InputDecoration(
                      labelText: 'Timestamp',
                      hintText: '00:12.34',
                      filled: true,
                      fillColor: AppColors.surfaceLight,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusMd,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildWordTimelineSection(BuildContext context) {
    final line = _selectedLine;
    if (line == null || line.tokens.isEmpty) return const SizedBox.shrink();

    Widget hint(String message) => Text(
      message,
      style: TextStyle(color: context.adaptiveTextSecondary, fontSize: 12),
    );

    final windows = _model.wordWindows(_selectedLineIndex);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingSm),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Word Timeline · Line ${_selectedLineIndex + 1}',
                  style: TextStyle(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (line.timestamp != null && !line.hasAnyWords)
                TextButton.icon(
                  onPressed: _autoFillWords,
                  icon: const Icon(LucideIcons.wand2, size: 14),
                  label: const Text('Auto-fill'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (line.timestamp == null)
            hint('Stamp this line first to edit its word timeline.')
          else if (!line.hasAnyWords)
            hint(
              'No word timing yet. Auto-fill spreads the words evenly as a '
              'starting point — or capture them in Word Sync mode.',
            )
          else if (!line.hasCompleteWords)
            hint('Some words are still untimed. Finish capturing in Word Sync mode.')
          else if (windows != null) ...[
            Text(
              'Drag a boundary to stretch or shrink the word before it. The '
              'last boundary moves the next line.',
              style: TextStyle(
                color: context.adaptiveTextSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            WordTimeline(
              segmentTexts: [
                for (var i = 0; i < line.segmentLayout.length; i++)
                  line.segmentLabel(i),
              ],
              tokenIndexPerSegment: [
                for (final entry in line.segmentLayout) entry.tokenIndex,
              ],
              windows: windows,
              selectedWordIndex: _selectedWordIndex,
              playhead: _currentPosition,
              lineEndDraggable: _model.isLineEndDraggable(
                _selectedLineIndex,
              ),
              onSelectWord: (index) {
                setState(() {
                  _selectedWordIndex = _selectedWordIndex == index
                      ? null
                      : index;
                });
              },
              onBoundaryChanged: _setWordBoundary,
              onLineEndChanged: _setLineEndBoundary,
              formatTime: (time) => widget.lyricsService
                  .formatTimestamp(time)
                  .replaceAll('[', '')
                  .replaceAll(']', ''),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _buildTimelineInspector(context),
          ],
        ],
      ),
    );
  }

  Widget _buildTimelineInspector(BuildContext context) {
    final line = _selectedLine;
    final wordIndex = _selectedWordIndex;
    final starts = line?.wordStarts;
    if (line == null ||
        wordIndex == null ||
        starts == null ||
        wordIndex >= starts.length ||
        starts[wordIndex] == null) {
      return const SizedBox.shrink();
    }
    final layout = line.segmentLayout;
    if (wordIndex >= layout.length) return const SizedBox.shrink();

    final token = line.segmentLabel(wordIndex);
    final windows = _model.wordWindows(_selectedLineIndex);
    final start = starts[wordIndex]!;
    final end = windows != null && wordIndex < windows.length
        ? windows[wordIndex].end
        : start;
    final lengthMs = (end - start).inMilliseconds;

    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingSm),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.accentDim),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Word ${wordIndex + 1} · "$token"',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.adaptiveTextPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Length ${(lengthMs / 1000).toStringAsFixed(2)}s',
                      style: TextStyle(
                        color: context.adaptiveTextSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppConstants.spacingSm),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _boundaryTimeController,
                  focusNode: _boundaryFocus,
                  onSubmitted: _applyBoundaryText,
                  decoration: InputDecoration(
                    labelText: 'Start',
                    hintText: '00:12.34',
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppConstants.radiusMd,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Length:',
                style: TextStyle(
                  color: context.adaptiveTextSecondary,
                  fontSize: 12,
                ),
              ),
              OutlinedButton(
                onPressed: () => _nudgeSelectedWordLength(
                  const Duration(milliseconds: -100),
                ),
                child: const Text('-100ms'),
              ),
              OutlinedButton(
                onPressed: () => _nudgeSelectedWordLength(
                  const Duration(milliseconds: -10),
                ),
                child: const Text('-10ms'),
              ),
              OutlinedButton(
                onPressed: () => _nudgeSelectedWordLength(
                  const Duration(milliseconds: 10),
                ),
                child: const Text('+10ms'),
              ),
              OutlinedButton(
                onPressed: () => _nudgeSelectedWordLength(
                  const Duration(milliseconds: 100),
                ),
                child: const Text('+100ms'),
              ),
              OutlinedButton.icon(
                onPressed: _setSelectedBoundaryToNow,
                icon: const Icon(LucideIcons.clock3, size: 14),
                label: const Text('Start at Now'),
              ),
            ],
          ),
          _buildSplitRow(context, line, wordIndex),
        ],
      ),
    );
  }

  /// Tap-a-letter syllable splitter for the selected segment's token:
  /// tapping a letter toggles the segment boundary before it, so a word
  /// can sweep slow-then-fast across its syllables.
  Widget _buildSplitRow(
    BuildContext context,
    EditableLyricLine line,
    int segmentIndex,
  ) {
    final layout = line.segmentLayout;
    if (segmentIndex < 0 || segmentIndex >= layout.length) {
      return const SizedBox.shrink();
    }
    final tokenIndex = layout[segmentIndex].tokenIndex;
    final core = line.tokens[tokenIndex].trim();
    if (core.length < 2) return const SizedBox.shrink();

    final breaks = line.segmentBreaks;
    final tokenBreaks = breaks != null && tokenIndex < breaks.length
        ? breaks[tokenIndex]
        : const <int>[];
    final selected = layout[segmentIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 20),
        Text(
          'Syllables — tap a letter to split or merge:',
          style: TextStyle(color: context.adaptiveTextSecondary, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 0,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var c = 0; c < core.length; c++) ...[
              if (tokenBreaks.contains(c))
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Container(
                    width: 2,
                    height: 18,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: c == 0
                    ? null
                    : () => _toggleSegmentBreak(tokenIndex, c),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: c >= selected.charStart && c < selected.charEnd
                          ? AppColors.accentDim
                          : Colors.transparent,
                    ),
                  ),
                  child: Text(
                    core[c],
                    style: TextStyle(
                      color: context.adaptiveTextPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildPlaybackTools(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingSm),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Playback Assist',
            style: TextStyle(
              color: context.adaptiveTextPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => _seekBy(const Duration(seconds: -2)),
                child: const Text('-2s'),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: widget.playerService.isPlayingNotifier,
                builder: (context, isPlaying, _) {
                  return FilledButton.icon(
                    onPressed: _togglePlayPause,
                    icon: Icon(
                      isPlaying ? LucideIcons.pause : LucideIcons.play,
                    ),
                    label: Text(isPlaying ? 'Pause' : 'Play'),
                  );
                },
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _seekBy(const Duration(seconds: 2)),
                child: const Text('+2s'),
              ),
              const Spacer(),
              SizedBox(
                width: 108,
                child: TextField(
                  controller: _currentTimeController,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: 'Now',
                    filled: true,
                    fillColor: AppColors.surfaceDark,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppConstants.radiusMd,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildShiftTools(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingSm),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Time Shift',
            style: TextStyle(
              color: context.adaptiveTextPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Move every stamped lyric forward or backward together.',
            style: TextStyle(
              color: context.adaptiveTextSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _shiftAll(const Duration(milliseconds: -500)),
                child: const Text('-500ms'),
              ),
              OutlinedButton(
                onPressed: () => _shiftAll(const Duration(milliseconds: -100)),
                child: const Text('-100ms'),
              ),
              OutlinedButton(
                onPressed: () => _shiftAll(const Duration(milliseconds: 100)),
                child: const Text('+100ms'),
              ),
              OutlinedButton(
                onPressed: () => _shiftAll(const Duration(milliseconds: 500)),
                child: const Text('+500ms'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLinePickerList(BuildContext context, {required bool compact}) {
    return Container(
      constraints: BoxConstraints(maxHeight: compact ? 200 : 280),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _lines.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: AppColors.glassBorder),
        itemBuilder: (context, index) {
          final line = _lines[index];
          final selected = index == _selectedLineIndex;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _selectLine(index),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppConstants.spacingSm,
                  vertical: AppConstants.spacingSm,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.accent
                            : AppColors.surfaceDark,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          color: selected
                              ? AppColors.surface
                              : context.adaptiveTextSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                     const SizedBox(width: 10),
                     Expanded(
                       child: Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           Text(
                             line.text.isEmpty ? '(Empty line)' : line.text,
                             maxLines: compact ? 1 : 2,
                             overflow: TextOverflow.ellipsis,
                             style: TextStyle(
                               color: context.adaptiveTextPrimary,
                               fontWeight: selected
                                   ? FontWeight.w700
                                   : FontWeight.w500,
                             ),
                           ),
                           const SizedBox(height: 2),
                           Text(
                             line.timestamp == null
                                 ? 'Not stamped yet'
                                 : widget.lyricsService.formatTimestamp(
                                     line.timestamp!,
                                   ),
                             style: TextStyle(
                               color: context.adaptiveTextSecondary,
                               fontSize: 12,
                             ),
                           ),
                         ],
                       ),
                     ),
                     if (line.hasAnyWords)
                       Padding(
                         padding: const EdgeInsets.only(left: 8),
                         child: Icon(
                           LucideIcons.mic,
                           size: 14,
                           color: line.hasCompleteWords
                               ? AppColors.accentDim
                               : AppColors.textTertiary,
                         ),
                       ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSaveNotice(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingSm),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            LucideIcons.badgeInfo,
            size: 16,
            color: context.adaptiveTextSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Save creates an `.lrc` file. If some lines are not stamped yet, Flick fills their times automatically so the file stays usable. Lines with fully stamped words export with per-word karaoke timing.',
              style: TextStyle(
                color: context.adaptiveTextSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<String?> readTextFromPickedLyricsFile(PlatformFile file) async {
  if (file.bytes != null) {
    return _decodeLyricsBytes(file.bytes!);
  }

  final path = file.path;
  if (path == null || path.isEmpty) return null;
  final diskFile = File(path);
  if (!await diskFile.exists()) return null;
  final bytes = await diskFile.readAsBytes();
  return _decodeLyricsBytes(bytes);
}

String? _decodeLyricsBytes(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    try {
      return latin1.decode(bytes);
    } catch (_) {
      return null;
    }
  }
}
