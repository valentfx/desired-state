import 'dart:convert';
import 'dart:io';

import 'package:desired_state_app/desktop_store.dart';
import 'package:desired_state_app/participant_store.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:desired_state_app/state_feedback.dart';
import 'package:desired_state_app/state_feedback_widgets.dart';

void main() {
  test(
    'last participant survives restart and follows an explicit merge',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'participant-default-',
      );
      try {
        final store = ParticipantStore(directoryProvider: () async => root);
        final first = await store.save('mike', 'first profile');
        final second = await store.save('mike', 'second profile');
        await store.rememberParticipant(first.id);
        expect(
          (await ParticipantStore(
            directoryProvider: () async => root,
          ).lastParticipant())?.id,
          first.id,
        );
        await store.save(
          second.name,
          second.info,
          id: first.id,
          newId: second.id,
          merge: true,
        );
        final restored = await ParticipantStore(
          directoryProvider: () async => root,
        ).lastParticipant();
        expect(restored?.id, second.id);
        expect(restored?.info, second.info);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'rating-only popup enables saving only after an explicit answer',
    (tester) async {
      SessionSetupResult? response;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  response = await showSessionSetup(
                    context,
                    const SessionContext(question: FeedbackQuestion.energy),
                    ratingOnly: true,
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
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save rating'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '7'));
      await tester.tap(find.widgetWithText(ChoiceChip, '7'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Save rating'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save rating'));
      await tester.pumpAndSettle();
      expect(response?.value, 7);
      expect(response?.context.question, FeedbackQuestion.energy);
    },
  );
  test(
    'posture steps preserve transitions and reset across disconnections',
    () {
      final origin = DateTime.utc(2026, 10, 7);
      Map<String, dynamic> event(
        int second,
        String type, [
        String? position,
      ]) => {
        'received_utc': origin.add(Duration(seconds: second)).toIso8601String(),
        'event': type,
        if (position != null) 'description': jsonEncode({'position': position}),
      };
      final events = [
        event(10, 'posture_estimate', 'On back'),
        event(50, 'posture_estimate', 'Left side'),
        event(70, 'bluetooth_disconnected'),
      ];
      expect(recordedPosturePoints(events, origin, 30, 90), [
        (30.0, 1.0),
        (50.0, 1.0),
        (50.0, 3.0),
        (70.0, 3.0),
        (70.0, 0.0),
        (90.0, 0.0),
      ]);
      expect(
        recordedPosturePoints([event(10, 'session_started')], origin, 0, 20),
        isEmpty,
      );
    },
  );
  test(
    'ring quality withholds oxygen without dropping motion observations',
    () {
      final data = <String, List<SignalPoint>>{};
      DesktopDecoder().decode(
        'o2ring_measurements',
        {
          'usable': false,
          'spo2_percent': 80,
          'pulse_bpm': 90,
          'motion_raw': 12,
        },
        1,
        data,
        0,
        2,
      );
      expect(data['SpO2 (%)']!.single.$2.isNaN, true);
      expect(data['Ring movement (raw)'], [(1.0, 12.0)]);
    },
  );
  test('participant correction and duplicate merge preserve original journal history', () async {
    final root = await Directory.systemTemp.createTemp('identity-correction-');
    try {
      final store = ParticipantStore(directoryProvider: () async => root);
      final first = await store.save('mike', 'first');
      final second = await store.save('mike', 'second');
      final original = await File('${root.path}/participants_v1.jsonl')
          .readAsString();
      await expectLater(
        store.save('mike', 'first', id: first.id, newId: second.id),
        throwsFormatException,
      );
      await store.save(
        second.name,
        second.info,
        id: first.id,
        newId: second.id,
        merge: true,
      );
      await store.save(
        'Mike',
        'corrected',
        id: second.id,
        newId: 'mike-primary',
      );
      final reopened = ParticipantStore(directoryProvider: () async => root);
      expect((await reopened.profiles()).keys, ['mike-primary']);
      expect(await reopened.canonicalId(first.id), 'mike-primary');
      expect(await reopened.canonicalId(second.id), 'mike-primary');
      expect(
        (await File(
          '${root.path}/participants_v1.jsonl',
        ).readAsString()).startsWith(original),
        true,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
  test(
    'delete moves a session to recoverable trash and blocks active deletion',
    () async {
      final root = await Directory.systemTemp.createTemp('session-trash-');
      try {
        final session = Directory('${root.path}/desired_state_sessions/test');
        await session.create(recursive: true);
        await File('${session.path}/manifest.json').writeAsString(
          jsonEncode({
            'schema_version': 1,
            'session_id': 'test',
            'started_utc': '2026-10-07T00:00:00Z',
          }),
        );
        await File('${session.path}/events.jsonl').writeAsString(
          '{"event":"session_ended","received_utc":"2026-10-07T00:01:00Z"}\n',
        );
        final active = SessionHistoryRepository(
          directoryProvider: () async => root,
          activeSessionId: () => 'test',
        );
        final entry = await active.readEntry(session);
        await expectLater(active.deleteSession(entry), throwsStateError);
        final repository = SessionHistoryRepository(
          directoryProvider: () async => root,
        );
        final path = await repository.deleteSession(entry);
        expect(await session.exists(), false);
        expect(await File('$path/manifest.json').exists(), true);
        expect(
          (jsonDecode(
            await File('${root.path}/deleted_sessions.json').readAsString(),
          ) as Map).containsKey('test'),
          true,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
