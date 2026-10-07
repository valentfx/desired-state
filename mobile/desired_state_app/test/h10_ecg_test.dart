import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/h10_ecg.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:desired_state_app/session_preferences.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;

List<int> ecgPacket(List<int> values, int timestamp) => [
  0,
  for (var i = 0; i < 8; i++) (timestamp >> (8 * i)) & 255,
  0,
  for (final value in values) ...[
    value & 255,
    (value >> 8) & 255,
    (value >> 16) & 255,
  ],
];

class EcgPolar extends FakePolar {
  final ecg = StreamController<H10EcgFrame>.broadcast(sync: true);
  @override
  Stream<H10EcgFrame> get ecgStream => ecg.stream;
  int timestamp = 1000000000;
  void emitEcg(List<int> samples, {bool oldReceipt = false}) {
    timestamp += (samples.length * 1000000000 / 130).round();
    ecg.add(
      H10EcgProtocol.decode(
        ecgPacket(samples, timestamp),
        oldReceipt ? DateTime.utc(2000) : DateTime.now(),
        130,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await ecg.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('H10 start settings and signed 24-bit type 0 decoding', () {
    expect(H10EcgProtocol.start(130, 14), [2, 0, 0, 1, 130, 0, 1, 1, 14, 0]);
    final bytes = ecgPacket([0, 1, -1, 8388607, -8388608, -1234], 0x123456789);
    final frame = H10EcgProtocol.decode(bytes, DateTime.utc(2026), 130);
    expect(frame.samples, [0, 1, -1, 8388607, -8388608, -1234]);
    expect(frame.sensorNanoseconds, BigInt.from(0x123456789));
    expect(frame.raw, bytes);
    expect(frame.toJson()['units'], 'microvolt');
  });
  test('malformed, compressed and other ECG types are rejected', () {
    final bytes = ecgPacket([1], 42);
    for (final bad in [
      bytes.sublist(0, 12),
      [...bytes, 1],
      [...bytes.take(9), 1, ...bytes.skip(10)],
      [...bytes.take(9), 128, ...bytes.skip(10)],
    ]) {
      expect(
        () => H10EcgProtocol.decode(bad, DateTime.now(), 130),
        throwsFormatException,
      );
    }
  });
  test(
    'ECG recording preserves identity, pauses, resumes and exports',
    () async {
      final root = await Directory.systemTemp.createTemp('h10-ecg-test-');
      final polar = EcgPolar();
      final c = SessionController(
        service: polar,
        foregroundService: FakeForeground(),
        directoryProvider: () async => root,
      );
      try {
        await c.connect(BluetoothDevice.fromId('ECG-H10'));
        await c.savePreferences(
          SessionPreferences(recording: recordingStreams.keys.toSet()),
        );
        await c.start(participantName: 'Original');
        final logger = c.sessionLogger!;
        polar.emitEcg([
          100,
          -100,
        ], oldReceipt: true); // conservative start boundary exclusion
        await Future<void>.delayed(const Duration(milliseconds: 25));
        polar.emitEcg([200, -200]);
        c.pause();
        polar.emitEcg([300, -300]);
        c.resume();
        polar.emitEcg([
          400,
          -400,
        ], oldReceipt: true); // conservative resume boundary
        await Future<void>.delayed(const Duration(milliseconds: 25));
        polar.emitEcg([500, -500]);
        await c.editRecordingParticipant('Corrected', 'note');
        await c.stop();
        polar.emitEcg([600, -600]);
        final saved = await rows(logger.directory, 'h10_ecg');
        expect(saved.map((r) => r['samples_uv']), [
          [200, -200],
          [500, -500],
        ]);
        expect(saved.every((r) => r['user_id'] == 'Original'), isTrue);
        expect(saved.every((r) => r['polar_id'] == 'ECG-H10'), isTrue);
        expect(
          saved.first['continuity_segment'],
          isNot(saved.last['continuity_segment']),
        );
        final repo = SessionHistoryRepository(
          directoryProvider: () async => root,
        );
        final entry = await repo.readEntry(logger.directory);
        expect((await repo.open(entry)).ecgSamples, 4);
        final exported = await repo.export(entry);
        expect(
          ZipDecoder()
              .decodeBytes(await exported.readAsBytes())
              .files
              .any((f) => f.name.endsWith('/h10_ecg.jsonl')),
          isTrue,
        );
      } finally {
        c.dispose();
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      }
    },
  );
}
