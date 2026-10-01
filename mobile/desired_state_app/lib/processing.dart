import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

enum AnalysisMode { raw, range, screened }

/// Arithmetic summary of finite plotted samples, never of invented gap values.
class MetricSummary {
  MetricSummary(Iterable<double?> input) {
    final values = input.whereType<double>().where((v) => v.isFinite).toList();
    count = values.length;
    if (values.isEmpty) return;
    minimum = values.reduce(math.min);
    maximum = values.reduce(math.max);
    final scale = math.max(minimum!.abs(), maximum!.abs());
    average = scale == 0
        ? 0
        : values.fold<double>(0, (sum, v) => sum + (v / scale) / count) * scale;
    if (!average!.isFinite) average = null;
  }
  late final int count;
  double? minimum, maximum, average;
}

class ProcessingConfig {
  const ProcessingConfig({
    this.mode = AnalysisMode.raw,
    this.minimum = 300,
    this.maximum = 2000,
    this.deviation = 25,
    this.reference = 9,
    this.windowSeconds = 60,
    this.minimumSamples = 3,
    this.minimumPairs = 1,
    this.coverage = 50,
    this.metrics = const ['HR', 'RR', 'RMSSD'],
  });
  static const version = 'rr-configurable-v2';
  final AnalysisMode mode;
  final double minimum, maximum, deviation, coverage;
  final int reference, windowSeconds, minimumSamples, minimumPairs;
  final List<String> metrics;
  static const availableMetrics = [
    'HR',
    'RR',
    'RMSSD',
    'SDNN',
    'pNN50',
    'lnRMSSD',
  ];
  void validate() {
    if (!minimum.isFinite ||
        !maximum.isFinite ||
        minimum < 1 ||
        maximum > 10000 ||
        minimum >= maximum ||
        !deviation.isFinite ||
        deviation < 1 ||
        deviation > 100 ||
        reference < 3 ||
        reference > 99 ||
        windowSeconds < 5 ||
        windowSeconds > 3600 ||
        minimumSamples < 3 ||
        minimumSamples > 10000 ||
        minimumPairs < 1 ||
        minimumPairs > 10000 ||
        !coverage.isFinite ||
        coverage < 0 ||
        coverage > 100 ||
        metrics.isEmpty ||
        metrics.toSet().length != metrics.length ||
        metrics.any((m) => !availableMetrics.contains(m))) {
      throw const FormatException(
        'Check bounds, thresholds, window, minimum counts and selected metrics.',
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'processing_version': version,
    'purpose': 'derived_view_only',
    'recorded_flags_processing': 'mobile-median9-25pct-300-2000-v1',
    'mode': mode.name,
    'minimum_ms': minimum,
    'maximum_ms': maximum,
    'deviation_percent': deviation,
    'reference_count': reference,
    'window_seconds': windowSeconds,
    'minimum_samples': minimumSamples,
    'minimum_pairs': minimumPairs,
    'usable_percent': coverage,
    'metrics': metrics,
  };
  factory ProcessingConfig.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != 1 || json['processing_version'] != version) {
      throw const FormatException('Unsupported processing settings version');
    }
    final result = ProcessingConfig(
      mode: AnalysisMode.values.byName(json['mode'] as String),
      minimum: (json['minimum_ms'] as num).toDouble(),
      maximum: (json['maximum_ms'] as num).toDouble(),
      deviation: (json['deviation_percent'] as num).toDouble(),
      reference: json['reference_count'] as int,
      windowSeconds: json['window_seconds'] as int,
      minimumSamples: json['minimum_samples'] as int,
      minimumPairs: json['minimum_pairs'] as int,
      coverage: (json['usable_percent'] as num).toDouble(),
      metrics: List<String>.from(json['metrics'] as List),
    );
    result.validate();
    return result;
  }
}

class ProcessingStore {
  ProcessingStore({this.directoryProvider});
  final Future<Directory> Function()? directoryProvider;
  ProcessingConfig config = const ProcessingConfig();
  String? error;
  bool _loaded = false;
  bool get ready => _loaded && error == null;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  File? _file;
  Future<void> load() => _loading ??= _load();
  Future<void> retry() {
    _loading = null;
    return load();
  }

  Future<void> _load() async {
    try {
      final root =
          await (directoryProvider ?? getApplicationDocumentsDirectory)();
      _file = File('${root.path}/desired_state_settings/processing.json');
      if (await _file!.exists()) {
        config = ProcessingConfig.fromJson(
          jsonDecode(await _file!.readAsString()) as Map<String, dynamic>,
        );
      }
      error = null;
      _loaded = true;
    } catch (failure) {
      error = 'Could not load processing settings: $failure';
    }
  }

  Future<void> save(ProcessingConfig value) {
    final operation = _writes.then((_) async {
      await load();
      value.validate();
      if (error != null) throw StateError(error!);
      final file = _file!;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(value.toJson()), flush: true);
      await temp.rename(file.path);
      config = value;
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}

class RrInput {
  const RrInput(
    this.time,
    this.value,
    this.segment, {
    this.packetIndex,
    this.recordedAccepted,
  });
  final DateTime time;
  final double value;
  final int segment;
  final int? packetIndex;
  final bool? recordedAccepted;
}

class AnalysisResult {
  const AnalysisResult(
    this.input,
    this.accepted,
    this.reason,
    this.values,
    this.usable,
    this.total,
    this.pairs,
    this.missing,
    this.plotSegment,
  );
  final RrInput input;
  final bool accepted;
  final String? reason, missing;
  final Map<String, double?> values;
  final int usable, total, pairs;
  final int plotSegment;
}

/// Derived-only processing. No values or recorded flags are modified.
class RrProcessor {
  RrProcessor(this.config) {
    config.validate();
  }
  final ProcessingConfig config;
  final List<double> _reference = [], _candidates = [];
  final List<AnalysisResult> results = [];
  final List<(RrInput, bool)> _window = [];
  int? _segment;
  int _plotSegment = 0;
  DateTime? _previous;
  double _median(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  AnalysisResult add(RrInput input) {
    if (_segment != input.segment ||
        (_previous != null &&
            (input.time.isBefore(_previous!) ||
                input.time.difference(_previous!) >=
                    const Duration(seconds: 10)))) {
      _reference.clear();
      _candidates.clear();
      _window.clear();
      _plotSegment++;
    }
    _segment = input.segment;
    _previous = input.time;
    final rr = input.value;
    var accepted = rr.isFinite && rr > 0;
    String? reason = accepted ? null : 'nonpositive/nonfinite';
    if (accepted &&
        config.mode != AnalysisMode.raw &&
        (rr < config.minimum || rr > config.maximum)) {
      accepted = false;
      reason = 'outside configured range';
      _candidates.clear();
    } else if (accepted &&
        config.mode == AnalysisMode.screened &&
        _reference.isNotEmpty) {
      final median = _median(_reference);
      if ((rr - median).abs() > median * config.deviation / 100) {
        accepted = false;
        reason = 'deviation from recent accepted median';
        _candidates.add(rr);
        if (_candidates.length > config.reference) _candidates.removeAt(0);
        if (_candidates.length == config.reference) {
          final candidate = _median(_candidates);
          if (_candidates.every(
            (v) => (v - candidate).abs() <= candidate * config.deviation / 100,
          )) {
            _reference.clear();
            _reference.addAll(_candidates.take(_candidates.length - 1));
            accepted = true;
            reason = 'reference reset after sustained in-range change';
          }
        }
      }
    }
    if (accepted) {
      _candidates.clear();
      _reference.add(rr);
      if (_reference.length > config.reference) _reference.removeAt(0);
    } else if (!rr.isFinite || rr <= 0) {
      _candidates.clear();
    }
    _window.add((input, accepted));
    final cutoff = input.time.subtract(Duration(seconds: config.windowSeconds));
    _window.removeWhere((item) => item.$1.time.isBefore(cutoff));
    final usable = _window
        .where((item) => item.$2)
        .map((item) => item.$1.value)
        .toList();
    var pairs = 0, over50 = 0;
    var squares = 0.0;
    for (var i = 1; i < _window.length; i++) {
      if (_window[i - 1].$2 && _window[i].$2) {
        final d = _window[i].$1.value - _window[i - 1].$1.value;
        squares += d * d;
        pairs++;
        if (d.abs() > 50) over50++;
      }
    }
    final fraction = usable.length / _window.length * 100;
    String? missing;
    if (usable.length < config.minimumSamples) {
      missing = 'Warming up: too few usable RR';
    } else if (fraction < config.coverage) {
      missing = 'Usable RR fraction below threshold';
    } else if (pairs < config.minimumPairs) {
      missing = 'Too few adjacent usable pairs';
    }
    final mean = usable.isEmpty
        ? 0.0
        : usable.reduce((a, b) => a + b) / usable.length;
    final variance = usable.length < 2
        ? double.nan
        : usable.fold<double>(0, (sum, v) => sum + (v - mean) * (v - mean)) /
              (usable.length - 1);
    final rmssd = pairs == 0 ? double.nan : math.sqrt(squares / pairs);
    double? gate(double v) => missing == null && v.isFinite ? v : null;
    final values = <String, double?>{
      'RR': config.mode == AnalysisMode.raw || accepted
          ? (rr.isFinite ? rr : null)
          : null,
      'RMSSD': gate(rmssd),
      'SDNN': gate(math.sqrt(variance)),
      'pNN50': gate(pairs == 0 ? double.nan : 100 * over50 / pairs),
      'lnRMSSD': gate(rmssd > 0 ? math.log(rmssd) : double.nan),
    };
    final result = AnalysisResult(
      input,
      accepted,
      reason,
      values,
      usable.length,
      _window.length,
      pairs,
      missing ??
          (values['RMSSD'] == null ? 'Numerical result unavailable' : null),
      _plotSegment,
    );
    results.add(result);
    return result;
  }
}
