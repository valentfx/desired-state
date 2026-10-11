import 'dart:io';

import 'package:desired_state_app/history_plot.dart';
import 'package:desired_state_app/plot_inspection.dart';
import 'package:desired_state_app/history_screen.dart';
import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;
import 'session_history_test.dart' show historyFixture, historyStart;

Future<void> settleIo(WidgetTester tester, bool Function() ready) async {
  // Real disk I/O must get wall-clock time; a loading spinner or live
  // timer must not be used as a global pumpAndSettle completion condition.
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 10)) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (ready()) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(ready(), isTrue, reason: 'Loaded/saved state must remain ready');
      return;
    }
  }
  fail('UI did not finish loading/saving within 10 seconds of real time');
}

void main() {
  testWidgets(
    'plot taps inspect original samples after display reduction and handle extreme raw values',
    (tester) async {
      final points = [
        for (var i = 0; i < 5000; i++)
          HistoryPoint(
            historyStart.add(Duration(seconds: i)),
            i.toDouble(),
            0,
            sourceIndex: i,
          ),
      ];
      HistoryPoint? inspected;
      Widget plot(List<HistoryPoint> data) => MaterialApp(
        home: Scaffold(
          body: HistoryPlot(
            title: 'RR',
            unit: 'ms',
            points: data,
            start: points.first.time,
            end: points.last.time,
            events: [points[100].time],
            color: Colors.deepPurple,
            onInspect: (point) => inspected = point,
          ),
        ),
      );
      await tester.pumpWidget(plot(points));
      final gesture = find.descendant(
        of: find.byType(HistoryPlot),
        matching: find.byType(InspectableSignalPlot),
      );
      final rect = tester.getRect(gesture);
      await tester.tapAt(
        Offset(
          rect.left + 54 + 2375 / 4999 * (rect.width - 62),
          rect.center.dy,
        ),
      );
      expect(inspected, same(points[2375]));
      await tester.pumpWidget(
        plot([
          HistoryPoint(points.first.time, -1e308, 0),
          HistoryPoint(points.last.time, 1e308, 0),
        ]),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'find saved events, compare raw/screened, inspect values and persist notes with keyboard',
    (tester) async {
      late Directory root;
      late SessionController controller;
      late SessionHistoryRepository repository;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('history-ui-');
        await historyFixture(root);
        controller = SessionController(
          service: FakePolar(),
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        await controller.quickMarkers.load();
        repository = SessionHistoryRepository(
          directoryProvider: () async => root,
        );
      });
      addTearDown(() async {
        tester.view.resetViewInsets();
        await tester.runAsync(() async {
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
      });
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: HistoryScreen(controller: controller, repository: repository),
        ),
      );
      await settleIo(
        tester,
        () => find.textContaining('Original intention').evaluate().isNotEmpty,
      );
      await tester.enterText(find.byType(TextField), 'no matching session');
      await tester.pump();
      expect(find.text('No saved sessions found.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Breathing');
      await tester.pump();
      await tester.tap(find.textContaining('Original intention'));
      await settleIo(
        tester,
        () => find.text('Edit notes & tags').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Events & notes'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Breathing').first);
      expect(find.byTooltip('Edit event note'), findsOneWidget);
      await tester.tap(find.text('Events & notes'));
      await tester.pumpAndSettle();
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Current screened'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Current screened'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current screened'));
      await tester.pump();
      final rrFinder = find.byWidgetPredicate(
        (w) => w is HistoryPlot && w.title == 'RR',
      );
      await tester.scrollUntilVisible(
        rrFinder,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final rrPlot = tester.widget<HistoryPlot>(rrFinder);
      expect(rrPlot.points.map((p) => p.value), [1000, 1010, null, 1020]);
      // Inspection uses the original point even when the current filter excludes it.
      rrPlot.onInspect(rrPlot.points[2]);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.textContaining('Raw RR 730'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Recorded flag: true'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Edit notes & tags'),
        -400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Edit notes & tags'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Description'),
        'Evening breathing',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'What helped / how I felt'),
        'Slow breathing helped',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Outcome tags'),
        'calmer, helped',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.getRect(find.text('Save')).bottom, lessThan(300));
      await tester.runAsync(() => tester.tap(find.text('Save')));
      await settleIo(
        tester,
        () => find.byType(HistoryMetadataEditor).evaluate().isEmpty,
      );
      tester.view.resetViewInsets();
      await tester.pump();
      await settleIo(tester, () => find.byType(ListView).evaluate().isNotEmpty);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pump();
      await settleIo(
        tester,
        () => find.text('Evening breathing').evaluate().isNotEmpty,
      );
      final reopened = (await tester.runAsync(() => repository.list()))!.single;
      expect(reopened.metadata.notes, 'Slow breathing helped');
      expect(reopened.metadata.tags, ['calmer', 'helped']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recording survives navigation into history and active session stays read-only',
    (tester) async {
      debugPrint('Active History: preparing recording');
      late Directory root;
      late SessionController controller;
      final polar = FakePolar();
      await tester.runAsync(() async {
        root = await Directory.systemTemp
            .createTemp('recording-history-ui-')
            .timeout(const Duration(seconds: 10));
        debugPrint('Active History: creating controller');
        controller = SessionController(
          service: polar,
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        debugPrint('Active History: loading markers');
        await controller.quickMarkers.load().timeout(
          const Duration(seconds: 10),
        );
        debugPrint('Active History: connecting fake H10');
        await controller
            .connect(BluetoothDevice.fromId('H10'))
            .timeout(const Duration(seconds: 10));
        debugPrint('Active History: starting named recording');
        await controller
            .start(
              participantName: 'Recording fixture',
              description: 'Active fixture',
            )
            .timeout(const Duration(seconds: 15));
        expect(controller.error, isNull);
        expect(controller.sessionLogger, isNotNull);
        debugPrint('Active History: flushing initial marker');
        polar.emit([1000, 1010]);
        // A flushed marker makes the active snapshot available to History.
        await controller
            .markQuickMarker(controller.quickMarkers.items.first)
            .timeout(const Duration(seconds: 10));
      });
      final logger = controller.sessionLogger!;
      addTearDown(() async {
        await tester.runAsync(() async {
          await controller.stop();
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
      });
      debugPrint('Active History: opening Live');
      await tester.pumpWidget(
        MaterialApp(home: CollectorScreen(controller: controller)),
      );
      await settleIo(
        tester,
        () => find.byTooltip('Recording settings').evaluate().isNotEmpty,
      );
      debugPrint('Active History: opening advanced tools');
      await tester.tap(find.byTooltip('Advanced tools'));
      await settleIo(
        tester,
        () => find.text('Recording tools').evaluate().isNotEmpty,
      );
      debugPrint('Active History: loading session list');
      await tester.ensureVisible(find.text('History'));
      await tester.pump();
      await tester.tap(find.text('History'));
      await settleIo(
        tester,
        () => find
            .text('Filter by participant, type and date')
            .evaluate()
            .isNotEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('Active fixture'),
        160,
        scrollable: find
            .descendant(
              of: find.byType(HistoryScreen),
              matching: find.byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      await tester.pump();
      debugPrint('Active History: opening active snapshot');
      polar.emit([1020]);
      await tester.tap(find.textContaining('Active fixture'));
      await settleIo(
        tester,
        () => find.text('Edit notes & tags').evaluate().isNotEmpty,
      );
      expect(find.textContaining('Recording continues'), findsNothing);
      expect(find.text('Assign/edit participant'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Edit notes & tags'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Re-export session'),
            )
            .onPressed,
        isNull,
      );
      debugPrint('Active History: returning to Live');
      polar.emit([1030]);
      for (var i = 0; i < 3; i++) {
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      await settleIo(
        tester,
        () => find.byTooltip('Stop recording').evaluate().isNotEmpty,
      );
      expect(find.byType(CollectorScreen), findsOneWidget);
      expect(controller.sessionLogger, same(logger));
      expect(controller.rrHistory.raw, [1000, 1010, 1020, 1030]);
      expect(controller.recordingState, RecordingState.recording);
      debugPrint('Active History: stopping and verifying four RR rows');
      await tester.runAsync(() async {
        await controller.stop();
        expect((await rows(logger.directory, 'rr')).length, 4);
      });
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
