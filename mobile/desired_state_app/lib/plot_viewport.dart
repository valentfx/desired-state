/// Bounded time navigation. Display-only: never changes recorded data.
(DateTime, DateTime) plotViewport({
  required DateTime first,
  required DateTime last,
  required DateTime start,
  required DateTime end,
  double shift = 0,
  double zoom = 1,
}) {
  final available = last.difference(first).inMicroseconds;
  if (available <= 0) return (first, last);
  final oldSpan = end.difference(start).inMicroseconds.clamp(1, available);
  final span = (oldSpan * zoom).round().clamp(
    available < 1000000 ? available : 1000000,
    available,
  );
  final center =
      start.difference(first).inMicroseconds + oldSpan / 2 + shift * oldSpan;
  final left = (center - span / 2).round().clamp(0, available - span);
  return (
    first.add(Duration(microseconds: left)),
    first.add(Duration(microseconds: left + span)),
  );
}
