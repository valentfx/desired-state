import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:desired_state_app/processing.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;
import 'session_history_test.dart' show historyFixture;

final start = DateTime.utc(2026, 9, 30);
List<AnalysisResult> process(
  List<double> values, {
  ProcessingConfig config = const ProcessingConfig(),
}) {
  final p = RrProcessor(config);
  for (final (i, v) in values.indexed) {
    p.add(RrInput(start.add(Duration(seconds: i)), v, 0));
  }
  return p.results;
}

void main() {
  test('raw, range-only and screening differ without replacing input or recorded flags', () {
    final input = [1000.0, 1010.0, 730.0, 1020.0, 2500.0];
    final raw = process(input);
    final range = process(
      input,
      config: const ProcessingConfig(mode: AnalysisMode.range),
    );
    final screened = process(
      input,
      config: const ProcessingConfig(mode: AnalysisMode.screened),
    );
    expect(raw.map((r) => r.accepted), [true, true, true, true, true]);
    expect(range.map((r) => r.accepted), [true, true, true, true, false]);
    expect(screened.map((r) => r.accepted), [true, true, false, true, false]);
    expect(screened[3].values['RMSSD'], 10);
    expect(
      raw[3].values['RMSSD'],
      closeTo(sqrt((100 + 78400 + 84100) / 3), 1e-8),
    );
    expect(input, [1000, 1010, 730, 1020, 2500]);
    final rr = RrInput(start, 730, 0, recordedAccepted: true, packetIndex: 2);
    final processor = RrProcessor(
      const ProcessingConfig(mode: AnalysisMode.screened),
    );
    processor.add(RrInput(start, 1000, 0));
    expect(processor.add(rr).accepted, false);
    expect(rr.recordedAccepted, true);
    expect(rr.packetIndex, 2);
  });
  test('known metric math and zero RMSSD logarithm', () {
    final last = process([1000, 1060, 1000]).last;
    expect(last.values['RMSSD'], 60);
    expect(last.values['SDNN'], closeTo(sqrt(1200), 1e-8));
    expect(last.values['pNN50'], 100);
    expect(last.values['lnRMSSD'], log(60));
    final zero = process([1000, 1000, 1000]).last;
    expect(zero.values['RMSSD'], 0);
    expect(zero.values['lnRMSSD'], isNull);
  });
  test(
    'receipt-time window expires inputs and gates sample fraction and pairs',
    () {
      final p = RrProcessor(const ProcessingConfig(windowSeconds: 5));
      for (var i = 0; i < 8; i++) {
        p.add(RrInput(start.add(Duration(seconds: i)), 1000 + i.toDouble(), 0));
      }
      expect(p.results.last.total, 6);
      expect(p.results.last.pairs, 5);
      final coverage = process(
        [1000, 1010, 1020, 20, 20, 20, 20],
        config: const ProcessingConfig(mode: AnalysisMode.range, coverage: 75),
      ).last;
      expect(coverage.missing, contains('fraction'));
      expect(coverage.values['RMSSD'], isNull);
      final pairs = process(
        [1000, 20, 1010, 20, 1020],
        config: const ProcessingConfig(mode: AnalysisMode.range, coverage: 0),
      ).last;
      expect(pairs.missing, contains('pairs'));
      expect(pairs.pairs, 0);
    },
  );
  test(
    'gaps and backwards time restart reference, metrics and plotted adjacency',
    () {
      for (final kind in ['segment', 'time', 'backwards']) {
        final p = RrProcessor(
          const ProcessingConfig(mode: AnalysisMode.screened),
        );
        for (var i = 0; i < 3; i++) {
          p.add(RrInput(start.add(Duration(seconds: i)), 600, 0));
        }
        final next = p.add(
          RrInput(
            start.add(
              Duration(
                seconds: kind == 'time'
                    ? 20
                    : kind == 'backwards'
                    ? 0
                    : 3,
              ),
            ),
            1000,
            kind == 'segment' ? 1 : 0,
          ),
        );
        expect(next.accepted, true, reason: kind);
        expect(next.total, 1);
        expect(next.values['RMSSD'], isNull);
        expect(next.plotSegment, isNot(p.results[2].plotSegment));
      }
    },
  );
  test('sustained rate shift resets reference prospectively without rescuing artifacts', () {
    final result = process(
      [600, 1000, 1010, 1000, 1010, 1020],
      config: const ProcessingConfig(mode: AnalysisMode.screened, reference: 3),
    );
    expect(result.map((r) => r.accepted), [
      true,
      false,
      false,
      true,
      true,
      true,
    ]);
    expect(result[3].reason, contains('reference reset'));
    expect(result.last.pairs, 2);
    expect(
      process(
        [1000, 2000, 500, 1900, 500],
        config: const ProcessingConfig(
          mode: AnalysisMode.screened,
          reference: 3,
        ),
      ).skip(1).every((r) => !r.accepted),
      true,
    );
  });
  test(
    'nonpositive/nonfinite raw inputs are preserved but break derived pairs',
    () {
      final result = process([
        1000,
        0,
        1010,
        double.nan,
        1020,
        double.infinity,
        1030,
      ]);
      expect(result.last.pairs, 0);
      expect(result.last.values['RMSSD'], isNull);
      expect(result[1].values['RR'], 0);
      expect(result[3].values['RR'], isNull);
      expect(process([1e308, 1000, 1020]).last.values['RMSSD'], isNull);
    },
  );
  test('settings validate, serialize, persist and recover after failed save without replacing corrupt files', () async {
    final root = await Directory.systemTemp.createTemp('processing-settings-');
    addTearDown(() => root.delete(recursive: true));
    final store = ProcessingStore(directoryProvider: () async => root);
    await store.load();
    const config = ProcessingConfig(
      mode: AnalysisMode.range,
      windowSeconds: 30,
      metrics: ['RR', 'SDNN'],
    );
    await store.save(config);
    final reload = ProcessingStore(directoryProvider: () async => root);
    await reload.load();
    expect(reload.config.toJson(), config.toJson());
    expect(
      () => const ProcessingConfig(minimum: 900, maximum: 500).validate(),
      throwsFormatException,
    );
    expect(
      () => const ProcessingConfig(coverage: double.nan).validate(),
      throwsFormatException,
    );
    expect(
      () => const ProcessingConfig(metrics: []).validate(),
      throwsFormatException,
    );
    final file = File('${root.path}/desired_state_settings/processing.json');
    final original = await file.readAsBytes();
    final blocker = await Directory('${file.path}.tmp').create();
    await expectLater(
      store.save(const ProcessingConfig()),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file.readAsBytes(), original);
    expect(store.config.toJson(), config.toJson());
    await blocker.delete();
    await store.save(const ProcessingConfig());
    await file.writeAsString('{"schema_version":99}');
    final broken = ProcessingStore(directoryProvider: () async => root);
    await broken.load();
    expect(broken.error, isNotNull);
    await expectLater(broken.save(config), throwsStateError);
    expect(await file.readAsString(), '{"schema_version":99}');
  });
  test('history processing journal and export preserve raw files and replay config', () async {
    final root = await Directory.systemTemp.createTemp('processing-journal-');
    addTearDown(() => root.delete(recursive: true));
    final dir = await historyFixture(root);
    final raw = await File('${dir.path}/rr.jsonl').readAsBytes();
    final repo = SessionHistoryRepository(directoryProvider: () async => root);
    final entry = await repo.readEntry(dir);
    const config = ProcessingConfig(
      mode: AnalysisMode.screened,
      reference: 5,
      metrics: ['RMSSD', 'pNN50'],
    );
    await repo.recordProcessingView(entry, config);
    final journal = await rows(dir, 'processing_views');
    final replay = ProcessingConfig.fromJson(
      journal.single['configuration'] as Map<String, dynamic>,
    );
    expect(
      process([1000, 1010, 730, 1020], config: replay).last.values,
      process([1000, 1010, 730, 1020], config: config).last.values,
    );
    expect(await File('${dir.path}/rr.jsonl').readAsBytes(), raw);
    final archive = ZipDecoder().decodeBytes(
      await (await repo.export(entry)).readAsBytes(),
    );
    expect(archive.findFile('saved/processing_views.jsonl'), isNotNull);
    await File('${dir.path}/processing_views.jsonl')
        .writeAsString('{broken', mode: FileMode.append);
    await expectLater(
      repo.recordProcessingView(entry, config),
      throwsStateError,
    );
  });
  test('live and reopened history use identical inputs/config; settings never alter capture flags', () async {
    final root = await Directory.systemTemp.createTemp('processing-live-');
    final polar = FakePolar();
    final controller = SessionController(
      service: polar,
      foregroundService: FakeForeground(),
      directoryProvider: () async => root,
    );
    addTearDown(() async {
      await controller.stop();
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await root.delete(recursive: true);
    });
    await controller.connect(BluetoothDevice.fromId('H10'));
    await controller.start(participantName: 'Fixture');
    polar.emit([1000, 1010, 730, 1020]);
    final logger = controller.sessionLogger!;
    await controller.saveProcessing(
      const ProcessingConfig(mode: AnalysisMode.range),
    );
    controller.pause();
    polar.emit([999]);
    controller.resume();
    polar.emit([1100, 1110, 1120]);
    await controller.stop();
    final repo = SessionHistoryRepository(directoryProvider: () async => root);
    final session = await repo.open(await repo.readEntry(logger.directory));
    final live = RrProcessor(controller.processing.config),
        replay = RrProcessor(controller.processing.config);
    for (final input in controller.analysisInputs) {
      live.add(input);
    }
    for (final rr in session.rr) {
      replay.add(RrInput(rr.time, rr.value, rr.segment));
    }
    expect(
      live.results.map((r) => r.values).toList(),
      replay.results.map((r) => r.values).toList(),
    );
    expect(controller.analysisInputs.map((r) => r.value), [
      1000,
      1010,
      730,
      1020,
      1100,
      1110,
      1120,
    ]);
    final raw = await rows(logger.directory, 'rr');
    expect(raw[2]['artifact_accepted'], false);
    final events = await rows(logger.directory, 'events');
    final changes = events.where(
      (e) => e['event'] == 'processing_configuration_changed',
    );
    expect(
      jsonDecode(changes.single['description'] as String)['mode'],
      'range',
    );
    expect(
      events.any((e) => e['event'] == 'processing_configuration_initial'),
      true,
    );
  });
}
