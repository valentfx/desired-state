import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'eeg_live_panel.dart';
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
        frame.channels.length == frame.channelCount &&
        frame.channelCount > 0;
    final values = good ? frame.values(null) : <String, double>{};
    final end = frame?.time ?? DateTime.now();
    final start = end.subtract(const Duration(seconds: 60));
    const bands = ['Alpha', 'Theta', 'Beta'];
    final series = {
      for (final band in bands)
        band: [
          for (final item in muse.bandHistory)
            if (!item.time.isBefore(start))
              (
                item.time.difference(start).inMicroseconds / 1000000,
                item.channels.length == item.channelCount &&
                        item.channelCount > 0
                    ? item.values(null)[band] ?? double.nan
                    : double.nan,
              ),
        ],
    };
    final finite = series.values
        .expand((v) => v)
        .map((v) => v.$2)
        .where((v) => v.isFinite);
    final maximum = finite.fold<double>(1, math.max) * 1.1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              good
                  ? 'EEG trends · ${frame.channelCount}/${frame.channelCount} channels'
                  : 'EEG · poor or stale signal',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SizedBox(
              height: 85,
              width: double.infinity,
              child: CustomPaint(
                painter: EegAxisPainter(
                  series,
                  left: 0,
                  right: 60,
                  minimum: 0,
                  maximum: maximum,
                  yLabel: 'µV²',
                  colors: const {
                    'Alpha': Colors.blue,
                    'Theta': Colors.teal,
                    'Beta': Colors.deepOrange,
                  },
                ),
              ),
            ),
            Wrap(
              spacing: 12,
              children: [
                for (final band in bands)
                  Text(
                    '$band ${values[band]?.toStringAsFixed(1) ?? '--'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: band == 'Alpha'
                          ? Colors.blue
                          : band == 'Theta'
                          ? Colors.teal
                          : Colors.deepOrange,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
