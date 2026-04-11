import 'package:flutter_test/flutter_test.dart';

import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/services/eq_preset_file_service.dart';
import 'package:flick/services/eq_preset_service.dart';

void main() {
  const service = EqPresetFileService();

  test('parses TXT equalizer presets', () {
    const text = '''
Preamp: -6.0 dB
Filter 1: ON PK Fc 24 Hz Gain -0.8 dB Q 1.100
Filter 2: ON PK Fc 190 Hz Gain -2.8 dB Q 0.500
Filter 3: ON PK Fc 1500 Hz Gain -1.7 dB Q 1.600
Filter 4: ON PK Fc 2700 Hz Gain 1.8 dB Q 2.000
Filter 5: ON PK Fc 3800 Hz Gain 5.6 dB Q 0.900
Filter 6: ON PK Fc 5000 Hz Gain -1.4 dB Q 0.500
Filter 7: ON PK Fc 13000 Hz Gain -3.0 dB Q 2.000
Filter 8: ON PK Fc 15000 Hz Gain 2.9 dB Q 0.500
Filter 9: ON PK Fc 15000 Hz Gain 4.4 dB Q 2.000
''';

    final preset = service.fromFileText(text: text, fileName: 'My Import.txt');

    expect(preset.name, 'My Import');
    expect(preset.mode, EqMode.parametric);
    expect(preset.preampDb, -6.0);
    expect(preset.parametricBands, hasLength(9));
    expect(preset.parametricBands.first.frequencyHz, 24.0);
    expect(preset.parametricBands.first.gainDb, -0.8);
    expect(preset.parametricBands.first.q, 1.1);
  });

  test('exports TXT equalizer presets', () {
    final preset = EqPreset(
      id: 'test',
      name: 'Example',
      enabled: true,
      mode: EqMode.parametric,
      preampDb: -6.0,
      graphicGainsDb: List<double>.filled(10, 0.0, growable: false),
      parametricBands: const [
        ParametricBand(frequencyHz: 24, gainDb: -0.8, q: 1.1),
        ParametricBand(frequencyHz: 190, gainDb: -2.8, q: 0.5),
      ],
    );

    final text = service.toTxtText(preset);

    expect(text, contains('Preamp: -6.0 dB'));
    expect(text, contains('Filter 1: ON PK Fc 24 Hz Gain -0.8 dB Q 1.100'));
    expect(text, contains('Filter 2: ON PK Fc 190 Hz Gain -2.8 dB Q 0.500'));
  });
}
