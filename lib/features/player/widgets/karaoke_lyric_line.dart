import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/player_service.dart';

/// Renders a single lyric line as karaoke-style text: a soft highlight
/// sweeps through the words in reading order based on playback position.
/// Real enhanced-LRC word timings drive the sweep; plain synced lines fall
/// back to a single whole-line window.
///
/// The widget subscribes to [PlayerService.positionNotifier] and
/// extrapolates between engine ticks with a frame ticker, so the sweep stays
/// smooth even when position updates arrive infrequently.
class KaraokeLyricLine extends StatefulWidget {
  final PlayerService playerService;
  final LyricsService lyricsService;
  final LyricsData lyrics;
  final int lineIndex;
  final TextAlign textAlign;
  final TextStyle style;
  final Color sungColor;
  final Color unsungColor;

  const KaraokeLyricLine({
    super.key,
    required this.playerService,
    required this.lyricsService,
    required this.lyrics,
    required this.lineIndex,
    required this.textAlign,
    required this.style,
    required this.sungColor,
    required this.unsungColor,
  });

  @override
  State<KaraokeLyricLine> createState() => _KaraokeLyricLineState();
}

class _KaraokeLyricLineState extends State<KaraokeLyricLine>
    with SingleTickerProviderStateMixin {
  static const double _fillEpsilon = 0.0004;

  late List<LyricsWord> _segments;
  Duration _basePosition = Duration.zero;
  Duration _tickerElapsed = Duration.zero;
  Duration _baseTickerElapsed = Duration.zero;
  bool _isPlaying = false;
  Ticker? _ticker;
  List<double> _lastFills = const [];
  int _builtForLineIndex = -1;
  LyricsData? _builtForLyrics;

  @override
  void initState() {
    super.initState();
    _basePosition = widget.playerService.positionNotifier.value;
    _isPlaying = widget.playerService.isPlayingNotifier.value;
    widget.playerService.positionNotifier.addListener(_onPositionTick);
    widget.playerService.isPlayingNotifier.addListener(_onPlayingChanged);
    _resolveWords();
    _updateTicker();
  }

  @override
  void didUpdateWidget(covariant KaraokeLyricLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lyrics, widget.lyrics) ||
        oldWidget.lineIndex != widget.lineIndex) {
      _resolveWords();
      _onPositionTick();
      return;
    }
    _updateTicker();
  }

  void _resolveWords() {
    _segments = [
      for (final word
          in widget.lyricsService.resolveWords(widget.lyrics, widget.lineIndex))
        ...LyricsService.splitKaraokeWord(word),
    ];
    _builtForLineIndex = widget.lineIndex;
    _builtForLyrics = widget.lyrics;
    _lastFills = const [];
  }

  void _onPositionTick() {
    _basePosition = widget.playerService.positionNotifier.value;
    _baseTickerElapsed = _tickerElapsed;
    _updateTicker();
  }

  void _onPlayingChanged() {
    // Freeze extrapolation at the exact current predicted position so
    // pausing does not jump the fill forward.
    _basePosition = _predictedPosition();
    _baseTickerElapsed = _tickerElapsed;
    _isPlaying = widget.playerService.isPlayingNotifier.value;
    _updateTicker();
  }

  void _updateTicker() {
    final shouldRun = _isPlaying && _segments.isNotEmpty && mounted;
    if (shouldRun && _ticker == null) {
      _tickerElapsed = Duration.zero;
      _baseTickerElapsed = Duration.zero;
      _ticker = createTicker(_onFrame);
      _ticker!.start();
    } else if (!shouldRun && _ticker != null) {
      _ticker!.dispose();
      _ticker = null;
      _rebuildIfFillsChanged();
    }
  }

  Duration _predictedPosition() {
    if (!_isPlaying) return _basePosition;
    final ahead = _tickerElapsed - _baseTickerElapsed;
    if (ahead < Duration.zero) return _basePosition;
    return _basePosition + ahead;
  }

  void _onFrame(Duration elapsed) {
    _tickerElapsed = elapsed;
    _rebuildIfFillsChanged();
  }

  void _rebuildIfFillsChanged() {
    if (_segments.isEmpty || !mounted) return;

    final position = _predictedPosition();
    final nextFills = <double>[
      for (final segment in _segments)
        LyricsService.fillForWord(segment, position),
    ];

    final previous = _lastFills;
    var changed = previous.length != nextFills.length;
    if (!changed) {
      for (var i = 0; i < nextFills.length; i++) {
        if ((previous[i] - nextFills[i]).abs() > _fillEpsilon) {
          changed = true;
          break;
        }
      }
    }
    if (!changed) return;

    setState(() => _lastFills = nextFills);
  }

  WrapAlignment get _wrapAlignment {
    switch (widget.textAlign) {
      case TextAlign.left:
        return WrapAlignment.start;
      case TextAlign.right:
        return WrapAlignment.end;
      default:
        return WrapAlignment.center;
    }
  }

  Widget _buildWord(LyricsWord word, double fill) {
    final clamped = fill.clamp(0.0, 1.0);
    final durationMs = word.end.inMilliseconds - word.start.inMilliseconds;
    final edgeStart = clamped >= 1.0 || durationMs <= 0
        ? clamped
        : (clamped - 80 / durationMs).clamp(0.0, 1.0);

    return ShaderMask(
      shaderCallback: (rect) {
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [widget.sungColor, widget.unsungColor],
          stops: [edgeStart, clamped],
        ).createShader(rect);
      },
      child: Text(word.text, style: widget.style),
    );
  }

  @override
  void dispose() {
    _ticker?.dispose();
    widget.playerService.positionNotifier.removeListener(_onPositionTick);
    widget.playerService.isPlayingNotifier.removeListener(_onPlayingChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_builtForLineIndex != widget.lineIndex ||
        !identical(_builtForLyrics, widget.lyrics)) {
      _resolveWords();
    }

    if (_segments.isEmpty) {
      return Text(
        widget.lyrics.lines[widget.lineIndex].text,
        textAlign: widget.textAlign,
        style: widget.style,
      );
    }

    final fills = _lastFills.isEmpty
        ? List<double>.filled(_segments.length, 0.0)
        : _lastFills;

    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: _wrapAlignment,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < _segments.length; i++)
            _buildWord(_segments[i], i < fills.length ? fills[i] : 0.0),
        ],
      ),
    );
  }
}
