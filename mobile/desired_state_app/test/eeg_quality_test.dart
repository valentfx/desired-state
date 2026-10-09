import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/eeg_bands.dart';

void main() {
  test('quality utility and band calculation use identical artifact gates', () {
    final clean = List<double>.generate(
      512,
      (i) => 20 * math.sin(2 * math.pi * 10 * i / 256),
    );
    final cases = <List<double>>[
      clean,
      clean.take(256).toList(),
      List<double>.filled(512, 0),
      [...clean]..[300] = double.nan,
      [...clean]..[300] = 300,
      [...clean]..[300] = 180,
    ];
    for (final samples in cases) {
      expect(
        assessEegWindow(samples, 256).usable,
        eegBandPower(samples, 256, artifactScreening: true) != null,
      );
    }
    expect(assessEegWindow(clean, 256).usable, isTrue);
    expect(assessEegWindow(cases[1], 256).reason, contains('Waiting'));
    expect(assessEegWindow(cases[2], 256).reason, contains('Flat'));
    expect(assessEegWindow(cases[3], 256).reason, 'Invalid sample');
    expect(assessEegWindow(cases[4], 256).reason, contains('Large amplitude'));
    expect(assessEegWindow(cases[5], 256).reason, contains('Abrupt'));
  });
  test(
    'older artifacts outside the processing window do not block current status',
    () {
      final clean = List<double>.generate(
        1024,
        (i) => 10 * math.sin(2 * math.pi * 10 * i / 256),
      );
      expect(assessEegWindow([double.nan, ...clean], 256).usable, isTrue);
    },
  );
}
