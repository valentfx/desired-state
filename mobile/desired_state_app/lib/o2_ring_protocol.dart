/// Frame handling for the legacy Viatom protocol observed on O2Ring 704916.
/// BLE notification boundaries are not protocol frame boundaries.
class ViatomFrameAssembler {
  final List<int> _buffer = [];
  DateTime? _lastFragment;
  int rejectedFrames = 0;

  void reset() {
    _buffer.clear();
    _lastFragment = null;
  }

  List<List<int>> add(List<int> bytes, DateTime receivedAt) {
    if (_lastFragment != null &&
        receivedAt.difference(_lastFragment!) > const Duration(seconds: 4)) {
      reset();
    }
    _lastFragment = receivedAt;
    _buffer.addAll(bytes);
    final frames = <List<int>>[];
    while (_buffer.isNotEmpty) {
      final start = _buffer.indexOf(0x55);
      if (start < 0) {
        _buffer.clear();
        break;
      }
      if (start > 0) _buffer.removeRange(0, start);
      if (_buffer.length < 7) break;
      final length = _buffer[5] | (_buffer[6] << 8);
      if (_buffer[2] != (_buffer[1] ^ 0xff) || length > 256) {
        rejectedFrames++;
        _buffer.removeAt(0);
        continue;
      }
      final size = 8 + length;
      if (_buffer.length < size) break;
      final frame = _buffer.sublist(0, size);
      if (viatomCrc8(frame.sublist(0, size - 1)) != frame.last) {
        rejectedFrames++;
        _buffer.removeAt(0);
        continue;
      }
      frames.add(List<int>.unmodifiable(frame));
      _buffer.removeRange(0, size);
    }
    return frames;
  }
}

int viatomCrc8(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
    }
  }
  return crc;
}
