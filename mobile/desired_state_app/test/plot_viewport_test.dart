import 'package:desired_state_app/plot_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'time browsing and zoom preserve duration and stay within recorded data',
    () {
      final first = DateTime.utc(2026);
      final last = first.add(const Duration(seconds: 100));
      final start = first.add(const Duration(seconds: 40));
      final end = first.add(const Duration(seconds: 60));
      for (final shift in [-100.0, -1.0, 0.0, 1.0, 100.0]) {
        final range = plotViewport(
          first: first,
          last: last,
          start: start,
          end: end,
          shift: shift,
        );
        expect(range.$1.isBefore(first), false);
        expect(range.$2.isAfter(last), false);
        expect(range.$2.difference(range.$1), const Duration(seconds: 20));
      }
      final zoomed = plotViewport(
        first: first,
        last: last,
        start: start,
        end: end,
        zoom: 0.5,
      );
      expect(zoomed.$1, first.add(const Duration(seconds: 45)));
      expect(zoomed.$2, first.add(const Duration(seconds: 55)));
      expect(
        plotViewport(
          first: first,
          last: last,
          start: start,
          end: end,
          zoom: 100,
        ),
        (first, last),
      );
      expect(
        plotViewport(first: first, last: first, start: first, end: first),
        (first, first),
      );
    },
  );
}
