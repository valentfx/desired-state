import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/main.dart';
import 'package:desired_state_app/polar_h10_service.dart';

void main() {
  testWidgets('Desired State collector screen loads', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DesiredStateApp());

    expect(find.text('Polar H10 Collector'), findsOneWidget);
    expect(find.text('Scan for Polar H10'), findsOneWidget);
    expect(find.text('Participant name'), findsOneWidget);
    expect(find.text('Event description'), findsOneWidget);
    expect(find.text('START RECORDING'), findsNothing);
  });

  testWidgets('collector keeps live data out of a session until recording starts', (
    tester,
  ) async {
    final service = _FakePolar();
    await tester.pumpWidget(
      MaterialApp(home: CollectorScreen(service: service)),
    );
    service.controller.add(
      PolarHeartRateData(
        heartRate: 43,
        rrIntervalsMs: [1400, 1410, 1390, 730],
        timestamp: DateTime(2026),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('43'), findsOneWidget);
    expect(find.text('730'), findsOneWidget);
    expect(find.text('--'), findsWidgets);
    expect(find.text('RMSSD (clean)'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Raw RR this session: 0\nAccepted RR: 0\nArtifacts rejected: 0',
      ),
      findsOneWidget,
    );
    service.controller.add(
      PolarHeartRateData(
        heartRate: 44,
        rrIntervalsMs: [],
        timestamp: DateTime(2026),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(find.text('730'), findsOneWidget);
    expect(find.text('44'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

class _FakePolar extends PolarH10Service {
  final controller = StreamController<PolarHeartRateData>();

  @override
  Stream<PolarHeartRateData> get dataStream => controller.stream;

  @override
  Future<void> dispose() => controller.close();
}
