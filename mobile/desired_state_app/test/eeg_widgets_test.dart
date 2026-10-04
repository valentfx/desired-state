import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/eeg_bands.dart';
import 'package:desired_state_app/eeg_live_panel.dart';
import 'package:desired_state_app/muse_athena_service.dart';
import 'package:desired_state_app/session_controller.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground;

void main() {
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
        expect(painter.minimum, 0);
        expect(painter.yLabel, 'Band power (µV²)');
        expect(painter.series.keys.toSet(), {'Alpha', 'Theta', 'Beta'});
        expect(painter.maximum, greaterThan(50));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Relative power'));
        await tester.tap(find.text('Relative power'));
        await tester.pumpAndSettle();
        final relative =
            tester.widget<CustomPaint>(plots).painter! as EegAxisPainter;
        expect(relative.maximum, 100);
        expect(relative.yLabel, 'Band power (%)');
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
