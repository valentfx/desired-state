import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'eeg_live_panel.dart';
import 'plot_inspection.dart';
import 'session_history.dart';
import 'signal_review.dart';

/// The same EEG comparison used by Session tools, rebuilt from immutable raw files.
class SavedEegScreen extends StatefulWidget {
  const SavedEegScreen({super.key, required this.entry});
  final HistoryEntry entry;
  @override
  State<SavedEegScreen> createState() => _SavedEegScreenState();
}

class _SavedEegScreenState extends State<SavedEegScreen> {
  late final Future<SignalReview> _review = reviewSignals(widget.entry);
  late final DateTime _origin = widget.entry.started ?? DateTime(1970);
  Future<ReplayReview>? _replay;
  double _replayStart = 0;
  DateTime? _lastSelection;
  @override
  Widget build(BuildContext context) {
    final selected = PlotInspectionScope.of(context)?.selection.time;
    if (selected != null && selected != _lastSelection) {
      _lastSelection = selected;
      final seconds = selected.difference(_origin).inMicroseconds / 1000000;
      if (seconds >= 0 &&
          (seconds < _replayStart ||
              seconds > _replayStart + 10 ||
              _replay == null)) {
        _replayStart = math.max(0.0, seconds - 5);
        _replay = replaySignals(widget.entry, _replayStart, _replayStart + 10);
      }
    }
    return PlotInspectionScope(
      saved: true,
      origin: _origin,
      controller: PlotInspectionScope.of(context)?.controller,
      valuesAt: (_) => {},
      child: Scaffold(
        appBar: AppBar(title: const Text('EEG processing & comparison')),
        body: FutureBuilder<SignalReview>(
          future: _review,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text('EEG could not be read: ${snapshot.error}'),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final review = snapshot.data!;
            final duration = math.max(
              1.0,
              (review.endTime ?? _origin).difference(_origin).inMicroseconds /
                  1000000,
            );
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                EegComparisonPlot(
                  frames: review.bands.map((b) => b.frame).toList(),
                  origin: _origin,
                  left: 0,
                  right: duration,
                  events: widget.entry.events
                      .where((e) => e['event'] == 'marked_event')
                      .map((e) => DateTime.tryParse('${e['received_utc']}'))
                      .whereType<DateTime>()
                      .map(
                        (t) => t.difference(_origin).inMicroseconds / 1000000,
                      )
                      .toList(),
                ),
                ExpansionTile(
                  title: const Text('Raw EEG / ECG excerpt'),
                  children: [
                    Slider(
                      min: 0,
                      max: math.max(.001, duration - 10),
                      value: _replayStart
                          .clamp(0.0, math.max(.001, duration - 10))
                          .toDouble(),
                      onChanged: (v) => setState(() => _replayStart = v),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () => _replay = replaySignals(
                          widget.entry,
                          _replayStart,
                          math.min(duration, _replayStart + 10),
                        ),
                      ),
                      child: const Text('Load 10 seconds'),
                    ),
                    if (_replay != null)
                      FutureBuilder<ReplayReview>(
                        future: _replay,
                        builder: (context, replay) {
                          if (replay.hasError) {
                            return Text('Replay failed: ${replay.error}');
                          }
                          if (!replay.hasData) {
                            return const LinearProgressIndicator();
                          }
                          final series = {
                            ...replay.data!.eeg.map(
                              (k, v) => MapEntry('EEG $k', v),
                            ),
                            ...replay.data!.ecg,
                          };
                          final finite = series.values
                              .expand((p) => p)
                              .map((p) => p.$2)
                              .where((v) => v.isFinite)
                              .toList();
                          final limit = finite.fold<double>(
                            1,
                            (a, b) => math.max(a, b.abs()),
                          );
                          return SizedBox(
                            height: 220,
                            width: double.infinity,
                            child: SignalPlot(
                              painter: EegAxisPainter(
                                series,
                                timeOrigin: _origin,
                                left: _replayStart,
                                right: _replayStart + 10,
                                minimum: -limit,
                                maximum: limit,
                                yLabel: 'Raw (µV)',
                                colors: {
                                  for (final (i, name) in series.keys.indexed)
                                    name: eegBandColors.values.elementAt(
                                      i % eegBandColors.length,
                                    ),
                                },
                                maximumGapSeconds: .04,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
                for (final warning in review.warnings) Text(warning),
              ],
            );
          },
        ),
      ),
    );
  }
}
