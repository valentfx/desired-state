import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/session_logger.dart';
import 'package:desired_state_app/state_feedback.dart';
import 'package:desired_state_app/state_feedback_widgets.dart';

void main() {
  test('pre/live/post answers retain identity and raw files; export includes journal', () async {
    final temp = await Directory.systemTemp.createTemp('state-rating-');
    addTearDown(() => temp.delete(recursive: true));
    final logger = await SessionLogger.start(
      polarId: 'ABC',
      deviceName: 'Test',
      participantName: 'Test',
      participantId: 'participant-1',
      directoryProvider: () async => temp,
      context: const SessionContext(
        desiredState: 'calm',
        purpose: 'experiment',
      ),
    );
    final store = StateFeedbackStore(logger.directory, logger.sessionId);
    final before = DateTime.utc(2026, 10, 5, 10);
    await store.add(
      question: FeedbackQuestion.goal,
      value: 0,
      phase: 'pre',
      source: 'test',
      desiredState: 'calm',
      participantId: 'participant-1',
      eventAt: before,
      enteredAt: before.add(const Duration(seconds: 20)),
    );
    await store.add(
      question: FeedbackQuestion.goal,
      value: 5,
      phase: 'during',
      source: 'test',
      desiredState: 'calm',
    );
    await logger.close();
    final original = await File('${logger.directory.path}/events.jsonl')
        .readAsString();
    await store.add(
      question: FeedbackQuestion.goal,
      value: 10,
      phase: 'post',
      source: 'test',
      desiredState: 'calm',
    );
    await Future.wait([
      for (var i = 0; i < 3; i++)
        store.add(
          question: FeedbackQuestion.anxiety,
          value: i,
          phase: 'followup',
          source: 'test',
        ),
    ]);
    final rows = await store.read();
    expect(rows, hasLength(6));
    expect(rows.first['value'], 0);
    expect(rows.first['participant_id'], 'participant-1');
    expect(rows.first['retrospective'], true);
    expect((rows.first['question'] as Map)['high_label'], 'Fully there');
    expect(rows.map((r) => r['event_id']).toSet(), hasLength(6));
    expect(
      await File('${logger.directory.path}/events.jsonl').readAsString(),
      original,
    );
    final export = await logger.createExportZip();
    final zip = ZipDecoder().decodeBytes(await export.readAsBytes());
    expect(
      zip.files.map((f) => f.name),
      contains('${logger.sessionId}/state_feedback.jsonl'),
    );
    final manifest = jsonDecode(
      await File('${logger.directory.path}/manifest.json').readAsString(),
    ) as Map;
    expect(manifest['schema_version'], 1); // Legacy consumers stay compatible.
    expect((manifest['session_context'] as Map)['purpose'], 'experiment');
  });

  test(
    'invalid ratings and corrupt journals are preserved and rejected',
    () async {
      final temp = await Directory.systemTemp.createTemp('rating-corrupt-');
      addTearDown(() => temp.delete(recursive: true));
      await File('${temp.path}/manifest.json')
          .writeAsString('{"session_id":"test"}');
      final store = StateFeedbackStore(temp, 'test');
      await expectLater(
        store.add(
          question: FeedbackQuestion.energy,
          value: 11,
          phase: 'pre',
          source: 'test',
        ),
        throwsArgumentError,
      );
      await expectLater(
        store.add(
          question: FeedbackQuestion.goal,
          value: 4,
          phase: 'pre',
          source: 'test',
        ),
        throwsArgumentError,
      );
      final file = File('${temp.path}/state_feedback.jsonl');
      await file.writeAsString('broken-original\n');
      await expectLater(
        store.add(
          question: FeedbackQuestion.energy,
          value: 4,
          phase: 'post',
          source: 'test',
        ),
        throwsFormatException,
      );
      expect(await file.readAsString(), 'broken-original\n');
      await file.delete();
      await store.add(
        question: FeedbackQuestion.energy,
        value: 4,
        phase: 'post',
        source: 'test',
      );
      expect(
        await store.read(),
        hasLength(1),
      ); // Failed write does not poison queue.
    },
  );

  testWidgets('rating bar starts unset and includes zero on a narrow screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: StateRatingBar(
              question: FeedbackQuestion.energy,
              value: null,
              onChanged: (n) {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('0'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(
      tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .where((c) => c.selected),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancel feedback leaves no answer and tapping zero returns zero',
    (tester) async {
      int? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showStateRating(
                    context,
                    FeedbackQuestion.energy,
                  );
                },
                child: const Text('Rate'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Rate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text('Rate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('0'));
      await tester.pumpAndSettle();
      expect(result, 0);
    },
  );
}
