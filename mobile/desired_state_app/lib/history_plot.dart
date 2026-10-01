import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'session_history.dart';

/// Display-only reduction: retain extrema and every discontinuity.
List<HistoryPoint> reduceHistoryPoints(
  List<HistoryPoint> points, {
  int target = 800,
}) {
  if (points.length <= target) return points;
  final keep = <int>{};
  final step = math.max(1, (points.length / (target / 4)).ceil());
  for (var start = 0; start < points.length; start += step) {
    final end = math.min(start + step, points.length);
    keep.addAll([start, end - 1]);
    int? low, high;
    for (var i = start; i < end; i++) {
      final value = points[i].value;
      if (value != null) {
        if (low == null || value < points[low].value!) low = i;
        if (high == null || value > points[high].value!) high = i;
      }
      if (value == null ||
          (i > 0 &&
              (points[i - 1].value == null ||
                  points[i - 1].segment != points[i].segment))) {
        keep.add(i);
        if (i > 0) keep.add(i - 1);
      }
    }
    if (low != null) keep.add(low);
    if (high != null) keep.add(high);
  }
  final indices = keep.toList()..sort();
  return [for (final i in indices) points[i]];
}

class HistoryPlot extends StatelessWidget {
  const HistoryPlot({
    super.key,
    required this.title,
    required this.unit,
    required this.points,
    required this.start,
    required this.end,
    required this.events,
    required this.color,
    required this.onInspect,
    this.cursor,
  });
  final String title, unit;
  final List<HistoryPoint> points;
  final DateTime start, end;
  final List<DateTime> events;
  final Color color;
  final DateTime? cursor;
  final ValueChanged<HistoryPoint> onInspect;
  @override
  Widget build(BuildContext context) {
    final visible = points
        .where((p) => !p.time.isBefore(start) && !p.time.isAfter(end))
        .toList();
    final values = visible.map((p) => p.value).whereType<double>().toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title ($unit)',
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
            if (values.isEmpty) const Text('No usable values in this range'),
            if (values.isNotEmpty)
              Text(
                '${values.reduce(math.min).toStringAsFixed(1)} – ${values.reduce(math.max).toStringAsFixed(1)} $unit',
              ),
            LayoutBuilder(
              builder: (context, constraints) {
                void inspect(double x) {
                  if (visible.isEmpty) return;
                  final fraction =
                      ((x - 8) / math.max(1, constraints.maxWidth - 16)).clamp(
                        0.0,
                        1.0,
                      );
                  final timestamp =
                      start.microsecondsSinceEpoch +
                      end.difference(start).inMicroseconds * fraction;
                  var nearest = visible.first;
                  for (final point in visible) {
                    if ((point.time.microsecondsSinceEpoch - timestamp).abs() <
                        (nearest.time.microsecondsSinceEpoch - timestamp)
                            .abs()) {
                      nearest = point;
                    }
                  }
                  onInspect(nearest);
                }

                return Semantics(
                  label: '$title plot. Tap to inspect a recorded value.',
                  child: GestureDetector(
                    onTapDown: (event) => inspect(event.localPosition.dx),
                    onLongPressStart: (event) =>
                        inspect(event.localPosition.dx),
                    child: SizedBox(
                      height: 130,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _HistoryPainter(
                          reduceHistoryPoints(visible),
                          start,
                          end,
                          events,
                          color,
                          cursor,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryPainter extends CustomPainter {
  _HistoryPainter(
    this.points,
    this.start,
    this.end,
    this.events,
    this.color,
    this.cursor,
  );
  final List<HistoryPoint> points;
  final DateTime start, end;
  final List<DateTime> events;
  final Color color;
  final DateTime? cursor;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      8,
      8,
      math.max(1, size.width - 16),
      size.height - 16,
    );
    final span = math.max(1, end.difference(start).inMicroseconds);
    double x(DateTime time) =>
        rect.left + time.difference(start).inMicroseconds / span * rect.width;
    canvas.save();
    canvas.clipRect(rect);
    for (var i = 0; i < 5; i++) {
      final y = rect.top + i * rect.height / 4;
      canvas.drawLine(
        Offset(rect.left, y),
        Offset(rect.right, y),
        Paint()..color = Colors.grey.withValues(alpha: .25),
      );
    }
    for (final event in events) {
      canvas.drawLine(
        Offset(x(event), rect.top),
        Offset(x(event), rect.bottom),
        Paint()..color = Colors.purple.withValues(alpha: .5),
      );
    }
    final values = points.map((p) => p.value).whereType<double>().toList();
    if (values.isNotEmpty) {
      final low = values.reduce(math.min), high = values.reduce(math.max);
      // Normalize before subtracting so even extreme finite raw inputs do not
      // overflow the canvas coordinates. Display scaling never alters data.
      final scale = math.max(1.0, math.max(low.abs(), high.abs()));
      final scaledLow = low / scale, scaledHigh = high / scale;
      final padding = math.max(1.0 / scale, (scaledHigh - scaledLow) * .1);
      double y(double value) =>
          rect.bottom -
          (value / scale - scaledLow + padding) /
              (scaledHigh - scaledLow + 2 * padding) *
              rect.height;
      HistoryPoint? previous;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.8;
      for (final point in points) {
        if (point.value == null) {
          previous = null;
          continue;
        }
        final position = Offset(x(point.time), y(point.value!));
        if (previous != null && previous.segment == point.segment) {
          canvas.drawLine(
            Offset(x(previous.time), y(previous.value!)),
            position,
            paint,
          );
        }
        canvas.drawCircle(position, 1.8, paint);
        previous = point;
      }
    }
    if (cursor != null) {
      canvas.drawLine(
        Offset(x(cursor!), rect.top),
        Offset(x(cursor!), rect.bottom),
        Paint()
          ..color = Colors.deepPurple
          ..strokeWidth = 2,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HistoryPainter oldDelegate) => true;
}

/// Each series retains native values; only its painted vertical coordinate is
/// scaled. Missing values and continuity segments are passed to the same painter
/// as the detailed plots. Inspection always uses unreduced source points.
class RelativeOverlayPlot extends StatelessWidget {
  const RelativeOverlayPlot({
    super.key,
    required this.series,
    required this.colors,
    required this.start,
    required this.end,
    required this.events,
    required this.onInspect,
    this.cursor,
  });
  final Map<String, List<HistoryPoint>> series;
  final Map<String, Color> colors;
  final DateTime start, end;
  final List<DateTime> events;
  final DateTime? cursor;
  final ValueChanged<DateTime> onInspect;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      void inspect(double x) {
        final fraction = ((x - 8) / math.max(1, constraints.maxWidth - 16))
            .clamp(0.0, 1.0);
        onInspect(
          start.add(
            Duration(
              microseconds: (end.difference(start).inMicroseconds * fraction)
                  .round(),
            ),
          ),
        );
      }

      return Semantics(
        label: 'Relative trends. Independently scaled series. Tap or drag to inspect original values.',
        child: GestureDetector(
          onTapDown: (d) => inspect(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => inspect(d.localPosition.dx),
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final entry in series.entries)
                CustomPaint(
                  painter: _HistoryPainter(
                    reduceHistoryPoints(
                      entry.value
                          .where(
                            (p) =>
                                !p.time.isBefore(start) && !p.time.isAfter(end),
                          )
                          .toList(),
                    ),
                    start,
                    end,
                    events,
                    colors[entry.key]!,
                    cursor,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
