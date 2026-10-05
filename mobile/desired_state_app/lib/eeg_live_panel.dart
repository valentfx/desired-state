import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'eeg_bands.dart';
import 'muse_athena_service.dart';
import 'session_controller.dart';

const _bandColors = <String, Color>{
  'Delta': Colors.purple,
  'Theta': Colors.teal,
  'Alpha': Colors.blue,
  'Beta': Colors.deepOrange,
};

class EegLivePanel extends StatefulWidget {
  const EegLivePanel({super.key, required this.controller});
  final SessionController controller;
  @override
  State<EegLivePanel> createState() => _EegLivePanelState();
}

class _EegLivePanelState extends State<EegLivePanel> {
  bool _relative = false, _raw = false, _follow = true;
  String? _channel;
  final Set<String> _visibleBands = {'Alpha', 'Theta', 'Beta'};
  double? _lockedMaximum;
  DateTime? _browseEnd;
  int _seconds = 60;
  Future<void> _captureBaseline(MuseAthenaService muse) async {
    final frame = muse.latestBands;
    if (frame == null || frame.channels.isEmpty || !muse.fresh) {
      return;
    }
    final recent = muse.bandHistory
        .where(
          (f) =>
              frame.time.difference(f.time) <= const Duration(seconds: 20) &&
              f.channels.isNotEmpty,
        )
        .toList();
    final channels = <String, Map<String, double>>{};
    for (final name in frame.channels.keys) {
      final valid = recent.where((f) => f.channels.containsKey(name)).toList();
      channels[name] = {
        for (final band in eegBands.keys)
          band:
              valid
                  .map((f) => f.channels[name]![band]!)
                  .reduce((a, b) => a + b) /
              valid.length,
      };
    }
    final baseline = EegBandFrame(frame.time, channels, frame.channelCount);
    muse.setBaseline(baseline);
    try {
      await widget.controller.sessionLogger?.writeEvent(
        'eeg_baseline_selected',
        description: jsonEncode({
          'version': 1,
          'channels': channels,
          'window_seconds': 20,
          'valid_windows': recent.length,
          'units': 'microvolt_squared',
          'method': 'hann_periodogram_1_30hz_v1',
        }),
        flush: true,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Baseline event not saved: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller.museAthena,
    builder: (context, _) {
      final muse = widget.controller.museAthena;
      if (!muse.streaming && muse.eegSamples == 0) {
        return const SizedBox.shrink();
      }
      final frame = muse.latestBands;
      final values = muse.fresh
          ? frame?.values(_channel, relative: _relative) ?? <String, double>{}
          : <String, double>{};
      final baseline = muse.baselineContinuity == muse.continuity
          ? muse.baseline
          : null;
      final reference = baseline?.values(_channel, relative: _relative) ?? {};
      final unit = _relative ? '%' : 'µV²';
      final bands = <String, List<(double, double)>>{
        for (final name in eegBands.keys) name: [],
      };
      final history = muse.bandHistory;
      final firstTime = history.isEmpty ? DateTime.now() : history.first.time;
      final lastTime = history.isEmpty ? firstTime : history.last.time;
      final full = lastTime.difference(firstTime).inMilliseconds / 1000;
      final right = _follow || _browseEnd == null
          ? full
          : (_browseEnd!.difference(firstTime).inMilliseconds / 1000)
                .clamp(0.0, full)
                .toDouble();
      final left = math.max(0.0, right - _seconds);
      for (final point in history) {
        final t = point.time.difference(firstTime).inMilliseconds / 1000;
        if (t < left || t > right) {
          continue;
        }
        final selected = point.values(_channel, relative: _relative);
        for (final band in bands.keys) {
          bands[band]!.add((t, selected[band] ?? double.nan));
        }
      }
      final plotted = {for (final band in _visibleBands) band: bands[band]!};
      final maxPower = plotted.values
          .expand((p) => p)
          .map((p) => p.$2)
          .where((v) => v.isFinite)
          .fold<double>(0, math.max);
      final referenceMaximum = reference.entries
          .where((e) => _visibleBands.contains(e.key))
          .map((e) => e.value)
          .fold<double>(0, math.max);
      final maximum = _relative
          ? 100.0
          : _lockedMaximum ??
                math.max(1.0, math.max(maxPower, referenceMaximum) * 1.1);
      return Card(
        child: ExpansionTile(
          initiallyExpanded: false,
          title: const Text('EEG band activity'),
          subtitle: Text(
            muse.fresh
                ? 'Alpha ${values['Alpha']?.toStringAsFixed(1) ?? '--'} · Theta ${values['Theta']?.toStringAsFixed(1) ?? '--'} · Beta ${values['Beta']?.toStringAsFixed(1) ?? '--'} $unit'
                : 'Disconnected / stale — last data retained',
          ),
          childrenPadding: const EdgeInsets.all(12),
          children: [
            Text(
              '${frame?.channels.length ?? 0}/${frame?.channelCount ?? 0} channels pass provisional signal checks · ${widget.controller.recordedEegSamples} EEG samples recorded',
            ),
            const Text(
              'Band power is not a validated relaxation or sleep score. Signal checks do not remove every eye/muscle artifact.',
            ),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Absolute power'),
                  selected: !_relative,
                  onSelected: (_) => setState(() {
                    _relative = false;
                    _lockedMaximum = null;
                  }),
                ),
                ChoiceChip(
                  label: const Text('Relative power'),
                  selected: _relative,
                  onSelected: (_) => setState(() {
                    _relative = true;
                    _lockedMaximum = null;
                  }),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              key: ValueKey(muse.continuity),
              isExpanded: true,
              initialValue: muse.eegHistory.containsKey(_channel)
                  ? _channel
                  : 'All usable',
              decoration: const InputDecoration(labelText: 'Channel'),
              items: [
                const DropdownMenuItem(
                  value: 'All usable',
                  child: Text(
                    'Mean of usable channels',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (final name in muse.eegHistory.keys)
                  DropdownMenuItem(
                    value: name,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (name) => setState(() {
                _channel = name == 'All usable' ? null : name;
              }),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final band in eegBands.keys)
                  FilterChip(
                    label: Text(band),
                    selected: _visibleBands.contains(band),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _visibleBands.add(band);
                      } else if (_visibleBands.length > 1) {
                        _visibleBands.remove(band);
                      }
                    }),
                  ),
              ],
            ),
            SizedBox(
              height: 200,
              width: double.infinity,
              child: CustomPaint(
                painter: EegAxisPainter(
                  plotted,
                  left: left,
                  right: math.max(left + 1, right),
                  minimum: 0,
                  maximum: maximum,
                  yLabel: 'Band power ($unit)',
                  colors: _bandColors,
                  references: {
                    for (final band in _visibleBands)
                      if (reference[band] != null) band: reference[band]!,
                  },
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final name in bands.keys)
                  Text(
                    '$name ${values[name]?.toStringAsFixed(2) ?? '--'} $unit',
                    style: TextStyle(color: _bandColors[name]),
                  ),
              ],
            ),
            if ((values['Beta'] ?? 0) > 0.000001)
              Text(
                'Alpha+Theta / Beta: ${((values['Alpha']! + values['Theta']!) / values['Beta']!).toStringAsFixed(2)} · exploratory ratio',
              ),
            for (final band in plotted.entries)
              if (band.value.any((p) => p.$2.isFinite))
                Text(
                  '${band.key} visible min ${band.value.map((p) => p.$2).where((v) => v.isFinite).reduce(math.min).toStringAsFixed(2)} / max ${band.value.map((p) => p.$2).where((v) => v.isFinite).reduce(math.max).toStringAsFixed(2)} $unit',
                ),
            Wrap(
              spacing: 8,
              children: [
                for (final seconds in [60, 300, 900])
                  ChoiceChip(
                    label: Text('${seconds}s'),
                    selected: _seconds == seconds,
                    onSelected: (_) => setState(() => _seconds = seconds),
                  ),
                TextButton(
                  onPressed: () => setState(() {
                    _follow = true;
                    _browseEnd = null;
                  }),
                  child: const Text('Follow EEG'),
                ),
                if (!_relative)
                  TextButton(
                    onPressed: () => setState(
                      () => _lockedMaximum = _lockedMaximum == null
                          ? maximum
                          : null,
                    ),
                    child: Text(
                      _lockedMaximum == null
                          ? 'Lock shared scale'
                          : 'Auto shared scale',
                    ),
                  ),
              ],
            ),
            if (full > 0)
              Slider(
                value: _follow ? 1 : (right / full).clamp(0.0, 1.0).toDouble(),
                onChanged: (value) => setState(() {
                  _follow = false;
                  _browseEnd = firstTime.add(
                    Duration(milliseconds: (value * full * 1000).round()),
                  );
                }),
              ),
            TextButton(
              onPressed: values.isEmpty ? null : () => _captureBaseline(muse),
              child: const Text('Set baseline from recent clean windows'),
            ),
            if (baseline != null)
              Text(
                'Baseline ${baseline.time.toLocal()} · dashed lines use the same scale',
              ),
            if (reference.isNotEmpty)
              Wrap(
                spacing: 8,
                children: [
                  for (final band in reference.keys)
                    Text(
                      'Baseline $band ${reference[band]!.toStringAsFixed(2)} $unit',
                    ),
                ],
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Raw EEG · shared zero and µV scale'),
              value: _raw,
              onChanged: (value) => setState(() => _raw = value),
            ),
            if (_raw) _rawPlot(muse),
          ],
        ),
      );
    },
  );
  Widget _rawPlot(MuseAthenaService muse) {
    final series = <String, List<(double, double)>>{};
    var limit = 1.0;
    for (final channel in muse.eegHistory.entries) {
      if (_channel != null && _channel != channel.key) {
        continue;
      }
      final points = channel.value;
      if (points.isEmpty) {
        continue;
      }
      series[channel.key] = [
        for (var i = 0; i < points.length; i++)
          ((i - points.length + 1) / math.max(1, muse.eegRate), points[i]),
      ];
      for (final value in points) {
        limit = math.max(limit, value.abs());
      }
    }
    return Column(
      children: [
        Text(
          muse.fresh ? 'Raw EEG (unfiltered)' : 'Raw EEG retained — not live',
        ),
        SizedBox(
          height: 200,
          width: double.infinity,
          child: CustomPaint(
            painter: EegAxisPainter(
              series,
              left: -1024 / math.max(1, muse.eegRate),
              right: 0,
              minimum: -limit,
              maximum: limit,
              yLabel: 'EEG (µV)',
              colors: {
                for (final (index, name) in series.keys.indexed)
                  name: _bandColors.values.elementAt(
                    index % _bandColors.length,
                  ),
              },
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final channel in series.entries)
              Text(
                '${channel.key}: min ${channel.value.map((p) => p.$2).reduce(math.min).toStringAsFixed(1)} / max ${channel.value.map((p) => p.$2).reduce(math.max).toStringAsFixed(1)} µV',
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
        Paint()..color = Colors.purple.withValues(alpha: .4),
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
      canvas.drawPath(path, paint);
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
