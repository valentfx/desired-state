import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'processing_presets.dart';
import 'plot_viewport.dart';

import 'processing.dart';
import 'session_controller.dart';
import 'session_history.dart';
import 'history_plot.dart';

/// One configurable view for live inputs and reopened immutable session rows.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({
    super.key,
    required this.controller,
    this.session,
    this.repository,
    this.embedded = false,
    this.header = const [],
  });
  final bool embedded;
  final List<Widget> header;
  final SessionController controller;
  final HistorySession? session;
  final SessionHistoryRepository? repository;
  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  bool _ready = false, _follow = true, _saving = false;
  String? _notice;
  String? _error, _configuration, _sessionId;
  RrProcessor? _processor;
  DateTime? _left, _right;
  HistoryPoint? _selected;
  String _metric = '';
  int? _preset;
  DateTime? _overlayCursor;
  late final List<RrInput>? _saved = widget.session?.rr
      .map(
        (r) => RrInput(
          r.time,
          r.value,
          r.segment,
          packetIndex: r.row['rr_index'] is int
              ? r.row['rr_index'] as int
              : null,
          recordedAccepted: r.row['artifact_accepted'] is bool
              ? r.row['artifact_accepted'] as bool
              : null,
        ),
      )
      .toList();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    if (widget.embedded) _preset = 60;
    _ready = widget.controller.processing.ready;
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool retry = false}) async {
    if (retry) {
      await widget.controller.processing.retry();
    } else {
      await widget.controller.processing.load();
    }
    if (mounted) {
      setState(() {
        _error = widget.controller.processing.error;
        _ready = _error == null;
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  Future<void> _settings() async {
    final config = await Navigator.push<ProcessingConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => ProcessingEditor(
          config: widget.controller.processing.config,
          presets: ProcessingPresets(
            directoryProvider: widget.controller.directoryProvider,
          ),
        ),
      ),
    );
    if (config == null || !mounted) return;
    await _apply(config);
  }

  Future<void> _apply(ProcessingConfig config) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await widget.controller.saveProcessing(config);
      if (!mounted) return;
      setState(() {
        _selected = null;
        _error = null;
      });
      final entry = widget.session?.entry;
      if (entry != null && !widget.repository!.isActive(entry.id)) {
        try {
          await widget.repository!.recordProcessingView(entry, config);
        } catch (e) {
          if (mounted) {
            setState(
              () => _error =
                  'Settings saved; history configuration journal failed: $e',
            );
          }
        }
      }
      if (mounted) setState(() => _notice = 'Settings applied');
    } catch (e) {
      if (mounted) setState(() => _error = 'Settings not fully saved: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final inputs = _saved ?? controller.analysisInputs;
    final config = controller.processing.config;
    final key = jsonEncode(config.toJson());
    final sessionId =
        widget.session?.entry.id ??
        controller.sessionLogger?.sessionId ??
        controller.lastSessionLogger?.sessionId;
    if (_configuration != key ||
        _processor == null ||
        _processor!.results.length > inputs.length ||
        _sessionId != sessionId) {
      _processor = RrProcessor(config);
      _configuration = key;
      _sessionId = sessionId;
      _selected = null;
      _overlayCursor = null;
    }
    final processor = _processor!;
    for (var i = processor.results.length; i < inputs.length; i++) {
      processor.add(inputs[i]);
    }
    final sourceHr =
        widget.session?.hr ??
        [
          for (final p in controller.timeline)
            HistoryPoint(p.timestamp, p.heartRate.toDouble(), p.segment),
        ];
    final hr = <HistoryPoint>[];
    var hrSegment = 0;
    for (var i = 0; i < sourceHr.length; i++) {
      final point = sourceHr[i];
      if (i > 0 &&
          (point.segment != sourceHr[i - 1].segment ||
              point.time.isBefore(sourceHr[i - 1].time) ||
              point.time.difference(sourceHr[i - 1].time) >=
                  const Duration(seconds: 10))) {
        hrSegment++;
      }
      hr.add(HistoryPoint(point.time, point.value, hrSegment));
    }
    final events =
        widget.session?.entry.events
            .where((e) => e['event'] == 'marked_event')
            .map((e) => DateTime.tryParse('${e['received_utc']}'))
            .whereType<DateTime>()
            .toList() ??
        controller.eventTimes;
    final times = {
      ...inputs.map((p) => p.time),
      ...hr.map((p) => p.time),
      ...events,
    }.toList()..sort();
    final first = times.isEmpty ? DateTime(1970) : times.first;
    final last = times.isEmpty ? first : times.last;
    DateTime clamp(DateTime time) => time.isBefore(first)
        ? first
        : time.isAfter(last)
        ? last
        : time;
    final end = _follow ? last : clamp(_right ?? last);
    final start = _follow
        ? (_preset == null
              ? first
              : clamp(end.subtract(Duration(seconds: _preset!))))
        : clamp(_left ?? first);
    final latest = processor.results.isEmpty ? null : processor.results.last;
    if (widget.embedded && _ready) {
      final series = <String, List<HistoryPoint>>{
        for (final metric in config.metrics)
          metric: metric == 'HR'
              ? hr
              : [
                  for (final r in processor.results)
                    HistoryPoint(r.input.time, r.values[metric], r.plotSegment),
                ],
      };
      String format(double? value) =>
          value != null && value.isFinite ? value.toStringAsFixed(1) : '--';
      final summaries = <Widget>[];
      for (final entry in series.entries) {
        final visible = entry.value
            .where((p) => !p.time.isBefore(start) && !p.time.isAfter(end))
            .toList();
        final summary = MetricSummary(visible.map((p) => p.value));
        HistoryPoint? selected;
        if (_overlayCursor != null && visible.isNotEmpty) {
          selected = visible.reduce(
            (a, b) =>
                a.time.difference(_overlayCursor!).abs() <=
                    b.time.difference(_overlayCursor!).abs()
                ? a
                : b,
          );
        }
        final current = selected ?? (visible.isEmpty ? null : visible.last);
        summaries.add(
          Tooltip(
            message:
                'Finite visible samples; arithmetic, not time-weighted average. Current/inspected sample at ${current?.time.toLocal() ?? '--'}',
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${entry.key == 'HR' ? 'BPM' : entry.key} ${format(current?.value)} ${_unit(entry.key)} | min ${format(summary.minimum)} avg ${format(summary.average)} max ${format(summary.maximum)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _color(entry.key),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );
      }
      void navigate({double shift = 0, double zoom = 1}) {
        final range = plotViewport(
          first: first,
          last: last,
          start: start,
          end: end,
          shift: shift,
          zoom: zoom,
        );
        setState(() {
          _follow = false;
          _left = range.$1;
          _right = range.$2;
          _overlayCursor = null;
        });
      }

      Widget panel(double height) => SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: _saving ? null : _settings,
                    icon: const Icon(Icons.tune, size: 18),
                    label: Text(
                      'Filters & metrics: ${config.mode.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                DropdownButton<int>(
                  value: _preset ?? 0,
                  items: [
                    for (final seconds in [30, 60, 300, 900, 3600, 0])
                      DropdownMenuItem(
                        value: seconds,
                        child: Text(seconds == 0 ? 'All' : '${seconds}s'),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _preset = v == 0 ? null : v;
                    _follow = true;
                    _overlayCursor = null;
                  }),
                ),
                IconButton(
                  tooltip: 'Back to live',
                  onPressed: () => setState(() {
                    _follow = true;
                    _overlayCursor = null;
                  }),
                  icon: Icon(
                    _follow ? Icons.play_circle_outline : Icons.play_circle,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Earlier data',
                  onPressed: () => navigate(shift: -0.8),
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: 'Zoom in',
                  onPressed: () => navigate(zoom: 0.5),
                  icon: const Icon(Icons.zoom_in),
                ),
                IconButton(
                  tooltip: 'Zoom out',
                  onPressed: () => navigate(zoom: 2),
                  icon: const Icon(Icons.zoom_out),
                ),
                IconButton(
                  tooltip: 'Later data',
                  onPressed: () => navigate(shift: 0.8),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            if (times.length > 1)
              SizedBox(
                height: 30,
                child: RangeSlider(
                  values: RangeValues(
                    times
                        .indexWhere((time) => !time.isBefore(start))
                        .clamp(0, times.length - 1)
                        .toDouble(),
                    times
                        .lastIndexWhere((time) => !time.isAfter(end))
                        .clamp(0, times.length - 1)
                        .toDouble(),
                  ),
                  min: 0,
                  max: (times.length - 1).toDouble(),
                  onChanged: (value) {
                    if (value.end - value.start < 1) return;
                    setState(() {
                      _follow = false;
                      _left = times[value.start.round()];
                      _right = times[value.end.round()];
                      _overlayCursor = null;
                    });
                  },
                ),
              ),
            const Text(
              'Relative trends · drag to browse, tap for values',
              style: TextStyle(fontSize: 12),
            ),
            if (_error != null)
              Text(_error!, maxLines: 2, overflow: TextOverflow.ellipsis),
            Expanded(
              child: RelativeOverlayPlot(
                series: series,
                colors: {
                  for (final metric in series.keys) metric: _color(metric),
                },
                start: start,
                end: end,
                events: events,
                cursor: _overlayCursor,
                onPan: (fraction) => navigate(shift: -fraction),
                onInspect: (time) => setState(() {
                  _overlayCursor = time;
                  _follow = false;
                  _left = start;
                  _right = end;
                }),
              ),
            ),
            Text(
              _overlayCursor == null
                  ? '${start.toLocal().toString().substring(11, 19)} - ${end.toLocal().toString().substring(11, 19)}'
                  : 'Inspecting ${_overlayCursor!.toLocal()} (nearest samples)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            ...summaries,
          ],
        ),
      );
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          ...widget.header,
          panel(
            400.0 +
                (summaries.length - 2).clamp(0, 99) * 24 +
                (MediaQuery.textScalerOf(context).scale(14) - 14) * 12,
          ),
          ExpansionTile(
            title: const Text('BPM & HRV details'),
            subtitle: const Text(
              'Native units · numeric axes · visible min/max',
            ),
            children: [
              for (final entry in series.entries)
                HistoryPlot(
                  title: entry.key == 'HR' ? 'Heart rate' : entry.key,
                  unit: _unit(entry.key),
                  points: entry.value,
                  start: start,
                  end: end,
                  events: events,
                  color: _color(entry.key),
                  cursor: _overlayCursor,
                  onInspect: (point) => setState(() {
                    _overlayCursor = point.time;
                    _follow = false;
                    _left = start;
                    _right = end;
                  }),
                ),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Select HRV values in Filters & metrics. Open H10 ECG waveform in Live for the acquired ECG.',
                ),
              ),
            ],
          ),
        ],
      );
    }
    final content = SafeArea(
      child: !_ready
          ? ListView(
              padding: const EdgeInsets.all(12),
              children: [
                ...widget.header,
                Text(_error ?? 'Loading settings…'),
                TextButton(
                  onPressed: () => _load(retry: true),
                  child: const Text('Retry'),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                ...widget.header,
                Row(
                  children: [
                    const Expanded(child: Text('Filters & metrics')),
                    if (widget.embedded)
                      IconButton(
                        tooltip: 'Processing settings',
                        onPressed: _ready && !_saving ? _settings : null,
                        icon: const Icon(Icons.tune),
                      ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final mode in AnalysisMode.values)
                      ChoiceChip(
                        label: Text(switch (mode) {
                          AnalysisMode.raw => 'Raw',
                          AnalysisMode.range => 'Range only',
                          AnalysisMode.screened => 'Screened',
                        }),
                        selected: config.mode == mode,
                        onSelected: _saving
                            ? null
                            : (_) => _apply(
                                ProcessingConfig.fromJson({
                                  ...config.toJson(),
                                  'mode': mode.name,
                                }),
                              ),
                      ),
                  ],
                ),
                const Text(
                  'Visible-range statistics: finite plotted samples; arithmetic average, not time-weighted.',
                ),
                for (final metric in config.metrics)
                  _summary(
                    metric,
                    metric == 'HR'
                        ? hr
                        : [
                            for (final r in processor.results)
                              HistoryPoint(
                                r.input.time,
                                r.values[metric],
                                r.plotSegment,
                              ),
                          ],
                    start,
                    end,
                  ),
                if (!widget.embedded && controller.sessionLogger != null)
                  Text(
                    '${controller.recordingState.name} · ${controller.connectionStatus} · last data ${controller.lastDataAge?.inSeconds ?? '-'}s',
                  ),
                if (widget.session != null)
                  Text(
                    'Saved snapshot: ${widget.session!.entry.participant} · ${widget.session!.entry.id}',
                  ),
                if (_saving) const Text('Saving settings…'),
                if (_notice != null) Text(_notice!),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (widget.session != null &&
                    widget.session!.warnings.isNotEmpty)
                  Text('Data warnings: ${widget.session!.warnings.join('; ')}'),
                Text(
                  '${config.mode.name} · ${ProcessingConfig.version} · ${config.windowSeconds}s receipt-time window',
                ),
                Text(
                  'Bounds ${config.minimum}–${config.maximum} ms · deviation ${config.deviation}% · reference ${config.reference} RR · minimum ${config.minimumSamples} samples / ${config.minimumPairs} pairs / ${config.coverage}% usable RR',
                ),
                const Text(
                  'Derived view only. Recorded flags stay unchanged. Gaps restart warm-up. Usable percentage is sample acceptance, not time coverage. Screening is provisional, not ECG-verified NN.',
                ),
                if (config.mode == AnalysisMode.screened)
                  Text(
                    'Reference resets after ${config.reference} consecutive in-range deviations clustered within the threshold; prior rejected RR remain excluded.',
                  ),
                if (latest != null)
                  Text(
                    'Latest window at ${latest.input.time.toLocal()}: ${latest.usable}/${latest.total} usable · ${latest.pairs} adjacent pairs · ${latest.missing ?? 'metrics available'}',
                  ),
                if (inputs.isEmpty)
                  const Text(
                    'No recorded RR yet. Start recording on Live or open a saved session.',
                  ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final seconds in <int?>[30, 60, 300, 900, 3600, null])
                      ChoiceChip(
                        label: Text(seconds == null ? 'All' : '${seconds}s'),
                        selected: _follow && _preset == seconds,
                        onSelected: (_) => setState(() {
                          _follow = true;
                          _preset = seconds;
                          _selected = null;
                        }),
                      ),
                    TextButton(
                      onPressed: () => setState(() {
                        _follow = true;
                        _preset = null;
                        _selected = null;
                      }),
                      child: Text(
                        widget.session == null
                            ? 'Back to live / Fit data'
                            : 'Fit data',
                      ),
                    ),
                  ],
                ),
                Text(
                  '${_follow ? (widget.session == null ? 'Following live' : 'Full/preset range') : 'Inspecting'} · ${start.toLocal()} – ${end.toLocal()}',
                ),
                if (times.length > 1)
                  RangeSlider(
                    values: RangeValues(
                      times
                          .indexWhere((t) => !t.isBefore(start))
                          .clamp(0, times.length - 1)
                          .toDouble(),
                      times
                          .lastIndexWhere((t) => !t.isAfter(end))
                          .clamp(0, times.length - 1)
                          .toDouble(),
                    ),
                    min: 0,
                    max: (times.length - 1).toDouble(),
                    divisions: times.length - 1,
                    onChanged: (value) {
                      if (value.end - value.start < 1) return;
                      setState(() {
                        _follow = false;
                        _left = times[value.start.round()];
                        _right = times[value.end.round()];
                        _selected = null;
                      });
                    },
                  ),
                for (final metric in config.metrics) ...[
                  HistoryPlot(
                    title: metric,
                    unit: _unit(metric),
                    points: metric == 'HR'
                        ? hr
                        : [
                            for (final (i, r) in processor.results.indexed)
                              HistoryPoint(
                                r.input.time,
                                r.values[metric],
                                r.plotSegment,
                                sourceIndex: i,
                              ),
                          ],
                    start: start,
                    end: end,
                    events: events,
                    color: _color(metric),
                    cursor: _selected?.time,
                    onInspect: (point) => setState(() {
                      _selected = point;
                      _metric = metric;
                      _follow = false;
                      _left = start;
                      _right = end;
                    }),
                  ),
                  if (_selected != null && _metric == metric)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$metric: ${_selected!.value?.toStringAsFixed(3) ?? 'unavailable'} ${_unit(metric)} · ${_selected!.time.toUtc()}',
                            ),
                            if (_selected!.sourceIndex != null) ...[
                              _inspection(
                                processor.results[_selected!.sourceIndex!],
                              ),
                              Wrap(
                                children: [
                                  for (final delta in [-1, 1])
                                    TextButton(
                                      onPressed:
                                          _selected!.sourceIndex! + delta < 0 ||
                                              _selected!.sourceIndex! + delta >=
                                                  processor.results.length
                                          ? null
                                          : () {
                                              final index =
                                                  _selected!.sourceIndex! +
                                                  delta;
                                              final r =
                                                  processor.results[index];
                                              setState(() {
                                                _selected = HistoryPoint(
                                                  r.input.time,
                                                  r.values[metric],
                                                  r.plotSegment,
                                                  sourceIndex: index,
                                                );
                                              });
                                            },
                                      child: Text(
                                        delta < 0 ? 'Previous RR' : 'Next RR',
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
    );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Processing & plots'),
        actions: [
          IconButton(
            tooltip: 'Processing settings',
            onPressed: _ready && !_saving ? _settings : null,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: content,
    );
  }

  Widget _summary(
    String metric,
    List<HistoryPoint> points,
    DateTime start,
    DateTime end,
  ) {
    final summary = MetricSummary(
      points
          .where((p) => !p.time.isBefore(start) && !p.time.isAfter(end))
          .map((p) => p.value),
    );
    String format(double? value) => value?.toStringAsFixed(2) ?? '--';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$metric (${_unit(metric)}) - ${summary.count} values'),
            Text(
              'Min ${format(summary.minimum)} | Max ${format(summary.maximum)} | Avg ${format(summary.average)}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _inspection(AnalysisResult result) => Text(
    'Raw RR ${result.input.value} ms · packet position ${result.input.packetIndex ?? 'unknown'}\nRecorded accepted: ${result.input.recordedAccepted ?? 'unknown'} · current: ${result.accepted ? 'accepted' : 'excluded'} ${result.reason ?? ''}\n${result.usable}/${result.total} usable · ${result.pairs} pairs · ${result.missing ?? (result.values[_metric] == null ? 'Selected metric undefined or numerically unavailable' : 'metrics available')}',
  );
  String _unit(String metric) => metric == 'HR'
      ? 'bpm'
      : metric == 'pNN50'
      ? '%'
      : metric == 'lnRMSSD'
      ? 'ln(ms)'
      : 'ms';
  Color _color(String metric) => switch (metric) {
    'HR' => Colors.blue.shade700,
    'RR' => Colors.teal.shade700,
    'RMSSD' => Colors.orange.shade800,
    'SDNN' => Colors.indigo,
    'pNN50' => Colors.brown,
    _ => Colors.pink.shade700,
  };
}

class ProcessingEditor extends StatefulWidget {
  const ProcessingEditor({super.key, required this.config, this.presets});
  final ProcessingPresets? presets;
  final ProcessingConfig config;
  @override
  State<ProcessingEditor> createState() => _ProcessingEditorState();
}

class _ProcessingEditorState extends State<ProcessingEditor> {
  late AnalysisMode _mode = widget.config.mode;
  late final _metrics = widget.config.metrics.toSet();
  late final List<TextEditingController> _fields = [
    widget.config.minimum,
    widget.config.maximum,
    widget.config.deviation,
    widget.config.reference,
    widget.config.windowSeconds,
    widget.config.minimumSamples,
    widget.config.minimumPairs,
    widget.config.coverage,
  ].map((v) => TextEditingController(text: v.toString())).toList();
  String? _error;
  static const _labels = [
    'Minimum RR ms (1–9999)',
    'Maximum RR ms (2–10000)',
    'Deviation % (1–100)',
    'Reference count (3–99)',
    'Window seconds (5–3600)',
    'Minimum samples (3–10000)',
    'Minimum pairs (1–10000)',
    'Minimum usable RR % (0–100)',
  ];
  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  ProcessingConfig _read() {
    double d(int i) => double.parse(_fields[i].text.trim());
    int n(int i) => int.parse(_fields[i].text.trim());
    final config = ProcessingConfig(
      mode: _mode,
      minimum: d(0),
      maximum: d(1),
      deviation: d(2),
      reference: n(3),
      windowSeconds: n(4),
      minimumSamples: n(5),
      minimumPairs: n(6),
      coverage: d(7),
      metrics: _metrics.toList(),
    );
    config.validate();
    return config;
  }

  void _save() {
    try {
      Navigator.pop(context, _read());
    } catch (e) {
      setState(() => _error = 'Invalid settings: $e');
    }
  }

  late final _presets = widget.presets ?? ProcessingPresets();
  String _presetName = 'Current / modified';
  bool _busy = false;
  Future<void> _operation(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(ProcessingPreset preset) {
    final c = preset.config;
    setState(() {
      _mode = c.mode;
      _metrics
        ..clear()
        ..addAll(c.metrics);
      final values = [
        c.minimum,
        c.maximum,
        c.deviation,
        c.reference,
        c.windowSeconds,
        c.minimumSamples,
        c.minimumPairs,
        c.coverage,
      ];
      for (var i = 0; i < _fields.length; i++) {
        _fields[i].text = values[i].toString();
      }
      _presetName = preset.name;
    });
  }

  Future<String?> _text(
    String title, {
    String initial = '',
    bool json = false,
  }) async {
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _PresetTextPage(title: title, initial: initial, json: json),
      ),
    );
  }

  Future<void> _choosePreset() => _operation(() async {
    final defaultConfig = await loadDefaultProcessing();
    final custom = await _presets.load();
    if (!mounted) return;
    final choices = [
      ProcessingPreset('Default', defaultConfig),
      ProcessingPreset(
        'Unfiltered',
        ProcessingConfig.fromJson({...defaultConfig.toJson(), 'mode': 'raw'}),
      ),
      ...custom,
    ];
    final choice = await showModalBottomSheet<ProcessingPreset>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final preset in choices)
              ListTile(
                title: Text(preset.name),
                onTap: () => Navigator.pop(context, preset),
              ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) _open(choice);
  });
  Future<void> _savePreset() => _operation(() async {
    final config = _read();
    final name = await _text('Save preset');
    if (name == null) return;
    final preset = ProcessingPreset(name.trim(), config);
    await _presets.save(preset);
    if (mounted) setState(() => _presetName = preset.name);
  });
  Future<void> _exportPreset() => _operation(() async {
    final preset = ProcessingPreset(_presetName, _read());
    await Clipboard.setData(ClipboardData(text: preset.encode()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Preset JSON copied. Save as a .json file or paste on another device.',
          ),
        ),
      );
    }
  });
  Future<void> _importPreset() => _operation(() async {
    final text = await _text('Import preset JSON', json: true);
    if (text == null) return;
    final preset = ProcessingPreset.decode(text);
    if (mounted) _open(preset);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Processing settings'),
      actions: [
        TextButton(
          onPressed: _busy ? null : _save,
          child: const Text('Apply & save'),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) Text(_error!),
          const Text(
            'Applies to the whole derived view and future defaults for Live and History. Raw recordings and v1 recorded flags stay unchanged.',
          ),
          ExpansionTile(
            title: const Text('Presets'),
            subtitle: Text(_presetName),
            children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Default is the current working screened configuration, not a validated optimum. Opening/importing stages changes; Apply & save activates them.',
                ),
              ),
              Wrap(
                children: [
                  TextButton(
                    onPressed: _busy ? null : _choosePreset,
                    child: const Text('Open preset'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _savePreset,
                    child: const Text('Save preset'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _exportPreset,
                    child: const Text('Copy JSON'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _importPreset,
                    child: const Text('Import JSON'),
                  ),
                ],
              ),
            ],
          ),
          const ListTile(title: Text('Basic settings')),
          DropdownButton<AnalysisMode>(
            value: _mode,
            isExpanded: true,
            items: [
              for (final mode in AnalysisMode.values)
                DropdownMenuItem(
                  value: mode,
                  child: Text(switch (mode) {
                    AnalysisMode.raw => 'Raw',
                    AnalysisMode.range => 'Range only',
                    AnalysisMode.screened => 'Artifact screened',
                  }),
                ),
            ],
            onChanged: (v) => setState(() {
              _mode = v!;
              _presetName = 'Current / modified';
            }),
          ),
          const Text(
            'Select metrics (HR = BPM). Live and detailed plots show all selected metrics. HR is device-reported.',
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final metric in ProcessingConfig.availableMetrics)
                FilterChip(
                  label: Text(metric),
                  selected: _metrics.contains(metric),
                  onSelected: (selected) => setState(() {
                    selected ? _metrics.add(metric) : _metrics.remove(metric);
                    _presetName = 'Current / modified';
                  }),
                ),
            ],
          ),
          ExpansionTile(
            title: const Text('Advanced settings'),
            children: [
              for (var i = 0; i < _fields.length; i++)
                TextField(
                  controller: _fields[i],
                  onChanged: (_) =>
                      setState(() => _presetName = 'Current / modified'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(labelText: _labels[i]),
                ),

              const Text(
                'Gaps always break RR adjacency. Raw preserves acquired values; invalid values and undefined metrics remain unavailable. Usable percentage is sample acceptance, not time coverage.',
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _PresetTextPage extends StatefulWidget {
  const _PresetTextPage({
    required this.title,
    required this.initial,
    required this.json,
  });
  final String title, initial;
  final bool json;
  @override
  State<_PresetTextPage> createState() => _PresetTextPageState();
}

class _PresetTextPageState extends State<_PresetTextPage> {
  late final _text = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _text.text),
          child: const Text('Done'),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLines: widget.json ? 18 : 1,
            decoration: InputDecoration(
              labelText: widget.json ? 'Portable preset JSON' : 'Preset name',
            ),
          ),
        ],
      ),
    ),
  );
}
