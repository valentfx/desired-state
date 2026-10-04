import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:desired_state_app/eeg_bands.dart';
import 'package:desired_state_app/eeg_live_panel.dart';
import 'package:desired_state_app/session_review_screen.dart';
import 'package:desired_state_app/session_analysis.dart';
import 'package:desired_state_app/signal_review.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:desired_state_app/session_logger.dart';
import 'package:desired_state_app/h10_ecg.dart';

import 'h10_ecg_test.dart' show ecgPacket;

final origin = DateTime.utc(2026, 10, 3, 12);
HistoryEntry makeEntry(Directory directory) => HistoryEntry(
  directory,
  {
    'schema_version': 1,
    'session_id': 'fixture',
    'started_utc': origin.toIso8601String(),
    'assignments': {'H10': 'Original'},
  },
  [
    {
      'event': 'session_ended',
      'received_utc': origin
          .add(const Duration(seconds: 120))
          .toIso8601String(),
    },
  ],
  HistoryMetadata(description: '', notes: '', tags: []),
  [],
  [],
  true,
  0,
);
HistorySession rrSession({bool gap = false}) {
  final rr = [
    for (var i = 0; i < 120; i++)
      HistoryRr(
        {},
        origin.add(Duration(seconds: i)),
        i < 60 ? (i.isEven ? 990.0 : 1010.0) : (i.isEven ? 970.0 : 1030.0),
        gap && i >= 30 ? 1 : 0,
        true,
        null,
        null,
        null,
      ),
  ];
  return HistorySession(
    makeEntry(Directory('/unused')),
    [
      for (var i = 0; i < 120; i++)
        HistoryPoint(origin.add(Duration(seconds: i)), i < 60 ? 70.0 : 65.0, 0),
    ],
    rr,
    [],
  );
}

void main() {
  test(
    'equal-duration screened windows calculate RR metrics and factual trends',
    () {
      final blocks = hrvBlocks(rrSession(), 60);
      expect(blocks, hasLength(2));
      expect(blocks.every((b) => b.ready), isTrue);
      expect(blocks.first.metrics['RMSSD'], closeTo(20, .001));
      expect(blocks.last.metrics['RMSSD'], closeTo(60, .001));
      expect(blocks.first.metrics['SDNN'], closeTo(math.sqrt(6000 / 59), .001));
      expect(blocks.last.metrics['pNN50'], 100);
      expect(blocks.first.metrics['lnRMSSD'], closeTo(math.log(20), .001));
      final insights = h10Observations(
        blocks,
        origin,
        origin.add(const Duration(seconds: 120)),
        origin,
        origin.add(const Duration(seconds: 60)),
      );
      expect(insights.any((s) => s.contains('increased by 40.0 ms')), isTrue);
      expect(
        insights.any((s) => s.contains('70.0 bpm; later 65.0 bpm')),
        isTrue,
      );
    },
  );
  test(
    'continuity gap makes a window unavailable and does not bridge pairs',
    () {
      final blocks = hrvBlocks(rrSession(gap: true), 60);
      expect(blocks.first.ready, isFalse);
      expect(blocks.first.pairs, 58);
      expect(blocks.first.metrics['RMSSD'], isNull);
      final insights = h10Observations(
        blocks,
        origin,
        origin.add(const Duration(seconds: 120)),
        origin,
        origin.add(const Duration(seconds: 60)),
      );
      expect(insights.any((s) => s.contains('No separate qualified')), isTrue);
    },
  );
  test('short data cannot produce qualified nervous-system feedback', () {
    final session = rrSession();
    final short = HistorySession(
      session.entry,
      session.hr.take(10).toList(),
      session.rr.take(10).toList(),
      [],
    );
    expect(hrvBlocks(short, 60).single.ready, isFalse);
  });
  test('EEG reconstruction resets at pause; raw replay and derived exports retain originals', () async {
    final root = await Directory.systemTemp.createTemp('saved-signal-review-');
    final logger = await SessionLogger.start(
      polarId: 'H10',
      deviceName: 'H10',
      participantName: 'Original',
      directoryProvider: () async => root,
      startedAt: origin,
      additionalDevices: {
        'MUSE_ATHENA': {'kind': 'muse_s_athena'},
      },
    );
    try {
      for (var second = 0; second < 5; second++) {
        await logger.logMuseBatch({
          'received_utc': origin
              .add(Duration(seconds: second + 1))
              .toIso8601String(),
          'eeg_rate_hz': 256,
          'eegCount': 256,
          'recording_segment': 0,
          'continuity_segment': 0,
          'eeg': {
            'EEG0': [
              for (var i = 0; i < 256; i++)
                10 * math.sin(2 * math.pi * 10 * (second * 256 + i) / 256),
            ],
          },
        });
      }
      await logger.logMuseBatch({
        'received_utc': origin
            .add(const Duration(seconds: 6))
            .toIso8601String(),
        'eeg_rate_hz': 256,
        'eegCount': 256,
        'recording_segment': 1,
        'continuity_segment': 0,
        'eeg': {'EEG0': List.filled(256, 0.0)},
      });
      await logger.logEcg(
        deviceId: 'H10',
        segment: 0,
        frame: H10EcgProtocol.decode(
          ecgPacket([-100, 200], 10000000000),
          origin.add(const Duration(seconds: 5)),
          130,
        ),
      );
      await logger.close();
      final repository = SessionHistoryRepository(
        directoryProvider: () async => root,
      );
      final entry = await repository.readEntry(logger.directory);
      final original = await File('${logger.directory.path}/muse_eeg.jsonl')
          .readAsBytes();
      final signals = await reviewSignals(entry);
      expect(signals.windows, 2);
      expect(signals.bands.every((b) => b.frame.channels.isNotEmpty), isTrue);
      expect(signals.bands.first.frame.values(null)['Alpha'], closeTo(50, .2));
      expect(
        signals.bands.last.frame.time,
        origin.add(const Duration(seconds: 5)),
      );
      final replay = await replaySignals(entry, 4.0, 6.0);
      expect(replay.ecg['ECG']!.map((p) => p.$2), [-100, 200]);
      expect(replay.eeg['EEG0'], isNotEmpty);
      await repository.recordAnalysisReview(entry, {'method': 'fixture'});
      expect(
        await File('${logger.directory.path}/muse_eeg.jsonl').readAsBytes(),
        original,
      );
      final zip = await repository.export(entry);
      expect(
        ZipDecoder()
            .decodeBytes(await zip.readAsBytes())
            .files
            .any((f) => f.name.endsWith('/analysis_reviews.jsonl')),
        isTrue,
      );
      final guarded = SessionHistoryRepository(
        directoryProvider: () async => root,
        activeSessionId: () => entry.id,
      );
      await expectLater(
        guarded.recordAnalysisReview(entry, {}),
        throwsStateError,
      );
      final journal = File('${logger.directory.path}/analysis_reviews.jsonl');
      await journal.writeAsString('broken\n');
      await expectLater(
        repository.recordAnalysisReview(entry, {}),
        throwsStateError,
      );
      expect(await journal.readAsString(), 'broken\n');
      // Wrong original identity must never contribute to reconstructed bands.
      final rows = const LineSplitter().convert(utf8.decode(original));
      final bad = rows
          .map((line) {
            final row = jsonDecode(line) as Map<String, dynamic>;
            row['user_id'] = 'Other';
            return jsonEncode(row);
          })
          .join('\n');
      await File('${logger.directory.path}/muse_eeg.jsonl')
          .writeAsString('$bad\n');
      expect((await reviewSignals(entry)).bands, isEmpty);
    } finally {
      await logger.close();
      await root.delete(recursive: true);
    }
  });
  testWidgets(
    'phone session review expands EEG and raw plots with shared axes',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bands = [
        for (final seconds in [20, 40, 80, 110])
          SavedBand(
            EegBandFrame(origin.add(Duration(seconds: seconds)), {
              'EEG0': {'Delta': 1, 'Theta': 10, 'Alpha': 50, 'Beta': 12.5},
            }, 1),
            0,
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: SessionReviewScreen(
            session: rrSession(),
            repository: SessionHistoryRepository(),
            signalLoader: (_, _) async => SignalReview(
              bands,
              [],
              4,
              4,
              origin.add(const Duration(seconds: 120)),
            ),
            replayLoader: (_, start, _) async => ReplayReview(
              {
                'EEG0': [(start + .1, -10), (start + .2, 10)],
              },
              {
                'ECG': [(start + .1, -100), (start + .2, 200)],
              },
              [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('H10 analysis overview'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('EEG post-processing'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('EEG post-processing'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('EEG band power'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<EegAxisPainter>();
      expect(
        painters.any(
          (p) =>
              p.yLabel == 'EEG band power (µV²)' &&
              p.minimum == 0 &&
              p.maximum > 50,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
