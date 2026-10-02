import 'dart:typed_data';

/// Polar PMD ACC protocol. Device timestamps are preserved, not treated as UTC.
class H10Acceleration {
  const H10Acceleration(
    this.receivedAt,
    this.sensorNanoseconds,
    this.frameType,
    this.sampleRate,
    this.rangeG,
    this.samples,
    this.raw,
  );
  final DateTime receivedAt;
  final BigInt sensorNanoseconds;
  final int frameType;
  final int sampleRate;
  final int rangeG;
  final List<List<int>> samples;
  final List<int> raw;
  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'received_utc': receivedAt.toUtc().toIso8601String(),
    'sensor_timestamp_ns': sensorNanoseconds.toString(),
    'timestamp_provenance': 'device_frame_end_ns_unsynchronized',
    'sample_timestamp_rule': 'frame_end_minus_remaining_samples_over_rate',
    'sample_rate_hz': sampleRate,
    'range_g': rangeG,
    'frame_type': frameType,
    'units': 'milli_g',
    'sample_count': samples.length,
    'xyz_mg': samples,
    'raw_frame': raw,
    'decoder_version': 'polar-pmd-acc-v1',
  };
}

class H10AccProtocol {
  static Map<int, List<int>> settings(
    List<int> bytes, {
    bool startAcknowledgment = false,
  }) {
    // Polar's PmdSetting accepts <=1-byte start-response parameter payloads.
    // A settings query still requires a complete TLV list.
    if (startAcknowledgment && bytes.length <= 1) return {};
    const widths = [2, 2, 2, 4, 1, 4, 16, 1, 1, 2, 4, 4, 1];
    final result = <int, List<int>>{};
    var offset = 0;
    while (offset < bytes.length) {
      if (offset + 2 > bytes.length) {
        throw const FormatException('Truncated PMD settings');
      }
      final type = bytes[offset++], count = bytes[offset++];
      if (type >= widths.length ||
          offset + count * widths[type] > bytes.length) {
        throw const FormatException('Invalid PMD settings');
      }
      final values = <int>[];
      for (var n = 0; n < count; n++) {
        var value = 0;
        for (var b = 0; b < widths[type]; b++) {
          if (b < 4) value |= bytes[offset + b] << (8 * b);
        }
        offset += widths[type];
        values.add(value);
      }
      result[type] = values;
    }
    return result;
  }

  static int choose(List<int>? values, List<int> preferred) {
    for (final value in preferred) {
      if (values?.contains(value) ?? false) return value;
    }
    throw const FormatException('No supported H10 accelerometer setting');
  }

  static List<int> start(int rate, int range) => [
    2,
    2,
    0,
    1,
    rate & 255,
    rate >> 8,
    1,
    1,
    16,
    0,
    2,
    1,
    range & 255,
    range >> 8,
  ];

  static double factor(Map<int, List<int>> settings) {
    final bits = settings[5]?.firstOrNull;
    if (bits == null) return 1;
    final data = ByteData(4)..setUint32(0, bits, Endian.little);
    final value = data.getFloat32(0, Endian.little);
    if (!value.isFinite || value <= 0) {
      throw const FormatException('Invalid ACC factor');
    }
    return value;
  }

  static H10Acceleration decode(
    List<int> bytes,
    DateTime receivedAt,
    int rate,
    int range, {
    double factor = 1,
  }) {
    if (bytes.length < 13 || bytes[0] != 2 || rate <= 0) {
      throw const FormatException('Invalid ACC frame');
    }
    var timestamp = BigInt.zero;
    for (var b = 0; b < 8; b++) {
      timestamp |= BigInt.from(bytes[b + 1]) << (b * 8);
    }
    final type = bytes[9] & 127, compressed = bytes[9] & 128 != 0;
    final payload = bytes.sublist(10);
    final samples = <List<int>>[];
    int signed(int offset, int width) {
      var value = 0;
      for (var b = 0; b < width; b++) {
        value |= payload[offset + b] << (b * 8);
      }
      final bits = width * 8;
      return value & (1 << (bits - 1)) == 0 ? value : value - (1 << bits);
    }

    if (!compressed) {
      if (type > 2 || payload.length % ((type + 1) * 3) != 0) {
        throw const FormatException('Invalid raw ACC sample length/type');
      }
      final width = type + 1;
      for (var offset = 0; offset < payload.length; offset += width * 3) {
        samples.add([
          for (var axis = 0; axis < 3; axis++)
            signed(offset + axis * width, width),
        ]);
      }
    } else {
      // H10 compressed TYPE_1 uses signed 16-bit references and LSB-first deltas.
      if (type != 1 || payload.length < 6) {
        throw const FormatException('Unsupported compressed ACC frame');
      }
      samples.add([signed(0, 2), signed(2, 2), signed(4, 2)]);
      var offset = 6;
      while (offset < payload.length) {
        if (offset + 2 > payload.length) {
          throw const FormatException('Truncated ACC delta header');
        }
        final width = payload[offset++], count = payload[offset++];
        final length = (width * count * 3 + 7) ~/ 8;
        if (width < 1 ||
            width > 32 ||
            count == 0 ||
            offset + length > payload.length) {
          throw const FormatException('Invalid ACC delta block');
        }
        var bit = 0;
        for (var n = 0; n < count; n++) {
          final next = <int>[];
          for (var axis = 0; axis < 3; axis++) {
            var delta = 0;
            for (var b = 0; b < width; b++, bit++) {
              delta |= ((payload[offset + bit ~/ 8] >> (bit % 8)) & 1) << b;
            }
            if (delta & (1 << (width - 1)) != 0) delta -= 1 << width;
            next.add(samples.last[axis] + delta);
          }
          samples.add(next);
        }
        offset += length;
      }
      if (factor != 1) {
        for (final sample in samples) {
          for (var axis = 0; axis < 3; axis++) {
            sample[axis] = (sample[axis] * factor).truncate();
          }
        }
      }
    }
    return H10Acceleration(
      receivedAt,
      timestamp,
      bytes[9],
      rate,
      range,
      samples,
      List<int>.of(bytes),
    );
  }
}
