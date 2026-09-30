import 'dart:io';

import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/quick_marker_widgets.dart';
import 'package:desired_state_app/quick_markers.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_controller_test.dart' show FakePolar, FakeForeground, until;

void main() {
  testWidgets(
    'manage labels with top Save and persist add rename reorder remove',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('marker-ui-test-'),
      ))!;
      final store = (await tester.runAsync(() async {
        final result = QuickMarkerStore(directoryProvider: () async => root);
        await result.load();
        return result;
      }))!;
      addTearDown(() async {
        store.dispose();
        await root.delete(recursive: true);
      });
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: QuickMarkerManager(store: store)),
      );
      await tester.tap(find.byTooltip('Add quick marker'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Grounding');
      // Simulate a phone keyboard: the Save action must stay visible above it.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.getRect(find.text('Save')).bottom, lessThan(300));
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await until(() => store.items.any((item) => item.label == 'Grounding'));
      });
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text('Grounding'), findsOneWidget);
      await tester.tap(find.byTooltip('Edit Grounding'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Walking');
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await until(() => store.items.last.label == 'Walking');
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Move Walking up'));
        await until(
          () => store.items[store.items.length - 2].label == 'Walking',
        );
      });
      await tester.pump();
      await tester.tap(find.byTooltip('Edit Walking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      for (
        var i = 0;
        i < 100 && store.items.any((item) => item.label == 'Walking');
        i++
      ) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('Walking'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('one-tap markers and optional notes keep recording active', (
    tester,
  ) async {
    late Directory root;
    late SessionController controller;
    final polar = FakePolar();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('marker-record-ui-');
      controller = SessionController(
        service: polar,
        foregroundService: FakeForeground(),
        directoryProvider: () async => root,
      );
      await controller.quickMarkers.load();
      await controller.connect(BluetoothDevice.fromId('test-device'));
      await controller.start(participantName: 'Test participant');
    });
    addTearDown(() async {
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
    await tester.runAsync(() async {
      await tester.tap(find.text('Anxious'));
      await tester.tap(find.text('Anxious'));
      await until(() => controller.recordedMarkers.length == 2);
    });
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Events (2)'), findsOneWidget);
    final viewport = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewport.boundaryMargin, EdgeInsets.zero);
    expect(viewport.panAxis, PanAxis.horizontal);
    await tester.tap(find.text('Events (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add note to Anxious').first);
    await tester.pumpAndSettle();
    polar.emit([1000, 1010, 1020]);
    expect(controller.rrHistory.rawCount, 3);
    await tester.enterText(find.byType(TextField), 'Slow breathing helped');
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await until(() => controller.markerNotes.isNotEmpty);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Slow breathing helped'), findsOneWidget);
    expect(controller.recordingState, RecordingState.recording);
    await tester.pumpWidget(const SizedBox());
  });
}
