import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Recording H10 layout is the common frame for every mobile time-series plot.
abstract final class PlotTemplate {
  static const left = 54.0, top = 16.0, right = 8.0, bottom = 26.0;
  static Rect area(Size size, {bool dualAxis = false}) => Rect.fromLTWH(
    left,
    top,
    math.max(1, size.width - left - (dualAxis ? left : right)),
    math.max(1, size.height - top - bottom),
  );
  static Color get gridColor => Colors.grey.withValues(alpha: .25);
}

/// One selection for the entire recording view, independent of widget mounting.
class PlotSelection extends ChangeNotifier {
  DateTime? time;
  Object? owner;
  void select(DateTime selected, Object source) {
    time = selected;
    owner = source;
    notifyListeners();
  }

  void clear() {
    time = null;
    owner = null;
    notifyListeners();
  }
}
