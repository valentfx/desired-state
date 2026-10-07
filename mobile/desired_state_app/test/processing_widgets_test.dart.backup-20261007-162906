import 'dart:io';

import 'package:desired_state_app/history_plot.dart';
import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/polar_h10_service.dart';
import 'package:desired_state_app/processing.dart';
import 'package:desired_state_app/processing_screen.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_widgets_test.dart' show settleIo;
import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;
import 'session_history_test.dart' show historyFixture;

void main() {
  testWidgets(
    'phone settings stay keyboard-safe and inspection freezes bounds while recording continues',
    (tester) async {
      late Directory root;
      late SessionController controller;
      final polar = FakePolar();
      final start = DateTime.utc(2026, 9, 30);
      void emit(int i) => polar.data.add(
        PolarHeartRateData(
          heartRate: 60,
          rrIntervalsMs: [1000 + i.toDouble()],
          timestamp: start.add(Duration(seconds: i)),
        ),
      );
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('processing-ui-');
        controller = SessionController(
          service: polar,
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        await controller.quickMarkers.load();
        await controller.connect(BluetoothDevice.fromId('H10'));
        await controller.start(participantName: 'Fixture');
        for (var i = 0; i < 10; i++) {
          emit(i);
        }
      });
      addTearDown(() async {
        tester.view.resetViewInsets();
        await tester.runAsync(() async {
          await controller.stop();
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
      });
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: CollectorScreen(controller: controller)),
      );
      await tester.tap(find.byTooltip('Session settings'));
      await settleIo(
        tester,
        () => find.text('Processing & plots').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Processing & plots'));
      await settleIo(
        tester,
        () => find.textContaining('receipt-time window').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Processing settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<AnalysisMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Range only').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'RR'));
      await tester.ensureVisible(find.text('Advanced settings'));
      await tester.tap(find.text('Advanced settings'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '400');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.getRect(find.text('Apply & save')).bottom, lessThan(300));
      emit(10);
      expect(controller.analysisInputs.length, 11);
      await tester.runAsync(() => tester.tap(find.text('Apply & save')));
      tester.view.resetViewInsets();
      await settleIo(
        tester,
        () =>
            controller.processing.config.mode == AnalysisMode.range &&
            find.byType(ProcessingEditor).evaluate().isEmpty,
      );
      final sliderFinder = find.byType(RangeSlider);
      await tester.scrollUntilVisible(
        sliderFinder,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      tester.widget<RangeSlider>(sliderFinder).onChanged!(
        const RangeValues(2, 5),
      );
      await tester.pump();
      final rrFinder = find.byWidgetPredicate(
        (w) => w is HistoryPlot && w.title == 'RR',
      );
      await tester.scrollUntilVisible(
        rrFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final plot = tester.widget<HistoryPlot>(rrFinder);
      expect(plot.start, start.add(const Duration(seconds: 2)));
      expect(plot.end, start.add(const Duration(seconds: 5)));
      emit(11);
      await tester.pump();
      expect(tester.widget<HistoryPlot>(rrFinder).end, plot.end);
      expect(controller.recordingState, RecordingState.recording);
      await tester.scrollUntilVisible(
        find.text('Back to live / Fit data'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Back to live / Fit data'));
      await tester.pump();
      await tester.scrollUntilVisible(
        rrFinder,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<HistoryPlot>(rrFinder).end,
        start.add(const Duration(seconds: 11)),
      );
      await tester.runAsync(() async {
        final saved = ProcessingStore(directoryProvider: () async => root);
        await saved.load();
        expect(saved.config.minimum, 400);
        expect(saved.config.mode, AnalysisMode.range);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'saved session settings select metrics and record a replayable view without editing raw data',
    (tester) async {
      late Directory root;
      late SessionController controller;
      late SessionHistoryRepository repo;
      late HistorySession session;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('processing-history-ui-');
        final dir = await historyFixture(root);
        controller = SessionController(
          service: FakePolar(),
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        repo = SessionHistoryRepository(directoryProvider: () async => root);
        session = await repo.open(await repo.readEntry(dir));
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ProcessingScreen(
            controller: controller,
            session: session,
            repository: repo,
          ),
        ),
      );
      await settleIo(
        tester,
        () => find.textContaining('receipt-time window').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Processing settings'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('SDNN'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('SDNN'));
      await tester.runAsync(() => tester.tap(find.text('Apply & save')));
      await settleIo(
        tester,
        () =>
            controller.processing.config.metrics.contains('SDNN') &&
            find.byType(ProcessingEditor).evaluate().isEmpty,
      );
      await settleIo(
        tester,
        () => find.text('Settings applied').evaluate().isNotEmpty,
      );
      await tester.runAsync(() async {
        final journal = await rows(session.entry.directory, 'processing_views');
        expect(journal.last['configuration']['metrics'], contains('SDNN'));
        expect((await rows(session.entry.directory, 'rr')).length, 4);
      });
      await tester.scrollUntilVisible(
        find.text('SDNN (ms)'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('SDNN (ms)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
