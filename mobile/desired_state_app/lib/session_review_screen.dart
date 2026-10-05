import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'eeg_bands.dart';
import 'eeg_live_panel.dart';
import 'processing.dart';
import 'session_history.dart';
import 'session_analysis.dart';
import 'signal_review.dart';
import 'session_controller.dart';

class SessionReviewScreen extends StatefulWidget {
  const SessionReviewScreen({
    super.key,
    required this.session,
    required this.repository,
    this.signalLoader,
    this.replayLoader,
    this.controller,
    this.onLive,
  });
  final SessionController? controller;
  final VoidCallback? onLive;
  final HistorySession session;
  final SessionHistoryRepository repository;
  final Future<SignalReview> Function(HistoryEntry, int)? signalLoader;
  final Future<ReplayReview> Function(HistoryEntry, double, double)?
  replayLoader;
  @override
  State<SessionReviewScreen> createState() => _SessionReviewScreenState();
}

class _SessionReviewScreenState extends State<SessionReviewScreen> {
  late final _origin = widget.session.entry.started ?? DateTime(1970);
  late double _duration = _sessionDuration();
  late RangeValues _range = RangeValues(0, _duration);
  late RangeValues _baseline = RangeValues(0, math.min(60.0, _duration));
  int _hrvSeconds = 60, _eegSeconds = 4;
  bool _relative = false, _saving = false;
  String? _channel, _notice;
  double? _locked;
  double _replayStart = 0;
  late List<HrvBlock> _blocks = hrvBlocks(widget.session, _hrvSeconds);
  late Future<SignalReview> _signals = _loadSignals();
  late Future<ReplayReview> _replay = _readReplay(0, math.min(10.0, _duration));
  Future<ReplayReview> _readReplay(double start, double end) =>
      widget.replayLoader != null
      ? widget.replayLoader!(widget.session.entry, start, end)
      : replaySignals(widget.session.entry, start, end);
  Future<SignalReview> _loadSignals() async {
    final result = await (widget.signalLoader != null
        ? widget.signalLoader!(widget.session.entry, _eegSeconds)
        : reviewSignals(widget.session.entry, eegSeconds: _eegSeconds));
    if (mounted && result.endTime != null) {
      final seconds =
          result.endTime!.difference(_origin).inMicroseconds / 1000000;
      if (seconds > _duration) {
        setState(() {
          final full = _range.end == _duration;
          _duration = seconds;
          if (full) {
            _range = RangeValues(_range.start, seconds);
          }
          _loadReplay();
        });
      }
    }
    return result;
  }

  double _sessionDuration() {
    final times = [
      ...widget.session.hr.map((p) => p.time),
      ...widget.session.rr.map((p) => p.time),
      ...widget.session.entry.events
          .map((e) => DateTime.tryParse('${e['received_utc']}'))
          .whereType<DateTime>(),
    ];
    return math.max(
      1.0,
      times.isEmpty
          ? 1.0
          : times
                .map((t) => t.difference(_origin).inMicroseconds / 1000000)
                .reduce(math.max),
    );
  }

  DateTime _time(double seconds) =>
      _origin.add(Duration(microseconds: (seconds * 1000000).round()));
  String _interval(RangeValues values) =>
      '${_time(values.start).toLocal()} to ${_time(values.end).toLocal()}';
  void _loadReplay() {
    final last = math.max(_range.start, _range.end - 10);
    _replayStart = _replayStart.clamp(_range.start, last).toDouble();
    _replay = _readReplay(
      _replayStart,
      math.min(_range.end, _replayStart + 10),
    );
  }

  Widget _plot(
    String title,
    Map<String, List<(double, double)>> series,
    String unit, {
    double? minimum,
    double? maximum,
    double? left,
    double? right,
    Map<String, double> references = const {},
  }) {
    final finite = series.values
        .expand((s) => s)
        .map((p) => p.$2)
        .where((v) => v.isFinite)
        .toList();
    if (finite.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('$title: no usable data in this interval'),
      );
    }
    final low = minimum ?? finite.reduce(math.min),
        high = maximum ?? finite.reduce(math.max);
    final padding = math.max(.1, (high - low).abs() * .1);
    final lo = minimum ?? low - padding, hi = maximum ?? high + padding;
    final colors = <String, Color>{};
    const palette = [
      Colors.blue,
      Colors.teal,
      Colors.deepOrange,
      Colors.purple,
    ];
    for (final (index, name) in series.keys.indexed) {
      colors[name] = switch (name) {
        'Alpha' => Colors.blue,
        'Theta' => Colors.teal,
        'Beta' => Colors.deepOrange,
        'Delta' => Colors.purple,
        _ => palette[index % palette.length],
      };
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        SizedBox(
          height: 220,
          width: double.infinity,
          child: CustomPaint(
            painter: EegAxisPainter(
              series,
              left: left ?? _range.start,
              right: math.max(
                (left ?? _range.start) + .001,
                right ?? _range.end,
              ),
              minimum: lo,
              maximum: hi,
              yLabel: '$title ($unit)',
              colors: colors,
              references: references,
              showPoints: false,
              events: [
                for (final e in widget.session.entry.events)
                  if (e['event'] == 'marked_event' ||
                      '${e['event']}'.startsWith('practice_'))
                    if (DateTime.tryParse('${e['received_utc']}') != null)
                      DateTime.parse('${e['received_utc']}')
                              .difference(_origin)
                              .inMicroseconds /
                          1000000,
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 12,
          children: [
            for (final entry in series.entries)
              if (entry.value.any((p) => p.$2.isFinite))
                Text(
                  '${entry.key}: min ${entry.value.map((p) => p.$2).where((v) => v.isFinite).reduce(math.min).toStringAsFixed(2)} / max ${entry.value.map((p) => p.$2).where((v) => v.isFinite).reduce(math.max).toStringAsFixed(2)} $unit',
                  style: TextStyle(color: colors[entry.key]),
                ),
          ],
        ),
      ],
    );
  }

  List<(double, double)> _metricPoints(String name) {
    final points = <(double, double)>[];
    for (final b in _blocks) {
      final t = b.end.difference(_origin).inMicroseconds / 1000000;
      if (b.start.isBefore(_time(_range.start)) ||
          b.end.isAfter(_time(_range.end))) {
        continue;
      }
      // Insert a break between nonoverlapping summary windows; no interpolation
      // implies continuous high-resolution HRV measurements.
      points.add((t - .001, double.nan));
      points.add((t, b.metrics[name] ?? double.nan));
    }
    return points;
  }

  Map<String, double> _reference(SignalReview review) {
    final available = review.bands.expand((b) => b.frame.channels.keys).toSet();
    final channel = available.contains(_channel) ? _channel : null;
    final frames = review.bands
        .where(
          (b) =>
              !b.frame.time.isBefore(_time(_baseline.start)) &&
              !b.frame.time.isAfter(_time(_baseline.end)),
        )
        .map((b) => b.frame.values(channel, relative: _relative))
        .where((v) => v.isNotEmpty)
        .toList();
    return {
      if (frames.isNotEmpty)
        for (final name in eegBands.keys)
          name: frames.fold<double>(0, (s, v) => s + v[name]!) / frames.length,
    };
  }

  List<String> _eegObservations(SignalReview review) {
    final available = review.bands.expand((b) => b.frame.channels.keys).toSet();
    final channel = available.contains(_channel) ? _channel : null;
    final baseline = _reference(review);
    final cutoff = _time(math.max(_range.start, _range.end - 20));
    final recent = review.bands
        .where(
          (b) =>
              !b.frame.time.isBefore(cutoff) &&
              !b.frame.time.isAfter(_time(_range.end)),
        )
        .map((b) => b.frame.values(channel, relative: _relative))
        .where((v) => v.isNotEmpty)
        .toList();
    if (baseline.isEmpty ||
        recent.length < 3 ||
        _baseline.end > _range.end - 20) {
      return [
        'Choose a separate baseline and a later interval with at least three usable EEG windows to compare band power.',
      ];
    }
    return [
      for (final name in ['Alpha', 'Theta', 'Beta'])
        'Mean $name: baseline ${baseline[name]!.toStringAsFixed(2)}, final usable windows ${(recent.fold<double>(0, (s, v) => s + v[name]!) / recent.length).toStringAsFixed(2)} ${_relative ? '%' : 'µV²'} (${recent.length} windows in the final 20 seconds of this view). Changing channel availability and eye/muscle artifacts may influence this comparison.',
    ];
  }

  Future<void> _save(SignalReview? signals) async {
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await widget.repository.recordAnalysisReview(widget.session.entry, {
        'method': 'descriptive-session-review-v1',
        'purpose': 'derived_review_only',
        'view_start_utc': _time(_range.start).toUtc().toIso8601String(),
        'view_end_utc': _time(_range.end).toUtc().toIso8601String(),
        'baseline_start_utc': _time(_baseline.start).toUtc().toIso8601String(),
        'baseline_end_utc': _time(_baseline.end).toUtc().toIso8601String(),
        'rr_settings': {
          'method': 'screened-median9-25pct-300-2000-v1',
          'window_seconds': _hrvSeconds,
          'minimum_usable_rr': 30,
          'minimum_pairs': 20,
          'minimum_accepted_fraction': .8,
          'minimum_receipt_span_fraction': .8,
          'rr_duration_estimate_fraction_bounds': [.8, 1.2],
        },
        'eeg_settings': {
          'method': 'hann_periodogram_1_30hz_v1',
          'window_seconds': _eegSeconds,
          'channel':
              signals != null &&
                  signals.bands.any(
                    (b) => b.frame.channels.containsKey(_channel),
                  )
              ? _channel
              : 'mean_of_usable',
          'relative_power': _relative,
          'maximum_centered_amplitude_uv': 250,
          'maximum_step_uv': 150,
          'minimum_variance_uv2': .01,
          'reference_band_power': signals == null ? {} : _reference(signals),
        },
        'hrv_windows': [
          for (final b in _blocks)
            if (!b.start.isBefore(_time(_range.start)) &&
                !b.end.isAfter(_time(_range.end)))
              b.toJson(),
        ],
        'observations': h10Observations(
          _blocks,
          _time(_range.start),
          _time(_range.end),
          _time(_baseline.start),
          _time(_baseline.end),
        ),
        'eeg_observations': signals == null
            ? <String>[]
            : _eegObservations(signals),
        'eeg_processed_windows': signals?.windows ?? 0,
        'eeg_usable_windows': signals?.usableWindows ?? 0,
        'timing': 'host_receipt_approximation_not_cross_device_synchronized',
      });
      if (mounted) {
        setState(
          () => _notice = 'Review settings and summary saved separately; included in session exports.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _notice = 'Review not saved: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Session analysis')),
    body: FutureBuilder<SignalReview>(
      future: _signals,
      builder: (context, snapshot) {
        final signals = snapshot.data;
        final start = _time(_range.start), end = _time(_range.end);
        final hr = widget.session.hr
            .where((p) => !p.time.isBefore(start) && !p.time.isAfter(end))
            .toList();
        final hrSummary = MetricSummary(hr.map((p) => p.value));
        final selected = _blocks
            .where((b) => !b.start.isBefore(start) && !b.end.isAfter(end))
            .toList();
        final qualified = selected.where((b) => b.ready).toList();
        final total = selected.fold<int>(0, (s, b) => s + b.total);
        final usable = selected.fold<int>(0, (s, b) => s + b.usable);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (widget.controller != null)
              ListenableBuilder(
                listenable: widget.controller!,
                builder: (context, _) =>
                    widget.controller!.sessionLogger == null
                    ? const SizedBox.shrink()
                    : ListTile(
                        title: Text(
                          widget.controller!.recordingState ==
                                  RecordingState.paused
                              ? 'Recording paused in Live'
                              : 'Recording continues in Live',
                        ),
                        trailing: TextButton(
                          onPressed:
                              widget.onLive ??
                              () => Navigator.popUntil(
                                context,
                                (route) => route.isFirst,
                              ),
                          child: const Text('Live'),
                        ),
                      ),
              ),
            Text(
              widget.session.entry.participant,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(widget.session.entry.id),
            const Text(
              'Descriptive review. Original recordings stay unchanged. HRV is screened device RR, not ECG-verified normal beats. Breathing, posture and movement need context.',
            ),
            const Text(
              'Timeline uses session seconds and phone receipt alignment. EEG/ECG device clocks are not synchronized; fine cross-device timing cannot be inferred.',
            ),
            const SizedBox(height: 12),
            Text('Viewing ${_interval(_range)}'),
            RangeSlider(
              min: 0,
              max: _duration,
              values: _range,
              onChanged: (v) {
                if (v.end - v.start < .1) {
                  return;
                }
                setState(() => _range = v);
              },
              onChangeEnd: (_) => setState(_loadReplay),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final seconds in [60, 300, 900, 0])
                  TextButton(
                    onPressed: () => setState(() {
                      _range = RangeValues(
                        0,
                        seconds == 0
                            ? _duration
                            : math.min(seconds.toDouble(), _duration),
                      );
                      _loadReplay();
                    }),
                    child: Text(seconds == 0 ? 'All' : '${seconds}s'),
                  ),
              ],
            ),
            ExpansionTile(
              initiallyExpanded: true,
              title: const Text('H10 analysis overview'),
              children: [
                Text(
                  'Mean device HR ${hrSummary.average?.toStringAsFixed(1) ?? '--'} bpm · min ${hrSummary.minimum?.toStringAsFixed(1) ?? '--'} / max ${hrSummary.maximum?.toStringAsFixed(1) ?? '--'} · ${hrSummary.count} measurements',
                ),
                Text(
                  '$usable/$total RR accepted within complete selected windows. Acceptance is a sample fraction, not measured time coverage.',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final seconds in [60, 300])
                      ChoiceChip(
                        label: Text('${seconds}s RR windows'),
                        selected: _hrvSeconds == seconds,
                        onSelected: (_) => setState(() {
                          _hrvSeconds = seconds;
                          _blocks = hrvBlocks(widget.session, seconds);
                          _baseline = RangeValues(
                            0,
                            math.min(seconds.toDouble(), _duration),
                          );
                        }),
                      ),
                  ],
                ),
                if (qualified.isNotEmpty)
                  Text(
                    'Latest qualified window: ${qualified.last.start.toLocal()} to ${qualified.last.end.toLocal()}',
                  ),
                if (qualified.isNotEmpty)
                  Wrap(
                    spacing: 12,
                    children: [
                      for (final name in ['RMSSD', 'SDNN', 'pNN50', 'lnRMSSD'])
                        Text(
                          '$name ${qualified.last.metrics[name]?.toStringAsFixed(2) ?? '--'} ${name == 'pNN50'
                              ? '%'
                              : name == 'lnRMSSD'
                              ? 'ln(ms)'
                              : 'ms'}',
                        ),
                    ],
                  ),
                for (final observation in h10Observations(
                  _blocks,
                  start,
                  end,
                  _time(_baseline.start),
                  _time(_baseline.end),
                ))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(observation),
                  ),
                const Text(
                  'Provisional window checks: ≥30 usable RR, ≥20 adjacent pairs, ≥80% acceptance/receipt span; RR-duration estimate 80–120% of window and one continuity segment. These are engineering checks, not clinically validated confidence.',
                ),
              ],
            ),
            ExpansionTile(
              title: const Text('Baseline interval'),
              children: [
                Text(_interval(_baseline)),
                RangeSlider(
                  min: 0,
                  max: _duration,
                  values: _baseline,
                  onChanged: (v) {
                    if (v.end - v.start >= .1) {
                      setState(() => _baseline = v);
                    }
                  },
                ),
                const Text(
                  'HRV comparison uses the last qualified full window in this baseline interval and the last separate qualified window in the view. EEG baseline averages usable band windows in this interval; no eye/muscle artifact guarantee.',
                ),
              ],
            ),
            ExpansionTile(
              title: const Text('Shared timeline · HR & HRV'),
              children: [
                _plot('Heart rate', {
                  'HR': [
                    for (final p in hr)
                      (
                        p.time.difference(_origin).inMicroseconds / 1000000,
                        p.value ?? double.nan,
                      ),
                  ],
                }, 'bpm'),
                _plot('RMSSD windows', {'RMSSD': _metricPoints('RMSSD')}, 'ms'),
                _plot('SDNN windows', {'SDNN': _metricPoints('SDNN')}, 'ms'),
                const Text(
                  'HRV points represent separate complete windows. EEG below uses this same time range; purple lines mark session/practice events. Gaps remain unavailable.',
                ),
              ],
            ),
            ExpansionTile(
              title: const Text('EEG post-processing'),
              children: [
                if (snapshot.connectionState != ConnectionState.done)
                  const LinearProgressIndicator(),
                if (snapshot.hasError)
                  Text('EEG review failed: ${snapshot.error}'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final seconds in [2, 4])
                      ChoiceChip(
                        label: Text('${seconds}s EEG window'),
                        selected: _eegSeconds == seconds,
                        onSelected: (_) => setState(() {
                          _eegSeconds = seconds;
                          _signals = _loadSignals();
                        }),
                      ),
                    ChoiceChip(
                      label: const Text('Absolute µV²'),
                      selected: !_relative,
                      onSelected: (_) => setState(() {
                        _relative = false;
                        _locked = null;
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('Relative %'),
                      selected: _relative,
                      onSelected: (_) => setState(() {
                        _relative = true;
                        _locked = null;
                      }),
                    ),
                  ],
                ),
                if (signals != null) _eegContent(signals),
              ],
            ),
            ExpansionTile(
              title: const Text('Raw ECG & EEG replay'),
              children: [
                Text(
                  '10-second excerpt starting ${_replayStart.toStringAsFixed(1)} seconds after session start',
                ),
                Slider(
                  min: _range.start,
                  max: math.max(_range.start + .001, _range.end - 10),
                  value: _replayStart
                      .clamp(
                        _range.start,
                        math.max(_range.start + .001, _range.end - 10),
                      )
                      .toDouble(),
                  onChanged: (v) => setState(() => _replayStart = v),
                  onChangeEnd: (_) => setState(_loadReplay),
                ),
                FutureBuilder<ReplayReview>(
                  future: _replay,
                  builder: (context, replay) {
                    if (replay.hasError) {
                      return Text('Replay failed: ${replay.error}');
                    }
                    if (!replay.hasData) {
                      return const LinearProgressIndicator();
                    }
                    final data = replay.data!;
                    double extent(Map<String, List<(double, double)>> series) =>
                        math.max(
                          1.0,
                          series.values
                                  .expand((p) => p)
                                  .map((p) => p.$2.abs())
                                  .where((v) => v.isFinite)
                                  .fold<double>(0, math.max) *
                              1.1,
                        );
                    return Column(
                      children: [
                        _plot(
                          'Raw ECG',
                          data.ecg,
                          'µV',
                          minimum: -extent(data.ecg),
                          maximum: extent(data.ecg),
                          left: _replayStart,
                          right: math.min(_range.end, _replayStart + 10),
                        ),
                        _plot(
                          'Raw EEG',
                          data.eeg,
                          'µV',
                          minimum: -extent(data.eeg),
                          maximum: extent(data.eeg),
                          left: _replayStart,
                          right: math.min(_range.end, _replayStart + 10),
                        ),
                        for (final warning in data.warnings) Text(warning),
                      ],
                    );
                  },
                ),
                const Text(
                  'ECG is displayed from recorded PMD frames. Automatic ECG beat detection and ECG-based HRV are not implemented; device RR remains the HRV source.',
                ),
              ],
            ),
            ExpansionTile(
              title: const Text('Markers, practice & session events'),
              children: [
                for (final event in widget.session.entry.events.where((e) {
                  final time = DateTime.tryParse('${e['received_utc']}');
                  return time != null &&
                      !time.isBefore(start) &&
                      !time.isAfter(end) &&
                      (e['event'] == 'marked_event' ||
                          '${e['event']}'.startsWith('practice_') ||
                          e['event'] == 'session_paused' ||
                          e['event'] == 'session_resumed');
                }))
                  ListTile(
                    title: Text(
                      '${event['event']} · ${event['marker_label'] ?? event['description'] ?? ''}',
                    ),
                    subtitle: Text('${event['received_utc']}'),
                  ),
              ],
            ),
            for (final warning in {
              ...widget.session.warnings,
              ...?signals?.warnings,
            })
              Text(warning),
            FilledButton.icon(
              onPressed:
                  _saving || snapshot.connectionState != ConnectionState.done
                  ? null
                  : () => _save(signals),
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving…' : 'Save analysis review'),
            ),
            if (_notice != null) Text(_notice!),
          ],
        );
      },
    ),
  );
  Widget _eegContent(SignalReview signals) {
    final channels =
        signals.bands.expand((b) => b.frame.channels.keys).toSet().toList()
          ..sort();
    final effectiveChannel = channels.contains(_channel) ? _channel : null;
    final series = <String, List<(double, double)>>{
      for (final band in eegBands.keys) band: [],
    };
    int? previousSegment;
    for (final b in signals.bands) {
      final t = b.frame.time.difference(_origin).inMicroseconds / 1000000;
      if (t < _range.start || t > _range.end) {
        continue;
      }
      final values = b.frame.values(effectiveChannel, relative: _relative);
      for (final band in series.keys) {
        if (previousSegment != null && previousSegment != b.segment) {
          series[band]!.add((t, double.nan));
        }
        series[band]!.add((t, values[band] ?? double.nan));
      }
      previousSegment = b.segment;
    }
    final reference = _reference(signals);
    final maxPower =
        [
          ...series.values
              .expand((p) => p)
              .map((p) => p.$2)
              .where((v) => v.isFinite),
          ...reference.values,
        ].fold<double>(1, math.max) *
        1.1;
    final maximum = _relative ? 100.0 : _locked ?? maxPower;
    return Column(
      children: [
        Text(
          '${signals.usableWindows}/${signals.windows} EEG windows have at least one provisionally usable channel. Channel availability can change over time.',
        ),
        DropdownButton<String>(
          value: effectiveChannel ?? '',
          isExpanded: true,
          items: [
            const DropdownMenuItem(
              value: '',
              child: Text('Mean of usable channels'),
            ),
            for (final name in channels)
              DropdownMenuItem(value: name, child: Text(name)),
          ],
          onChanged: (v) => setState(() => _channel = v == '' ? null : v),
        ),
        _plot(
          'EEG band power',
          series,
          _relative ? '%' : 'µV²',
          minimum: 0,
          maximum: maximum,
          references: reference,
        ),
        if (!_relative)
          TextButton(
            onPressed: () =>
                setState(() => _locked = _locked == null ? maximum : null),
            child: Text(
              _locked == null ? 'Lock shared scale' : 'Auto shared scale',
            ),
          ),
        Wrap(
          spacing: 12,
          children: [
            for (final entry in reference.entries)
              Text(
                'Baseline ${entry.key}: ${entry.value.toStringAsFixed(2)} ${_relative ? '%' : 'µV²'}',
              ),
          ],
        ),
        for (final observation in _eegObservations(signals))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(observation),
          ),
        const Text(
          'All bands share zero and one scale. Dashed lines are the selected baseline. Bands are recomputed from raw saved samples with continuity resets; no relaxation/sleep classification.',
        ),
      ],
    );
  }
}
