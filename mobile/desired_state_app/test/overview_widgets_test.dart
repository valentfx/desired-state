import 'dart:convert';
import 'dart:io';

import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/overview_scope.dart';
import 'package:desired_state_app/overview_screen.dart';
import 'package:desired_state_app/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_widgets_test.dart' show settleIo;
import 'session_controller_test.dart' show FakePolar, FakeForeground;
import 'session_history_test.dart' show historyFixture;

import 'navigation_test_helpers.dart' show openScreen;

void main() {
  test('personal scope excludes mixed, unassigned and malformed ownership', () {
    expect(
      overviewParticipant({
        'assignments': {'h10': 'Me', 'ring': 'Me'},
      }),
      'Me',
    );
    for (final assignments in [
      null,
      {},
      {'h10': 'unassigned'},
      {'h10': ' UNASSIGNED '},
      {'h10': ''},
      {'h10': null},
      {'h10': 12},
      {'h10': 'Me', 'ring': 'Someone else'},
    ]) {
      expect(overviewParticipant({'assignments': assignments}), isNull);
    }
  });

  testWidgets(
    'overview selection persists and isolates personal sessions without changing recordings',
    (tester) async {
      late Directory root;
      late SessionController controller;
      final originals = <File, String>{};
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('overview-ui-');
        for (final (id, assignments, description) in [
          (
            'mine',
            {'H10': 'Fixture person', 'Ring': 'Fixture person'},
            'My session',
          ),
          ('other', {'H10': 'Other person'}, 'Other session'),
          (
            'mixed',
            {'H10': 'Fixture person', 'Ring': 'Other person'},
            'Mixed session',
          ),
          ('unassigned', {'H10': 'unassigned'}, 'Unassigned session'),
        ]) {
          final dir = await historyFixture(root, id: id);
          final file = File('${dir.path}/manifest.json');
          final manifest =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          manifest['assignments'] = assignments;
          manifest['description'] = description;
          await file.writeAsString(jsonEncode(manifest));
          originals[file] = await file.readAsString();
        }
        controller = SessionController(
          service: FakePolar(),
          foregroundService: FakeForeground(),
          directoryProvider: () async => root,
        );
        await controller.quickMarkers.load();
      });
      addTearDown(
        () => tester.runAsync(() async {
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        }),
      );
      await tester.binding.setSurfaceSize(const Size(390, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Widget screen() => MaterialApp(
        home: OverviewScreen(
          controller: controller,
          onLive: () {},
          onAnalyze: () {},
        ),
      );
      await tester.pumpWidget(screen());
      await settleIo(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      expect(find.text('My session'), findsNothing);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Fixture person').last));
      await settleIo(
        tester,
        () => find.text('My session').evaluate().isNotEmpty,
      );
      expect(find.text('Other session'), findsNothing);
      expect(find.text('Mixed session'), findsNothing);
      expect(find.text('Unassigned session'), findsNothing);
      expect(controller.participant, 'unassigned');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(screen());
      await settleIo(
        tester,
        () => find.text('My session').evaluate().isNotEmpty,
      );
      await tester.runAsync(() async {
        for (final item in originals.entries) {
          expect(await item.key.readAsString(), item.value);
        }
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('screen menu keeps Live state while resizing to mobile', (
    tester,
  ) async {
    late Directory root;
    late SessionController controller;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('overview-wide-');
      controller = SessionController(
        service: FakePolar(),
        foregroundService: FakeForeground(),
        directoryProvider: () async => root,
      );
      await controller.quickMarkers.load();
    });
    addTearDown(
      () => tester.runAsync(() async {
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      }),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1280, 850));
    await tester.pumpWidget(
      MaterialApp(home: SessionHome(controller: controller)),
    );
    await settleIo(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    await openScreen(tester, 'Recording');
    await settleIo(
      tester,
      () => find
          .widgetWithText(TextField, 'Participant name')
          .evaluate()
          .isNotEmpty,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Participant name'),
      'Draft participant',
    );
    await tester.binding.setSurfaceSize(const Size(390, 850));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Draft participant'), findsOneWidget);
    await openScreen(tester, 'Devices');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Devices'), findsOneWidget);
    await openScreen(tester, 'Overview');
    await settleIo(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    expect(find.text('Overview'), findsOneWidget);
    await openScreen(tester, 'Recording');
    await settleIo(
      tester,
      () => find
          .widgetWithText(TextField, 'Participant name')
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('Draft participant'), findsOneWidget);
    expect(controller.participant, 'unassigned');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
