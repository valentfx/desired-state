import 'dart:convert';
import 'dart:io';

import 'package:desired_state_app/device_screen.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'o2_ring_recording_test.dart' show FakeRing;
import 'history_widgets_test.dart' show settleIo;

import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;

Future<SessionController> athenaFixture(
  Directory root,
  FakePolar polar,
  FakeRing ring,
) async {
  final controller = SessionController(
    service: polar,
    ringService: ring,
    foregroundService: FakeForeground(),
    directoryProvider: () async => root,
  );
  controller.sessionLogger = await SessionLogger.start(
    polarId: 'MUSE_ATHENA',
    deviceName: 'Muse S Athena',
    primaryDeviceKind: 'muse_s_athena',
    participantName: 'unassigned',
    directoryProvider: () async => root,
  );
  controller.recordingState = RecordingState.recording;
  controller.sessionStartedAt = DateTime.now().toUtc();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'first H10 and ring attach to an Athena session with distinct identities',
    () async {
      final root = await Directory.systemTemp.createTemp('device-attachment-');
      final polar = FakePolar();
      final ring = FakeRing();
      final controller = await athenaFixture(root, polar, ring);
      addTearDown(() async {
        await controller.stop();
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      });
      final logger = controller.sessionLogger!;
      expect(controller.canReconnect, isFalse);
      await controller.connect(BluetoothDevice.fromId('E9E53B2C'));
      expect(controller.connected, isTrue);
      expect(controller.canReconnect, isTrue);
      polar.emit([1000, 1010]);
      await controller.connectRing(BluetoothDevice.fromId('RING_A'));
      ring.emit();
      expect(controller.sessionLogger, same(logger));
      await expectLater(
        controller.connect(BluetoothDevice.fromId('OTHER_H10')),
        throwsStateError,
      );
      await expectLater(
        controller.connectRing(BluetoothDevice.fromId('RING_B')),
        throwsStateError,
      );
      await controller.stop();
      final manifest = jsonDecode(
        await File('${logger.directory.path}/manifest.json').readAsString(),
      ) as Map<String, dynamic>;
      expect(manifest['session_id'], logger.sessionId);
      expect(manifest['devices']['MUSE_ATHENA']['kind'], 'muse_s_athena');
      expect(manifest['devices']['E9E53B2C']['kind'], 'polar_h10');
      expect(manifest['devices']['RING_A']['kind'], 'wellue_o2ring');
      expect(manifest['assignments'].keys.toSet(), {
        'MUSE_ATHENA',
        'E9E53B2C',
        'RING_A',
      });
      final rr = await rows(logger.directory, 'rr');
      expect(rr.length, 2);
      expect(rr.every((row) => row['polar_id'] == 'E9E53B2C'), isTrue);
      final oxygen = await rows(logger.directory, 'o2ring_measurements');
      expect(oxygen.single['device_id'], 'RING_A');
      expect(oxygen.single['spo2_percent'], 98);
      final events = await rows(logger.directory, 'events');
      expect(
        events
            .where((row) => row['event'] == 'device_attached')
            .map((row) => row['device_id']),
        ['E9E53B2C', 'RING_A'],
      );
    },
  );

  testWidgets(
    'Athena recording retains both scan controls and hides unselected H10 reconnect',
    (tester) async {
      late Directory root;
      late SessionController controller;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('device-controls-');
        controller = await athenaFixture(root, FakePolar(), FakeRing());
      });
      addTearDown(
        () => tester.runAsync(() async {
          await controller.stop();
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: DeviceScreen(controller: controller)),
      );
      await tester.tap(find.text('Polar H10'));
      await settleIo(
        tester,
        () => find.text('Scan for Polar H10').evaluate().isNotEmpty,
      );
      expect(find.text('Reconnect H10'), findsNothing);
      expect(find.text('Scan for Polar H10'), findsOneWidget);
      expect(find.text('No H10 heart-rate data received yet'), findsOneWidget);
      // Finish the incoming route before tapping its visible Back button.
      // Continuous diagnostics frames prevent a global pumpAndSettle.
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byType(BackButton).hitTestable());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('O2Ring').hitTestable());
      await settleIo(
        tester,
        () => find.text('Scan for O2Ring').evaluate().isNotEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('Scan for O2Ring'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(find.text('Scan for O2Ring').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'failed first H10 connection leaves status and retry controls available',
    () async {
      final root = await Directory.systemTemp.createTemp('device-failure-');
      final polar = FakePolar()..fail = true;
      final controller = await athenaFixture(root, polar, FakeRing());
      addTearDown(() async {
        await controller.stop();
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      });
      final logger = controller.sessionLogger;
      await controller.connect(BluetoothDevice.fromId('E9E53B2C'));
      expect(controller.connectionStatus, contains('radio unavailable'));
      expect(controller.connected, isFalse);
      expect(controller.connecting, isFalse);
      expect(controller.polarId, isNull);
      expect(controller.canReconnect, isFalse);
      expect(controller.sessionLogger, same(logger));
      polar.fail = false;
      await controller.connect(BluetoothDevice.fromId('E9E53B2C'));
      expect(controller.connected, isTrue);
    },
  );
}
