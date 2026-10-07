import 'dart:convert';

/// Carry a recorded categorical estimate only until a recorded discontinuity.
/// Zero is explicit unknown; no calibration or sleep staging is inferred.
List<(double, double)> recordedPosturePoints(
  List<Map<String, dynamic>> events,
  DateTime origin,
  double start,
  double end,
) {
  const labels = [
    'Unknown',
    'On back',
    'Right side',
    'Left side',
    'Upright',
    'Prone',
    'Uncalibrated',
  ];
  final changes = <(double, double)>[];
  var hasPosture = false;
  for (final event in events) {
    final timestamp = DateTime.tryParse('${event['received_utc']}');
    if (timestamp == null) continue;
    final time = timestamp.difference(origin).inMicroseconds / 1000000;
    if (event['event'] == 'posture_estimate') {
      hasPosture = true;
      var code = 0;
      try {
        final details = jsonDecode('${event['description']}') as Map;
        code = labels.indexOf('${details['position']}');
      } catch (_) {
        /* Malformed estimates remain unknown. */
      }
      changes.add((time, (code < 0 ? 0 : code).toDouble()));
    } else if ([
      'session_paused',
      'bluetooth_disconnected',
      'bluetooth_manual_disconnect',
      'accelerometer_clock_gap_or_reset',
      'posture_calibration_selected',
    ].contains(event['event'])) {
      changes.add((time, 0));
    }
  }
  if (!hasPosture) return [];
  changes.sort((a, b) => a.$1.compareTo(b.$1));
  var current = 0.0;
  for (final point in changes) {
    if (point.$1 <= start) current = point.$2;
  }
  final result = <(double, double)>[(start, current)];
  for (final point in changes) {
    if (point.$1 <= start || point.$1 > end) continue;
    result.add((point.$1, current));
    result.add(point);
    current = point.$2;
  }
  result.add((end, current));
  return result;
}
