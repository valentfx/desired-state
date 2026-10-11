import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'session_history.dart';
import 'processing.dart';
import 'plot_template.dart';

const inspectionOrder = [
  'BPM',
  'HRV',
  'SpO2',
  'Position',
  'Alpha',
  'Beta',
  'Theta',
  'Delta',
  'Gamma',
  'ECG',
];
String inspectionKey(String name) {
  if (name.startsWith('EEG ') && name.endsWith(' (µV²)')) {
    return name.substring(4, name.length - 6);
  }
  return switch (name) {
    'HR' || 'Heart rate' => 'BPM',
    'RMSSD' || 'RMSSD (ms)' => 'HRV',
    'SpO2 (%)' => 'SpO2',
    'ECG (µV)' => 'ECG',
    'Sleep position (recorded estimate)' => 'Position',
    'O2Ring oxygen (raw decoded)' => 'SpO2',
    _ => name,
  };
}

String elapsedLabel(double seconds) {
  final negative = seconds < 0 ? '−' : '';
  final total = seconds.abs().round();
  final h = total ~/ 3600;
  final m = (total ~/ 60) % 60;
  final s = total % 60;
  return '$negative${h > 0 ? '$h:' : ''}${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

class InspectionValue {
  const InspectionValue(this.time, this.text);
  final DateTime time;
  final String text;
}

InspectionValue? nearestInspection(
  List<HistoryPoint> points,
  DateTime time,
  String unit, {
  Duration tolerance = const Duration(seconds: 3),
}) {
  HistoryPoint? nearest;
  for (final point in points) {
    if (nearest == null ||
        point.time.difference(time).abs() <
            nearest.time.difference(time).abs()) {
      nearest = point;
    }
  }
  if (nearest == null ||
      nearest.time.difference(time).abs() > tolerance ||
      nearest.value == null ||
      !nearest.value!.isFinite) {
    return null;
  }
  return InspectionValue(
    nearest.time,
    '${nearest.value!.toStringAsFixed(2)} $unit',
  );
}

/// A saved view supplies its own values; it never borrows the current live stream.
class PlotInspectionScope extends StatefulWidget {
  const PlotInspectionScope({
    super.key,
    required this.child,
    required this.origin,
    this.controller,
    this.valuesAt,
    this.sampleDescription =
        'Nearest original sample; streams are not synchronized',
    this.saved = false,
  });
  final Widget child;
  final bool saved;
  final DateTime origin;
  final String sampleDescription;
  final SessionController? controller;
  final Map<String, InspectionValue?> Function(DateTime)? valuesAt;
  static PlotInspectionContext? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlotInspectionContext>();
  @override
  State<PlotInspectionScope> createState() => _PlotInspectionScopeState();
}

class _PlotInspectionScopeState extends State<PlotInspectionScope> {
  final _selection = PlotSelection();
  @override
  void didUpdateWidget(PlotInspectionScope old) {
    super.didUpdateWidget(old);
    // A newly started recording owns a fresh time coordinate.
    if (old.origin != widget.origin) _selection.clear();
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parent = PlotInspectionScope.of(context);
    final selection = parent?.origin == widget.origin
        ? parent!.selection
        : _selection;
    return PlotInspectionContext(
      origin: widget.origin,
      controller: widget.controller ?? parent?.controller,
      valuesAt:
          parent?.origin == widget.origin &&
              parent?.saved == widget.saved &&
              widget.valuesAt != null
          ? (time) => {...parent!.values(time), ...widget.valuesAt!(time)}
          : widget.valuesAt,
      sampleDescription: widget.sampleDescription,
      saved: widget.saved,
      selection: selection,
      child: widget.child,
    );
  }
}

class PlotInspectionContext extends InheritedNotifier<PlotSelection> {
  const PlotInspectionContext({
    super.key,
    required super.child,
    required this.origin,
    this.controller,
    this.valuesAt,
    required this.sampleDescription,
    required this.saved,
    required PlotSelection selection,
  }) : super(notifier: selection);
  final bool saved;
  final DateTime origin;
  final String sampleDescription;
  final SessionController? controller;
  final Map<String, InspectionValue?> Function(DateTime)? valuesAt;
  PlotSelection get selection => notifier!;
  Map<String, InspectionValue?> values(DateTime time) =>
      valuesAt?.call(time) ??
      (saved || controller == null
          ? {}
          : liveInspectionValues(controller!, time));
  @override
  bool updateShouldNotify(PlotInspectionContext oldWidget) =>
      saved != oldWidget.saved ||
      origin != oldWidget.origin ||
      controller != oldWidget.controller ||
      valuesAt != oldWidget.valuesAt ||
      sampleDescription != oldWidget.sampleDescription ||
      super.updateShouldNotify(oldWidget);
}

Map<String, InspectionValue?> liveInspectionValues(
  SessionController c,
  DateTime time,
) {
  final result = <String, InspectionValue?>{};
  result['BPM'] = nearestInspection(
    [for (final p in c.heartTrend) HistoryPoint(p.$1, p.$2, 0)],
    time,
    'bpm',
  );
  // Reuse the applied processor, including its continuity and quality gates.
  final processor = RrProcessor(c.processing.config);
  for (final input in c.analysisInputs) {
    processor.add(input);
  }
  result['HRV'] = nearestInspection(
    [
      for (final p in processor.results)
        HistoryPoint(p.input.time, p.values['RMSSD'], p.plotSegment),
    ],
    time,
    'ms RMSSD',
  );
  result['SpO2'] = nearestInspection(
    [for (final p in c.oxygenTrend) HistoryPoint(p.$1, p.$2, 0)],
    time,
    '%',
  );
  var distance = const Duration(days: 99999);
  for (final p in c.posturePreview) {
    final d = p.$1.difference(time).abs();
    if (d < distance) {
      distance = d;
      result['Position'] = d <= const Duration(seconds: 3)
          ? InspectionValue(p.$1, p.$2)
          : null;
    }
  }
  for (final band in ['Alpha', 'Beta', 'Theta', 'Delta', 'Gamma']) {
    result[band] = nearestInspection(
      [
        for (final f in c.museAthena.bandHistory)
          HistoryPoint(
            f.time,
            f.values(
              null,
              decibels: true,
              artifactScreening: c.preferences.eegArtifactScreening,
            )[band],
            f.segment,
          ),
      ],
      time,
      'dB re 1 µV²',
    );
  }
  final frame = c.latestEcg;
  if (frame != null && c.ecgPreview.isNotEmpty) {
    result['ECG'] = nearestInspection(
      [
        for (final p in c.ecgPreview)
          HistoryPoint(
            frame.receivedAt.add(
              Duration(
                microseconds:
                    ((p.$1 - frame.sensorNanoseconds).toDouble() / 1000)
                        .round(),
              ),
            ),
            p.$2,
            0,
          ),
      ],
      time,
      'µV',
      tolerance: const Duration(milliseconds: 100),
    );
  }
  for (var axis = 0; axis < 3; axis++) {
    result['ACC ${['X', 'Y', 'Z'][axis]}'] = nearestInspection(
      [for (final p in c.accTrends[axis]) HistoryPoint(p.$1, p.$2, 0)],
      time,
      'mG',
    );
  }
  return result;
}

class PlotReadout extends StatelessWidget {
  const PlotReadout({
    super.key,
    required this.time,
    required this.origin,
    required this.values,
    required this.onClose,
    this.maxHeight = 145,
  });
  final DateTime time, origin;
  final Map<String, InspectionValue?> values;
  final VoidCallback onClose;
  final double maxHeight;
  @override
  Widget build(BuildContext context) {
    final c = PlotInspectionScope.of(context)?.controller;
    final disabled = c?.preferences.hiddenInspection ?? {'ECG'};
    final names = [
      ...inspectionOrder,
      ...values.keys.where((k) => !inspectionOrder.contains(k)),
    ].where((k) => !disabled.contains(k)).toList();
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Recording +${elapsedLabel(time.difference(origin).inMicroseconds / 1000000)}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Close readout',
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final name in names)
                    Tooltip(
                      message: values[name] == null
                          ? 'No nearby usable sample'
                          : 'Sample ${values[name]!.time.toLocal()} · ${PlotInspectionScope.of(context)?.sampleDescription ?? 'nearest sample'}',
                      child: Text('$name: ${values[name]?.text ?? '—'}'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared touch behavior for waveform and band charts. Original points, not
/// display-reduced/interpolated values, supply the readout.
class InspectableSignalPlot extends StatefulWidget {
  const InspectableSignalPlot({
    super.key,
    required this.child,
    required this.series,
    required this.left,
    required this.right,
    this.origin,
    this.unit = '',
    this.leftInset = PlotTemplate.left,
    this.rightInset = PlotTemplate.right,
    this.onInspect,
  });
  final Widget child;
  final Map<String, List<(double, double)>> series;
  final double left, right, leftInset, rightInset;
  final DateTime? origin;
  final String unit;
  final ValueChanged<DateTime>? onInspect;
  @override
  State<InspectableSignalPlot> createState() => _InspectableSignalPlotState();
}

class _InspectableSignalPlotState extends State<InspectableSignalPlot> {
  DateTime? _selectedTime;
  final _owner = Object();
  Map<String, InspectionValue?> _values = {};
  @override
  Widget build(BuildContext context) {
    final scope = PlotInspectionScope.of(context);
    final origin = widget.origin ?? scope?.origin ?? DateTime(1970);
    scope?.controller?.inspectionFields.addAll(
      widget.series.keys.map(inspectionKey),
    );
    final selectedTime = scope != null ? scope.selection.time : _selectedTime;
    final seconds = selectedTime?.difference(origin).inMicroseconds;
    final cursor = seconds == null ? null : seconds / 1000000;
    final time = cursor == null || cursor < widget.left || cursor > widget.right
        ? null
        : selectedTime;
    final ownsReadout =
        scope == null || identical(scope.selection.owner, _owner);
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onTapDown: (d) {
          final seconds =
              widget.left +
              ((d.localPosition.dx - widget.leftInset) /
                          (constraints.maxWidth -
                                  widget.leftInset -
                                  widget.rightInset)
                              .clamp(1, double.infinity))
                      .clamp(0, 1) *
                  (widget.right - widget.left);
          final selected = origin.add(
            Duration(microseconds: (seconds * 1000000).round()),
          );
          final scopedValues = scope?.values(selected) ?? {};
          final values = <String, InspectionValue?>{};
          for (final entry in widget.series.entries) {
            final points = [
              for (final p in entry.value)
                HistoryPoint(
                  origin.add(Duration(microseconds: (p.$1 * 1000000).round())),
                  p.$2,
                  0,
                ),
            ];
            final key = inspectionKey(entry.key);
            final unit = widget.unit.contains('dB')
                ? 'dB re 1 µV²'
                : widget.unit.contains('µV²')
                ? 'µV²'
                : widget.unit.contains('µV')
                ? 'µV'
                : widget.unit;
            if (unit.isEmpty && scopedValues.containsKey(key)) continue;
            final value = nearestInspection(points, selected, unit);
            if (key == 'Position' && value != null) {
              final point = points.reduce(
                (a, b) =>
                    a.time.difference(selected).abs() <=
                        b.time.difference(selected).abs()
                    ? a
                    : b,
              );
              final index = point.value!.round();
              const labels = [
                'Unknown',
                'On back',
                'Right side',
                'Left side',
                'Upright',
                'Prone',
                'Uncalibrated',
              ];
              values[key] = InspectionValue(
                value.time,
                index >= 0 && index < labels.length ? labels[index] : 'Unknown',
              );
            } else {
              values[key] = value;
            }
          }
          setState(() {
            _selectedTime = selected;
            _values = values;
          });
          scope?.selection.select(selected, _owner);
          widget.onInspect?.call(selected);
        },
        child: Stack(
          children: [
            Positioned.fill(child: widget.child),
            if (time != null)
              Positioned(
                left:
                    widget.leftInset +
                    ((cursor! - widget.left) /
                            (widget.right - widget.left).clamp(
                              .001,
                              double.infinity,
                            )) *
                        (constraints.maxWidth -
                            widget.leftInset -
                            widget.rightInset),
                top: PlotTemplate.top,
                bottom: PlotTemplate.bottom,
                child: const VerticalDivider(
                  key: ValueKey('plot-cursor'),
                  width: 1,
                  thickness: 1,
                  color: Colors.deepPurple,
                ),
              ),
            if (time != null && ownsReadout)
              Positioned(
                left: widget.leftInset,
                right: widget.rightInset,
                bottom: PlotTemplate.bottom,
                child: PlotReadout(
                  time: time,
                  origin: scope?.origin ?? origin,
                  values: {...?scope?.values(time), ..._values},
                  maxHeight: (constraints.maxHeight - PlotTemplate.bottom)
                      .clamp(48, 145)
                      .toDouble(),
                  onClose: () {
                    scope?.selection.clear();
                    setState(() => _selectedTime = null);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
