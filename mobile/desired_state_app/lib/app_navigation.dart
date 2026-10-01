import 'package:flutter/widgets.dart';

/// Routes back to the app's persistent tabs without recreating recording state.
class AppNavigation extends InheritedWidget {
  const AppNavigation({
    super.key,
    required this.showLive,
    required this.showHistory,
    required super.child,
  });
  final VoidCallback showLive, showHistory;
  static AppNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppNavigation>();
  @override
  bool updateShouldNotify(AppNavigation oldWidget) => false;
}
