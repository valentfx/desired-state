import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openScreen(WidgetTester tester, String name) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  // Start the ticker in one frame before advancing animation time.
  // A timed first pump starts at elapsed zero, leaving the drawer off-screen.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  final destination = find.descendant(
    of: find.byType(Drawer),
    matching: find.text(name),
  );
  await tester.ensureVisible(destination);
  await tester.pump();
  expect(
    destination.hitTestable(),
    findsOneWidget,
    reason: 'The drawer must finish opening before selecting $name',
  );
  await tester.tap(destination);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}
