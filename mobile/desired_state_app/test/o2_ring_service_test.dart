import 'package:flutter_test/flutter_test.dart';

import 'package:desired_state_app/device_models.dart';
import 'package:desired_state_app/o2_ring_service.dart';

void main() {
  test('decodes standard BLE pulse oximeter SFLOAT values', () {
    // 98.0 (980 × 10^-1) and 75.0 (750 × 10^-1), little endian.
    final reading = O2RingService.decodeStandardPulseOximeter([
      0,
      0xd4,
      0xf3,
      0xee,
      0xf2,
    ], DateTime.utc(2026));

    expect(reading?.spo2, 98);
    expect(reading?.pulse, 75);
  });

  test('does not invent a reading from incomplete data', () {
    expect(
      O2RingService.decodeStandardPulseOximeter([0, 1], DateTime.utc(2026)),
      isNull,
    );
  });

  test('uses the Viatom READ_SENSORS request without guessing a decode', () {
    expect(O2RingService.readSensorsCommand, <int>[
      0xaa,
      0x17,
      0xe8,
      0,
      0,
      0,
      0,
      0x1b,
    ]);
    // Vendor responses are not passed through the standard SIG decoder.
    expect(
      O2RingService.decodeNotification(O2RingService.viatomNotify, <int>[
        0xaa,
        0x17,
        0xe8,
        0,
        0,
        0,
        0,
        0x1b,
      ], DateTime.utc(2026)),
      isNull,
    );
  });

  test('routes only standard measurement notifications to the SIG decoder', () {
    final now = DateTime.utc(2026);
    final bytes = <int>[0, 0xd4, 0xf3, 0xee, 0xf2];
    final reading = O2RingService.decodeNotification(
      O2RingService.continuousMeasurement,
      bytes,
      now,
    );
    expect(reading?.spo2, 98);
    expect(reading?.pulse, 75);
    for (final characteristic in [
      O2RingService.viatomNotify,
      O2RingService.oxyIiNotify,
    ]) {
      expect(
        O2RingService.decodeNotification(characteristic, bytes, now),
        isNull,
      );
    }
  });

  test('builds the OxyII live request frame with its documented CRC-8', () {
    // This command uses the separate O2Ring-S/T8520 protocol, not the legacy
    // AA/17 request. CRC-8/ITU fixture from the reverse-engineered protocol.
    expect(O2RingService.buildOxyIiLiveSamplesRequest(0), <int>[
      0xa5,
      0x04,
      0xfb,
      0,
      0,
      0,
      0,
      0x93,
    ]);
    expect(O2RingService.buildOxyIiLiveSamplesRequest(1), <int>[
      0xa5,
      0x04,
      0xfb,
      0,
      1,
      0,
      0,
      0xf8,
    ]);
  });

  test(
    'raw diagnostics distinguish transmitted packets from received ones',
    () {
      final packet = RawBlePacket(
        receivedAt: DateTime.utc(2026),
        characteristic: 'service/characteristic',
        bytes: const <int>[0xaa, 0x17, 0xe8],
        direction: BlePacketDirection.tx,
      );

      expect(packet.direction, BlePacketDirection.tx);
      expect(packet.hex, 'AA 17 E8');
    },
  );
}
