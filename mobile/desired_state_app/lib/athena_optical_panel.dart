import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'eeg_live_panel.dart';
import 'session_controller.dart';

class AthenaOpticalPanel extends StatelessWidget {
  const AthenaOpticalPanel({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) {
    final muse = controller.museAthena;
    if (muse.acquisitionPreset == 'p21' && muse.opticalSamples == 0) {
      return const SizedBox.shrink();
    }
    final source = {
      for (final channel in muse.opticalHistory.entries)
        if (channel.value.any((v) => v.isFinite && v != 0))
          channel.key: channel.value,
    };
    final series = {
      for (final entry in source.entries)
        'Optical ${entry.key}': [
          for (var i = 0; i < entry.value.length; i++)
            (
              (i - entry.value.length + 1) / math.max(1, muse.opticalRate),
              entry.value[i],
            ),
        ],
    };
    final values = source.values
        .expand((v) => v)
        .where((v) => v.isFinite)
        .toList();
    final low = values.isEmpty ? 0.0 : values.reduce(math.min);
    final high = values.isEmpty ? 1.0 : values.reduce(math.max);
    final padding = math.max(1.0, (high - low) * .05);
    final stale =
        muse.lastOpticalAt == null ||
        DateTime.now().difference(muse.lastOpticalAt!) >
            const Duration(seconds: 3);
    return ExpansionTile(
      title: const Text('Athena optical data'),
      subtitle: Text(
        stale
            ? 'Waiting / stale optical stream'
            : '${muse.opticalSamples} samples · ${muse.opticalRate} Hz',
      ),
      children: [
        SizedBox(
          height: 200,
          width: double.infinity,
          child: SignalPlot(
            painter: EegAxisPainter(
              series,
              timeOrigin: muse.lastOpticalAt,
              left: -1024 / math.max(1, muse.opticalRate),
              right: 0,
              minimum: low - padding,
              maximum: high + padding,
              yLabel: 'Raw optical intensity',
              colors: {
                for (final (i, name) in series.keys.indexed)
                  name: eegBandColors.values.elementAt(
                    i % eegBandColors.length,
                  ),
              },
              maximumGapSeconds: 2 / math.max(1, muse.opticalRate),
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
        const Text(
          'Experimental optical capture. Wavelength/channel mapping and hemoglobin conversion are not validated; this is not SpO2 or Muse brain oxygenation.',
        ),
      ],
    );
  }
}
