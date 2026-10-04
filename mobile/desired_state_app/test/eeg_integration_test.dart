import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/eeg_bands.dart';
import 'package:desired_state_app/muse_athena_service.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:desired_state_app/participant_tools.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;

class FakeMuse extends MuseAthenaService {
  final data = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get batches => data.stream;
  void emit(int count) {
    streaming = true;
    lastSamplesAt = DateTime.now();
    data.add({
      'eegCount': count,
      'eeg': {'0': List.filled(count, 1.0)},
      'received_utc': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  void dispose() {
    unawaited(data.close());
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('band power retains common physical scale and sinusoid power', () {
    final samples = List.generate(
      1024,
      (i) =>
          10 * math.sin(2 * math.pi * 10 * i / 256) +
          5 * math.sin(2 * math.pi * 20 * i / 256),
    );
    final power = eegBandPower(samples, 256)!;
    expect(power['Alpha'], closeTo(50, 0.2));
    expect(power['Beta'], closeTo(12.5, 0.2));
    expect(power['Alpha']! / power['Beta']!, closeTo(4, 0.02));
    final relative = EegBandFrame(DateTime.now(), {
      '0': power,
    }, 1).values(null, relative: true);
    expect(relative.values.reduce((a, b) => a + b), closeTo(100, 0.001));
    expect(relative['Alpha'], closeTo(80, 0.2));
  });
  test(
    'flatline, insufficient samples and large spikes do not yield feedback',
    () {
      expect(eegBandPower(List.filled(1024, 10), 256), isNull);
      expect(eegBandPower(List.filled(100, 1), 256), isNull);
      final samples = List.generate(1024, (i) => math.sin(i.toDouble()));
      samples[500] = 1000;
      expect(eegBandPower(samples, 256), isNull);
    },
  );
  test(
    'EEG-only recording respects pause/stop and exports raw batches',
    () async {
      final root = await Directory.systemTemp.createTemp('eeg-session-');
      final muse = FakeMuse()..eegRate = 256;
      final controller = SessionController(
        service: FakePolar(),
        museService: muse,
        foregroundService: FakeForeground(),
        directoryProvider: () async => root,
      );
      try {
        muse.emit(1);
        expect(controller.canStart, isTrue);
        await controller.start(participantName: 'Original');
        final logger = controller.sessionLogger!;
        muse.emit(2);
        controller.pause();
        muse.emit(7);
        controller.resume();
        muse.emit(3);
        await controller.editRecordingParticipant('Corrected', 'User note');
        await controller.stop();
        muse.emit(11);
        final saved = await rows(logger.directory, 'muse_eeg');
        expect(saved.map((r) => r['eegCount']), [2, 3]);
        expect(saved.every((r) => r['user_id'] == 'Original'), isTrue);
        final repo = SessionHistoryRepository(
          directoryProvider: () async => root,
        );
        final entry = await repo.readEntry(logger.directory);
        expect(entry.participant, 'Corrected');
        expect(entry.originalParticipant, 'Original');
        expect(entry.metadata.userInfo, 'User note');
        final opened = await repo.open(entry);
        expect(opened.eegSamples, 5);
        final zip = await repo.export(entry);
        final names = ZipDecoder()
            .decodeBytes(await zip.readAsBytes())
            .files
            .map((f) => f.name);
        expect(names.any((n) => n.endsWith('/muse_eeg.jsonl')), isTrue);
        expect(names.any((n) => n.endsWith('/history_edits.jsonl')), isTrue);
      } finally {
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      }
    },
  );
  test('saved participant correction preserves raw manifest and HR analysis', () async {
    final root = await Directory.systemTemp.createTemp('participant-edit-');
    final polar = FakePolar();
    final controller = SessionController(
      service: polar,
      foregroundService: FakeForeground(),
      directoryProvider: () async => root,
    );
    try {
      // EEG-only fixture plus a raw HR row exercises original ownership checks.
      final muse = controller.museAthena;
      muse.streaming = true;
      muse.lastSamplesAt = DateTime.now();
      await controller.start(participantName: 'unassigned');
      final logger = controller.sessionLogger!;
      await logger.logMeasurement(
        polarId: 'MUSE_ATHENA',
        participantName: 'unassigned',
        heartRate: 60,
        intervals: [],
        receivedAt: DateTime.now(),
      );
      await controller.stop();
      final manifest = File('${logger.directory.path}/manifest.json');
      final original = await manifest.readAsString();
      final repo = SessionHistoryRepository(
        directoryProvider: () async => root,
      );
      final entry = await repo.readEntry(logger.directory);
      await repo.saveMetadata(
        entry,
        participantMetadata(entry.metadata, 'Me', 'Info'),
      );
      expect(await manifest.readAsString(), original);
      final updated = await repo.open(entry);
      expect(updated.hr.single.value, 60);
      expect(updated.entry.participant, 'Me');
      expect(jsonDecode(original)['assignments']['MUSE_ATHENA'], 'unassigned');
    } finally {
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      await root.delete(recursive: true);
    }
  });
}
