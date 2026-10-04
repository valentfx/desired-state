import 'dart:math' as math;

import 'processing.dart';
import 'session_history.dart';

class HrvBlock {
  const HrvBlock(
    this.start,
    this.end,
    this.total,
    this.usable,
    this.pairs,
    this.receiptSpan,
    this.rrDuration,
    this.ready,
    this.metrics,
    this.meanHr,
  );
  final DateTime start, end;
  final int total, usable, pairs;
  final double receiptSpan, rrDuration;
  final bool ready;
  final Map<String, double?> metrics;
  final double? meanHr;
  double get acceptance => total == 0 ? 0 : 100 * usable / total;
  Map<String, dynamic> toJson() => {
    'start_utc': start.toUtc().toIso8601String(),
    'end_utc': end.toUtc().toIso8601String(),
    'total_rr': total,
    'usable_rr': usable,
    'adjacent_pairs': pairs,
    'receipt_span_seconds': receiptSpan,
    'rr_duration_estimate_seconds': rrDuration,
    'qualified': ready,
    'metrics': metrics,
    'mean_hr_bpm': meanHr,
  };
}

/// Fixed-duration, nonoverlapping RR summaries. No pair crosses a rejection,
/// source/processing segment, clock reversal, pause or detected receipt gap.
List<HrvBlock> hrvBlocks(HistorySession session, int seconds) {
  final origin =
      session.entry.started ??
      (session.rr.isEmpty ? DateTime(1970) : session.rr.first.time);
  final processor = RrProcessor(
    ProcessingConfig(
      mode: AnalysisMode.screened,
      windowSeconds: seconds,
      metrics: const ['HR', 'RMSSD', 'SDNN', 'pNN50', 'lnRMSSD'],
    ),
  );
  final groups = <int, List<AnalysisResult>>{};
  for (final rr in session.rr) {
    final result = processor.add(RrInput(rr.time, rr.value, rr.segment));
    final index =
        rr.time.difference(origin).inMicroseconds ~/ (seconds * 1000000);
    if (rr.time.isBefore(origin)) continue;
    groups.putIfAbsent(index, () => []).add(result);
  }
  final blocks = <HrvBlock>[];
  for (final index in groups.keys.toList()..sort()) {
    final group = groups[index]!;
    final good = group.where((r) => r.accepted).toList();
    final start = origin.add(Duration(seconds: index * seconds));
    final end = start.add(Duration(seconds: seconds));
    final hr = session.hr
        .where((p) => !p.time.isBefore(start) && p.time.isBefore(end))
        .map((p) => p.value);
    final hrMean = MetricSummary(hr).average;
    var pairs = 0, over50 = 0;
    var squares = 0.0;
    for (var i = 1; i < group.length; i++) {
      final a = group[i - 1], b = group[i];
      if (!a.accepted || !b.accepted || a.plotSegment != b.plotSegment) {
        continue;
      }
      final delta = b.input.value - a.input.value;
      squares += delta * delta;
      pairs++;
      if (delta.abs() > 50) over50++;
    }
    final receiptSpan =
        group.last.input.time
            .difference(group.first.input.time)
            .inMicroseconds /
        1000000;
    final duration = good.fold<double>(
      0,
      (sum, r) => sum + r.input.value / 1000,
    );
    final ready =
        good.length >= 30 &&
        pairs >= 20 &&
        good.length / group.length >= .8 &&
        receiptSpan >= seconds * .8 &&
        duration >= seconds * .8 &&
        duration <= seconds * 1.2 &&
        group.map((r) => r.plotSegment).toSet().length == 1;
    final mean = good.isEmpty
        ? 0.0
        : good.fold<double>(0, (s, r) => s + r.input.value) / good.length;
    final variance = good.length < 2
        ? double.nan
        : good.fold<double>(
                0,
                (s, r) => s + (r.input.value - mean) * (r.input.value - mean),
              ) /
              (good.length - 1);
    final rmssd = pairs == 0 ? double.nan : math.sqrt(squares / pairs);
    double? gate(double value) => ready && value.isFinite ? value : null;
    blocks.add(
      HrvBlock(
        start,
        end,
        group.length,
        good.length,
        pairs,
        receiptSpan,
        duration,
        ready,
        {
          'RMSSD': gate(rmssd),
          'SDNN': gate(math.sqrt(variance)),
          'pNN50': gate(pairs == 0 ? double.nan : 100.0 * over50 / pairs),
          'lnRMSSD': gate(rmssd > 0 ? math.log(rmssd) : double.nan),
        },
        hrMean,
      ),
    );
  }
  return blocks;
}

List<String> h10Observations(
  List<HrvBlock> blocks,
  DateTime start,
  DateTime end,
  DateTime baselineStart,
  DateTime baselineEnd,
) {
  final selected = blocks
      .where((b) => !b.start.isBefore(start) && !b.end.isAfter(end))
      .toList();
  final qualified = selected.where((b) => b.ready).toList();
  final baseline = qualified
      .where(
        (b) => !b.start.isBefore(baselineStart) && !b.end.isAfter(baselineEnd),
      )
      .toList();
  final observations = <String>[
    '${qualified.length}/${selected.length} complete RR windows pass provisional overview checks.',
  ];
  if (baseline.isEmpty ||
      qualified.isEmpty ||
      qualified.last.start.isBefore(baseline.last.end)) {
    observations.add(
      'No separate qualified baseline and later window available for a trend comparison.',
    );
    return observations;
  }
  final a = baseline.last, b = qualified.last;
  String interval(HrvBlock v) => '${v.start.toLocal()} to ${v.end.toLocal()}';
  for (final name in ['RMSSD', 'SDNN', 'pNN50']) {
    final x = a.metrics[name], y = b.metrics[name];
    if (x == null || y == null) continue;
    final d = y - x;
    final unit = name == 'pNN50' ? 'percentage points' : 'ms';
    observations.add(
      '$name ${d.abs() < .05 ? 'was unchanged at displayed precision' : '${d > 0 ? 'increased' : 'decreased'} by ${d.abs().toStringAsFixed(1)} $unit'}: baseline ${x.toStringAsFixed(1)}, later ${y.toStringAsFixed(1)}. Baseline ${interval(a)}; later ${interval(b)}.',
    );
  }
  if (a.meanHr != null && b.meanHr != null) {
    observations.add(
      'Mean device heart rate: baseline ${a.meanHr!.toStringAsFixed(1)} bpm; later ${b.meanHr!.toStringAsFixed(1)} bpm over those same intervals.',
    );
  }
  observations.add(
    'These are observed changes, not a nervous-system diagnosis. Breathing, posture, movement and recording quality can affect the pattern.',
  );
  return observations;
}
