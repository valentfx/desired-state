import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'eeg_live_panel.dart';

class EcgLivePanel extends StatefulWidget {
  const EcgLivePanel({super.key, required this.controller});
  final SessionController controller;
  @override
  State<EcgLivePanel> createState() => _EcgLivePanelState();
}

class _EcgLivePanelState extends State<EcgLivePanel> {
  List<(BigInt, double)>? _held;
  double? _locked;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      if (c.polarId == null && c.ecgPreview.isEmpty) {
        return const SizedBox.shrink();
      }
      final source = _held ?? c.ecgPreview;
      final end = source.isEmpty ? BigInt.zero : source.last.$1;
      final points = [
        for (final p in source) ((p.$1 - end).toDouble() / 1000000000, p.$2),
      ];
      final limit =
          _locked ??
          math.max(
            100.0,
            points.map((p) => p.$2.abs()).fold<double>(0, math.max) * 1.1,
          );
      return Card(
        child: ExpansionTile(
          title: const Text('H10 ECG waveform'),
          subtitle: Text(
            c.ecgFresh
                ? '${c.ecgStatus} · ${c.recordedEcgSamples} samples recorded'
                : '${c.ecgStatus} · no fresh ECG',
          ),
          childrenPadding: const EdgeInsets.all(12),
          children: [
            const Text(
              'Single-lead ECG · unfiltered µV · last 10 seconds. Visual inspection only.',
            ),
            if (points.isNotEmpty) ...[
              SizedBox(
                height: 220,
                width: double.infinity,
                child: CustomPaint(
                  painter: EegAxisPainter(
                    {'ECG': points},
                    left: -10,
                    right: 0,
                    minimum: -limit,
                    maximum: limit,
                    yLabel: 'ECG (µV)',
                    colors: const {'ECG': Colors.red},
                  ),
                ),
              ),
              Text(
                'Visible min ${points.map((p) => p.$2).reduce(math.min).toStringAsFixed(1)} / max ${points.map((p) => p.$2).reduce(math.max).toStringAsFixed(1)} µV',
              ),
            ] else
              const Text('Waiting for ECG samples'),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => _held = _held == null ? List.of(c.ecgPreview) : null,
                  ),
                  child: Text(_held == null ? 'Hold waveform' : 'Follow ECG'),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _locked = _locked == null ? limit : null),
                  child: Text(_locked == null ? 'Lock scale' : 'Auto scale'),
                ),
              ],
            ),
            const Text(
              'Holding or collapsing the plot does not pause acquisition. Session pause stops recording new ECG batches. Device time is not synchronized to EEG or phone UTC.',
            ),
          ],
        ),
      );
    },
  );
}
