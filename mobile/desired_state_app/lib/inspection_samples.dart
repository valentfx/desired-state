import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'plot_inspection.dart';
import 'session_history.dart';

/// Reads original low-rate ring samples once for stopped-session inspection.
/// Posture comes from the original event journal, including unknown estimates.
Future<Map<String, List<InspectionValue>>> loadInspectionSamples(
  HistoryEntry entry,
) {
  final directory = entry.directory.path, id = entry.id;
  final assignments = Map<String, dynamic>.from(
    entry.manifest['assignments'] as Map? ?? {},
  );
  final events = entry.events;
  return Isolate.run(() async {
    final result = <String, List<InspectionValue>>{};
    final file = File('$directory/o2ring_measurements.jsonl');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        try {
          final row = jsonDecode(line);
          if (row is! Map ||
              row['schema_version'] != 1 ||
              row['session_id'] != id ||
              !assignments.containsKey(row['device_id']) ||
              row['user_id'] != assignments[row['device_id']]) {
            continue;
          }
          final time = DateTime.parse(row['received_utc'] as String);
          final value = row['spo2_percent'];
          result
              .putIfAbsent('SpO2', () => [])
              .add(
                InspectionValue(
                  time,
                  row['usable'] != false && value is num && value.isFinite
                      ? '$value %'
                      : '—',
                ),
              );
        } catch (_) {
          /* Original row remains preserved. */
        }
      }
    }
    for (final row in events) {
      if ([
        'session_paused',
        'measurement_gap',
        'bluetooth_disconnected',
        'bluetooth_manual_disconnect',
        'accelerometer_clock_gap_or_reset',
      ].contains(row['event'])) {
        final time = DateTime.tryParse('${row['received_utc']}');
        if (time != null) {
          result
              .putIfAbsent('Position', () => [])
              .add(InspectionValue(time, 'Unknown'));
        }
      }
      if (row['event'] != 'posture_estimate') continue;
      try {
        final position = jsonDecode(row['description'] as String)['position'];
        result
            .putIfAbsent('Position', () => [])
            .add(
              InspectionValue(
                DateTime.parse(row['received_utc'] as String),
                '$position',
              ),
            );
      } catch (_) {
        /* Unknown legacy rows are not guessed. */
      }
    }
    return result;
  });
}

Map<String, InspectionValue?> inspectionSamplesAt(
  Map<String, List<InspectionValue>> source,
  DateTime time,
) {
  final result = <String, InspectionValue?>{};
  for (final entry in source.entries) {
    InspectionValue? selected;
    for (final point in entry.value) {
      if (entry.key == 'Position') {
        // Position is a logged state transition; do not use a future state.
        if (!point.time.isAfter(time) &&
            (selected == null || point.time.isAfter(selected.time))) {
          selected = point;
        }
      } else if (selected == null ||
          point.time.difference(time).abs() <
              selected.time.difference(time).abs()) {
        selected = point;
      }
    }
    result[entry.key] =
        selected == null ||
            (entry.key != 'Position' &&
                selected.time.difference(time).abs() >
                    const Duration(seconds: 3))
        ? null
        : selected;
  }
  return result;
}
