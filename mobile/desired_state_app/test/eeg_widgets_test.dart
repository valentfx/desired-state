import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/eeg_bands.dart';
import 'package:desired_state_app/eeg_live_panel.dart';
import 'package:desired_state_app/muse_athena_service.dart';
import 'package:desired_state_app/session_controller.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground;

void main() {
  testWidgets('EEG screen toggle and comparison repaint the same raw windows', (
    tester,
  ) async {
    final clean = List<double>.generate(
      1024,
      (i) => 10 * math.sin(2 * math.pi * 10 * i / 256),
    );
    final artifact = [...clean]..[500] = 600;
    final origin = DateTime(2026);
    final frames = [
      buildEegFrame(origin, {'1': artifact}, 256),
      buildEegFrame(origin.add(const Duration(seconds: 1)), {'1': clean}, 256),
    ];
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              EegComparisonPlot(
                frames: frames,
                origin: origin,
                left: 0,
                right: 60,
              ),
            ],
          ),
        ),
      ),
    );
    final plots = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is EegAxisPainter,
    );
    EegAxisPainter painter() =>
        tester.widget<CustomPaint>(plots).painter! as EegAxisPainter;
    expect(painter().series['Alpha']!.first.$2.isFinite, isTrue);
    await tester.tap(find.text('EEG amplitude/step/flatline screen'));
    await tester.pump();
    expect(painter().series['Alpha']!.first.$2.isNaN, isTrue);
    expect(painter().series['Alpha']!.last.$2.isFinite, isTrue);
    await tester.tap(find.text('Overlay comparison'));
    await tester.pump();
    expect(painter().series['Alpha · unscreened']!.first.$2.isFinite, isTrue);
    expect(painter().series['Alpha · screened']!.first.$2.isNaN, isTrue);
    expect(painter().dashedSeries, contains('Alpha · screened'));
    expect(artifact[500], 600);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'EEG bands share one physical axis and expanded phone panel scrolls',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('eeg-widget-'),
      ))!;
      final muse = MuseAthenaService();
      muse.streaming = true;
      muse.lastSamplesAt = DateTime.now();
      muse.eegRate = 256;
      muse.eegHistory['0'] = [1, -1, 2, -2];
      muse.bandHistory.add(
        EegBandFrame(DateTime.now(), {
          '0': {'Delta': 3, 'Theta': 20, 'Alpha': 50, 'Beta': 10},
        }, 1),
      );
      final controller = SessionController(
        service: FakePolar(),
        museService: muse,
        foregroundService: FakeForeground(),
        directoryProvider: () async => root,
      );
      try {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(children: [EegLivePanel(controller: controller)]),
            ),
          ),
        );
        await tester.tap(find.text('EEG band activity'));
        await tester.pumpAndSettle();
        final plots = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is EegAxisPainter,
        );
        expect(plots, findsOneWidget);
        final painter =
            tester.widget<CustomPaint>(plots).painter! as EegAxisPainter;
        expect(painter.minimum, lessThan(10));
        expect(painter.yLabel, 'EEG dB re 1 µV²');
        expect(painter.series.keys.toSet(), {
          'Delta',
          'Theta',
          'Alpha',
          'Beta',
          'Gamma',
        });
        expect(painter.maximum, greaterThan(16));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('%'));
        await tester.tap(find.text('%'));
        await tester.pumpAndSettle();
        final relative =
            tester.widget<CustomPaint>(plots).painter! as EegAxisPainter;
        expect(relative.maximum, 100);
        expect(relative.yLabel, 'EEG (%)');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
