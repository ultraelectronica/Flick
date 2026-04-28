import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flick/models/song.dart';

/// A single lyric line, optionally timestamped for synchronized display.
class LyricsLine {
  final Duration timestamp;
  final String text;

  const LyricsLine({required this.timestamp, required this.text});
}

/// Parsed lyrics payload.
class LyricsData {
  final List<LyricsLine> lines;
  final bool isSynchronized;
  final String? source;

  const LyricsData({
    required this.lines,
    required this.isSynchronized,
    this.source,
  });
}

class LyricsService {
  static const MethodChannel _storageChannel = MethodChannel(
    'com.ultraelectronica.flick/storage',
  );

  final Map<String, LyricsData?> _cache = {};

  Future<LyricsData?> loadLyricsForSong(Song song) async {
    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) return null;

    if (_cache.containsKey(filePath)) {
      return _cache[filePath];
    }

    final embedded = await _loadEmbeddedLyricsText(filePath);
    if (embedded != null && embedded.content.trim().isNotEmpty) {
      final parsed = _parseLyrics(embedded.content, source: embedded.source);
      _cache[filePath] = parsed;
      return parsed;
    }

    final loaded = await _loadLyricsText(filePath);
    if (loaded == null || loaded.content.trim().isEmpty) {
      _cache[filePath] = null;
      return null;
    }

    final parsed = _parseLyrics(loaded.content, source: loaded.source);
    _cache[filePath] = parsed;
    return parsed;
  }

  int findCurrentLineIndex(LyricsData lyrics, Duration position) {
    if (!lyrics.isSynchronized || lyrics.lines.isEmpty) return -1;

    final targetMs = position.inMilliseconds;
    int left = 0;
    int right = lyrics.lines.length - 1;
    int result = -1;

    while (left <= right) {
      final mid = left + ((right - left) ~/ 2);
      final lineMs = lyrics.lines[mid].timestamp.inMilliseconds;
      if (lineMs <= targetMs) {
        result = mid;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    return result;
  }

  Future<_LoadedLyrics?> _loadEmbeddedLyricsText(String filePath) async {
    try {
      final result = await _storageChannel.invokeMapMethod<String, dynamic>(
        'readEmbeddedLyrics',
        {'audioUri': filePath},
      );
      final content = result?['content'] as String?;
      if (content != null && content.trim().isNotEmpty) {
        return _LoadedLyrics(
          content: content,
          source: result?['source'] as String? ?? 'embedded',
        );
      }
    } catch (_) {
      // Best-effort lookup. Fall back to sidecar lookup.
    }
    return null;
  }

  Future<_LoadedLyrics?> _loadLyricsText(String filePath) async {
    final parsedUri = Uri.tryParse(filePath);
    final isAndroidContentUri =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        parsedUri?.scheme == 'content';

    if (isAndroidContentUri) {
      try {
        final result = await _storageChannel.invokeMapMethod<String, dynamic>(
          'readSiblingLyrics',
          {'audioUri': filePath},
        );
        final content = result?['content'] as String?;
        if (content != null && content.trim().isNotEmpty) {
          return _LoadedLyrics(
            content: content,
            source: result?['name'] as String? ?? result?['uri'] as String?,
          );
        }
      } catch (_) {
        // Best-effort only. Fall back to local path resolution.
      }
    }

    final localPath = _resolveLocalPath(filePath);
    if (localPath == null || localPath.isEmpty) return null;

    final audioFile = File(localPath);
    final parent = audioFile.parent;
    final stem = _basenameWithoutExtension(audioFile.path);
    final sep = Platform.pathSeparator;

    final candidates = <String>[
      '${parent.path}$sep$stem.lrc',
      '${parent.path}$sep$stem.txt',
      '${parent.path}$sep$stem.xml',
      '${parent.path}$sep$stem.LRC',
      '${parent.path}$sep$stem.TXT',
      '${parent.path}$sep$stem.XML',
    ];

    for (final candidatePath in candidates) {
      final file = File(candidatePath);
      if (!await file.exists()) continue;

      final content = await _readTextFile(file);
      if (content != null && content.trim().isNotEmpty) {
        return _LoadedLyrics(content: content, source: file.path);
      }
    }

    return null;
  }

  String? _resolveLocalPath(String filePath) {
    if (RegExp(r'^[a-zA-Z]:\\').hasMatch(filePath)) {
      return filePath;
    }

    final parsed = Uri.tryParse(filePath);
    if (parsed != null && parsed.scheme == 'file') {
      return parsed.toFilePath();
    }

    if (parsed != null && parsed.scheme.isNotEmpty) {
      return null;
    }

    return filePath;
  }

  String _basenameWithoutExtension(String path) {
    final normalized = path.replaceAll('\\', '/');
    final filename = normalized.split('/').last;
    final dotIndex = filename.lastIndexOf('.');
    if (dotIndex <= 0) return filename;
    return filename.substring(0, dotIndex);
  }

  Future<String?> _readTextFile(File file) async {
    try {
      return await file.readAsString();
    } catch (_) {
      try {
        return await file.readAsString(encoding: latin1);
      } catch (_) {
        return null;
      }
    }
  }

  LyricsData _parseLyrics(String raw, {String? source}) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('<?xml') || trimmed.startsWith('<')) {
      final xmlData = _parseXmlLyrics(trimmed, source: source);
      if (xmlData != null) return xmlData;
    }

    final normalized = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceFirst(RegExp(r'^\uFEFF'), '');
    final rows = normalized.split('\n');

    final timestampPattern = RegExp(r'\[(\d{1,2}:\d{2}(?:[.:]\d{1,3})?)\]');
    final offsetPattern = RegExp(
      r'^\s*\[offset:([+-]?\d+)\]\s*$',
      caseSensitive: false,
    );
    final metadataPattern = RegExp(r'^\s*\[[a-zA-Z]+:.*\]\s*$');

    var offsetMs = 0;
    var hasTimestamps = false;
    final parsedLines = <LyricsLine>[];

    for (final row in rows) {
      final line = row.trimRight();
      if (line.trim().isEmpty) continue;

      final offsetMatch = offsetPattern.firstMatch(line);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1) ?? '') ?? offsetMs;
        continue;
      }

      final matches = timestampPattern.allMatches(line).toList();
      if (matches.isNotEmpty) {
        hasTimestamps = true;
        final lyricText = line.replaceAll(timestampPattern, '').trim();
        for (final match in matches) {
          final parsedTime = _parseTimestamp(match.group(1) ?? '');
          if (parsedTime == null) continue;

          final adjustedMs = parsedTime.inMilliseconds + offsetMs;
          final clamped = Duration(
            milliseconds: adjustedMs < 0 ? 0 : adjustedMs,
          );
          if (lyricText.isEmpty) continue;
          parsedLines.add(LyricsLine(timestamp: clamped, text: lyricText));
        }
        continue;
      }

      if (metadataPattern.hasMatch(line)) {
        continue;
      }

      parsedLines.add(LyricsLine(timestamp: Duration.zero, text: line.trim()));
    }

    if (hasTimestamps) {
      parsedLines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return LyricsData(
        lines: parsedLines,
        isSynchronized: true,
        source: source,
      );
    }

    return LyricsData(
      lines: parsedLines.where((line) => line.text.isNotEmpty).toList(),
      isSynchronized: false,
      source: source,
    );
  }

  LyricsData? _parseXmlLyrics(String xml, {String? source}) {
    try {
      final linePattern = RegExp(
        r'<line\s+start="(\d+)"\s*>([^<]*)</line>',
        caseSensitive: false,
      );
      final altPattern = RegExp(
        r'<line\s+start="(\d{1,2}):(\d{2})\.(\d{2})"\s*>([^<]*)</line>',
        caseSensitive: false,
      );

      final lines = <LyricsLine>[];
      var hasTimestamps = false;

      for (final match in linePattern.allMatches(xml)) {
        hasTimestamps = true;
        final ms = int.tryParse(match.group(1) ?? '') ?? 0;
        final text = match.group(2)?.trim() ?? '';
        if (text.isNotEmpty) {
          lines.add(LyricsLine(timestamp: Duration(milliseconds: ms), text: text));
        }
      }

      if (lines.isEmpty) {
        for (final match in altPattern.allMatches(xml)) {
          hasTimestamps = true;
          final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
          final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
          final centis = int.tryParse(match.group(3) ?? '0') ?? 0;
          final ms = (minutes * 60 + seconds) * 1000 + centis * 10;
          final text = match.group(4)?.trim() ?? '';
          if (text.isNotEmpty) {
            lines.add(LyricsLine(timestamp: Duration(milliseconds: ms), text: text));
          }
        }
      }

      if (lines.isNotEmpty) {
        lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return LyricsData(lines: lines, isSynchronized: hasTimestamps, source: source);
      }
    } catch (_) {
      // Fall through to plain-text parser
    }
    return null;
  }

  Duration? _parseTimestamp(String timestamp) {
    final match = RegExp(
      r'^(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?$',
    ).firstMatch(timestamp.trim());
    if (match == null) return null;

    final minutes = int.tryParse(match.group(1) ?? '');
    final seconds = int.tryParse(match.group(2) ?? '');
    if (minutes == null || seconds == null) return null;

    final fractionRaw = match.group(3);
    var millis = 0;
    if (fractionRaw != null && fractionRaw.isNotEmpty) {
      if (fractionRaw.length == 1) {
        millis = int.parse(fractionRaw) * 100;
      } else if (fractionRaw.length == 2) {
        millis = int.parse(fractionRaw) * 10;
      } else {
        millis = int.parse(fractionRaw.substring(0, 3));
      }
    }

    return Duration(minutes: minutes, seconds: seconds, milliseconds: millis);
  }
}

class _LoadedLyrics {
  final String content;
  final String? source;

  const _LoadedLyrics({required this.content, this.source});
}
