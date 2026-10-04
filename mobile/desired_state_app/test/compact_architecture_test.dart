import 'dart:convert';
import 'dart:io';

import 'package:desired_state_app/posture_calibration.dart';
import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/rr_history.dart';
import 'package:desired_state_app/ecg_live_panel.dart';
import 'package:desired_state_app/eeg_live_panel.dart';
import 'package:desired_state_app/compact_eeg_panel.dart';
import 'package:flutter/material.dart';
import 'package:desired_state_app/session_preferences.dart';
import 'package:desired_state_app/session_timeline_screen.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_widgets_test.dart' show settleIo;

import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'compact Live keeps recording controls and moves full EEG/ECG off the dashboard',
    (tester) async {
      late Directory root;
      late SessionController c;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('compact-dashboard-');
        final polar = FakePolar();
        c = SessionController(
          service: polar,
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        await c.connect(BluetoothDevice.fromId('H10'));
        await c.start(participantName: '');
        polar.emit([1000, 1010, 1020]);
      });
      addTearDown(
        () => tester.runAsync(() async {
          await c.stop();
          c.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        }),
      );
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: CollectorScreen(controller: c)),
      );
      await settleIo(
        tester,
        () => find
            .byTooltip('Stop recording')
            .hitTestable()
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(EcgLivePanel), findsNothing);
      expect(find.byType(EegLivePanel), findsNothing);
      expect(find.byType(CompactEegPanel), findsOneWidget);
      expect(find.byTooltip('Live settings'), findsOneWidget);
      expect(c.recordingState, RecordingState.recording);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('posture captures reject movement and classify known, ambiguous and unknown orientations', () {
    final back = stableGravity(List.generate(200, (_) => [0, 0, 1000]));
    final calibration = PostureCalibration(
      id: 'one',
      deviceId: 'H10',
      name: 'Normal',
      positions: {
        'On back': back,
        'Right side': [1, 0, 0],
        'Left side': [-1, 0, 0],
        'Upright': [0, 1, 0],
      },
    );
    expect(
      calibration.classify([
        [0, 0, 1000],
        [0, 0, 1001],
      ]),
      'On back',
    );
    expect(
      calibration.classify([
        [1000, 0, 0],
        [1001, 0, 0],
      ]),
      'Right side',
    );
    expect(
      calibration.classify([
        [0, 0, -1000],
      ]),
      'Unknown',
    );
    expect(
      calibration.classify([
        [1000, 0, 0],
        [-1000, 0, 0],
      ]),
      'Moving',
    );
    expect(
      () => stableGravity([
        [0, 0, 1000],
      ]),
      throwsFormatException,
    );
    expect(
      PostureCalibration.fromJson(calibration.toJson()).positions.keys,
      calibration.positions.keys,
    );
  });
  test('bounded preview preserves recent RMSSD and continuity', () {
    final history = RrHistory();
    history.addAll(List.generate(1000, (i) => 1000.0 + (i % 2) * 10));
    final before = history.rmssd;
    history.retainLatest(600);
    expect(history.rawCount, 600);
    expect(history.rmssd, before);
    history.breakSequence();
    history.addAll([1000, 1010]);
    expect(history.rmssd, isNotNull);
  });
  test('preferences survive restart and preserve a corrupt file', () async {
    final root = await Directory.systemTemp.createTemp('preferences-contract-');
    addTearDown(() => root.delete(recursive: true));
    final store = PreferencesStore(() async => root);
    await store.save(
      SessionPreferences(recording: {'heart', 'muse'}, showEeg: false),
    );
    final loaded = await store.load();
    expect(loaded.records('heart'), isTrue);
    expect(loaded.records('ecg'), isFalse);
    expect(loaded.showEeg, isFalse);
    final file = await store.file;
    await file.writeAsString('{damaged');
    await expectLater(store.save(SessionPreferences()), throwsFormatException);
    expect(await file.readAsString(), '{damaged');
  });
  test('preview precedes Record; display choices do not alter recording; recording changes are logged', () async {
    final root = await Directory.systemTemp.createTemp(
      'recording-preferences-',
    );
    final polar = FakePolar();
    final c = SessionController(
      service: polar,
      foregroundService: FakeForeground(),
      directoryProvider: () async => root,
    );
    addTearDown(() async {
      await c.stop();
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      await root.delete(recursive: true);
    });
    await c.connect(BluetoothDevice.fromId('H10'));
    polar.emit([1000, 1010, 1020]);
    expect(c.heartRate, 60);
    expect(c.rmssd, 10);
    expect(c.sessionLogger, isNull);
    expect(c.rrHistory.rawCount, 0);
    await c.savePreferences(SessionPreferences(showEeg: false));
    await c.start(participantName: '');
    final logger = c.sessionLogger!;
    polar.emit([1000, 1010, 1020]);
    await c.savePreferences(
      SessionPreferences(recording: {'muse'}, showEeg: false),
    );
    polar.emit([1030]);
    await c.stop();
    expect((await rows(logger.directory, 'rr')).length, 3);
    final events = await rows(logger.directory, 'events');
    expect(
      events.any((v) => v['event'] == 'session_preferences_changed'),
      isTrue,
    );
  });
  test('calibration is included as a versioned session snapshot', () async {
    final root = await Directory.systemTemp.createTemp('calibration-snapshot-');
    final c = SessionController(
      service: FakePolar(),
      foregroundService: FakeForeground(),
      directoryProvider: () async => root,
    );
    addTearDown(() async {
      await c.stop();
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      await root.delete(recursive: true);
    });
    await c.connect(BluetoothDevice.fromId('H10'));
    await c.selectCalibration(
      PostureCalibration(
        id: 'original',
        deviceId: 'H10',
        name: 'Normal',
        positions: {
          'On back': [0, 0, 1],
          'Right side': [1, 0, 0],
          'Left side': [-1, 0, 0],
        },
      ),
    );
    await c.start(participantName: '');
    final logger = c.sessionLogger!;
    await c.selectCalibration(
      PostureCalibration(
        id: 'new',
        deviceId: 'H10',
        name: 'Changed',
        positions: {
          'On back': [0, 0, -1],
          'Right side': [1, 0, 0],
          'Left side': [-1, 0, 0],
        },
      ),
    );
    await c.stop();
    final snapshot = jsonDecode(
      await File('${logger.directory.path}/posture_calibration.json')
          .readAsString(),
    ) as Map;
    expect(snapshot['id'], 'original');
    expect(
      (await rows(
        logger.directory,
        'events',
      )).any((v) => v['event'] == 'posture_calibration_selected'),
      isTrue,
    );
  });
  test('timeline reads complete lines incrementally without duplicates and derives RR metrics', () async {
    final root = await Directory.systemTemp.createTemp('timeline-reader-');
    addTearDown(() => root.delete(recursive: true));
    final origin = DateTime.utc(2026);
    final file = File('${root.path}/rr.jsonl');
    String line(int i) => jsonEncode({
      'received_utc': origin.add(Duration(seconds: i)).toIso8601String(),
      'rr_ms': 1000 + i * 10,
      'artifact_accepted': true,
      'continuity_segment': 0,
    });
    await file.writeAsString('${line(0)}\n${line(1)}\n${line(2)}\n');
    final reader = TimelineReader();
    var result = await reader.read(root, origin, 0, 10, incremental: true);
    expect(result['RR (ms)']!.length, 3);
    expect(result['RMSSD (ms)']!.last.$2, 10);
    await file.writeAsString(line(3), mode: FileMode.append);
    result = await reader.read(root, origin, 0, 10, incremental: true);
    expect(result['RR (ms)']!.length, 3);
    await file.writeAsString('\n', mode: FileMode.append);
    result = await reader.read(root, origin, 0, 10, incremental: true);
    expect(result['RR (ms)']!.length, 4);
  });
}
