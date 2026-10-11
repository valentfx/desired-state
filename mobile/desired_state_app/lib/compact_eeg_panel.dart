import 'package:flutter/material.dart';

import 'eeg_live_panel.dart';
import 'eeg_bands.dart';

import 'dart:math' as math;

import 'session_controller.dart';

class CompactEegPanel extends StatelessWidget {
  const CompactEegPanel({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) {
    final muse = controller.museAthena;
    if (!muse.streaming && muse.bandHistory.isEmpty) {
      return const SizedBox.shrink();
    }
    final frame = muse.latestBands;
    final good =
        muse.fresh &&
        frame != null &&
        frame.channels.isNotEmpty &&
        frame.channelCount > 0;
    final values = good
        ? frame.values(
            null,
            decibels: true,
            artifactScreening: controller.preferences.eegArtifactScreening,
          )
        : <String, double>{};
    final end = frame?.time ?? DateTime.now();
    final start = end.subtract(const Duration(seconds: 60));
    final bands = eegBands.keys;
    final series = {
      for (final band in bands)
        band: [
          for (final item in muse.bandHistory)
            if (!item.time.isBefore(start))
              (
                item.time.difference(start).inMicroseconds / 1000000,
                item.channels.isNotEmpty && item.channelCount > 0
                    ? item.values(
                            null,
                            decibels: true,
                            artifactScreening:
                                controller.preferences.eegArtifactScreening,
                          )[band] ??
                          double.nan
                    : double.nan,
              ),
        ],
    };
    final finite = series.values
        .expand((p) => p)
        .map((p) => p.$2)
        .where((v) => v.isFinite)
        .toList();
    final low = finite.isEmpty ? -10.0 : finite.reduce(math.min) - 2;
    final high = finite.isEmpty ? 10.0 : finite.reduce(math.max) + 2;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              good
                  ? 'EEG powerbands · ${frame.channelCount}/${frame.channelCount} channels'
                  : 'EEG · waiting or stale',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SizedBox(
              height: 100,
              width: double.infinity,
              child: SignalPlot(
                painter: EegAxisPainter(
                  series,
                  timeOrigin: start,
                  events: controller.eventTimes
                      .map(
                        (time) =>
                            time.difference(start).inMicroseconds / 1000000,
                      )
                      .toList(),
                  left: 0,
                  right: 60,
                  minimum: low,
                  maximum: high,
                  yLabel: 'dB',
                  colors: const {
                    'Delta': Colors.purple,
                    'Alpha': Colors.blue,
                    'Theta': Colors.teal,
                    'Beta': Colors.deepOrange,
                    'Gamma': Colors.pink,
                  },
                ),
              ),
            ),
            const Text(
              'dB re 1 µV² · not a state score',
              style: TextStyle(fontSize: 10),
            ),
            Wrap(
              spacing: 12,
              children: [
                for (final band in bands)
                  Text(
                    '${band[0]} ${values[band]?.toStringAsFixed(0) ?? '--'}',
                    style: TextStyle(fontSize: 12, color: eegBandColors[band]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
