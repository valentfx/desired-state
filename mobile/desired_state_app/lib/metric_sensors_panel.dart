import 'eeg_quality_panel.dart';
import 'eeg_live_panel.dart';
import 'athena_optical_panel.dart';

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'session_history.dart';
import 'history_plot.dart';
import 'ecg_live_panel.dart';

/// Observes the app-owned sensor streams; never starts a separate recorder.
class MetricSensorsPanel extends StatelessWidget {
  const MetricSensorsPanel({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final now = DateTime.now();
      final start = now.subtract(const Duration(seconds: 20));
      return Column(
        children: [
          EegLivePanel(controller: controller),
          AthenaOpticalPanel(controller: controller),
          if (controller.museAthena.streaming ||
              controller.museAthena.eegSamples > 0)
            EegQualityPanel(controller: controller),
          if (controller.ringId != null) ...[
            HistoryPlot(
              title: 'O2Ring oxygen (raw decoded)',
              unit: '%',
              start: start,
              end: now,
              events: const [],
              color: Colors.blue,
              points: _points(controller.oxygenTrend, start),
              onInspect: (p) => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${p.value?.toStringAsFixed(1) ?? "--"}%'),
                ),
              ),
            ),
            const Text(
              'O2Ring: decoded measurements; no configurable waveform filter.',
            ),
          ],
          if (controller.polarId != null) ...[
            ListTile(
              title: Text('Posture: ${controller.currentPosture}'),
              subtitle: Text(
                'Calibration: ${controller.activeCalibration?.id ?? 'not selected'} · recording ${controller.preferences.records('posture') ? 'on' : 'off'}',
              ),
            ),
            Text(
              'ECG recording ${controller.preferences.records('ecg') ? 'on' : 'off'} · acceleration recording ${controller.preferences.records('acc') ? 'on' : 'off'}',
            ),
            EcgLivePanel(controller: controller),
            ExpansionTile(
              title: const Text('H10 acceleration (live)'),
              subtitle: Text(controller.accelerationStatus),
              children: [
                for (var axis = 0; axis < 3; axis++)
                  HistoryPlot(
                    title: 'ACC ${['X', 'Y', 'Z'][axis]}',
                    unit: 'mG',
                    start: start,
                    end: now,
                    events: const [],
                    color: [Colors.red, Colors.green, Colors.blue][axis],
                    points: _points(controller.accTrends[axis], start),
                    onInspect: (point) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          duration: const Duration(seconds: 3),
                          content: Text(
                            'Acceleration: ${point.value?.toStringAsFixed(1) ?? '--'} mG at ${point.time.toLocal()}',
                          ),
                        ),
                      );
                    },
                  ),
                const Text(
                  'Last 20 seconds of acquired samples. Posture needs a matching saved calibration. Display does not enable recording.',
                ),
              ],
            ),
          ],
        ],
      );
    },
  );
  List<HistoryPoint> _points(List<(DateTime, double)> source, DateTime start) {
    final result = <HistoryPoint>[];
    DateTime? previous;
    var segment = 0;
    for (final sample in source) {
      if (sample.$1.isBefore(start)) {
        continue;
      }
      if (previous != null &&
          sample.$1.difference(previous) > const Duration(seconds: 2)) {
        segment++;
      }
      result.add(HistoryPoint(sample.$1, sample.$2, segment));
      previous = sample.$1;
    }
    return result;
  }
}
