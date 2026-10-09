import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/material.dart';

import 'eeg_bands.dart';
import 'session_controller.dart';

const eegBandColors = <String, Color>{
  'Delta': Colors.purple,
  'Theta': Colors.teal,
  'Alpha': Colors.blue,
  'Beta': Colors.deepOrange,
  'Gamma': Colors.pink,
};

/// Detail-only shared comparison: identical windows, axes and raw source.
class EegComparisonPlot extends StatefulWidget {
  const EegComparisonPlot({
    super.key,
    required this.frames,
    required this.origin,
    required this.left,
    required this.right,
    this.events = const [],
    this.screening = false,
    this.onScreeningChanged,
    this.onUnitsChanged,
    this.onChannelChanged,
    this.baseline,
  });
  final List<EegBandFrame> frames;
  final EegBandFrame? baseline;
  final DateTime origin;
  final double left, right;
  final List<double> events;
  final bool screening;
  final ValueChanged<bool>? onScreeningChanged;
  final ValueChanged<String>? onUnitsChanged;
  final ValueChanged<String?>? onChannelChanged;
  @override
  State<EegComparisonPlot> createState() => _EegComparisonPlotState();
}

class _EegComparisonPlotState extends State<EegComparisonPlot> {
  late bool _screening = widget.screening;
  bool _compare = false;
  String? _channel;
  String _units = 'dB';
  final Set<String> _bands = eegBands.keys.toSet();
  @override
  void didUpdateWidget(EegComparisonPlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.screening != widget.screening) {
      _screening = widget.screening;
    }
  }

  @override
  Widget build(BuildContext context) {
    final series = <String, List<(double, double)>>{};
    final colors = <String, Color>{};
    final available =
        widget.frames.expand((f) => f.channels.keys).toSet().toList()..sort();
    final effectiveChannel = available.contains(_channel) ? _channel : null;
    for (final band in _bands) {
      for (final screened in _compare ? [false, true] : [_screening]) {
        final key = _compare
            ? '$band · ${screened ? 'screened' : 'unscreened'}'
            : band;
        final points = <(double, double)>[];
        int? previous;
        for (final frame in widget.frames) {
          final t =
              frame.time.difference(widget.origin).inMicroseconds / 1000000;
          if (t < widget.left || t > widget.right) {
            continue;
          }
          if (previous != null && previous != frame.segment) {
            points.add((t, double.nan));
          }
          final values = frame.values(
            effectiveChannel,
            relative: _units == '%',
            decibels: _units == 'dB',
            artifactScreening: screened,
          );
          points.add((t, values[band] ?? double.nan));
          previous = frame.segment;
        }
        series[key] = points;
        colors[key] = screened || !_compare
            ? eegBandColors[band]!
            : eegBandColors[band]!.withValues(alpha: .35);
      }
    }
    final finite = series.values
        .expand((p) => p)
        .map((p) => p.$2)
        .where((v) => v.isFinite)
        .toList();
    final low = _units == '%'
        ? 0.0
        : finite.isEmpty
        ? -10.0
        : finite.reduce(math.min);
    final high = _units == '%'
        ? 100.0
        : finite.isEmpty
        ? 10.0
        : finite.reduce(math.max);
    final padding = math.max(1.0, (high - low) * .1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          children: [
            ChoiceChip(
              label: const Text('No EEG screening'),
              selected: !_screening,
              onSelected: (_) => _select(false),
            ),
            ChoiceChip(
              label: const Text('EEG amplitude/step/flatline screen'),
              selected: _screening,
              onSelected: (_) => _select(true),
            ),
            FilterChip(
              label: const Text('Overlay comparison'),
              selected: _compare,
              onSelected: (v) => setState(() => _compare = v),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          children: [
            for (final unit in ['dB', 'µV²', '%'])
              ChoiceChip(
                label: Text(unit),
                selected: _units == unit,
                onSelected: (_) {
                  setState(() => _units = unit);
                  widget.onUnitsChanged?.call(unit);
                },
              ),
          ],
        ),
        DropdownButton<String>(
          value: effectiveChannel ?? '',
          isExpanded: true,
          items: [
            const DropdownMenuItem(
              value: '',
              child: Text('Mean of available channels'),
            ),
            for (final channel in available)
              DropdownMenuItem(value: channel, child: Text('EEG $channel')),
          ],
          onChanged: (v) {
            setState(() => _channel = v == '' ? null : v);
            widget.onChannelChanged?.call(_channel);
          },
        ),
        Wrap(
          spacing: 6,
          children: [
            for (final band in eegBands.keys)
              FilterChip(
                label: Text(band, style: TextStyle(color: eegBandColors[band])),
                selected: _bands.contains(band),
                onSelected: (v) => setState(() {
                  if (v) {
                    _bands.add(band);
                  } else if (_bands.length > 1) {
                    _bands.remove(band);
                  }
                }),
              ),
          ],
        ),
        SizedBox(
          height: 220,
          width: double.infinity,
          child: CustomPaint(
            painter: EegAxisPainter(
              series,
              left: widget.left,
              right: math.max(widget.left + .001, widget.right),
              minimum: _units == '%' || _units == 'µV²' ? 0 : low - padding,
              maximum: _units == '%' ? 100 : high + padding,
              yLabel: _units == 'dB' ? 'EEG dB re 1 µV²' : 'EEG ($_units)',
              colors: colors,
              references: _compare
                  ? const {}
                  : widget.baseline?.values(
                          effectiveChannel,
                          relative: _units == '%',
                          decibels: _units == 'dB',
                          artifactScreening: _screening,
                        ) ??
                        const {},
              events: widget.events,
              dashedSeries: _compare
                  ? series.keys
                        .where(
                          (k) =>
                              k.endsWith('screened') &&
                              !k.endsWith('unscreened'),
                        )
                        .toSet()
                  : const {},
            ),
          ),
        ),
        if (finite.isEmpty) const Text('Waiting for a complete EEG window.'),
        if (_compare)
          const Text(
            'Faint: unscreened · dashed: screened · gaps: excluded windows',
          ),
        if (_screening || _compare)
          const Text(
            'Screen: centered >250 µV, step >150 µV/sample, variance <0.01 µV².',
          ),
      ],
    );
  }

  void _select(bool value) {
    setState(() => _screening = value);
    widget.onScreeningChanged?.call(value);
  }
}

class EegLivePanel extends StatelessWidget {
  const EegLivePanel({super.key, required this.controller});
  final SessionController controller;
  Future<void> _saveScreen(bool value, BuildContext context) async {
    final p = controller.preferences;
    try {
      await controller.savePreferences(p.copyWith(eegArtifactScreening: value));
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('EEG option not saved: $error')));
      }
    }
  }

  Future<void> _baseline(BuildContext context) async {
    final muse = controller.museAthena;
    final now = muse.latestBands?.time;
    if (now == null || !muse.fresh) {
      return;
    }
    final frames = muse.bandHistory
        .where(
          (f) =>
              f.segment == muse.continuity &&
              now.difference(f.time) <= const Duration(seconds: 20),
        )
        .toList();
    Map<String, Map<String, double>> average(bool screened) {
      final source = <String, List<Map<String, double>>>{};
      for (final frame in frames) {
        for (final channel
            in (screened
                    ? frame.screenedChannels ??
                          const <String, Map<String, double>>{}
                    : frame.channels)
                .entries) {
          source.putIfAbsent(channel.key, () => []).add(channel.value);
        }
      }
      return {
        for (final channel in source.entries)
          if (channel.value.length >= 3)
            channel.key: {
              for (final band in eegBands.keys)
                if (channel.value.every((p) => p.containsKey(band)))
                  band:
                      channel.value.fold<double>(
                        0,
                        (sum, p) => sum + p[band]!,
                      ) /
                      channel.value.length,
            },
      };
    }

    final raw = average(false), screened = average(true);
    if (raw.isEmpty) {
      return;
    }
    final baseline = EegBandFrame(
      now,
      raw,
      muse.eegHistory.length,
      screenedChannels: screened,
      segment: muse.continuity,
    );
    muse.setBaseline(baseline);
    try {
      await controller.sessionLogger?.writeEvent(
        'eeg_baseline_selected',
        description: jsonEncode({
          'processing_version': 2,
          'channels': raw,
          'screened_channels': screened,
          'window_seconds': 20,
          'units': 'microvolt_squared',
          'continuity_segment': muse.continuity,
        }),
        flush: true,
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Baseline not saved: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final muse = controller.museAthena;
      if (!muse.streaming && muse.bandHistory.isEmpty) {
        return const SizedBox.shrink();
      }
      final end = muse.latestBands?.time ?? DateTime.now();
      final origin = end.subtract(const Duration(seconds: 60));
      return ExpansionTile(
        title: const Text('EEG band activity'),
        children: [
          EegComparisonPlot(
            baseline: muse.baselineContinuity == muse.continuity
                ? muse.baseline
                : null,
            frames: muse.bandHistory,
            origin: origin,
            left: 0,
            right: 60,
            screening: controller.preferences.eegArtifactScreening,
            onScreeningChanged: (v) => _saveScreen(v, context),
            events: controller.eventTimes
                .map((t) => t.difference(origin).inMicroseconds / 1000000)
                .toList(),
          ),
          TextButton(
            onPressed: muse.fresh ? () => _baseline(context) : null,
            child: const Text('Set 20-second EEG baseline'),
          ),
          ExpansionTile(
            title: const Text('Raw EEG overlay (µV)'),
            children: [
              RawEegPlot(channels: muse.eegHistory, rate: muse.eegRate),
            ],
          ),
        ],
      );
    },
  );
}

class RawEegPlot extends StatelessWidget {
  const RawEegPlot({super.key, required this.channels, required this.rate});
  final Map<String, List<double>> channels;
  final int rate;
  @override
  Widget build(BuildContext context) {
    final series = {
      for (final entry in channels.entries)
        'EEG ${entry.key}': [
          for (var i = 0; i < entry.value.length; i++)
            ((i - entry.value.length + 1) / math.max(1, rate), entry.value[i]),
        ],
    };
    final limit = series.values
        .expand((p) => p)
        .map((p) => p.$2.abs())
        .where((v) => v.isFinite)
        .fold<double>(1, math.max);
    return Column(
      children: [
        SizedBox(
          height: 200,
          width: double.infinity,
          child: CustomPaint(
            painter: EegAxisPainter(
              series,
              left: -1024 / math.max(1, rate),
              right: 0,
              minimum: -limit,
              maximum: limit,
              yLabel: 'Raw EEG (µV)',
              colors: {
                for (final (i, name) in series.keys.indexed)
                  name: eegBandColors.values.elementAt(
                    i % eegBandColors.length,
                  ),
              },
              maximumGapSeconds: 2 / math.max(1, rate),
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final (i, name) in series.keys.indexed)
              Text(
                name,
                style: TextStyle(
                  color: eegBandColors.values.elementAt(
                    i % eegBandColors.length,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Every trace shares this one transform. Missing windows break the path.
class EegAxisPainter extends CustomPainter {
  EegAxisPainter(
    this.series, {
    required this.left,
    required this.right,
    required this.minimum,
    required this.maximum,
    required this.yLabel,
    required this.colors,
    this.dashedSeries = const {},
    this.references = const {},
    this.showPoints = false,
    this.events = const [],
    this.maximumGapSeconds = 5,
  });
  final Map<String, List<(double, double)>> series;
  final double left, right, minimum, maximum;
  final String yLabel;
  final Map<String, Color> colors;
  final Map<String, double> references;
  final Set<String> dashedSeries;
  final bool showPoints;
  final double? maximumGapSeconds;
  final List<double> events;
  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromLTRB(58, 22, size.width - 8, size.height - 36);
    if (area.width <= 0 || area.height <= 0) {
      return;
    }
    void label(String text, Offset position) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(fontSize: 10, color: Colors.black87),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, position);
    }

    double x(double value) =>
        area.left + (value - left) / (right - left) * area.width;
    double y(double value) =>
        area.bottom - (value - minimum) / (maximum - minimum) * area.height;
    label(yLabel, const Offset(0, 0));
    final grid = Paint()..color = Colors.grey.shade400;
    final divisions = area.height < 80 ? 1 : 4;
    for (var i = 0; i <= divisions; i++) {
      final value = minimum + (maximum - minimum) * i / divisions;
      canvas.drawLine(
        Offset(area.left, y(value)),
        Offset(area.right, y(value)),
        grid,
      );
      label(value.toStringAsFixed(1), Offset(0, y(value) - 5));
    }
    label(
      'min ${minimum.toStringAsFixed(1)} / max ${maximum.toStringAsFixed(1)}',
      Offset(area.left, size.height - 12),
    );
    label(left.toStringAsFixed(0), Offset(area.left, area.bottom + 4));
    label(right.toStringAsFixed(0), Offset(area.right - 24, area.bottom + 4));
    label('Time (s)', Offset(area.center.dx - 20, area.bottom + 4));
    canvas.save();
    canvas.clipRect(area);
    for (final event in events) {
      canvas.drawLine(
        Offset(x(event), area.top),
        Offset(x(event), area.bottom),
        Paint()
          ..color = Colors.black87
          ..strokeWidth = 2,
      );
    }
    for (final entry in series.entries) {
      final paint = Paint()
        ..color = (colors[entry.key] ?? Colors.blue)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      final path = Path();
      var started = false;
      double? previous;
      for (final point in entry.value) {
        if (!point.$2.isFinite) {
          started = false;
          previous = null;
          continue;
        }
        if (previous != null &&
            maximumGapSeconds != null &&
            point.$1 - previous > maximumGapSeconds!) {
          started = false;
        }
        if (!started) {
          path.moveTo(x(point.$1), y(point.$2));
          started = true;
        } else {
          path.lineTo(x(point.$1), y(point.$2));
        }
        if (showPoints) {
          canvas.drawCircle(Offset(x(point.$1), y(point.$2)), 1.8, paint);
        }
        previous = point.$1;
      }
      if (dashedSeries.contains(entry.key)) {
        for (final metric in path.computeMetrics()) {
          for (var distance = 0.0; distance < metric.length; distance += 10) {
            canvas.drawPath(
              metric.extractPath(
                distance,
                math.min(distance + 5, metric.length),
              ),
              paint,
            );
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }
      final baseline = references[entry.key];
      if (baseline != null) {
        for (var dx = area.left; dx < area.right; dx += 8) {
          canvas.drawLine(
            Offset(dx, y(baseline)),
            Offset(math.min(dx + 4, area.right), y(baseline)),
            paint,
          );
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EegAxisPainter oldDelegate) => true;
}
