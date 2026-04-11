import 'dart:convert';

import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/services/eq_preset_service.dart';

class EqPresetFileService {
  static final JsonEncoder _jsonEncoder = const JsonEncoder.withIndent('  ');

  static const Map<ParametricBandType, String> _bandTypeCodes = {
    ParametricBandType.peaking: 'PK',
    ParametricBandType.lowShelf: 'LS',
    ParametricBandType.highShelf: 'HS',
    ParametricBandType.lowPass: 'LP',
    ParametricBandType.highPass: 'HP',
    ParametricBandType.bandPass: 'BP',
    ParametricBandType.notch: 'NO',
    ParametricBandType.allPass: 'AP',
  };

  static final Map<String, ParametricBandType> _codeToBandType = {
    for (final entry in _bandTypeCodes.entries) entry.value: entry.key,
  };

  static final RegExp _preampLinePattern = RegExp(
    r'^Preamp:\s*([+-]?\d+(?:\.\d+)?)\s*dB$',
    caseSensitive: false,
  );

  static final RegExp _filterLinePattern = RegExp(
    r'^Filter\s+(\d+):\s+(ON|OFF)\s+([A-Za-z]+)\s+Fc\s+([+-]?\d+(?:\.\d+)?)\s+Hz(?:\s+Gain\s+([+-]?\d+(?:\.\d+)?)\s+dB)?\s+Q\s+([+-]?\d+(?:\.\d+)?)$',
    caseSensitive: false,
  );

  const EqPresetFileService();

  String toJsonText(EqPreset preset) => _jsonEncoder.convert(preset.toJson());

  String toTxtText(EqPreset preset) {
    final buffer = StringBuffer()
      ..writeln('Preamp: ${preset.preampDb.toStringAsFixed(1)} dB');

    final bands = preset.mode == EqMode.parametric
        ? preset.parametricBands
        : _graphicBandsAsParametric(preset.graphicGainsDb);

    for (var i = 0; i < bands.length; i++) {
      final band = bands[i];
      final typeCode = _bandTypeCodes[band.type] ?? 'PK';
      final gainSegment = band.type.supportsGain
          ? ' Gain ${band.gainDb.toStringAsFixed(1)} dB'
          : '';
      buffer.writeln(
        'Filter ${i + 1}: ${band.enabled ? 'ON' : 'OFF'} '
        '$typeCode Fc ${_formatHz(band.frequencyHz)} Hz'
        '$gainSegment Q ${band.q.toStringAsFixed(3)}',
      );
    }

    return buffer.toString().trimRight();
  }

  EqPreset fromFileText({required String text, required String fileName}) {
    final normalizedName = _baseNameWithoutExtension(fileName).trim();
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{')) {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('Expected a JSON object.');
      }
      final preset = EqPreset.fromJson(decoded.cast<String, dynamic>());
      return preset.copyWith(
        name: preset.name.trim().isEmpty ? normalizedName : preset.name,
      );
    }

    return _parseTxt(text: text, fileName: normalizedName);
  }

  EqPreset _parseTxt({required String text, required String fileName}) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);

    if (lines.isEmpty) {
      throw const FormatException('Preset file is empty.');
    }

    double preampDb = 0.0;
    var lineIndex = 0;
    final preampMatch = _preampLinePattern.firstMatch(lines.first);
    if (preampMatch != null) {
      preampDb = double.parse(preampMatch.group(1)!);
      lineIndex = 1;
    }

    final bands = <ParametricBand>[];
    for (var i = lineIndex; i < lines.length; i++) {
      final line = lines[i];
      final match = _filterLinePattern.firstMatch(line);
      if (match == null) {
        throw FormatException('Invalid filter line: $line');
      }

      final typeCode = match.group(3)!.toUpperCase();
      final type = _codeToBandType[typeCode];
      if (type == null) {
        throw FormatException('Unsupported filter type: $typeCode');
      }

      final gainMatch = match.group(5);
      bands.add(
        ParametricBand(
          enabled: match.group(2)!.toUpperCase() == 'ON',
          frequencyHz: _clampFrequency(double.parse(match.group(4)!)),
          gainDb: type.supportsGain && gainMatch != null
              ? _clampGain(double.parse(gainMatch))
              : 0.0,
          q: _clampQ(double.parse(match.group(6)!)),
          type: type,
        ),
      );
    }

    if (bands.isEmpty) {
      throw const FormatException('No filters found in preset file.');
    }

    return EqPreset(
      id: '',
      name: fileName.isEmpty ? 'Imported Preset' : fileName,
      enabled: true,
      mode: EqMode.parametric,
      preampDb: preampDb,
      graphicGainsDb: List<double>.filled(10, 0.0, growable: false),
      parametricBands: List<ParametricBand>.unmodifiable(bands),
    );
  }

  List<ParametricBand> _graphicBandsAsParametric(List<double> gainsDb) {
    final frequencies = EqualizerState.defaultGraphicFrequenciesHz;
    return List<ParametricBand>.generate(
      gainsDb.length,
      (index) => ParametricBand(
        enabled: gainsDb[index].abs() >= 0.01,
        frequencyHz: frequencies[index],
        gainDb: _clampGain(gainsDb[index]),
        q: 1.0,
      ),
      growable: false,
    );
  }

  static String _baseNameWithoutExtension(String fileName) {
    final slashIndex = fileName.lastIndexOf(RegExp(r'[/\\]'));
    final base = slashIndex >= 0
        ? fileName.substring(slashIndex + 1)
        : fileName;
    final dotIndex = base.lastIndexOf('.');
    return dotIndex > 0 ? base.substring(0, dotIndex) : base;
  }

  static String _formatHz(double hz) {
    final rounded = hz.roundToDouble();
    if ((hz - rounded).abs() < 0.001) {
      return rounded.toStringAsFixed(0);
    }
    return hz.toStringAsFixed(1);
  }

  static double _clampFrequency(double value) {
    return value.clamp(20.0, 20000.0).toDouble();
  }

  static double _clampGain(double value) {
    return value
        .clamp(EqualizerNotifier.gainMinDb, EqualizerNotifier.gainMaxDb)
        .toDouble();
  }

  static double _clampQ(double value) {
    return value.clamp(0.2, 10.0).toDouble();
  }
}
