import 'dart:convert';

import 'package:desired_state_app/device_screen.dart';
import 'package:desired_state_app/device_detail_screen.dart';

import 'dart:io';

import 'package:desired_state_app/history_plot.dart';
import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/processing.dart';
import 'package:desired_state_app/processing_presets.dart';
import 'package:desired_state_app/processing_screen.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_widgets_test.dart' show settleIo;
import 'session_controller_test.dart' show FakePolar, FakeForeground, rows;

import 'navigation_test_helpers.dart' show openScreen;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'portable presets round-trip and preserve corrupt libraries and built-ins',
    () async {
      final root = await Directory.systemTemp.createTemp('preset-contract-');
      addTearDown(() => root.delete(recursive: true));
      final store = ProcessingPresets(directoryProvider: () async => root);
      final defaults = await loadDefaultProcessing();
      expect(defaults.metrics, ['HR', 'RMSSD']);
      expect(defaults.mode, AnalysisMode.screened);
      final custom = ProcessingPreset('My settings', defaults);
      expect(
        ProcessingPreset.decode(custom.encode()).config.toJson(),
        defaults.toJson(),
      );
      await store.save(custom);
      final reloaded = await ProcessingPresets(
        directoryProvider: () async => root,
      ).load();
      expect(reloaded.single.name, custom.name);
      expect(reloaded.single.config.toJson(), defaults.toJson());
      await expectLater(store.save(custom), throwsFormatException);
      await expectLater(
        store.save(ProcessingPreset('Default', defaults)),
        throwsFormatException,
      );
      final future = jsonDecode(custom.encode()) as Map<String, dynamic>;
      future['preset_schema_version'] = 99;
      expect(
        () => ProcessingPreset.decode(jsonEncode(future)),
        throwsFormatException,
      );
      future['preset_schema_version'] = 1;
      future['configuration']['minimum_ms'] = -1;
      expect(
        () => ProcessingPreset.decode(jsonEncode(future)),
        throwsFormatException,
      );
      final file = File('${root.path}/desired_state_settings/presets.json');
      await file.writeAsString('{broken');
      await expectLater(
        store.save(ProcessingPreset('Another', defaults)),
        throwsFormatException,
      );
      expect(await file.readAsString(), '{broken');
    },
  );

  testWidgets(
    'presets stage before apply, save and reopen with advanced values intact',
    (tester) async {
      late Directory root;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('preset-ui-');
      });
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      final store = ProcessingPresets(directoryProvider: () async => root);
      ProcessingConfig? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.push<ProcessingConfig>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ProcessingEditor(
                        config: const ProcessingConfig(),
                        presets: store,
                      ),
                    ),
                  );
                },
                child: const Text('Settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Presets'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Open preset')));
      await settleIo(tester, () => find.text('Default').evaluate().isNotEmpty);
      await tester.runAsync(() => tester.tap(find.text('Default')));
      await settleIo(
        tester,
        () =>
            tester
                .widget<DropdownButton<AnalysisMode>>(
                  find.byType(DropdownButton<AnalysisMode>),
                )
                .value ==
            AnalysisMode.screened,
      );
      expect(result, isNull);
      expect(
        tester
            .widget<DropdownButton<AnalysisMode>>(
              find.byType(DropdownButton<AnalysisMode>),
            )
            .value,
        AnalysisMode.screened,
      );
      await tester.tap(find.text('Save preset'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Trial');
      await tester.runAsync(() => tester.tap(find.text('Done')));
      await settleIo(
        tester,
        () =>
            find.byType(TextField).evaluate().isEmpty &&
            find.text('Trial').evaluate().isNotEmpty,
      );
      final saved = (await tester.runAsync(store.load))!;
      expect(saved.single.config.reference, 9);
      await tester.runAsync(() => tester.tap(find.text('Open preset')));
      await settleIo(
        tester,
        () => find.text('Unfiltered').evaluate().isNotEmpty,
      );
      await tester.runAsync(() => tester.tap(find.text('Trial').last));
      await settleIo(tester, () => find.byType(BottomSheet).evaluate().isEmpty);
      await tester.tap(find.text('Apply & save'));
      await tester.pumpAndSettle();
      expect(result!.mode, AnalysisMode.screened);
      expect(result!.metrics, ['HR', 'RMSSD']);
      expect(result!.reference, 9);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone Live fits one screen, overlays freeze, device reconnect keeps session and gaps',
    (tester) async {
      late Directory root;
      late SessionController controller;
      final polar = FakePolar();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('compact-live-');
        controller = SessionController(
          service: polar,
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        await controller.quickMarkers.load();
        await controller.connect(BluetoothDevice.fromId('H10'));
        await controller.start(participantName: 'Layout fixture');
        polar.emit([1000, 1010, 1020]);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await controller.stop();
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
        await tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(360, 640));
      await tester.pumpWidget(
        MaterialApp(home: SessionHome(controller: controller)),
      );
      await openScreen(tester, 'Session');
      await settleIo(
        tester,
        () => find.byType(RelativeOverlayPlot).evaluate().isNotEmpty,
      );
      final logger = controller.sessionLogger!;
      expect(find.byType(RelativeOverlayPlot), findsOneWidget);
      expect(find.byType(HistoryPlot), findsNothing);
      final plot = tester.widget<RelativeOverlayPlot>(
        find.byType(RelativeOverlayPlot),
      );
      expect(plot.series.keys, ['HR', 'RMSSD']);
      final verticalScrolls = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      );
      expect(verticalScrolls, findsWidgets);
      // Test the scaled summary's layout box, rather than the unscaled
      // RenderParagraph centre used by a Text hit-test finder.
      final rmssdSummary = find.ancestor(
        of: find.textContaining('RMSSD 10.0'),
        matching: find.byType(FittedBox),
      );
      expect(rmssdSummary, findsOneWidget);
      await tester.ensureVisible(rmssdSummary);
      await tester.pump();
      expect(find.byTooltip('Stop recording').hitTestable(), findsOneWidget);
      expect(find.textContaining('RMSSD 10.0'), findsOneWidget);
      expect(rmssdSummary.hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.byType(RelativeOverlayPlot));
      await tester.pump();
      expect(find.byType(RelativeOverlayPlot).hitTestable(), findsOneWidget);
      await tester.tap(find.byType(RelativeOverlayPlot));
      await tester.pump();
      final frozen = tester
          .widget<RelativeOverlayPlot>(find.byType(RelativeOverlayPlot))
          .end;
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        polar.emit([1030]);
      });
      await tester.pump();
      expect(
        tester
            .widget<RelativeOverlayPlot>(find.byType(RelativeOverlayPlot))
            .end,
        frozen,
      );
      await tester.ensureVisible(find.byTooltip('Back to live'));
      // Apply the scroll layout before locating the tap point. Without this
      // frame the stale centre can lie underneath the app bar.
      await tester.pump();
      expect(find.byTooltip('Back to live').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Back to live'));
      await tester.pump();
      expect(
        tester
            .widget<RelativeOverlayPlot>(find.byType(RelativeOverlayPlot))
            .end
            .isAfter(frozen),
        isTrue,
      );
      await tester.tap(find.byTooltip('Device connection'));
      await settleIo(
        tester,
        () => find
            .widgetWithText(AppBar, 'Devices')
            .hitTestable()
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.text('Polar H10'));
      await settleIo(
        tester,
        () => find.text('Reconnect H10').evaluate().isNotEmpty,
      );
      expect(find.text('Scan for Polar H10'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Reconnect H10'),
        180,
        scrollable: find
            .descendant(
              of: find.byType(DeviceDetailScreen),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      await tester.pump();
      expect(find.text('Reconnect H10').hitTestable(), findsOneWidget);
      final connectsBefore = polar.connects;
      await tester.runAsync(() => tester.tap(find.text('Reconnect H10')));
      // Recovery intentionally requires a measurement, not just a BLE link.
      // Wait for the new fake link, then supply the recovery packet.
      await settleIo(
        tester,
        () => polar.connects > connectsBefore && controller.recovering,
      );
      expect(controller.connected, isFalse);
      expect(controller.sessionLogger, same(logger));
      await tester.runAsync(() async {
        polar.emit([1040, 1050]);
      });
      await settleIo(
        tester,
        () =>
            controller.connected && !controller.recovering && !controller.busy,
      );
      expect(controller.sessionLogger, same(logger));
      expect(
        controller.analysisInputs.last.segment,
        isNot(controller.analysisInputs.first.segment),
      );
      // Pop one completed route at a time. During animation both routes
      // contain Back tooltips, so pageBack would be ambiguous.
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byType(BackButton).hitTestable());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byType(BackButton).hitTestable());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // Live may schedule frames continuously, and settings load from disk.
      // Wait for this route's usable state while allowing real I/O to run.
      await settleIo(
        tester,
        () =>
            find.byType(DeviceScreen).evaluate().isEmpty &&
            find.byType(RelativeOverlayPlot).evaluate().isNotEmpty &&
            find
                .byTooltip('Stop recording')
                .hitTestable()
                .evaluate()
                .isNotEmpty,
      );
      expect(find.byTooltip('Stop recording').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await controller.stop();
        expect((await rows(logger.directory, 'rr')).length, 6);
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}
