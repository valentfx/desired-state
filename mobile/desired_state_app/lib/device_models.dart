/// The small common vocabulary shared by device adapters and diagnostics.
/// It intentionally describes capabilities, rather than assuming every sensor
/// is a heart-rate strap.
enum DeviceCapability { heartRate, rrInterval, spo2, pulse, motion, battery }

enum DeviceConnectionStatus { disconnected, connecting, connected, error }

class DeviceIdentity {
  const DeviceIdentity({
    required this.id,
    required this.name,
    required this.kind,
    required this.capabilities,
  });

  final String id;
  final String name;
  final String kind;
  final Set<DeviceCapability> capabilities;
}

/// A bounded, timestamped notification. Unknown packets deliberately remain
/// available to diagnostics; a decoder must never discard their raw bytes.
class RawBlePacket {
  const RawBlePacket({
    required this.receivedAt,
    required this.characteristic,
    required this.bytes,
    this.direction = BlePacketDirection.rx,
    this.interpretation,
  });

  final DateTime receivedAt;
  final String characteristic;
  final List<int> bytes;
  final BlePacketDirection direction;
  final String? interpretation;

  String get hex => bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}

enum BlePacketDirection { tx, rx }

class O2RingReading {
  const O2RingReading({
    required this.receivedAt,
    this.spo2,
    this.pulse,
    this.quality,
    this.motion,
    this.battery,
    this.perfusionIndexRaw,
    this.wornCode,
    this.rawFrame = const [],
    this.decoderVersion = 'bluetooth-sig-2a5f-v1',
  });

  final DateTime receivedAt;
  final int? spo2;
  final int? pulse;
  final int? quality;
  final double? motion;
  final int? battery;

  /// Protocol byte, without an assumed percent scaling.
  final int? perfusionIndexRaw;
  final int? wornCode;
  final List<int> rawFrame;
  final String decoderVersion;
  bool? get worn => wornCode == 0 ? false : (wornCode == 1 ? true : null);
  bool get usable => worn != false && spo2 != null && pulse != null;
}
