import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/desktop_inspection.dart';

void main() {
  test('cursor never carries an EEG value across an outage', () {
    final value = inspectDesktopSignal('EEG Alpha (µV²)', const [
      (10, 8.62),
    ], 200);
    expect(value.status, 'No data');
    expect(value.value, isNull);
    expect(value.sampleTime, isNull);
  });
  test('nearest original sample exposes timestamp; rejected windows remain rejected', () {
    final value = inspectDesktopSignal('BPM', const [(10, 60), (11, 62)], 10.8);
    expect(value.value, 62);
    expect(value.sampleTime, 11);
    final rejected = inspectDesktopSignal('EEG Theta (µV²)', [
      (10, 5),
      (11, double.nan),
      (12, 6),
    ], 11);
    expect(rejected.status, 'Rejected / unavailable');
    expect(rejected.value, isNull);
  });
  test(
    'waveform tolerance is tight and a gap boundary cannot hide a valid sample',
    () {
      expect(
        inspectDesktopSignal('ECG (µV)', const [(1, 100)], 1.2).value,
        isNull,
      );
      expect(
        inspectDesktopSignal('ECG (µV)', const [(1, 100)], 1.002).value,
        100,
      );
      expect(
        inspectDesktopSignal('BPM', [(1, double.nan), (1, 60)], 1).value,
        60,
      );
    },
  );
  test('missing recorded signal has explicit no-data state', () {
    expect(inspectDesktopSignal('SpO2 (%)', [], 0).status, 'No data');
  });
}
