import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/desktop_screen.dart';

void main() {
  testWidgets(
    'desktop line plot shows native units and shared inspection value',
    (tester) async {
      double? cursor;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopSignalPlot(
              title: 'ECG (µV)',
              points: const [(0, 100), (1, -200), (2, 300)],
              start: 0,
              end: 2,
              cursor: 1,
              markers: const [1],
              timeLabel: (t) => '${t.toInt()}s',
              onCursor: (v) => cursor = v,
            ),
          ),
        ),
      );
      expect(find.text('ECG (µV) · 1s: -200.00'), findsOneWidget);
      await tester.tap(find.byType(CustomPaint).last);
      expect(cursor, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
}
