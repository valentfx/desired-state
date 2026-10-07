import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/polar_h10_service.dart';
import 'package:desired_state_app/session_controller.dart';

import 'navigation_test_helpers.dart' show openScreen;

void main() {
  testWidgets(
    'Overview opens first and Live is reachable without a recording',
    (WidgetTester tester) async {
      await tester.pumpWidget(const DesiredStateApp());

      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Scan for devices'), findsNothing);
      await openScreen(tester, 'Session');
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is AppBar &&
              widget.title is Text &&
              (widget.title as Text).data == 'Session',
        ),
        findsOneWidget,
      );
      expect(find.text('Scan for devices'), findsNothing);
      await tester.ensureVisible(find.text('Connect devices'));
      await tester.pump();
      await tester.tap(find.text('Connect devices').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('Polar H10'), findsOneWidget);
      expect(find.text('O2Ring'), findsOneWidget);
      expect(find.text('Scan for Polar H10'), findsNothing);
      await tester.tap(find.text('Polar H10').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Scan for Polar H10').hitTestable(), findsOneWidget);
      await tester.tap(find.byType(BackButton).hitTestable());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('O2Ring').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Scan for O2Ring').hitTestable(), findsOneWidget);
      expect(find.text('START RECORDING'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'collector keeps live data out of a session until recording starts',
    (tester) async {
      final service = _FakePolar();
      final controller = SessionController(service: service);
      await tester.pumpWidget(
        MaterialApp(home: CollectorScreen(controller: controller)),
      );
      service.controller.add(
        PolarHeartRateData(
          heartRate: 43,
          rrIntervalsMs: [1400, 1410, 1390, 730],
          timestamp: DateTime(2026),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('START RECORDING'), findsNothing);
      service.controller.add(
        PolarHeartRateData(
          heartRate: 44,
          rrIntervalsMs: [],
          timestamp: DateTime(2026),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('START RECORDING'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}

class _FakePolar extends PolarH10Service {
  final controller = StreamController<PolarHeartRateData>();

  @override
  Stream<PolarHeartRateData> get dataStream => controller.stream;

  @override
  Future<void> dispose() => controller.close();
}
