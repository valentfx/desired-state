import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/participant_tools.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:desired_state_app/history_screen.dart';
import 'package:desired_state_app/session_controller.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground;
import 'history_widgets_test.dart' show settleIo;

HistoryEntry entry(String name, {String? id, HistoryMetadata? metadata}) =>
    HistoryEntry(
      Directory('/unused'),
      {
        'schema_version': 1,
        'session_id': 'session',
        'assignments': {'H10': name},
        'participant_id': ?id,
        'started_utc': '2026-10-03T12:00:00Z',
      },
      [],
      metadata ?? HistoryMetadata(description: '', notes: '', tags: []),
      [],
      [],
      true,
      0,
    );

class MemoryProfiles extends ParticipantStore {
  MemoryProfiles(this.values);
  final Map<String, ParticipantProfile> values;
  @override
  Future<Map<String, ParticipantProfile>> profiles() async => Map.of(values);
}

class MemoryHistory extends SessionHistoryRepository {
  MemoryHistory(this.entries);
  final List<HistoryEntry> entries;
  @override
  Future<List<HistoryEntry>> list() async => entries;
}

void main() {
  late Directory root;
  late ParticipantStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('participants-');
    store = ParticipantStore(directoryProvider: () async => root);
  });
  tearDown(() async => root.delete(recursive: true));
  test(
    'v1 migration and rename preserve permanent identity and journal',
    () async {
      final file = File('${root.path}/participants_v1.jsonl');
      final original =
          '${jsonEncode({'version': 1, 'name': 'Alex', 'info': 'Old'})}\n';
      await file.writeAsString(original);
      final profile = (await store.profiles()).values.single;
      final renamed = await store.save('Alex Updated', 'New', id: profile.id);
      expect(renamed.id, profile.id);
      final reopened = await ParticipantStore(
        directoryProvider: () async => root,
      ).profiles();
      expect(reopened.length, 1);
      expect(reopened[profile.id]!.name, 'Alex Updated');
      expect((await file.readAsString()).startsWith(original), isTrue);
      expect(
        HistoryFilter(participantId: renamed.id)
            .matches(entry('Alex', id: profile.id)),
        isTrue,
      );
    },
  );
  test(
    'same-name people have separate IDs and require explicit selection',
    () async {
      final a = await store.save('Alex', 'First');
      final b = await store.save('Alex', 'Second');
      expect(a.id, isNot(b.id));
      expect(await store.profiles(), hasLength(2));
      await expectLater(store.resolve('Alex', ''), throwsFormatException);
      expect((await store.resolve('Alex', '', id: b.id)).info, 'Second');
      expect(
        HistoryFilter(participantId: a.id).matches(entry('Alex', id: b.id)),
        isFalse,
      );
      expect(
        HistoryFilter(participantId: a.id).matches(entry('Alex')),
        isFalse,
      );
    },
  );
  test(
    'participant writes serialize across stores and recover after failure',
    () async {
      final other = ParticipantStore(directoryProvider: () async => root);
      final saved = await Future.wait([
        store.save('First', 'One'),
        other.save('Second', 'Two'),
      ]);
      final profiles = await other.profiles();
      expect(profiles.keys.toSet(), saved.map((p) => p.id).toSet());
      expect(profiles.values.map((p) => p.name), ['First', 'Second']);
      await expectLater(store.save('', ''), throwsFormatException);
      final third = await other.save('Third', 'Three');
      final reopened = await store.profiles();
      expect(reopened.length, 3);
      expect(reopened[third.id]!.name, 'Third');
      expect(reopened.values.map((p) => p.name), ['First', 'Second', 'Third']);
    },
  );
  test('corrupt participant journal is preserved and not appended', () async {
    final file = File('${root.path}/participants_v1.jsonl');
    await file.writeAsString('broken journal\n');
    await expectLater(store.save('Person', ''), throwsFormatException);
    expect(await file.readAsString(), 'broken journal\n');
  });
  test(
    'session reassignment and later note edits retain ID and original identity',
    () {
      final original = entry('Original', id: 'first');
      final corrected = participantMetadata(
        original.metadata,
        'Corrected',
        'Info',
        participantId: 'second',
      );
      final saved = HistoryMetadata.fromJson(corrected.toJson());
      final assigned = entry('Original', id: 'first', metadata: saved);
      expect(assigned.participantId, 'second');
      expect(assigned.originalParticipant, 'Original');
      expect(assigned.manifest['participant_id'], 'first');
      expect(HistoryFilter(participantId: 'second').matches(assigned), isTrue);
      expect(HistoryFilter(participantId: 'first').matches(assigned), isFalse);
    },
  );
  testWidgets(
    'participant directory provides edit and filtered-session shortcut',
    (tester) async {
      final p = (await tester.runAsync(
        () => store.save('Alex', 'Information'),
      ))!;
      ParticipantProfile? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipantsScreen(
            store: store,
            onViewSessions: (profile) => selected = profile,
          ),
        ),
      );
      await settleIo(tester, () => find.text('Alex').evaluate().isNotEmpty);
      expect(find.text('Alex'), findsOneWidget);
      await tester.tap(find.text('View sessions'));
      expect(selected?.id, p.id);
      await tester.tap(find.text('Alex'));
      await settleIo(tester, () {
        final save = find.widgetWithText(FilledButton, 'Save');
        return save.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(save).onPressed != null;
      });
      expect(
        find.widgetWithText(TextField, 'Participant name'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'Alex',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh participants'));
      await settleIo(tester, () => find.text('Alex').evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Alex'));
      await settleIo(tester, () {
        final save = find.widgetWithText(FilledButton, 'Save');
        return save.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(save).onPressed != null;
      });
      await tester.enterText(
        find.widgetWithText(TextField, 'Participant name'),
        'Alex Updated',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settleIo(
        tester,
        () =>
            find.text('Alex Updated').evaluate().isNotEmpty &&
            find.byType(AlertDialog).evaluate().isEmpty,
      );
      final profiles = (await tester.runAsync(() => store.profiles()))!;
      expect(profiles[p.id]!.name, 'Alex Updated');
      expect(profiles.length, 1);
      await tester.tap(find.text('View sessions'));
      expect(selected?.id, p.id);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Analyze filters permanent IDs and opens all or selected sessions',
    (tester) async {
      final controller = SessionController(
        service: FakePolar(),
        foregroundService: FakeForeground(),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: HistoryScreen(
              controller: controller,
              repository: MemoryHistory([
                entry('Old name', id: 'p-first'),
                entry('Other', id: 'p-second'),
              ]),
              participantStore: MemoryProfiles({
                'p-first': const ParticipantProfile('p-first', 'Renamed', ''),
                'p-second': const ParticipantProfile('p-second', 'Other', ''),
              }),
              analyze: true,
              initialParticipantId: 'p-first',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Renamed · All dates · 1 sessions'), findsOneWidget);
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('All participants').last);
        await tester.pumpAndSettle();
        expect(
          find.text('All participants · All dates · 2 sessions'),
          findsOneWidget,
        );
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Other · p-second').last);
        await tester.pumpAndSettle();
        expect(find.text('Other · All dates · 1 sessions'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );
}
