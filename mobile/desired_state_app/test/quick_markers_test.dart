import 'dart:convert';
import 'dart:io';

import 'package:desired_state_app/quick_markers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late QuickMarkerStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('quick-markers-test-');
    store = QuickMarkerStore(directoryProvider: () async => root);
  });
  tearDown(() async {
    store.dispose();
    await root.delete(recursive: true);
  });

  test(
    'add rename reorder remove and empty list persist across restart',
    () async {
      await store.load();
      expect(store.ready, isTrue);
      await Future.wait([store.add('Grounding'), store.add('Walk')]);
      final marker = store.items.firstWhere(
        (item) => item.label == 'Grounding',
      );
      await store.rename(marker.id, '  Slow   breathing  ');
      await store.move(marker.id, -100);
      await store.remove(store.items.last.id);
      final restarted = QuickMarkerStore(directoryProvider: () async => root);
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(
        restarted.items.map((item) => item.toJson()),
        store.items.map((item) => item.toJson()),
      );
      expect(restarted.items.first.id, marker.id);
      expect(restarted.items.first.label, 'Slow breathing');
      for (final item in List.of(restarted.items)) {
        await restarted.remove(item.id);
      }
      final empty = QuickMarkerStore(directoryProvider: () async => root);
      addTearDown(empty.dispose);
      await empty.load();
      expect(
        empty.items,
        isEmpty,
      ); // Deliberate removal must not reseed defaults.
    },
  );

  test(
    'validation errors do not poison later saves or alter previous settings',
    () async {
      await store.load();
      final before = store.items.map((item) => item.toJson()).toList();
      await expectLater(store.add('   '), throwsFormatException);
      await expectLater(store.add('anxious'), throwsFormatException);
      await expectLater(store.add('x' * 49), throwsFormatException);
      expect(store.items.map((item) => item.toJson()), before);
      await store.add('Recovery');
      expect(store.items.last.label, 'Recovery');
      expect(
        store.items.map((item) => item.id).toSet().length,
        store.items.length,
      );
    },
  );

  test(
    'malformed and future settings are preserved instead of reset',
    () async {
      final file = File(
        '${root.path}/desired_state_settings/quick_markers.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('{broken');
      await store.load();
      expect(store.ready, isFalse);
      expect(store.error, isNotNull);
      await expectLater(store.add('New'), throwsStateError);
      expect(await file.readAsString(), '{broken');
      final future = jsonEncode({'schema_version': 99, 'markers': []});
      await file.writeAsString(future);
      await store.retryLoad();
      expect(store.ready, isFalse);
      expect(await file.readAsString(), future);
      await file.writeAsString(
        jsonEncode({'schema_version': 1, 'markers': []}),
      );
      await store.retryLoad();
      expect(store.ready, isTrue);
      await store.add('Recovered');
      expect(store.items.single.label, 'Recovered');
    },
  );

  test('failed persistence does not publish an unsaved definition', () async {
    await store.load();
    final obstruction = Directory(
      '${root.path}/desired_state_settings/quick_markers.json.tmp',
    );
    await obstruction.create();
    await expectLater(
      store.add('Unsaved'),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.items.any((item) => item.label == 'Unsaved'), isFalse);
    await obstruction.delete();
    await store.add('Saved');
    expect(store.items.last.label, 'Saved');
  });
}
