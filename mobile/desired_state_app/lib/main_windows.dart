import 'package:flutter/material.dart';

import 'desktop_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DesiredStateWindows());
}

class DesiredStateWindows extends StatelessWidget {
  const DesiredStateWindows({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Desired State · Analyze',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff267b80),
      useMaterial3: true,
    ),
    home: const DesktopScreen(),
  );
}
