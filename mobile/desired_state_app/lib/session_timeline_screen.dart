import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'eeg_live_panel.dart';
import 'session_controller.dart';

class TimelineReader {
  final Map<String, int> _offsets = {};
  final Map<String, String> _segments = {};
  final Map<String, List<(double, double)>> _cache = {};
  double? _lastStart;
  final List<(double, bool)> _rrWindow = [];
  int? _rrSegment;
  double? _rmssd(dynamic value, dynamic accepted, dynamic segment) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    if (_rrSegment != segment) {
      _rrWindow.clear();
      _rrSegment = segment is int ? segment : null;
    }
    _rrWindow.add((value.toDouble(), accepted == true));
    if (_rrWindow.length > 60) {
      _rrWindow.removeAt(0);
    }
    var count = 0, pairs = 0;
    var sum = 0.0;
    for (var i = 0; i < _rrWindow.length; i++) {
      if (!_rrWindow[i].$2) {
        continue;
      }
      count++;
      if (i > 0 && _rrWindow[i - 1].$2) {
        final d = _rrWindow[i].$1 - _rrWindow[i - 1].$1;
        sum += d * d;
        pairs++;
      }
    }
    return count >= 3 && pairs > 0 ? math.sqrt(sum / pairs) : null;
  }

  final List<String> warnings = [];
  Future<Map<String, List<(double, double)>>> read(
    Directory directory,
    DateTime origin,
    double start,
    double end, {
    bool incremental = false,
  }) async {
    if (!incremental || _lastStart == null || start < _lastStart!) {
      _offsets.clear();
      _cache.clear();
      _rrWindow.clear();
      _rrSegment = null;
      _segments.clear();
    }
    _lastStart = start;
    warnings.clear();
    var rowSegment = '';
    void add(String key, double time, dynamic value) {
      if (value is! num || value.isInfinite || time < start || time > end) {
        return;
      }
      final points = _cache.putIfAbsent(key, () => []);
      if (_segments.containsKey(key) && _segments[key] != rowSegment) {
        points.add((time, double.nan));
      }
      _segments[key] = rowSegment;
      points.add((time, value.toDouble()));
      // Preserve local extrema when reducing display points; never alter files.
      if (points.length > 6000) {
        final reduced = <(double, double)>[];
        for (var i = 0; i < points.length; i += 4) {
          final group = points.sublist(i, math.min(i + 4, points.length));
          if (group.any((v) => !v.$2.isFinite)) {
            reduced.add((group.first.$1, double.nan));
            continue;
          }
          final low = group.reduce((a, b) => a.$2 < b.$2 ? a : b),
              high = group.reduce((a, b) => a.$2 > b.$2 ? a : b);
          if (low.$1 <= high.$1) {
            reduced.add(low);
            if (high != low) {
              reduced.add(high);
            }
          } else {
            reduced.add(high);
            reduced.add(low);
          }
        }
        points
          ..clear()
          ..addAll(reduced);
      }
    }

    for (final name in [
      'measurements',
      'rr',
      'o2ring_measurements',
      'h10_accelerometer',
      'h10_ecg',
      'muse_eeg',
      'muse_bands',
      'events',
    ]) {
      final file = File('${directory.path}/$name.jsonl');
      if (!await file.exists()) {
        continue;
      }
      var offset = _offsets[name] ?? 0;
      if (offset > await file.length()) {
        offset = 0;
        _offsets[name] = 0;
      }
      final pending = <int>[];
      var consumed = offset;
      await for (final chunk in file.openRead(offset)) {
        for (final byte in chunk) {
          pending.add(byte);
          if (byte != 10) {
            continue;
          }
          consumed += pending.length;
          try {
            final row =
                jsonDecode(utf8.decode(pending)) as Map<String, dynamic>;
            rowSegment =
                '$name:${row['continuity_segment'] ?? 0}:${row['recording_segment'] ?? 0}';
            final timestamp = DateTime.tryParse('${row['received_utc']}');
            if (timestamp != null) {
              final seconds =
                  timestamp.difference(origin).inMicroseconds / 1000000;
              if (name == 'measurements') {
                add('BPM', seconds, row['heart_rate_bpm']);
              }
              if (name == 'rr') {
                add('RR (ms)', seconds, row['rr_ms']);
                add(
                  'RMSSD (ms)',
                  seconds,
                  _rmssd(
                    row['rr_ms'],
                    row['artifact_accepted'],
                    row['continuity_segment'],
                  ),
                );
              }
              if (name == 'o2ring_measurements') {
                add(
                  'SpO2 (%)',
                  seconds,
                  row['usable'] == false ? double.nan : row['spo2_percent'],
                );
                add(
                  'Pulse (bpm)',
                  seconds,
                  row['usable'] == false ? double.nan : row['pulse_bpm'],
                );
              }
              if (name == 'muse_bands' && row['channels'] is Map) {
                for (final band in ['Delta', 'Theta', 'Alpha', 'Beta']) {
                  final channels = (row['channels'] as Map).values
                      .whereType<Map>()
                      .toList();
                  if (channels.isNotEmpty &&
                      channels.length == row['total_channels']) {
                    add(
                      'EEG $band (µV²)',
                      seconds,
                      channels
                              .map((v) => (v[band] as num).toDouble())
                              .reduce((a, b) => a + b) /
                          channels.length,
                    );
                  } else {
                    add('EEG $band (µV²)', seconds, double.nan);
                  }
                }
              }
              if (name == 'h10_ecg' && row['samples_uv'] is List) {
                final samples = row['samples_uv'] as List;
                final rate = (row['sample_rate_hz'] as num?)?.toDouble() ?? 130;
                for (var i = 0; i < samples.length; i++) {
                  add(
                    'ECG (µV)',
                    seconds - (samples.length - 1 - i) / rate,
                    samples[i],
                  );
                }
              }
              if (name == 'h10_accelerometer' && row['xyz_mg'] is List) {
                final samples = row['xyz_mg'] as List;
                final rate = (row['sample_rate_hz'] as num?)?.toDouble() ?? 50;
                for (var i = 0; i < samples.length; i++) {
                  final xyz = samples[i] as List;
                  for (var axis = 0; axis < 3; axis++) {
                    add(
                      'ACC ${['X', 'Y', 'Z'][axis]} (mG)',
                      seconds - (samples.length - 1 - i) / rate,
                      xyz[axis],
                    );
                  }
                }
              }
              if (name == 'muse_eeg') {
                for (final field in ['eeg', 'accel', 'gyro']) {
                  if (row[field] is! Map) {
                    continue;
                  }
                  final rate =
                      (row[field == 'eeg' ? 'eeg_rate_hz' : 'motion_rate_hz']
                              as num?)
                          ?.toDouble() ??
                      (field == 'eeg' ? 256 : 52);
                  for (final entry in (row[field] as Map).entries) {
                    final samples = entry.value as List;
                    for (var i = 0; i < samples.length; i++) {
                      add(
                        'Muse $field ${entry.key}',
                        seconds - (samples.length - 1 - i) / rate,
                        samples[i],
                      );
                    }
                  }
                }
              }
              if (name == 'events' && row['event'] == 'marked_event') {
                add('Markers', seconds, 1);
              }
            }
          } catch (_) {
            if (warnings.length < 10) {
              warnings.add('Unreadable $name row omitted');
            }
          }
          pending.clear();
        }
      }
      // A partial last line remains for the next read after the writer flushes.
      _offsets[name] = consumed;
    }
    for (final points in _cache.values) {
      points.removeWhere((v) => v.$1 < start);
    }
    return {
      for (final entry in _cache.entries) entry.key: List.of(entry.value),
    };
  }
}

Future<(TimelineReader, Map<String, List<(double, double)>>)>
readTimelineInWorker(
  TimelineReader reader,
  String path,
  DateTime origin,
  double start,
  double end,
  bool incremental,
) async {
  final data = await reader.read(
    Directory(path),
    origin,
    start,
    end,
    incremental: incremental,
  );
  return (reader, data);
}

Future<(TimelineReader, Map<String, List<(double, double)>>)> runTimelineWorker(
  TimelineReader reader,
  String path,
  DateTime origin,
  double start,
  double end,
  bool incremental,
) {
  if (kIsWeb) {
    return readTimelineInWorker(reader, path, origin, start, end, incremental);
  }
  return Isolate.run(
    () => readTimelineInWorker(reader, path, origin, start, end, incremental),
  );
}

class SessionTimelineScreen extends StatefulWidget {
  const SessionTimelineScreen({
    super.key,
    required this.directory,
    required this.origin,
    required this.title,
    this.end,
    this.controller,
  });
  final Directory directory;
  final DateTime origin;
  final DateTime? end;
  final String title;
  final SessionController? controller;
  @override
  State<SessionTimelineScreen> createState() => _SessionTimelineScreenState();
}

class _SessionTimelineScreenState extends State<SessionTimelineScreen> {
  TimelineReader _reader = TimelineReader();
  Timer? _timer;
  Map<String, List<(double, double)>> _data = {};
  bool _loading = false, _follow = true, _raw = false;
  String? _error;
  DateTime? _lastActiveEnd;
  bool _finalRead = false;
  double _right = 0;
  int _seconds = 60;
  double _shownStart = 0, _shownEnd = 60;
  bool get _active =>
      widget.controller?.sessionLogger?.directory.path == widget.directory.path;
  double get _duration {
    final last = widget.controller?.lastSessionLogger;
    final stopped = last?.directory.path == widget.directory.path
        ? last?.stoppedAt
        : null;
    final end = _active
        ? DateTime.now()
        : widget.end ??
              stopped ??
              _lastActiveEnd ??
              widget.origin.add(const Duration(seconds: 60));
    return math.max(1, end.difference(widget.origin).inMicroseconds / 1000000);
  }

  @override
  void initState() {
    super.initState();
    _right = _duration;
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_follow &&
          (_active ||
              (!_finalRead &&
                  widget.controller?.lastSessionLogger?.directory.path ==
                      widget.directory.path))) {
        _refresh();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) {
      return;
    }
    if (_active) {
      _lastActiveEnd = DateTime.now();
    }
    setState(() => _loading = true);
    final right = _follow ? _duration : _right.clamp(0.0, _duration).toDouble();
    final left = math.max(0.0, right - _seconds);
    try {
      if (_active) {
        await widget.controller!.sessionLogger?.flush();
      }
      final reader = _reader;
      final path = widget.directory.path;
      final origin = widget.origin;
      final incremental = _follow && _active;
      final result = await runTimelineWorker(
        reader,
        path,
        origin,
        left,
        right,
        incremental,
      );
      _reader = result.$1;
      final data = result.$2;
      if (!_active) {
        _finalRead = true;
      }
      if (mounted) {
        setState(() {
          _data = data;
          _right = right;
          _shownStart = left;
          _shownEnd = right;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        IconButton(
          tooltip: 'Refresh signals',
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_active) const Text('Recording continues · viewing saved data'),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ChoiceChip(
              label: const Text('Follow live'),
              selected: _follow,
              onSelected: (_) {
                setState(() => _follow = true);
                _refresh();
              },
            ),
            for (final seconds in [30, 60, 300])
              ChoiceChip(
                label: Text('${seconds}s'),
                selected: _seconds == seconds,
                onSelected: (_) {
                  setState(() => _seconds = seconds);
                  _refresh();
                },
              ),
            IconButton(
              tooltip: 'Earlier interval',
              onPressed: _loading
                  ? null
                  : () {
                      setState(() {
                        _follow = false;
                        _right = math.max(1, _right - _seconds * .8);
                      });
                      _refresh();
                    },
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Later interval',
              onPressed: _loading
                  ? null
                  : () {
                      setState(() {
                        _follow = false;
                        _right = math.min(_duration, _right + _seconds * .8);
                      });
                      _refresh();
                    },
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Slider(
          value: _right.clamp(0.0, _duration).toDouble(),
          min: 0,
          max: _duration,
          onChanged: _loading
              ? null
              : (v) => setState(() {
                  _follow = false;
                  _right = v;
                }),
          onChangeEnd: (_) => _refresh(),
        ),
        Text(
          '${widget.origin.add(Duration(milliseconds: (_shownStart * 1000).round())).toLocal()} — ${widget.origin.add(Duration(milliseconds: (_shownEnd * 1000).round())).toLocal()}',
        ),
        SwitchListTile(
          title: const Text('Raw waveforms and motion'),
          value: _raw,
          onChanged: (v) => setState(() => _raw = v),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (_data.isEmpty && !_loading)
          const Text('No saved samples in this interval.'),
        for (final entry in _data.entries)
          if (entry.key != 'Markers' &&
              (_raw ||
                  (!entry.key.startsWith('ECG') &&
                      !entry.key.startsWith('ACC') &&
                      !entry.key.startsWith('Muse '))))
            _plot(entry.key, entry.value),
        for (final warning in _reader.warnings) Text(warning),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Raw samples retain device timestamps in the files. This view aligns batches by phone receipt time; waveform timing across devices is approximate. EEG bands require all channels to pass screening.',
          ),
        ),
      ],
    ),
  );
  Widget _plot(String title, List<(double, double)> points) {
    if (points.isEmpty) {
      return const SizedBox.shrink();
    }
    final finite = points.map((v) => v.$2).where((v) => v.isFinite).toList();
    if (finite.isEmpty) {
      return const SizedBox.shrink();
    }
    final low = finite.reduce(math.min), high = finite.reduce(math.max);
    final pad = math.max(.1, (high - low) * .1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        SizedBox(
          height: 150,
          width: double.infinity,
          child: CustomPaint(
            painter: EegAxisPainter(
              {title: points},
              left: _shownStart,
              right: math.max(_shownStart + .001, _shownEnd),
              minimum: low - pad,
              maximum: high + pad,
              yLabel: title,
              colors: {title: Colors.blue},
              maximumGapSeconds: null,
              events: _data['Markers']?.map((v) => v.$1).toList() ?? [],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
