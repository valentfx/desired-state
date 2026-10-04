import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/polar_h10_service.dart';
import 'package:desired_state_app/recording_foreground_service.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';

class FakePolar extends PolarH10Service {
  final data = StreamController<PolarHeartRateData>.broadcast(sync: true);
  final connections = StreamController<bool>.broadcast(sync: true);
  int connects = 0;
  int disconnects = 0;
  bool fail = false;
  Completer<void>? pendingConnect;
  @override
  Stream<PolarHeartRateData> get dataStream => data.stream;
  @override
  Stream<bool> get connectionStream => connections.stream;
  @override
  Future<void> connect(BluetoothDevice device) async {
    connects++;
    if (fail) throw StateError('radio unavailable');
    await pendingConnect?.future;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  void emit(List<double> rr) => data.add(
    PolarHeartRateData(
      heartRate: 60,
      rrIntervalsMs: rr,
      timestamp: DateTime.now(),
    ),
  );
  @override
  Future<void> dispose() async {
    await data.close();
    await connections.close();
    await super.dispose();
  }
}

class FakeForeground extends RecordingForegroundService {
  int starts = 0;
  int stops = 0;
  @override
  Future<void> start(String sessionId) async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> update({
    required String state,
    required int? heartRate,
    required double? rmssd,
    required int artifactCount,
    required Duration elapsed,
  }) async {}
}

Future<void> until(bool Function() done) async {
  final limit = DateTime.now().add(const Duration(seconds: 3));
  while (!done()) {
    if (DateTime.now().isAfter(limit)) fail('Timed out waiting for controller');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<List<Map<String, dynamic>>> rows(Directory dir, String stream) async => [
  for (final line in await File('${dir.path}/$stream.jsonl').readAsLines())
    jsonDecode(line) as Map<String, dynamic>,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late FakePolar polar;
  late FakeForeground foreground;
  late SessionController controller;
  var elapsed = Duration.zero;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'desired-state-recovery-test-',
    );
    polar = FakePolar();
    foreground = FakeForeground();
    elapsed = Duration.zero;
    controller = SessionController(
      service: polar,
      foregroundService: foreground,
      directoryProvider: () async => temp,
      elapsedClock: () => elapsed,
      staleAfter: const Duration(milliseconds: 100),
      retryDelay: const Duration(milliseconds: 5),
      tickInterval: const Duration(milliseconds: 5),
    );
    await controller.connect(BluetoothDevice.fromId('E9E53B2C'));
    await controller.start(
      participantName: 'test participant',
      description: 'test intention',
    );
  });
  tearDown(() async {
    await controller.stop();
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    await temp.delete(recursive: true);
  });

  test('quick marker snapshots and later notes survive definition edits and export', () async {
    final store = controller.quickMarkers;
    await store.load();
    final definition = store.items.first;
    final logger = controller.sessionLogger!;
    polar.emit([1000, 1010]);
    final markers = await Future.wait([
      controller.markQuickMarker(definition),
      controller.markQuickMarker(definition),
    ]);
    expect(markers.map((marker) => marker!.id).toSet(), hasLength(2));
    await store.rename(definition.id, 'Renamed');
    await store.remove(definition.id);
    controller.pause();
    final pausedMarker = await controller.markQuickMarker(store.items.first);
    expect(pausedMarker, isNotNull);
    expect(controller.recordingState, RecordingState.paused);
    await controller.addMarkerNote(markers.first!, 'Before stop');
    await controller.stop();
    final raw = await File('${logger.directory.path}/rr.jsonl').readAsBytes();
    final originalEvents = await File('${logger.directory.path}/events.jsonl')
        .readAsBytes();
    await controller.addMarkerNote(markers.first!, 'What helped afterward');
    expect(await File('${logger.directory.path}/rr.jsonl').readAsBytes(), raw);
    expect(
      await File('${logger.directory.path}/events.jsonl').readAsBytes(),
      originalEvents,
    );
    final events = (await rows(
      logger.directory,
      'events',
    )).where((row) => row['event'] == 'marked_event').toList();
    expect(events, hasLength(3));
    expect(events.first['marker_label'], definition.label);
    expect(events.first['marker_definition_id'], definition.id);
    expect(events.first['marker_type'], 'quick');
    expect(events.first['event_id'], markers.first!.id);
    expect(
      events.first['received_utc'],
      markers.first!.timestamp.toUtc().toIso8601String(),
    );
    expect(events.first['session_id'], logger.sessionId);
    expect(events.first['user_id'], 'test participant');
    final notes = await rows(logger.directory, 'marker_notes');
    expect(notes.map((row) => row['event_id']).toSet(), {markers.first!.id});
    expect(notes.map((row) => row['description']), [
      'Before stop',
      'What helped afterward',
    ]);
    final zip = ZipDecoder().decodeBytes(
      await (await logger.createExportZip()).readAsBytes(),
    );
    expect(
      zip.files.map((file) => file.name),
      contains('${logger.sessionId}/marker_notes.jsonl'),
    );
    expect(await controller.markQuickMarker(store.items.first), isNull);
  });

  test(
    'failed note save does not interrupt raw recording or later annotations',
    () async {
      final logger = controller.sessionLogger!;
      await controller.quickMarkers.load();
      final marker = (await controller.markQuickMarker(
        controller.quickMarkers.items.first,
      ))!;
      final obstruction = Directory(
        '${logger.directory.path}/marker_notes.jsonl',
      );
      await obstruction.create();
      await expectLater(
        controller.addMarkerNote(marker, 'unsaved'),
        throwsA(isA<FileSystemException>()),
      );
      polar.emit([1000, 1010]);
      await obstruction.delete();
      await controller.addMarkerNote(marker, 'saved');
      await controller.stop();
      expect(await rows(logger.directory, 'rr'), hasLength(2));
      expect(
        (await rows(logger.directory, 'marker_notes')).single['description'],
        'saved',
      );
      expect(controller.error, isNull);
    },
  );

  test(
    'disconnect recovery preserves session, notes, raw rows and gap adjacency',
    () async {
      final logger = controller.sessionLogger!;
      polar.emit([1000, 1010]);
      await controller.markEvent('before gap');
      polar.connections.add(false);
      await until(() => polar.connects == 2);
      polar.emit([1100, 1110]);
      await until(() => !controller.recovering);
      await controller.markEvent('after gap');
      expect(identical(controller.sessionLogger, logger), isTrue);
      expect(controller.rrHistory.raw, [1000, 1010, 1100, 1110]);
      expect(controller.rmssd, 10); // Never includes the 90 ms cross-gap pair.
      expect(controller.timeline.map((p) => p.segment), [0, 1]);
      expect(foreground.starts, 1);
      await controller.stop(outcome: 'test outcome');
      final rr = await rows(logger.directory, 'rr');
      expect(rr.map((r) => r['rr_ms']), [1000, 1010, 1100, 1110]);
      expect(rr.map((r) => r['rr_index']), [0, 1, 0, 1]);
      expect(rr.map((r) => r['continuity_segment']), [0, 0, 1, 1]);
      expect(
        rr.every(
          (r) =>
              r['session_id'] == logger.sessionId &&
              r['user_id'] == 'test participant',
        ),
        isTrue,
      );
      final events = await rows(logger.directory, 'events');
      expect(
        events.map((r) => r['event']),
        containsAll([
          'bluetooth_disconnected',
          'measurement_gap',
          'recovery_attempt',
          'measurement_recovered',
          'recovery_succeeded',
          'session_outcome',
          'session_ended',
        ]),
      );
      expect(
        events
            .where((r) => r['event'] == 'marked_event')
            .map((r) => r['description']),
        ['before gap', 'after gap'],
      );
      final manifest = jsonDecode(
        await File('${logger.directory.path}/manifest.json').readAsString(),
      );
      expect(manifest['description'], 'test intention');
    },
  );

  test(
    'stale link retries are bounded even when connect succeeds without data',
    () async {
      final logger = controller.sessionLogger!;
      polar.emit([1000]);
      elapsed = const Duration(seconds: 1);
      await until(() => controller.connectionStatus.contains('exhausted'));
      expect(polar.connects, 4); // initial connection + three recovery attempts
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(polar.connects, 4);
      expect(controller.rrHistory.raw, [1000]);
      controller.reconnect();
      await until(() => polar.connects == 5);
      polar.emit([1010]);
      await until(() => !controller.recovering);
      expect(controller.sessionLogger, same(logger));
      await controller.stop();
      final events = await rows(logger.directory, 'events');
      expect(
        events.map((r) => r['event']),
        containsAll([
          'measurement_stale',
          'recovery_exhausted',
          'recovery_succeeded',
        ]),
      );
    },
  );

  test(
    'radio failures exhaust retries without producing measurements',
    () async {
      polar.fail = true;
      polar.connections.add(false);
      await until(() => controller.connectionStatus.contains('exhausted'));
      expect(polar.connects, 4);
      expect(controller.timeline, isEmpty);
      expect(controller.rrHistory.raw, isEmpty);
    },
  );

  test('late packet breaks adjacency even before the watchdog runs', () async {
    polar.emit([1000, 1010]);
    elapsed = const Duration(seconds: 1);
    polar.emit([1100, 1110]);
    expect(controller.rmssd, 10);
    expect(controller.timeline.map((p) => p.segment), [0, 1]);
    expect(polar.connects, 1);
  });

  test('manual reconnect while paused restores only the link', () async {
    polar.emit([1000, 1010]);
    controller.pause();
    polar.connections.add(false);
    elapsed = const Duration(minutes: 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(polar.connects, 1);
    controller.reconnect();
    await until(() => polar.connects == 2);
    polar.emit([1100]);
    await until(() => !controller.recovering);
    expect(controller.recordingState, RecordingState.paused);
    expect(controller.rrHistory.raw, [1000, 1010]);
    controller.resume();
    polar.emit([1110]);
    expect(controller.rrHistory.raw, [1000, 1010, 1110]);
    expect(controller.rmssd, 10);
  });

  test(
    'pause cancels in-flight recovery; resume continues the same session',
    () async {
      final logger = controller.sessionLogger;
      polar.emit([1000, 1010]);
      polar.pendingConnect = Completer<void>();
      controller.reconnect();
      await until(() => polar.connects == 2);
      controller.pause();
      polar.pendingConnect!.complete();
      polar.pendingConnect = null;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      polar.emit([1200]);
      expect(controller.recordingState, RecordingState.paused);
      expect(controller.rrHistory.raw, [1000, 1010]);
      expect(polar.connects, 2);
      controller.resume();
      await until(() => polar.connects == 3);
      polar.emit([1100]);
      await until(() => !controller.recovering);
      expect(controller.sessionLogger, same(logger));
      expect(controller.rmssd, 10);
    },
  );

  test(
    'manual disconnect suppresses retries until explicit reconnect',
    () async {
      await controller.disconnect();
      elapsed = const Duration(minutes: 1);
      polar.emit([999]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(polar.connects, 1);
      expect(controller.rrHistory.raw, isEmpty);
      controller.reconnect();
      await until(() => polar.connects == 2);
      polar.emit([1000]);
      await until(() => !controller.recovering);
      expect(controller.rrHistory.raw, [1000]);
    },
  );

  test(
    'stop during connection cannot reopen or append to the completed session',
    () async {
      final logger = controller.sessionLogger!;
      polar.pendingConnect = Completer<void>();
      controller.reconnect();
      await until(() => polar.connects == 2);
      await controller.stop();
      polar.pendingConnect!.complete();
      polar.emit([1000]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.sessionLogger, isNull);
      expect(controller.recordingState, RecordingState.stopped);
      expect(await rows(logger.directory, 'measurements'), isEmpty);
      expect(polar.connects, 2);
      expect(foreground.stops, 1);
    },
  );

  testWidgets(
    'recording survives disposal and recreation of the collector screen',
    (tester) async {
      final logger = controller.sessionLogger!;
      await tester.pumpWidget(
        MaterialApp(home: CollectorScreen(controller: controller)),
      );
      expect(find.byTooltip('Device connection'), findsOneWidget);
      expect(find.byTooltip('Stop recording'), findsOneWidget);
      expect(controller.recordingState, RecordingState.recording);
      await tester.pumpWidget(const SizedBox());
      polar.emit([1000, 1010, 1020]);
      expect(controller.rrHistory.rawCount, 3);
      await tester.pumpWidget(
        MaterialApp(home: CollectorScreen(controller: controller)),
      );
      expect(find.text('● REC'), findsOneWidget);
      expect(find.byTooltip('Stop recording'), findsOneWidget);
      expect(controller.sessionLogger, same(logger));
      expect(controller.recordingState, RecordingState.recording);
      expect(controller.rrHistory.rawCount, 3);
      expect(controller.timeline.length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
