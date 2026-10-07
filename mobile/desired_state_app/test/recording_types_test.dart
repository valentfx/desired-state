import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/recording_types.dart';
import 'package:desired_state_app/state_feedback.dart';

void main() {
  test(
    'custom type revisions and archive retain the captured definition',
    () async {
      final root = await Directory.systemTemp.createTemp('recording-types-');
      try {
        final store = RecordingTypeStore(directoryProvider: () async => root);
        final first = await store.save('Sauna', 'Seated dry heat recording');
        final snapshot = first.toJson();
        final renamed = await store.save(
          'Dry sauna',
          'Dry heat with timed breaks',
          id: first.id,
        );
        expect(renamed.id, first.id);
        expect(renamed.version, 2);
        await store.save(
          renamed.name,
          renamed.definition,
          id: first.id,
          archived: true,
        );
        final reloaded = await RecordingTypeStore(
          directoryProvider: () async => root,
        ).list();
        expect(reloaded[first.id]!.archived, isTrue);
        expect(reloaded[first.id]!.version, 3);
        expect(snapshot['name'], 'Sauna');
        expect(snapshot['version'], 1);
        await store.select(first.id);
        expect(
          await RecordingTypeStore(directoryProvider: () async => root)
              .lastSelection(),
          first.id,
        );
        expect(
          recordingTypeId({
            'session_context': {'recording_type': snapshot},
          }),
          first.id,
        );
        expect(recordingTypeLabel({}), 'Unspecified');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test('unreadable definitions are preserved and block writes', () async {
    final root = await Directory.systemTemp.createTemp(
      'recording-types-corrupt-',
    );
    try {
      final file = File('${root.path}/recording_types.jsonl');
      await file.writeAsString('{broken\n');
      final store = RecordingTypeStore(directoryProvider: () async => root);
      await expectLater(
        store.save('Test', 'Definition'),
        throwsFormatException,
      );
      expect(await file.readAsString(), '{broken\n');
    } finally {
      await root.delete(recursive: true);
    }
  });
  test(
    'overall feeling uses 1 to 10 and legacy zero ratings remain readable',
    () async {
      final root = await Directory.systemTemp.createTemp('overall-feeling-');
      try {
        await File('${root.path}/manifest.json')
            .writeAsString(jsonEncode({'session_id': 'rating-test'}));
        final store = StateFeedbackStore(root, 'rating-test');
        await store.add(
          question: FeedbackQuestion.energy,
          value: 0,
          phase: 'during',
          source: 'test',
        );
        await expectLater(
          store.add(
            question: FeedbackQuestion.overall,
            value: 0,
            phase: 'during',
            source: 'test',
          ),
          throwsArgumentError,
        );
        await store.add(
          question: FeedbackQuestion.overall,
          value: 1,
          phase: 'during',
          source: 'test',
        );
        final rows = await store.read();
        expect(rows.map((row) => row['value']), [0, 1]);
        expect((rows.last['question'] as Map)['minimum'], 1);
        final context = SessionContext(
          experience: 'session',
          question: FeedbackQuestion.overall,
          recordingType: defaultRecordingTypes.first.toJson(),
        );
        expect(context.toJson()['experience'], 'session');
        expect(recordingTypeId({'session_context': context.toJson()}), 'sleep');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
