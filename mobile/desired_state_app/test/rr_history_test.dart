import 'dart:math';

import 'package:desired_state_app/rr_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves raw artifacts and skips pairs across rejected beats', () {
    final history = RrHistory();
    final input = [1400.0, 1410.0, 730.0, 1390.0, 1400.0];
    history.addAll(input);
    expect(history.raw, input);
    expect(history.clean, [1400, 1410, 1390, 1400]);
    expect(history.artifactCount, 1);
    expect(history.rmssd, 10);
    expect(() => history.raw.add(1), throwsUnsupportedError);
    expect(() => history.clean.clear(), throwsUnsupportedError);
  });

  test('range boundaries and nonfinite values', () {
    for (final value in [300.0, 2000.0]) {
      final history = RrHistory()..addAll([value]);
      expect(history.clean, [value]);
    }
    final history = RrHistory()
      ..addAll([299, 2001, double.nan, double.infinity, -double.infinity]);
    expect(history.rawCount, 5);
    expect(history.cleanCount, 0);
    expect(history.artifactCount, 5);
    expect(history.rmssd, isNull);
  });

  test('25 percent boundary is inclusive and rejects beyond it', () {
    for (final value in [750.0, 1250.0, 749.0, 1251.0]) {
      final history = RrHistory()..addAll([1000, value]);
      expect(history.artifactCount, value >= 750 && value <= 1250 ? 0 : 1);
    }
  });

  test(
    'median uses latest nine accepted beats without sorting raw history',
    () {
      final history = RrHistory()
        ..addAll([
          1000,
          1200,
          1200,
          1200,
          1200,
          1200,
          1200,
          1200,
          1200,
          1200,
          1490,
        ]);
      expect(history.artifactCount, 0);
      expect(history.raw.first, 1000);
      expect(history.clean.last, 1490);
    },
  );

  test('RMSSD needs three accepted samples and handles empty packets', () {
    final history = RrHistory();
    expect(history.rmssd, isNull);
    history.addAll([1000, 1010]);
    history.addAll([]);
    expect(history.rmssd, isNull);
    history.addAll([1030]);
    expect(history.rmssd, closeTo(sqrt(250), 0.000001));
  });

  test('rolling window expires old data but preserves complete histories', () {
    final history = RrHistory()..addAll(List.filled(350, 1000.0));
    expect(history.rawCount, 350);
    expect(history.cleanCount, 350);
    expect(history.rmssd, 0);
    history.addAll(List.filled(60, 100.0));
    expect(history.rmssd, isNull);
    expect(history.rawCount, 410);
    expect(history.cleanCount, 350);
    expect(history.artifactCount, 60);
    history.clear();
    expect(history.raw, isEmpty);
    expect(history.clean, isEmpty);
    expect(history.artifactCount, 0);
    expect(history.rmssd, isNull);
    history.addAll([600, 610, 620]);
    expect(history.rmssd, 10);
  });
}
