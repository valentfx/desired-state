import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:desired_state_app/device_models.dart';
import 'package:desired_state_app/h10_accelerometer.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground;
import 'session_history_test.dart' show historyFixture, writeRows, stamp;

List<int> packet(int type, List<int> payload) => [
  2,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  type,
  ...payload,
];

class AccPolar extends FakePolar {
  final acceleration = StreamController<H10Acceleration>.broadcast(sync: true);
  final raw = StreamController<RawBlePacket>.broadcast(sync: true);
  @override
  Stream<RawBlePacket> get pmdPackets => raw.stream;
  @override
  Stream<H10Acceleration> get accelerationStream => acceleration.stream;
  void emitAcc() {
    final bytes = packet(1, [100, 0, 156, 255, 232, 3]);
    raw.add(
      RawBlePacket(
        receivedAt: DateTime.now(),
        characteristic: 'pmd/data',
        bytes: bytes,
      ),
    );
    acceleration.add(H10AccProtocol.decode(bytes, DateTime.now(), 50, 8));
  }

  @override
  Future<void> dispose() async {
    await acceleration.close();
    await raw.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Polar start acknowledgments may contain zero or one parameter byte',
    () {
      expect(H10AccProtocol.settings([], startAcknowledgment: true), isEmpty);
      expect(H10AccProtocol.settings([0], startAcknowledgment: true), isEmpty);
      expect(
        H10AccProtocol.settings([
          5,
          1,
          0,
          0,
          128,
          63,
        ], startAcknowledgment: true)[5],
        [1065353216],
      );
      expect(() => H10AccProtocol.settings([0]), throwsFormatException);
      expect(
        () => H10AccProtocol.settings([5, 1, 0], startAcknowledgment: true),
        throwsFormatException,
      );
    },
  );
  test('signed raw axes and 64-bit device timestamp remain exact', () {
    final frame = H10AccProtocol.decode(
      packet(1, [100, 0, 156, 255, 232, 3]),
      DateTime.utc(2026),
      50,
      8,
    );
    expect(frame.samples, [
      [100, -100, 1000],
    ]);
    expect(frame.sensorNanoseconds, BigInt.one << 32);
    expect(frame.toJson()['sensor_timestamp_ns'], '4294967296');
    expect(frame.toJson()['units'], 'milli_g');
  });
  test(
    'LSB-first signed compressed deltas accumulate from previous sample',
    () {
      // 4-bit deltas: [+1,-2,+3], [-1,+2,-3]. Packed nibbles 1,e,3,f,2,d.
      final frame = H10AccProtocol.decode(
        packet(0x81, [100, 0, 156, 255, 232, 3, 4, 2, 0xe1, 0xf3, 0xd2]),
        DateTime.utc(2026),
        50,
        8,
      );
      expect(frame.samples, [
        [100, -100, 1000],
        [101, -102, 1003],
        [100, -100, 1000],
      ]);
      expect(
        () => H10AccProtocol.decode(
          packet(0x81, [100, 0, 156, 255, 232, 3, 4, 2, 0xe1]),
          DateTime.utc(2026),
          50,
          8,
        ),
        throwsFormatException,
      );
    },
  );
  test('negotiate advertised settings and preserve response scale factor', () {
    final settings = H10AccProtocol.settings([
      0,
      2,
      25,
      0,
      50,
      0,
      1,
      1,
      16,
      0,
      2,
      2,
      4,
      0,
      8,
      0,
    ]);
    expect(H10AccProtocol.choose(settings[0], [50, 25]), 50);
    expect(H10AccProtocol.start(50, 8), [
      2,
      2,
      0,
      1,
      50,
      0,
      1,
      1,
      16,
      0,
      2,
      1,
      8,
      0,
    ]);
    expect(
      H10AccProtocol.factor(H10AccProtocol.settings([5, 1, 0, 0, 0, 64])),
      2,
    );
    expect(() => H10AccProtocol.settings([0, 2, 25]), throwsFormatException);
    expect(() => H10AccProtocol.choose([8], [16]), throwsFormatException);
  });
  test(
    'History opens legacy and combined sessions with identity validation',
    () async {
      final root = await Directory.systemTemp.createTemp('h10-history');
      try {
        await historyFixture(root, id: 'legacy');
        final combined = await historyFixture(
          root,
          id: 'combined',
          rr: [
            {
              'session_id': 'combined',
              'polar_id': 'H10',
              'user_id': 'Fixture person',
              'received_utc': stamp(0),
              'rr_ms': 1000,
            },
            {
              'session_id': 'combined',
              'polar_id': 'stranger',
              'user_id': 'Fixture person',
              'received_utc': stamp(1),
              'rr_ms': 1100,
            },
          ],
        );
        final manifestFile = File('${combined.path}/manifest.json');
        final manifest = jsonDecode(
          await manifestFile.readAsString(),
        ) as Map<String, dynamic>;
        manifest['assignments'] = {
          'H10': 'Fixture person',
          'ring': 'Fixture person',
        };
        manifest['devices'] = {
          'H10': {'kind': 'polar_h10'},
          'ring': {'kind': 'wellue_o2ring'},
        };
        await manifestFile.writeAsString(jsonEncode(manifest));
        await writeRows(combined, 'o2ring_measurements', [
          {
            'session_id': 'combined',
            'device_id': 'ring',
            'user_id': 'Fixture person',
            'received_utc': stamp(0),
            'spo2_percent': 98,
          },
        ]);
        final repo = SessionHistoryRepository(
          directoryProvider: () async => root,
        );
        final entries = await repo.list();
        expect(entries.length, 2);
        final legacy = await repo.open(
          entries.firstWhere((e) => e.id == 'legacy'),
        );
        expect(legacy.rr.length, 4);
        final session = await repo.open(
          entries.firstWhere((e) => e.id == 'combined'),
        );
        expect(session.rr.length, 1);
        expect(session.oxygen.length, 1);
        expect(session.warnings.any((w) => w.contains('identity')), isTrue);
        expect(await repo.storageDiagnostics(), contains('Sessions found: 2'));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'ACC recording follows pause and stop, and exports recorded axes',
    () async {
      final root = await Directory.systemTemp.createTemp('h10-acc-recording');
      final polar = AccPolar();
      final controller = SessionController(
        service: polar,
        foregroundService: FakeForeground(),
        directoryProvider: () async => root,
      );
      try {
        await controller.connect(BluetoothDevice.fromId('E9E53B2C'));
        polar.emit([1000]);
        await controller.start(participantName: 'ACC fixture');
        expect(controller.sessionLogger, isNotNull, reason: controller.error);
        final logger = controller.sessionLogger!;
        polar.emitAcc();
        controller.pause();
        polar.emitAcc();
        controller.resume();
        polar.emitAcc();
        await controller.stop();
        polar.emitAcc();
        final rows = await File(
          '${logger.directory.path}/h10_accelerometer.jsonl',
        ).readAsLines();
        expect(rows.length, 2);
        final rawRows = await File('${logger.directory.path}/h10_pmd_raw.jsonl')
            .readAsLines();
        expect(rawRows.length, 2);
        expect(
          (jsonDecode(rawRows.first) as Map)['bytes'],
          packet(1, [100, 0, 156, 255, 232, 3]),
        );
        expect(controller.recordedAccSamples, 2);
        final first = jsonDecode(rows.first) as Map;
        expect(first['xyz_mg'], [
          [100, -100, 1000],
        ]);
        expect(first['session_id'], logger.sessionId);
        final archive = ZipDecoder().decodeBytes(
          await (await logger.createExportZip()).readAsBytes(),
        );
        expect(
          archive.files.any((f) => f.name.endsWith('/h10_accelerometer.jsonl')),
          isTrue,
        );
        expect(
          archive.files.any((f) => f.name.endsWith('/h10_pmd_raw.jsonl')),
          isTrue,
        );
      } finally {
        controller.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await root.delete(recursive: true);
      }
    },
  );
}
