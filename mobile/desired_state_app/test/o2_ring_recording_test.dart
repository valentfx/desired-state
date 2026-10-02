import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:desired_state_app/device_models.dart';
import 'package:desired_state_app/o2_ring_protocol.dart';
import 'package:desired_state_app/o2_ring_service.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_controller_test.dart' show FakeForeground, FakePolar;

const captured = <int>[
  0x55,
  0,
  0xff,
  0,
  0,
  13,
  0,
  98,
  64,
  0,
  0,
  0,
  0,
  0,
  61,
  0,
  0,
  6,
  1,
  0,
  0x16,
];

class FakeRing extends O2RingService {
  final samples = StreamController<O2RingReading>.broadcast(sync: true);
  final raw = StreamController<RawBlePacket>.broadcast(sync: true);
  final states = StreamController<DeviceConnectionStatus>.broadcast(sync: true);
  bool closed = false;
  @override
  Stream<O2RingReading> get readings => samples.stream;
  @override
  Stream<RawBlePacket> get packets => raw.stream;
  @override
  Stream<DeviceConnectionStatus> get statusStream => states.stream;
  @override
  Future<void> connect(BluetoothDevice device) async {
    states.add(DeviceConnectionStatus.connected);
  }

  @override
  Future<void> disconnect() async {
    states.add(DeviceConnectionStatus.disconnected);
  }

  @override
  Future<void> dispose() async {
    closed = true;
    await super.dispose();
    await samples.close();
    await raw.close();
    await states.close();
  }

  void emit() {
    final now = DateTime.now().toUtc();
    raw.add(
      RawBlePacket(
        receivedAt: now,
        characteristic: 'viatom/notify',
        bytes: captured,
      ),
    );
    samples.add(O2RingService.decodeLegacySensorFrame(captured, now)!);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('physical 20+1 fragments decode only after CRC arrives', () {
    final assembler = ViatomFrameAssembler();
    final now = DateTime.utc(2026);
    expect(assembler.add(captured.sublist(0, 20), now), isEmpty);
    final frames = assembler.add([0x16], now);
    expect(frames, [captured]);
    final reading = O2RingService.decodeLegacySensorFrame(frames.single, now)!;
    expect(reading.spo2, 98);
    expect(reading.pulse, 64);
    expect(reading.battery, 61);
    expect(reading.worn, isTrue);
    expect(reading.perfusionIndexRaw, 6);
    expect(reading.rawFrame, captured);
  });

  test(
    'CRC corruption and invalid response headers never create a reading',
    () {
      final now = DateTime.utc(2026);
      final broken = List<int>.of(captured)..[7] = 97;
      expect(O2RingService.decodeLegacySensorFrame(broken, now), isNull);
      final assembler = ViatomFrameAssembler();
      expect(assembler.add(broken, now), isEmpty);
      expect(assembler.rejectedFrames, greaterThan(0));
      expect(assembler.add(captured, now), [captured]);
      final other = List<int>.of(captured)
        ..[1] = 1
        ..[2] = 0xfe;
      other[20] = viatomCrc8(other.sublist(0, 20));
      expect(O2RingService.decodeLegacySensorFrame(other, now), isNull);
    },
  );

  test('coalesced frames and stale fragments retain frame boundaries', () {
    final now = DateTime.utc(2026);
    final assembler = ViatomFrameAssembler();
    expect(assembler.add([...captured, ...captured], now), [
      captured,
      captured,
    ]);
    assembler.add(captured.sublist(0, 20), now);
    expect(assembler.add([0x16], now.add(const Duration(seconds: 5))), isEmpty);
    expect(assembler.add(captured, now.add(const Duration(seconds: 6))), [
      captured,
    ]);
    assembler.add(captured.sublist(0, 20), now);
    assembler.reset();
    expect(assembler.add([0x16], now), isEmpty);
  });

  test('off-finger and calibration samples preserve raw bytes without valid vitals', () {
    final frame = List<int>.of(captured)..[18] = 0;
    frame[20] = viatomCrc8(frame.sublist(0, 20));
    final reading = O2RingService.decodeLegacySensorFrame(
      frame,
      DateTime.utc(2026),
    )!;
    expect(reading.spo2, isNull);
    expect(reading.pulse, isNull);
    expect(reading.usable, isFalse);
    expect(reading.rawFrame[7], 98);
    frame[18] = 1;
    frame[7] = 0;
    frame[8] = 0;
    frame[20] = viatomCrc8(frame.sublist(0, 20));
    expect(
      O2RingService.decodeLegacySensorFrame(frame, DateTime.utc(2026))!.usable,
      isFalse,
    );
  });

  for (final withH10 in [false, true]) {
    test(
      'ring recording${withH10 ? ' alongside H10' : ' alone'} respects pause/stop and exports raw bytes',
      () async {
        final temp = await Directory.systemTemp.createTemp('o2record-');
        final ring = FakeRing();
        final polar = FakePolar();
        final controller = SessionController(
          service: polar,
          ringService: ring,
          foregroundService: FakeForeground(),
          directoryProvider: () async => temp,
        );
        try {
          await controller.connectRing(
            BluetoothDevice.fromId('FB:87:5D:7B:29:37'),
          );
          if (withH10) {
            await controller.connect(BluetoothDevice.fromId('E9E53B2C'));
          }
          ring.emit(); // Live-only, before recording.
          await controller.start(participantName: 'Michael');
          final logger = controller.sessionLogger!;
          ring.emit();
          if (withH10) {
            polar.emit([1000, 1010]);
          }
          controller.pause();
          ring.emit(); // Paused live values are visible but not recorded.
          controller.resume();
          ring.emit();
          await controller.stop();
          ring.emit(); // Stopped samples must not reopen any streams.
          final lines = await File(
            '${logger.directory.path}/o2ring_measurements.jsonl',
          ).readAsLines();
          expect(lines, hasLength(2));
          final row = jsonDecode(lines.first) as Map<String, dynamic>;
          expect(row['device_id'], 'FB:87:5D:7B:29:37');
          expect(row['user_id'], 'Michael');
          expect(row['spo2_percent'], 98);
          expect(row['pulse_bpm'], 64);
          expect(row['raw_frame'], captured);
          expect(row['crc_valid'], isTrue);
          expect(
            await File('${logger.directory.path}/o2ring_raw.jsonl')
                .readAsLines(),
            hasLength(2),
          );
          final h10 = await File('${logger.directory.path}/measurements.jsonl')
              .readAsLines();
          expect(h10, hasLength(withH10 ? 1 : 0));
          final archive = ZipDecoder().decodeBytes(
            await (await logger.createExportZip()).readAsBytes(),
          );
          expect(
            archive.files.map((f) => f.name),
            containsAll([
              '${logger.sessionId}/o2ring_measurements.jsonl',
              '${logger.sessionId}/o2ring_raw.jsonl',
            ]),
          );
          expect(ring.closed, isFalse);
        } finally {
          controller.dispose();
          // Let asynchronous stream cancellation/disposal finish before deleting files.
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await temp.delete(recursive: true);
        }
      },
    );
  }
}
