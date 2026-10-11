import 'dart:io';

import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/session_timer_widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:desired_state_app/history_plot.dart';
import 'package:desired_state_app/plot_template.dart';
import 'package:desired_state_app/eeg_live_panel.dart';
import 'package:desired_state_app/plot_inspection.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:desired_state_app/session_history.dart';
import 'package:desired_state_app/session_preferences.dart';
import 'package:desired_state_app/preferences_screen.dart';
import 'package:desired_state_app/processing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_widgets_test.dart' show settleIo;
import 'session_controller_test.dart' show FakePolar, FakeForeground;

void main() {
  testWidgets(
    'new recording opens full setup without starting or losing saved recording',
    (tester) async {
      late Directory root;
      late SessionController c;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('recording-next-');
        c = SessionController(
          service: FakePolar(),
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        await c.connect(BluetoothDevice.fromId('H10'));
        await c.start(participantName: 'Test');
        await c.stop();
      });
      final saved = c.lastSessionLogger;
      addTearDown(
        () => tester.runAsync(() async {
          c.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: CollectorScreen(controller: c)),
      );
      await settleIo(
        tester,
        () => find.text('NEW RECORDING').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('NEW RECORDING'));
      await tester.pumpAndSettle();
      expect(find.text('Recording type optional'), findsOneWidget);
      expect(find.byType(SessionTimerSetup), findsOneWidget);
      expect(c.sessionLogger, isNull);
      expect(identical(c.lastSessionLogger, saved), isTrue);
    },
  );
  test('elapsed time remains session-relative over minutes and hours', () {
    expect(elapsedLabel(125), '02:05');
    expect(elapsedLabel(3725), '1:02:05');
    expect(inspectionKey('RMSSD'), 'HRV');
    expect(inspectionKey('EEG Gamma (µV²)'), 'Gamma');
  });
  test(
    'nearest values preserve gaps and do not extrapolate old measurements',
    () {
      final origin = DateTime.utc(2026);
      final points = [
        HistoryPoint(origin, 60, 0),
        HistoryPoint(origin.add(const Duration(seconds: 1)), null, 0),
      ];
      expect(nearestInspection(points, origin, 'bpm')!.text, '60.00 bpm');
      expect(
        nearestInspection(
          points,
          origin.add(const Duration(seconds: 1)),
          'bpm',
        ),
        isNull,
      );
      expect(
        nearestInspection(
          points,
          origin.add(const Duration(seconds: 60)),
          'bpm',
        ),
        isNull,
      );
    },
  );
  test('old settings migrate readout defaults and unknown future fields round trip', () {
    final old = SessionPreferences().toJson()..remove('hidden_inspection');
    expect(SessionPreferences.fromJson(old).hiddenInspection, {'ECG'});
    final next = SessionPreferences.fromJson(old)
        .copyWith(hiddenInspection: {'ECG', 'Gamma', 'Future temperature'});
    expect(
      SessionPreferences.fromJson(next.toJson()).hiddenInspection,
      next.hiddenInspection,
    );
    expect(
      () => SessionPreferences.fromJson({
        ...old,
        'hidden_inspection': [42],
      }),
      throwsFormatException,
    );
  });
  testWidgets('touch shows all scoped metrics in order, hides ECG and closes', (
    tester,
  ) async {
    final origin = DateTime.utc(2026);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlotInspectionScope(
            origin: origin,
            valuesAt: (time) => {
              'SpO2': InspectionValue(time, '98 %'),
              'Position': InspectionValue(time, 'Left side'),
              'Gamma': InspectionValue(time, '2 dB'),
              'ECG': InspectionValue(time, '100 µV'),
            },
            child: HistoryPlot(
              title: 'HR',
              unit: 'bpm',
              start: origin.add(const Duration(seconds: 120)),
              end: origin.add(const Duration(seconds: 130)),
              points: [
                HistoryPoint(origin.add(const Duration(seconds: 125)), 65, 0),
              ],
              events: const [],
              color: Colors.blue,
              onInspect: (_) {},
            ),
          ),
        ),
      ),
    );
    final plot = find.byType(InspectableSignalPlot);
    await tester.tapAt(tester.getRect(plot).center);
    await tester.pump();
    expect(find.byType(PlotReadout), findsOneWidget);
    expect(find.text('BPM: 65.00 bpm'), findsOneWidget);
    expect(find.text('SpO2: 98 %'), findsOneWidget);
    expect(find.text('Position: Left side'), findsOneWidget);
    expect(find.textContaining('ECG:'), findsNothing);
    await tester.tap(find.byTooltip('Close readout'));
    await tester.pump();
    expect(find.byType(PlotReadout), findsNothing);
    expect(tester.takeException(), isNull);
  });
  test('shared frame keeps the original H10 margins', () {
    expect(
      PlotTemplate.area(const Size(400, 220)),
      const Rect.fromLTWH(54, 16, 338, 178),
    );
    expect(PlotTemplate.area(const Size(400, 220), dualAxis: true).right, 346);
  });
  testWidgets(
    'shared cursor reaches ECG and later mounted plots; only one popup',
    (tester) async {
      final origin = DateTime.utc(2026);
      late StateSetter change;
      var showThird = false;
      Widget plot(String name) => SizedBox(
        height: 150,
        width: double.infinity,
        child: SignalPlot(
          painter: EegAxisPainter(
            {
              name: [(0, 60), (10, 70)],
            },
            timeOrigin: origin,
            left: 0,
            right: 10,
            minimum: 0,
            maximum: 100,
            yLabel: name == 'ECG' ? 'µV' : 'bpm',
            colors: {name: Colors.blue},
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlotInspectionScope(
              origin: origin,
              valuesAt: (time) => {'SpO2': InspectionValue(time, '98 %')},
              child: StatefulBuilder(
                builder: (context, setState) {
                  change = setState;
                  return Column(
                    children: [
                      plot('BPM'),
                      PlotInspectionScope(
                        origin: origin,
                        valuesAt: (_) => {},
                        child: plot('ECG'),
                      ),
                      if (showThird) plot('Alpha'),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tapAt(
        tester.getRect(find.byType(InspectableSignalPlot).first).center,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('plot-cursor')), findsNWidgets(2));
      expect(find.byType(PlotReadout), findsOneWidget);
      expect(find.text('SpO2: 98 %'), findsOneWidget);
      change(() => showThird = true);
      await tester.pump();
      expect(find.byKey(const ValueKey('plot-cursor')), findsNWidgets(3));
      await tester.tap(find.byTooltip('Close readout'));
      await tester.pump();
      expect(find.byKey(const ValueKey('plot-cursor')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'active saved snapshot shares only the marker, never live values',
    (tester) async {
      final origin = DateTime.utc(2026);
      PlotSelection? liveSelection, savedSelection;
      Map<String, InspectionValue?>? savedValues;
      await tester.pumpWidget(
        MaterialApp(
          home: PlotInspectionScope(
            origin: origin,
            valuesAt: (time) => {'SpO2': InspectionValue(time, '99 %')},
            child: Builder(
              builder: (context) {
                liveSelection = PlotInspectionScope.of(context)!.selection;
                return PlotInspectionScope(
                  origin: origin,
                  saved: true,
                  valuesAt: (time) => {
                    'Position': InspectionValue(time, 'On back'),
                  },
                  child: Builder(
                    builder: (context) {
                      final scope = PlotInspectionScope.of(context)!;
                      savedSelection = scope.selection;
                      savedValues = scope.values(origin);
                      return const SizedBox();
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(identical(liveSelection, savedSelection), isTrue);
      expect(savedValues!.containsKey('SpO2'), isFalse);
      expect(savedValues!['Position']!.text, 'On back');
    },
  );
  testWidgets(
    'single Session settings persists H10 metric and readout selection',
    (tester) async {
      late Directory root;
      late SessionController c;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('inspection-settings-');
        c = SessionController(
          service: FakePolar(),
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
      });
      addTearDown(
        () => tester.runAsync(() async {
          c.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => PreferencesScreen(controller: c),
                  ),
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await settleIo(
        tester,
        () => find.byType(ProcessingEditor).evaluate().isNotEmpty,
      );
      expect(find.text('Recording settings'), findsOneWidget);
      await tester.tap(find.text('Touch readout'));
      await tester.pumpAndSettle();
      final gamma = find.widgetWithText(SwitchListTile, 'Gamma');
      await tester.ensureVisible(gamma);
      await tester.pumpAndSettle();
      await tester.tap(gamma);
      await tester.ensureVisible(find.text('Touch readout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Touch readout'));
      await tester.pumpAndSettle();
      final sdnn = find.widgetWithText(FilterChip, 'SDNN');
      await tester.scrollUntilVisible(
        sdnn,
        180,
        scrollable: find
            .descendant(
              of: find.byType(ProcessingEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(sdnn);
      await tester.runAsync(() => tester.tap(find.text('Apply & save')));
      await settleIo(
        tester,
        () => find.byType(ProcessingEditor).evaluate().isEmpty,
      );
      expect(c.processing.config.metrics, contains('SDNN'));
      expect(c.preferences.hiddenInspection, containsAll(['ECG', 'Gamma']));
      final reloaded = await tester.runAsync(
        () => PreferencesStore(() async => root).load(),
      );
      expect(reloaded!.hiddenInspection, contains('Gamma'));
      expect(find.text('Open settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
