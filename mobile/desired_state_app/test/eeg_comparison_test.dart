import 'dart:math' as math;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/eeg_bands.dart';
import 'package:desired_state_app/session_preferences.dart';

void main() {
  test(
    'default retains artifact-rich power; explicit screen excludes same window',
    () {
      final samples = List<double>.generate(
        1024,
        (i) => 10 * math.sin(2 * math.pi * 10 * i / 256),
      );
      samples[500] = 600;
      final original = [...samples];
      expect(eegBandPower(samples, 256), isNotNull);
      expect(eegBandPower(samples, 256, artifactScreening: true), isNull);
      final frame = buildEegFrame(DateTime(2026), {'1': samples}, 256);
      expect(frame.channels.length, 1);
      expect(frame.screenedChannels, isEmpty);
      expect(frame.qualityReasons['1'], contains('Large amplitude'));
      expect(frame.values(null, decibels: true)['Alpha'], isNotNull);
      expect(frame.values(null, artifactScreening: true), isEmpty);
      expect(samples, original);
    },
  );
  test('Gamma physical power and decibel reference are explicit', () {
    final samples = List<double>.generate(
      1024,
      (i) => 10 * math.sin(2 * math.pi * 40 * i / 256),
    );
    final powers = eegBandPower(samples, 256)!;
    expect(powers['Gamma'], closeTo(50, .2));
    final frame = EegBandFrame(DateTime(2026), {'1': powers}, 1);
    expect(frame.values(null, decibels: true)['Gamma'], closeTo(16.9897, .03));
    expect(frame.values(null, relative: true)['Gamma'], closeTo(100, .1));
  });
  test(
    'legacy missing Gamma and low-rate unavailable Gamma are not synthesized',
    () {
      final frame = EegBandFrame(DateTime(2026), {
        '1': {'Delta': 1, 'Theta': 1, 'Alpha': 1, 'Beta': 1},
      }, 1);
      expect(frame.values(null).containsKey('Gamma'), isFalse);
      final samples = List<double>.generate(
        256,
        (i) => math.sin(2 * math.pi * 10 * i / 64),
      );
      expect(eegBandPower(samples, 64)!.containsKey('Gamma'), isFalse);
      expect(eegBandPower([...samples]..[100] = double.nan, 64), isNull);
    },
  );
  test(
    'screening choice persists; older preferences migrate with screening off',
    () async {
      final root = await Directory.systemTemp.createTemp('eeg-choice-');
      addTearDown(() => root.delete(recursive: true));
      final store = PreferencesStore(() async => root);
      expect((await store.load()).eegArtifactScreening, isFalse);
      await store.save(
        SessionPreferences(
          eegArtifactScreening: true,
          museOpticalCapture: true,
        ),
      );
      final restored = await store.load();
      expect(restored.eegArtifactScreening, isTrue);
      expect(restored.museOpticalCapture, isTrue);
      expect(restored.copyWith(showEeg: false).museOpticalCapture, isTrue);
      expect(restored.copyWith(showEeg: false).eegArtifactScreening, isTrue);
      final legacy = SessionPreferences().toJson()
        ..['schema_version'] = 2
        ..remove('eeg_artifact_screening');
      expect(SessionPreferences.fromJson(legacy).eegArtifactScreening, isFalse);
    },
  );
}
