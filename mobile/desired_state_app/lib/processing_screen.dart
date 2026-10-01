import 'dart:convert';

import 'package:flutter/material.dart';

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
        builder: (_) =>
            ProcessingEditor(config: widget.controller.processing.config),
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
                    for (final seconds in <int?>[30, 60, 300, null])
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
  const ProcessingEditor({super.key, required this.config});
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

  void _save() {
    try {
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
      Navigator.pop(context, config);
    } catch (e) {
      setState(() => _error = 'Invalid settings: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Processing settings'),
      actions: [
        TextButton(onPressed: _save, child: const Text('Apply & save')),
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
            onChanged: (v) => setState(() => _mode = v!),
          ),
          for (var i = 0; i < _fields.length; i++)
            TextField(
              controller: _fields[i],
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(labelText: _labels[i]),
            ),
          const Text(
            'Select metrics. HR is device-reported and unaffected by RR screening.',
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
                  }),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
