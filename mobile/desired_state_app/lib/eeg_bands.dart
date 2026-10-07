import 'dart:math' as math;

const eegBands = <String, (double, double)>{
  'Delta': (1, 4),
  'Theta': (4, 8),
  'Alpha': (8, 13),
  'Beta': (13, 30),
};

/// Uses the same window and limits as band-power processing. This is an
/// artifact screen, not electrode impedance or a clinical quality measure.
class EegWindowQuality {
  const EegWindowQuality(this.samples, this.reason);
  final int samples;
  final String? reason;
  bool get usable => reason == null;
}

EegWindowQuality assessEegWindow(
  List<double> samples,
  int rate, {
  int maximumSamples = 1024,
}) {
  if (rate < 64) {
    return const EegWindowQuality(0, 'Waiting for sample rate');
  }
  var n = 1;
  while (n * 2 <= samples.length && n * 2 <= maximumSamples) {
    n *= 2;
  }
  if (n < rate * 2) {
    return EegWindowQuality(n, 'Waiting for at least 2 seconds');
  }
  final source = samples.sublist(samples.length - n);
  if (source.any((v) => !v.isFinite)) {
    return EegWindowQuality(n, 'Invalid sample');
  }
  final mean = source.reduce((a, b) => a + b) / n;
  var variance = 0.0;
  for (var i = 0; i < n; i++) {
    final centered = source[i] - mean;
    if (centered.abs() > 250) {
      return EegWindowQuality(n, 'Large amplitude (>250 µV centered)');
    }
    if (i > 0 && (source[i] - source[i - 1]).abs() > 150) {
      return EegWindowQuality(n, 'Abrupt change (>150 µV/sample)');
    }
    variance += centered * centered;
  }
  if (variance / n < 0.01) {
    return EegWindowQuality(n, 'Flat signal (variance <0.01 µV²)');
  }
  return EegWindowQuality(n, null);
}

/// Detrended Hann-window periodogram, one-sided power in microvolts squared.
/// All bands use identical samples, window normalization and channel scaling.
Map<String, double>? eegBandPower(
  List<double> samples,
  int rate, {
  int maximumSamples = 1024,
}) {
  final quality = assessEegWindow(
    samples,
    rate,
    maximumSamples: maximumSamples,
  );
  if (!quality.usable) {
    return null;
  }
  final n = quality.samples;
  final source = samples.sublist(samples.length - n);
  final mean = source.reduce((a, b) => a + b) / n;
  final real = List<double>.filled(n, 0), imaginary = List<double>.filled(n, 0);
  var windowEnergy = 0.0;
  for (var i = 0; i < n; i++) {
    final weight = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    real[i] = (source[i] - mean) * weight;
    windowEnergy += weight * weight;
  }
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    while ((j & bit) != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      final swap = real[i];
      real[i] = real[j];
      real[j] = swap;
    }
  }
  for (var length = 2; length <= n; length *= 2) {
    for (var start = 0; start < n; start += length) {
      for (var k = 0; k < length ~/ 2; k++) {
        final angle = -2 * math.pi * k / length;
        final wr = math.cos(angle), wi = math.sin(angle);
        final a = start + k, b = a + length ~/ 2;
        final tr = wr * real[b] - wi * imaginary[b];
        final ti = wr * imaginary[b] + wi * real[b];
        real[b] = real[a] - tr;
        imaginary[b] = imaginary[a] - ti;
        real[a] += tr;
        imaginary[a] += ti;
      }
    }
  }
  final result = {for (final band in eegBands.keys) band: 0.0};
  for (var k = 1; k <= n ~/ 2; k++) {
    final frequency = k * rate / n;
    final power =
        (k == n ~/ 2 ? 1 : 2) *
        (real[k] * real[k] + imaginary[k] * imaginary[k]) /
        (n * windowEnergy);
    for (final band in eegBands.entries) {
      if (frequency >= band.value.$1 && frequency < band.value.$2) {
        result[band.key] = result[band.key]! + power;
      }
    }
  }
  return result;
}

class EegBandFrame {
  const EegBandFrame(this.time, this.channels, this.channelCount);
  final DateTime time;
  final Map<String, Map<String, double>> channels;
  final int channelCount;
  Map<String, double> values(String? channel, {bool relative = false}) {
    final selected = channel == null
        ? channels.values.toList()
        : [?channels[channel]];
    if (selected.isEmpty) return {};
    final result = {
      for (final name in eegBands.keys)
        name:
            selected.map((p) => p[name]!).reduce((a, b) => a + b) /
            selected.length,
    };
    if (relative) {
      final total = result.values.reduce((a, b) => a + b);
      if (total <= 0) return {};
      return result.map((key, value) => MapEntry(key, value * 100 / total));
    }
    return result;
  }
}
