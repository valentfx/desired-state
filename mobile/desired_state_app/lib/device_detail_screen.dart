import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'calibration_screen.dart';
import 'ecg_live_panel.dart';
import 'eeg_live_panel.dart';
import 'preferences_screen.dart';
import 'session_controller.dart';

class DeviceDetailScreen extends StatelessWidget {
  const DeviceDetailScreen({
    super.key,
    required this.controller,
    required this.kind,
    required this.connectionBuilder,
    required this.controlsChanged,
  });
  final SessionController controller;
  final String kind;
  final Widget Function() connectionBuilder;
  final Listenable controlsChanged;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        kind == 'h10'
            ? 'Polar H10'
            : kind == 'ring'
            ? 'O2Ring'
            : 'Muse S Athena',
      ),
    ),
    body: AnimatedBuilder(
      animation: Listenable.merge([
        controller,
        controller.museAthena,
        controlsChanged,
      ]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          connectionBuilder(),
          ListTile(
            leading: const Icon(Icons.save_outlined),
            title: const Text('Recording settings'),
            subtitle: const Text('Choose which acquired streams to save'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => PreferencesScreen(
                  controller: controller,
                  streams: kind == 'h10'
                      ? ['heart', 'ecg', 'acc', 'pmd']
                      : kind == 'ring'
                      ? ['ring']
                      : ['muse'],
                ),
              ),
            ),
          ),
          if (kind == 'h10')
            ListTile(
              leading: const Icon(Icons.accessibility_new),
              title: const Text('Posture calibration'),
              subtitle: Text(controller.currentPosture),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => CalibrationScreen(controller: controller),
                ),
              ),
            ),
          if (kind == 'h10') ...[
            SignalTrend(
              title: 'BPM',
              unit: 'bpm',
              series: {'BPM': controller.heartTrend},
            ),
            SignalTrend(
              title: 'RMSSD',
              unit: 'ms',
              series: {'RMSSD': controller.hrvTrend},
            ),
            SignalTrend(
              title: 'RR intervals',
              unit: 'ms',
              series: {'RR': controller.rrTrend},
            ),
            EcgLivePanel(controller: controller),
            SignalTrend(
              title: 'Acceleration',
              unit: 'mG',
              series: {
                'X': controller.accTrends[0],
                'Y': controller.accTrends[1],
                'Z': controller.accTrends[2],
              },
            ),
          ],
          if (kind == 'ring') ...[
            SignalTrend(
              title: 'Oxygen',
              unit: '%',
              series: {'SpO2': controller.oxygenTrend},
            ),
            SignalTrend(
              title: 'Pulse',
              unit: 'bpm',
              series: {'Pulse': controller.pulseTrend},
            ),
          ],
          if (kind == 'muse') ...[
            EegLivePanel(controller: controller),
            _motion('Acceleration', controller.museAthena.accelHistory, 'g'),
            _motion('Gyroscope', controller.museAthena.gyroHistory, '°/s'),
          ],
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Diagnostics follows acquisition. Collapsing a signal does not change recording.',
            ),
          ),
        ],
      ),
    ),
  );
  Widget _motion(String title, Map<String, List<double>> history, String unit) {
    final now = controller.museAthena.lastSamplesAt ?? DateTime.now();
    final rate = controller.museAthena.motionRate;
    return SignalTrend(
      title: title,
      unit: unit,
      series: {
        for (final entry in history.entries)
          entry.key: [
            for (var i = 0; i < entry.value.length; i++)
              (
                now.subtract(
                  Duration(
                    microseconds:
                        ((entry.value.length - 1 - i) *
                                1000000 /
                                (rate > 0 ? rate : 52))
                            .round(),
                  ),
                ),
                entry.value[i],
              ),
          ],
      },
    );
  }
}

class SignalTrend extends StatelessWidget {
  const SignalTrend({
    super.key,
    required this.title,
    required this.unit,
    required this.series,
    this.height = 170,
  });
  final String title, unit;
  final Map<String, List<(DateTime, double)>> series;
  final double height;
  @override
  Widget build(BuildContext context) {
    final points = series.values.expand((v) => v).toList();
    if (points.isEmpty) {
      return ListTile(
        title: Text(title),
        subtitle: const Text('Waiting for samples'),
      );
    }
    final end = points.map((v) => v.$1).reduce((a, b) => a.isAfter(b) ? a : b);
    final start = end.subtract(const Duration(seconds: 60));
    final plot = {
      for (final entry in series.entries)
        entry.key: [
          for (final point in entry.value)
            if (!point.$1.isBefore(start))
              (point.$1.difference(start).inMicroseconds / 1000000, point.$2),
        ],
    };
    final values = plot.values
        .expand((v) => v)
        .map((v) => v.$2)
        .where((v) => v.isFinite)
        .toList();
    if (values.isEmpty) {
      return ListTile(
        title: Text(title),
        subtitle: const Text('No recent samples'),
      );
    }
    final low = values.reduce(math.min), high = values.reduce(math.max);
    final pad = math.max(0.1, (high - low) * .1);
    return ExpansionTile(
      title: Text(title),
      subtitle: Text('Last 60 seconds · $unit'),
      initiallyExpanded: true,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: EegAxisPainter(
              plot,
              left: 0,
              right: 60,
              minimum: low - pad,
              maximum: high + pad,
              yLabel: unit,
              colors: {
                for (final (i, key) in plot.keys.indexed)
                  key: [
                    Colors.blue,
                    Colors.teal,
                    Colors.deepOrange,
                    Colors.purple,
                  ][i % 4],
              },
            ),
          ),
        ),
      ],
    );
  }
}
