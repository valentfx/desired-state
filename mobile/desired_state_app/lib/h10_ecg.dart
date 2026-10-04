/// Polar H10 PMD ECG type 0: signed 24-bit samples in microvolts.
/// Device frame timestamp is retained separately from host receipt time.
class H10EcgFrame {
  const H10EcgFrame(
    this.receivedAt,
    this.sensorNanoseconds,
    this.sampleRate,
    this.samples,
    this.raw,
  );
  final DateTime receivedAt;
  final BigInt sensorNanoseconds;
  final int sampleRate;
  final List<int> samples, raw;
  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'received_utc': receivedAt.toUtc().toIso8601String(),
    'sensor_timestamp_ns': sensorNanoseconds.toString(),
    'timestamp_provenance': 'polar_device_frame_end_ns_unsynchronized',
    'sample_timestamp_rule': 'frame_end_minus_remaining_samples_over_rate',
    'sample_rate_hz': sampleRate,
    'frame_type': 0,
    'units': 'microvolt',
    'sample_count': samples.length,
    'samples_uv': samples,
    'raw_frame': raw,
    'decoder_version': 'polar-pmd-ecg-type0-v1',
  };
}

class H10EcgProtocol {
  static List<int> start(int rate, int resolution) => [
    2,
    0,
    0,
    1,
    rate & 255,
    rate >> 8,
    1,
    1,
    resolution & 255,
    resolution >> 8,
  ];
  static H10EcgFrame decode(List<int> bytes, DateTime receivedAt, int rate) {
    if (rate <= 0 ||
        bytes.length < 13 ||
        bytes[0] != 0 ||
        bytes[9] != 0 ||
        (bytes.length - 10) % 3 != 0) {
      throw const FormatException('Unsupported or malformed H10 ECG frame');
    }
    var timestamp = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      timestamp |= BigInt.from(bytes[i + 1]) << (8 * i);
    }
    final samples = <int>[];
    for (var i = 10; i < bytes.length; i += 3) {
      var value = bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16);
      if ((value & 0x800000) != 0) value -= 0x1000000;
      samples.add(value);
    }
    return H10EcgFrame(
      receivedAt,
      timestamp,
      rate,
      List.unmodifiable(samples),
      List.unmodifiable(bytes),
    );
  }
}
