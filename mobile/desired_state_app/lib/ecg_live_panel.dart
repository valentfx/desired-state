import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'eeg_live_panel.dart';
import 'plot_inspection.dart';
import 'session_history.dart';
import 'signal_review.dart';

class EcgLivePanel extends StatefulWidget {
  const EcgLivePanel({super.key, required this.controller});
  final SessionController controller;
  @override
  State<EcgLivePanel> createState() => _EcgLivePanelState();
}

class _EcgLivePanelState extends State<EcgLivePanel> {
  List<(BigInt, double)>? _held;
  double? _locked;
  DateTime? _heldTime;
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
      final selected = PlotInspectionScope.of(context)?.selection.time;
      final anchor = _heldTime ?? c.latestEcg?.receivedAt;
      final logger = c.sessionLogger ?? c.lastSessionLogger;
      final replaySelected =
          selected != null &&
          logger != null &&
          (anchor == null ||
              selected.isBefore(anchor.subtract(const Duration(seconds: 10))) ||
              selected.isAfter(anchor));
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
            if (replaySelected)
              _SelectedEcgExcerpt(
                key: ValueKey('${logger.sessionId}:$selected'),
                directory: logger.directory,
                selected: selected,
              )
            else if (points.isNotEmpty) ...[
              SizedBox(
                height: 220,
                width: double.infinity,
                child: SignalPlot(
                  painter: EegAxisPainter(
                    {'ECG': points},
                    timeOrigin: _heldTime ?? c.latestEcg?.receivedAt,
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
                  onPressed: () => setState(() {
                    _heldTime = _held == null ? c.latestEcg?.receivedAt : null;
                    _held = _held == null ? List.of(c.ecgPreview) : null;
                  }),
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

/// Bounded original-file excerpt when the shared cursor predates the live buffer.
class _SelectedEcgExcerpt extends StatefulWidget {
  const _SelectedEcgExcerpt({
    super.key,
    required this.directory,
    required this.selected,
  });
  final Directory directory;
  final DateTime selected;
  @override
  State<_SelectedEcgExcerpt> createState() => _SelectedEcgExcerptState();
}

class _SelectedEcgExcerptState extends State<_SelectedEcgExcerpt> {
  DateTime? _origin;
  double _left = 0;
  late final Future<ReplayReview> _replay = _load();
  Future<ReplayReview> _load() async {
    final entry = await SessionHistoryRepository().readEntry(widget.directory);
    _origin = entry.started;
    if (_origin == null) {
      throw const FormatException('Recording start is unavailable');
    }
    _left = math.max(
      0.0,
      widget.selected.difference(_origin!).inMicroseconds / 1000000 - 5,
    );
    return replaySignals(entry, _left, _left + 10);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ReplayReview>(
    future: _replay,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Text('ECG excerpt unavailable: ${snapshot.error}');
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const LinearProgressIndicator();
      }
      final replay = snapshot.data!;
      final finite = replay.ecg.values
          .expand((v) => v)
          .map((p) => p.$2)
          .where((v) => v.isFinite);
      if (finite.isEmpty) {
        return const Text('No recorded ECG at the selected time');
      }
      final limit =
          finite.fold<double>(100, (a, b) => math.max(a, b.abs())) * 1.1;
      return Column(
        children: [
          const Text(
            'Recorded ECG around selected time · approximate host anchor',
          ),
          SizedBox(
            height: 220,
            width: double.infinity,
            child: SignalPlot(
              painter: EegAxisPainter(
                replay.ecg,
                timeOrigin: _origin,
                left: _left,
                right: _left + 10,
                minimum: -limit,
                maximum: limit,
                yLabel: 'ECG (µV)',
                colors: const {'ECG': Colors.red},
              ),
            ),
          ),
          for (final warning in replay.warnings) Text(warning),
        ],
      );
    },
  );
}
