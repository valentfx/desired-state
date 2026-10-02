import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/polar_h10_service.dart';
import 'package:desired_state_app/session_controller.dart';

void main() {
  testWidgets(
    'Overview opens first and Live is reachable without a recording',
    (WidgetTester tester) async {
      await tester.pumpWidget(const DesiredStateApp());

      expect(find.text('Overview'), findsNWidgets(2));
      expect(find.text('Scan for devices'), findsNothing);
      await tester.tap(find.text('Live'));
      await tester.pump();
      expect(find.text('Desired State'), findsOneWidget);
      expect(find.text('Scan for devices'), findsNothing);
      await tester.tap(find.text('Connect H10'));
      await tester.pumpAndSettle();
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('Scan for devices'), findsOneWidget);
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
