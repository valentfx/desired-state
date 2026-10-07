import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:desired_state_app/session_timer.dart';
import 'package:desired_state_app/session_preferences.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_timeline_screen.dart';
import 'package:desired_state_app/recorded_posture.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;

class TimerForeground extends FakeForeground {
  int alerts = 0;
  bool? vibration;
  @override
  Future<void> timerAlert({required bool vibrate}) async {
    alerts++;
    vibration = vibrate;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('new defaults exclude ECG, legacy choices migrate and posture is independent', () {
    final defaults = SessionPreferences();
    expect(defaults.records('ecg'), isFalse);
    expect(defaults.records('posture'), isTrue);
    final legacy = SessionPreferences.fromJson({
      'schema_version': 1,
      'recording': ['ecg', 'acc'],
      'show_eeg': true,
      'show_oxygen': true,
      'show_posture': true,
    });
    expect(legacy.records('ecg'), isTrue);
    expect(legacy.records('posture'), isTrue);
    final independent = SessionPreferences.fromJson(
      SessionPreferences(recording: {'posture'}).toJson(),
    );
    expect(independent.records('posture'), isTrue);
    expect(independent.records('acc'), isFalse);
  });
  test('active timer excludes paused time and completes once', () {
    var now = Duration.zero;
    final timer = SessionCountdown(clock: () => now);
    timer.start(const Duration(minutes: 1));
    now = const Duration(seconds: 20);
    timer.pause();
    now = const Duration(hours: 2);
    expect(timer.remaining, const Duration(seconds: 40));
    expect(timer.checkCompletion(), isFalse);
    timer.resume();
    now += const Duration(seconds: 40);
    expect(timer.checkCompletion(), isTrue);
    expect(timer.checkCompletion(), isFalse);
    expect(timer.remaining, Duration.zero);
    timer.clear();
    expect(timer.duration, isNull);
  });
  test(
    'preferences remember duration and vibration, preserve corrupt source',
    () async {
      final root = await Directory.systemTemp.createTemp('timer-pref-');
      try {
        final store = SessionTimerPreferenceStore(
          directoryProvider: () async => root,
        );
        await store.save(
          const SessionTimerPreference(minutes: 7, vibrate: false),
        );
        final value = await store.load();
        expect(value.minutes, 7);
        expect(value.vibrate, isFalse);
        final file = File('${root.path}/session_timer_preference.json');
        await file.writeAsString('invalid');
        await expectLater(
          store.save(const SessionTimerPreference()),
          throwsFormatException,
        );
        expect(await file.readAsString(), 'invalid');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'controller alerts once, retains recording and journals timer lifecycle',
    () async {
      final root = await Directory.systemTemp.createTemp('timer-recording-');
      var now = Duration.zero;
      final foreground = TimerForeground();
      final controller = SessionController(
        service: FakePolar(),
        foregroundService: foreground,
        directoryProvider: () async => root,
        elapsedClock: () => now,
        tickInterval: const Duration(milliseconds: 5),
        staleAfter: const Duration(days: 1),
      );
      try {
        await controller.connect(BluetoothDevice.fromId('H10'));
        controller.nextTimerDuration = const Duration(seconds: 60);
        controller.nextTimerVibrate = false;
        await controller.start(participantName: '');
        final logger = controller.sessionLogger!;
        now = const Duration(seconds: 20);
        controller.pause();
        now = const Duration(hours: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(foreground.alerts, 0);
        expect(
          controller.sessionCountdown.remaining,
          const Duration(seconds: 40),
        );
        controller.resume();
        now += const Duration(seconds: 40);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(foreground.alerts, 1);
        expect(foreground.vibration, isFalse);
        expect(controller.recordingState, RecordingState.recording);
        expect(controller.sessionLogger, same(logger));
        await controller.stop();
        final events = (await rows(
          logger.directory,
          'events',
        )).map((row) => row['event']).toList();
        expect(
          events,
          containsAllInOrder([
            'session_timer_started',
            'session_timer_paused',
            'session_timer_resumed',
            'session_timer_completed',
          ]),
        );
        expect(
          events.where((value) => value == 'session_timer_completed').length,
          1,
        );
      } finally {
        await controller.stop();
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      }
    },
  );
  test('phone timeline uses shared posture transitions with pause gaps and incremental carry', () async {
    final root = await Directory.systemTemp.createTemp('phone-posture-');
    try {
      final origin = DateTime.utc(2026);
      final events = <Map<String, dynamic>>[
        {
          'received_utc': origin.toIso8601String(),
          'event': 'posture_estimate',
          'description': jsonEncode({'position': 'On back'}),
        },
        {
          'received_utc': origin
              .add(const Duration(seconds: 5))
              .toIso8601String(),
          'event': 'session_paused',
        },
        {
          'received_utc': origin
              .add(const Duration(seconds: 8))
              .toIso8601String(),
          'event': 'posture_estimate',
          'description': jsonEncode({'position': 'Left side'}),
        },
      ];
      await File('${root.path}/events.jsonl')
          .writeAsString('${events.map(jsonEncode).join('\n')}\n');
      final reader = TimelineReader();
      final first = await reader.read(root, origin, 0, 10, incremental: true);
      expect(
        first['Sleep position (recorded estimate)'],
        recordedPosturePoints(events, origin, 0, 10),
      );
      final next = await reader.read(root, origin, 6, 10, incremental: true);
      expect(next['Sleep position (recorded estimate)']!.first, (6.0, 0.0));
      expect(next['Sleep position (recorded estimate)']!.last, (10.0, 3.0));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
