import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:desired_state_app/session_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'activity markers preserve machine identity and immutable labels',
    () async {
      final temp = await Directory.systemTemp.createTemp('activity-marker-');
      addTearDown(() => temp.delete(recursive: true));
      final logger = await SessionLogger.start(
        polarId: 'TEST',
        deviceName: 'Test',
        participantName: 'Person',
        directoryProvider: () async => temp,
      );
      await logger.writeEvent(
        'marked_event',
        eventId: 'event-1',
        markerDefinitionId: 'activity-yoga',
        markerLabel: 'Yoga',
        markerType: 'quick',
        activityId: 'yoga',
        flush: true,
      );
      await logger.close();
      final rows = (await File(
        '${logger.directory.path}/events.jsonl',
      ).readAsLines()).map(jsonDecode).toList();
      final marker = rows.firstWhere((r) => r['event_id'] == 'event-1');
      expect(marker['activity_id'], 'yoga');
      expect(marker['activity_action'], 'mark');
      expect(marker['activity_schema_version'], 1);
      expect(marker['marker_label'], 'Yoga');
      expect(marker.containsKey('duration'), false);
    },
  );

  test('writes a Flask-compatible identifiable session', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'desired-state-log-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final logger = await SessionLogger.start(
      polarId: 'e9e53b2c',
      deviceName: 'Polar H10 E9E53B2C',
      participantName: 'Michael',
      directoryProvider: () async => temporary,
      startedAt: DateTime.utc(2026, 9, 27, 12),
    );
    await logger.logMeasurement(
      polarId: 'E9E53B2C',
      participantName: 'Michael',
      heartRate: 45,
      intervals: const [
        LoggedRr(rrMs: 1334, accepted: true),
        LoggedRr(
          rrMs: 731,
          accepted: false,
          artifactReason: 'more_than_25_percent_from_recent_median',
        ),
      ],
      receivedAt: DateTime.utc(2026, 9, 27, 12, 1),
    );
    await logger.writeEvent(
      'marked_event',
      description: 'began slow breathing',
    );
    await logger.close();

    final manifest = jsonDecode(
      await File('${logger.directory.path}/manifest.json').readAsString(),
    );
    expect(manifest['assignments'], {'E9E53B2C': 'Michael'});
    expect(manifest['devices']['E9E53B2C']['name'], 'Polar H10 E9E53B2C');
    final rr = (await File(
      '${logger.directory.path}/rr.jsonl',
    ).readAsLines()).map(jsonDecode).toList();
    expect(rr, hasLength(2));
    expect(rr[1]['artifact_accepted'], isFalse);
    expect(rr[1]['artifact_reason'], 'more_than_25_percent_from_recent_median');
    final events = (await File(
      '${logger.directory.path}/events.jsonl',
    ).readAsLines()).map(jsonDecode).toList();
    expect(events.map((event) => event['event']), [
      'session_started',
      'marked_event',
      'session_ended',
    ]);
    expect(events[1]['description'], 'began slow breathing');
    final export = await logger.createExportZip();
    expect(await export.exists(), isTrue);
    final exported = ZipDecoder().decodeBytes(await export.readAsBytes());
    expect(
      exported.files.map((file) => file.name),
      containsAll([
        '${logger.sessionId}/manifest.json',
        '${logger.sessionId}/events.jsonl',
        '${logger.sessionId}/measurements.jsonl',
        '${logger.sessionId}/rr.jsonl',
      ]),
    );
  });
}
