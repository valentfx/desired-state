import 'dart:math';

/// Provisional artifact screening; accepted RR is not ECG-verified NN data.
class RrHistory {
  final List<double> _raw = [];
  final List<double> _clean = [];
  final List<bool> _accepted = [];
  final Set<int> _breaks = {};
  int _artifactCount = 0;

  List<double> get raw => List.unmodifiable(_raw);
  List<double> get clean => List.unmodifiable(_clean);
  int get rawCount => _raw.length;
  int get cleanCount => _clean.length;
  int get artifactCount => _artifactCount;

  List<RrSample> addAll(Iterable<double> intervals) {
    final samples = <RrSample>[];
    for (final rr in intervals) {
      // Preserve every input, including rejected values, in acquisition order.
      _raw.add(rr);
      var accepted = rr.isFinite && rr >= 300 && rr <= 2000;
      String? artifactReason;
      if (!accepted) {
        artifactReason = 'outside_300_to_2000_ms';
      }
      if (accepted && _clean.isNotEmpty) {
        final recent = _clean.sublist(max(0, _clean.length - 9))..sort();
        final middle = recent.length ~/ 2;
        final median = recent.length.isOdd
            ? recent[middle]
            : (recent[middle - 1] + recent[middle]) / 2;
        accepted = (rr - median).abs() <= median * 0.25;
        if (!accepted) {
          artifactReason = 'more_than_25_percent_from_recent_median';
        }
      }
      _accepted.add(accepted);
      if (accepted) {
        _clean.add(rr);
      } else {
        _artifactCount++;
      }
      samples.add(
        RrSample(rrMs: rr, accepted: accepted, artifactReason: artifactReason),
      );
    }
    return samples;
  }

  /// Latest 60 acquired intervals, using only adjacent accepted pairs.
  /// Rejected beats break adjacency; old clean beats cannot mask a bad window.
  double? get rmssd {
    final start = max(0, _raw.length - 60);
    var acceptedCount = 0;
    var pairs = 0;
    var sumSquares = 0.0;
    for (var i = start; i < _raw.length; i++) {
      if (!_accepted[i]) {
        continue;
      }
      acceptedCount++;
      if (i > start && _accepted[i - 1] && !_breaks.contains(i)) {
        final difference = _raw[i] - _raw[i - 1];
        sumSquares += difference * difference;
        pairs++;
      }
    }
    return acceptedCount >= 3 && pairs > 0 ? sqrt(sumSquares / pairs) : null;
  }

  /// A recording pause is not a successive heartbeat pair.
  void breakSequence() => _breaks.add(_raw.length);

  /// Bound a diagnostic preview while retaining adjacency and screening state.
  /// Session histories do not call this; their raw acquisition rows stay intact.
  void retainLatest(int count) {
    if (count < 60) {
      throw ArgumentError('Keep at least 60 intervals');
    }
    final remove = _raw.length - count;
    if (remove <= 0) {
      return;
    }
    final breaks = _breaks
        .where((index) => index >= remove)
        .map((index) => index - remove)
        .toList();
    _raw.removeRange(0, remove);
    _accepted.removeRange(0, remove);
    _breaks
      ..clear()
      ..addAll(breaks);
    _clean
      ..clear()
      ..addAll([
        for (var i = 0; i < _raw.length; i++)
          if (_accepted[i]) _raw[i],
      ]);
    _artifactCount = _accepted.where((value) => !value).length;
  }

  void clear() {
    _raw.clear();
    _clean.clear();
    _accepted.clear();
    _breaks.clear();
    _artifactCount = 0;
  }
}

class RrSample {
  const RrSample({
    required this.rrMs,
    required this.accepted,
    this.artifactReason,
  });

  final double rrMs;
  final bool accepted;
  final String? artifactReason;
}
