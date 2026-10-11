import 'session_history.dart';
import 'recording_types.dart';

String recordingTitle(HistoryEntry entry) {
  final description = entry.metadata.description.trim().split('\n').first;
  if (description.isNotEmpty) return description;
  final type = recordingTypeLabel(entry.manifest);
  return type == 'Unspecified' ? 'Recording' : type;
}

String recordingSensors(HistoryEntry entry) {
  final devices = entry.manifest['devices'];
  final kinds = devices is Map
      ? devices.values.whereType<Map>().map((d) => d['kind']).toSet()
      : <dynamic>{};
  final labels = <String>[
    if (kinds.contains('polar_h10')) 'H10',
    if (kinds.contains('wellue_o2ring')) 'O2Ring',
    if (kinds.contains('muse_s_athena')) 'EEG',
  ];
  return labels.isEmpty ? 'Recorded sensors' : labels.join(' · ');
}

String recordingDuration(HistoryEntry entry) {
  final start = entry.started;
  if (start == null) return 'Duration unknown';
  final stopped = entry.events
      .where((e) => e['event'] == 'session_ended')
      .map((e) => DateTime.tryParse('${e['received_utc']}'))
      .whereType<DateTime>()
      .firstOrNull;
  final times =
      entry.events
          .map((e) => DateTime.tryParse('${e['received_utc']}'))
          .whereType<DateTime>()
          .where((t) => !t.isBefore(start))
          .toList()
        ..sort();
  final end = stopped ?? times.lastOrNull;
  if (end == null) return 'Duration unknown';
  final seconds = end.difference(start).inSeconds;
  final h = seconds ~/ 3600, m = (seconds ~/ 60) % 60, s = seconds % 60;
  return '${h > 0 ? '${h}h ' : ''}${m}m ${s}s${stopped == null ? ' so far' : ''}';
}
