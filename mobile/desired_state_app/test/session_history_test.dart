import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:desired_state_app/history_plot.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:flutter_test/flutter_test.dart';

final historyStart = DateTime.utc(2026, 9, 30, 12);
String stamp(int seconds) =>
    historyStart.add(Duration(seconds: seconds)).toIso8601String();

Future<void> writeRows(Directory dir, String name, List<Object> rows) =>
    File('${dir.path}/$name.jsonl')
        .writeAsString('${rows.map(jsonEncode).join('\n')}\n');

Future<Directory> historyFixture(
  Directory root, {
  String id = 'saved',
  bool ended = true,
  List<Object>? rr,
  List<Object>? events,
}) async {
  final dir = await Directory('${root.path}/desired_state_sessions/$id')
      .create(recursive: true);
  await File('${dir.path}/manifest.json').writeAsString(
    jsonEncode({
      'schema_version': 1,
      'session_id': id,
      'started_utc': stamp(0),
      'description': 'Original intention',
      'assignments': {'H10': 'Fixture person'},
    }),
  );
  await writeRows(
    dir,
    'events',
    events ??
        [
          {'event': 'session_started', 'received_utc': stamp(0)},
          {
            'event': 'marked_event',
            'received_utc': stamp(2),
            'description': 'Breathing',
          },
          if (ended) {'event': 'session_ended', 'received_utc': stamp(5)},
        ],
  );
  await writeRows(
    dir,
    'rr',
    rr ??
        [
          for (final (i, value) in [1000, 1010, 730, 1020].indexed)
            {
              'rr_ms': value,
              'received_utc': stamp(i),
              'rr_index': 0,
              'artifact_accepted': true,
              'continuity_segment': 0,
            },
        ],
  );
  await writeRows(dir, 'measurements', [
    for (var i = 0; i < 4; i++)
      {'heart_rate_bpm': 60 + i, 'received_utc': stamp(i)},
  ]);
  return dir;
}

void main() {
  late Directory root;
  late SessionHistoryRepository repository;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('history-repository-');
    repository = SessionHistoryRepository(directoryProvider: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'empty history and extreme raw RR give no invented derived values',
    () async {
      expect(await repository.list(), isEmpty);
      final dir = await historyFixture(
        root,
        rr: [
          {'rr_ms': 1e308, 'received_utc': stamp(0)},
          {'rr_ms': 1000, 'received_utc': stamp(1)},
          {'rr_ms': 1010, 'received_utc': stamp(2)},
        ],
      );
      final session = await repository.open(await repository.readEntry(dir));
      expect(session.rr.first.value, 1e308);
      expect(session.rr.last.rawRmssd, isNull);
      expect(session.rr.last.screenedRmssd, isNull);
    },
  );

  test('reopens legacy sessions, compares current screening without changing raw flags', () async {
    final dir = await historyFixture(root);
    final original = await File('${dir.path}/rr.jsonl').readAsBytes();
    final entry = (await repository.list()).single;
    expect(entry.ended, isTrue);
    expect(entry.metadata.eventNotes['legacy-event-2'], 'Breathing');
    final session = await repository.open(entry);
    expect(session.warnings, isEmpty);
    expect(session.hr.map((p) => p.value), [60, 61, 62, 63]);
    expect(session.rrSeries(false).map((p) => p.value), [
      1000,
      1010,
      730,
      1020,
    ]);
    expect(session.rrSeries(true).map((p) => p.value), [
      1000,
      1010,
      null,
      1020,
    ]);
    expect(session.rr[2].row['artifact_accepted'], true);
    expect(session.rr.last.screenedRmssd, 10);
    expect(
      session.rr.last.rawRmssd,
      closeTo(sqrt((100 + 78400 + 84100) / 3), 1e-8),
    );
    expect(await File('${dir.path}/rr.jsonl').readAsBytes(), original);
  });

  test('segments, legacy pause events, stale and backwards times never create RR pairs', () async {
    for (final kind in ['segment', 'pause', 'stale', 'clock']) {
      final dir = await historyFixture(
        root,
        id: kind,
        rr: [
          {'rr_ms': 1000, 'received_utc': stamp(0)},
          {'rr_ms': 1010, 'received_utc': stamp(1)},
          {
            'rr_ms': 1100,
            'received_utc': stamp(
              kind == 'stale'
                  ? 20
                  : kind == 'clock'
                  ? -1
                  : 3,
            ),
            if (kind == 'segment') 'continuity_segment': 1,
          },
        ],
        events: [
          if (kind == 'pause')
            {'event': 'session_paused', 'received_utc': stamp(2)},
        ],
      );
      final session = await repository.open(await repository.readEntry(dir));
      expect(
        session.rr.last.segment,
        isNot(session.rr[1].segment),
        reason: kind,
      );
      expect(session.rr.last.rawRmssd, 10, reason: kind);
      expect(session.rr.last.screenedRmssd, 10, reason: kind);
      expect(session.rr.map((r) => r.value), [1000, 1010, 1100]);
    }
  });

  test(
    'incomplete, malformed, missing and future-version logs are explicit',
    () async {
      final dir = await historyFixture(root, ended: false);
      await File('${dir.path}/rr.jsonl').writeAsString(
        '${jsonEncode({'rr_ms': 1000, 'received_utc': stamp(0)})}\n{broken\n'
        '${jsonEncode({'rr_ms': 1020, 'received_utc': stamp(1)})}\n'
        '${jsonEncode({'rr_ms': 1030, 'received_utc': stamp(2)})}\n{"partial":',
      );
      await File('${dir.path}/measurements.jsonl').delete();
      final session = await repository.open((await repository.list()).single);
      expect(session.entry.ended, false);
      expect(session.rr.length, 3);
      expect(session.rr[0].segment, isNot(session.rr[1].segment));
      expect(session.rr.last.rawRmssd, 10);
      expect(session.warnings.any((w) => w.contains('unreadable row 2')), true);
      expect(session.warnings, contains('Missing measurements.jsonl'));
      final future = await historyFixture(root, id: 'future');
      await File('${future.path}/manifest.json')
          .writeAsString('{"schema_version":99,"session_id":"future"}');
      final entries = await repository.list();
      expect(entries, hasLength(2));
      final unsupported = entries.singleWhere((e) => e.id == 'future');
      expect(unsupported.readable, false);
      await expectLater(repository.open(unsupported), throwsFormatException);
    },
  );

  test('packet positions and order survive repeated timestamps and foreign rows break adjacency', () async {
    final dir = await historyFixture(
      root,
      rr: [
        for (var i = 0; i < 3; i++)
          {
            'rr_ms': 1000 + i * 10,
            'rr_index': i,
            'received_utc': stamp(0),
            if (i == 1) 'polar_id': 'OTHER',
          },
        {'rr_ms': 1030, 'rr_index': 0, 'received_utc': stamp(1)},
      ],
    );
    final session = await repository.open(await repository.readEntry(dir));
    expect(session.rr.map((r) => r.row['rr_index']), [0, 2, 0]);
    expect(session.rr.map((r) => r.value), [1000, 1020, 1030]);
    expect(session.rr.last.screenedRmssd, 10);
    expect(session.warnings.single, contains('identity'));
  });

  test('annotations persist, keep provenance, export originals and reject stale edits', () async {
    final dir = await historyFixture(root);
    final originals = {
      for (final name in [
        'manifest.json',
        'rr.jsonl',
        'events.jsonl',
        'measurements.jsonl',
      ])
        name: await File('${dir.path}/$name').readAsBytes(),
    };
    final entry = await repository.readEntry(dir);
    final values = HistoryMetadata(
      description: 'Updated intention',
      notes: 'Breathing helped',
      tags: ['calmer'],
      eventNotes: {'legacy-event-2': 'Slow breathing'},
    );
    final edited = await repository.saveMetadata(entry, values);
    expect(
      edited.revisions.single['previous']['description'],
      'Original intention',
    );
    expect(edited.revisions.single['edited_utc'], isNotEmpty);
    await expectLater(repository.saveMetadata(entry, values), throwsStateError);
    final reopened = await SessionHistoryRepository(
      directoryProvider: () async => root,
    ).readEntry(dir);
    expect(reopened.metadata.toJson(), values.toJson());
    final archive = ZipDecoder().decodeBytes(
      await (await repository.export(reopened)).readAsBytes(),
    );
    expect(archive.findFile('saved/history_edits.jsonl'), isNotNull);
    for (final name in originals.keys) {
      expect(await File('${dir.path}/$name').readAsBytes(), originals[name]);
      expect(archive.findFile('saved/$name')!.content, originals[name]);
    }
    final cleared = await repository.saveMetadata(
      reopened,
      HistoryMetadata(description: '', notes: '', tags: [], eventNotes: {}),
    );
    expect(cleared.revisions.length, 2);
    expect(cleared.metadata.notes, isEmpty);
  });

  test('later Live event notes remain visible after history edit; stale editor must reload', () async {
    final dir = await historyFixture(root);
    await writeRows(dir, 'marker_notes', [
      {'event_id': 'legacy-event-2', 'description': 'First note'},
    ]);
    var entry = await repository.readEntry(dir);
    entry = await repository.saveMetadata(
      entry,
      HistoryMetadata(
        description: 'Edited',
        notes: '',
        tags: [],
        eventNotes: {'legacy-event-2': 'Corrected note'},
      ),
    );
    await File('${dir.path}/marker_notes.jsonl').writeAsString(
      '${jsonEncode({'event_id': 'legacy-event-2', 'description': 'Later note'})}\n',
      mode: FileMode.append,
    );
    await expectLater(
      repository.saveMetadata(entry, entry.metadata),
      throwsStateError,
    );
    entry = await repository.readEntry(dir);
    expect(
      entry.metadata.eventNotes['legacy-event-2'],
      'Corrected note\nLater note',
    );
    entry = await repository.saveMetadata(entry, entry.metadata);
    expect(
      entry.metadata.eventNotes['legacy-event-2'],
      'Corrected note\nLater note',
    );
    final archive = ZipDecoder().decodeBytes(
      await (await repository.export(entry)).readAsBytes(),
    );
    expect(archive.findFile('saved/marker_notes.jsonl'), isNotNull);
  });

  test(
    'active sessions and damaged edit journals cannot be edited/exported',
    () async {
      final dir = await historyFixture(root);
      var active = 'saved';
      repository = SessionHistoryRepository(
        directoryProvider: () async => root,
        activeSessionId: () => active,
      );
      final entry = await repository.readEntry(dir);
      await expectLater(
        repository.saveMetadata(entry, entry.metadata),
        throwsStateError,
      );
      await expectLater(repository.export(entry), throwsStateError);
      active = '';
      await File('${dir.path}/history_edits.jsonl')
          .writeAsString('{"partial":');
      final damaged = await repository.readEntry(dir);
      expect(damaged.editsReadable, false);
      expect((await repository.open(damaged)).rr, hasLength(4));
      await expectLater(
        repository.saveMetadata(damaged, damaged.metadata),
        throwsStateError,
      );
    },
  );

  test(
    'display reduction preserves peaks, gaps and original source indices',
    () {
      final points = [
        for (var i = 0; i < 5000; i++)
          HistoryPoint(
            historyStart.add(Duration(seconds: i)),
            i == 127
                ? 9000
                : i == 244
                ? null
                : 1000,
            i < 1234 ? 0 : 1,
            sourceIndex: i,
          ),
      ];
      final reduced = reduceHistoryPoints(points);
      expect(reduced.length, lessThan(1000));
      expect(
        reduced,
        containsAll([
          points[127],
          points[243],
          points[244],
          points[245],
          points[1233],
          points[1234],
        ]),
      );
      expect(reduced.first, points.first);
      expect(reduced.last, points.last);
      expect(points.length, 5000);
    },
  );
}
