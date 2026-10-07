import 'dart:convert';
import 'dart:io';

import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/history_screen.dart';
import 'package:desired_state_app/processing.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_widgets_test.dart' show settleIo;
import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;
import 'session_history_test.dart' show historyFixture;

import 'navigation_test_helpers.dart' show openScreen;

void main() {
  test(
    'metric summaries omit missing/nonfinite samples and retain real zeroes',
    () {
      final stats = MetricSummary([
        0,
        10,
        20,
        null,
        double.nan,
        double.infinity,
      ]);
      expect(stats.count, 3);
      expect(stats.minimum, 0);
      expect(stats.maximum, 20);
      expect(stats.average, 10);
      expect(MetricSummary([null, double.nan]).average, isNull);
      expect(MetricSummary([-1e308, 1e308]).average, 0);
    },
  );

  test('History filters combine saved user, session/device ID and inclusive local dates', () async {
    final root = await Directory.systemTemp.createTemp('home-filter-');
    addTearDown(() => root.delete(recursive: true));
    final dir = await historyFixture(root, id: 'Session-ABC');
    final repo = SessionHistoryRepository(directoryProvider: () async => root);
    var entry = await repo.readEntry(dir);
    final day = entry.started!.toLocal();
    final filter = HistoryFilter(
      user: 'Fixture person',
      identifier: ' abc ',
      from: day,
      to: day,
    );
    expect(filter.matches(entry), true);
    expect(const HistoryFilter(identifier: 'h10').matches(entry), true);
    expect(const HistoryFilter(user: 'Other person').matches(entry), false);
    expect(
      HistoryFilter(from: day.add(const Duration(days: 1))).matches(entry),
      false,
    );
    final manifest = File('${dir.path}/manifest.json');
    final data =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    data['started_utc'] = DateTime(
      day.year,
      day.month,
      day.day,
      23,
      59,
      59,
    ).toUtc().toIso8601String();
    await manifest.writeAsString(jsonEncode(data));
    entry = await repo.readEntry(dir);
    expect(filter.matches(entry), true);
    data['started_utc'] = 'unknown';
    await manifest.writeAsString(jsonEncode(data));
    entry = await repo.readEntry(dir);
    expect(filter.matches(entry), false);
    expect(const HistoryFilter(identifier: 'ABC').matches(entry), true);
  });

  testWidgets(
    'Overview first, direct Start, editable Live notes and navigation retain recording',
    (tester) async {
      late Directory root;
      late SessionController controller;
      final polar = FakePolar();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('home-live-');
        await historyFixture(root);
        controller = SessionController(
          service: polar,
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        await controller.quickMarkers.load();
        await controller.connect(BluetoothDevice.fromId('H10'));
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await controller.stop();
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
      });
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: SessionHome(controller: controller)),
      );
      expect(find.text('Overview'), findsOneWidget);
      await openScreen(tester, 'Analyze');
      await settleIo(
        tester,
        () => find.textContaining('Original intention').evaluate().isNotEmpty,
      );
      expect(find.text('Analyze'), findsOneWidget);
      expect(controller.sessionLogger, isNull);
      await openScreen(tester, 'Session');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Participant name'),
        'Live tester',
      );
      // The connect list builds children lazily; scroll to construct Start.
      await tester.scrollUntilVisible(
        find.text('START RECORDING'),
        180,
        scrollable: find
            .descendant(
              of: find.byType(CollectorScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pump();
      expect(find.text('START RECORDING').hitTestable(), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.text('START RECORDING')));
      await settleIo(
        tester,
        () =>
            controller.sessionLogger != null &&
            find.byTooltip('Session notes').evaluate().isNotEmpty,
      );
      final logger = controller.sessionLogger!;
      expect(find.byType(BottomSheet), findsNothing);
      await settleIo(
        tester,
        () => find.byTooltip('Session settings').evaluate().isNotEmpty,
      );
      expect(find.byTooltip('Session settings'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.byTooltip('Session notes')));
      await settleIo(
        tester,
        () => find.byType(HistoryMetadataEditor).evaluate().isNotEmpty,
      );
      polar.emit([1000, 1010, 1020]);
      await tester.enterText(
        find.widgetWithText(TextField, 'Description'),
        'Edited intention',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'What helped / how I felt'),
        'Breathing helped',
      );
      await tester.runAsync(() => tester.tap(find.text('Save')));
      await settleIo(
        tester,
        () => find.byType(HistoryMetadataEditor).evaluate().isEmpty,
      );
      final repo = (await tester.runAsync(
        () async =>
            SessionHistoryRepository(directoryProvider: () async => root),
      ))!;
      final entry = (await tester.runAsync(
        () => repo.readEntry(logger.directory),
      ))!;
      expect(entry.metadata.description, 'Edited intention');
      expect(entry.metadata.notes, 'Breathing helped');
      expect(controller.sessionLogger, same(logger));
      expect(controller.rrHistory.rawCount, 3);
      final manifest = (await tester.runAsync(
        () => File('${logger.directory.path}/manifest.json').readAsString(),
      ))!;
      expect(jsonDecode(manifest)['description'], '');
      expect(
        find.textContaining('BPM 60.0 bpm | min 60.0 avg 60.0 max 60.0'),
        findsOneWidget,
      );
      expect(
        find.textContaining('RMSSD 10.0 ms | min 10.0 avg 10.0 max 10.0'),
        findsOneWidget,
      );
      await openScreen(tester, 'Analyze');
      await settleIo(
        tester,
        () => find.textContaining('Edited intention').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.textContaining('Edited intention'));
      await tester.pump();
      await tester.tap(find.textContaining('Edited intention').hitTestable());
      await settleIo(
        tester,
        () => find.text('Edit notes & tags').evaluate().isNotEmpty,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(RecordingHistoryBanner),
          matching: find.text('Session'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Stop recording'), findsOneWidget);
      expect(controller.sessionLogger, same(logger));
      await tester.runAsync(() => tester.tap(find.byTooltip('Stop recording')));
      await settleIo(
        tester,
        () => find.text('Session saved').evaluate().isNotEmpty,
      );
      expect(find.byType(BottomSheet), findsNothing);
      await tester.runAsync(() async {
        expect((await rows(logger.directory, 'rr')).length, 3);
        expect(
          (await repo.readEntry(logger.directory)).metadata.notes,
          'Breathing helped',
        );
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'History user/ID controls combine and clear; date control opens',
    (tester) async {
      late Directory root;
      late SessionController controller;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('history-filter-ui-');
        await historyFixture(root, id: 'alpha');
        final other = await historyFixture(root, id: 'beta');
        final file = File('${other.path}/manifest.json');
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        json['assignments'] = {'OTHER': 'Another person'};
        await file.writeAsString(jsonEncode(json));
        controller = SessionController(
          service: FakePolar(),
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        MaterialApp(home: HistoryScreen(controller: controller)),
      );
      await settleIo(
        tester,
        () => find.textContaining('2 sessions').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Filter by participant, type and date'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Legacy / unassigned ID: Fixture person').last,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Original intention'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Session or device ID'),
        'beta',
      );
      await tester.pump();
      expect(find.text('No saved sessions found.'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 sessions'), findsOneWidget);
      await tester.tap(find.text('Date range'));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
