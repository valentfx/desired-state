import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive.dart';

import 'session_history.dart';
import 'recorded_posture.dart';
export 'recorded_posture.dart' show recordedPosturePoints;

typedef SignalPoint = (double, double);
const desktopStreams = [
  'measurements',
  'rr',
  'o2ring_measurements',
  'events',
  'muse_bands',
  'h10_ecg',
  'h10_accelerometer',
  'muse_eeg',
];
const rawStreams = {'h10_ecg', 'h10_accelerometer', 'muse_eeg'};

/// Import originals into a staging directory; publish only after validation.
Future<String> importDesktopZip(String source, String rootPath) =>
    Isolate.run(() => importDesktopZipWorker(source, rootPath));

Future<String> importDesktopZipWorker(String source, String rootPath) async {
  final archive = ZipDecoder().decodeBytes(
    await File(source).readAsBytes(),
    verify: true,
  );
  final files = archive.files.where((f) => f.isFile).toList();
  final names = <String>{};
  var size = 0;
  for (final file in files) {
    final name = file.name.replaceAll('\\', '/');
    if (file.isSymbolicLink ||
        name.startsWith('/') ||
        name.contains(':') ||
        name.split('/').any((v) => v == '..' || v.isEmpty) ||
        !names.add(name)) {
      throw const FormatException('Unsafe or duplicate ZIP path');
    }
    size += file.size;
    if (size > 8 * 1024 * 1024 * 1024) {
      throw const FormatException('Expanded session exceeds 8 GiB');
    }
  }
  final manifests = files
      .where(
        (f) => f.name.replaceAll('\\', '/').split('/').last == 'manifest.json',
      )
      .toList();
  if (manifests.length != 1) {
    throw const FormatException('Select one exported session ZIP');
  }
  final manifestFile = manifests.single;
  final manifest =
      jsonDecode(utf8.decode(manifestFile.content)) as Map<String, dynamic>;
  final id = manifest['session_id'];
  if (manifest['schema_version'] != 1 ||
      id is! String ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id) ||
      DateTime.tryParse('${manifest['started_utc']}') == null) {
    throw const FormatException('Unsupported session manifest');
  }
  final prefix = manifestFile.name
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'manifest\.json$'), '');
  final root = Directory(rootPath);
  await root.create(recursive: true);
  final destination = Directory('$rootPath/$id');
  if (await destination.exists()) {
    throw StateError(
      'Session $id is already imported; existing data was retained',
    );
  }
  // Staging is outside the session listing and on the same filesystem.
  final stage = await Directory(root.parent.path)
      .createTemp('.desired-state-import-');
  try {
    for (final file in files) {
      final name = file.name.replaceAll('\\', '/');
      if (!name.startsWith(prefix)) {
        continue;
      }
      final relative = name.substring(prefix.length);
      if (relative.contains('/')) {
        throw const FormatException('Nested session files are unsupported');
      }
      await File('${stage.path}/$relative')
          .writeAsBytes(file.content, flush: true);
    }
    await stage.rename(destination.path);
    return destination.path;
  } finally {
    if (await stage.exists()) {
      await stage.delete(recursive: true);
    }
  }
}

/// Byte offsets refer to complete JSONL lines, including multibyte text.
Stream<(int, String)> desktopLines(File file, [int offset = 0]) async* {
  var position = offset;
  final pending = <int>[];
  await for (final chunk in file.openRead(offset)) {
    var start = 0;
    while (start < chunk.length) {
      final newline = chunk.indexOf(10, start);
      if (newline < 0) {
        pending.addAll(chunk.sublist(start));
        break;
      }
      pending.addAll(chunk.sublist(start, newline));
      yield (position, utf8.decode(pending));
      position += pending.length + 1;
      pending.clear();
      start = newline + 1;
    }
  }
  if (pending.isNotEmpty) {
    yield (position, utf8.decode(pending));
  }
}

class DesktopIndex {
  DesktopIndex(this.path, this.origin);
  final String path;
  final DateTime origin;
  double duration = 1;
  final Map<String, List<(double, int)>> offsets = {};
  final Map<String, List<SignalPoint>> overview = {};
  final Map<String, int> rows = {};
  final List<String> warnings = [];
  final Set<String> unordered = {};
}

void reduceDesktopPoints(List<SignalPoint> points) {
  if (points.length <= 6000) {
    return;
  }
  final reduced = <SignalPoint>[];
  for (var i = 0; i < points.length; i += 4) {
    final group = points.sublist(i, math.min(i + 4, points.length));
    if (group.any((p) => !p.$2.isFinite)) {
      reduced.add((group.first.$1, double.nan));
      continue;
    }
    final low = group.reduce((a, b) => a.$2 < b.$2 ? a : b);
    final high = group.reduce((a, b) => a.$2 > b.$2 ? a : b);
    reduced.addAll(low.$1 <= high.$1 ? [low, high] : [high, low]);
  }
  points
    ..clear()
    ..addAll(reduced);
}

class DesktopDecoder {
  final Map<String, String> segments = {};
  final Map<String, double> lastTimes = {};
  final List<(double, bool)> rr = [];
  String? rrSegment;
  double? rrTime;
  void decode(
    String name,
    Map<String, dynamic> row,
    double t,
    Map<String, List<SignalPoint>> output,
    double start,
    double end,
  ) {
    final segment = '${row['continuity_segment']}:${row['recording_segment']}';
    void add(String key, double time, dynamic value, [double gap = 10]) {
      if (time < start || time > end || value is! num) {
        return;
      }
      final points = output.putIfAbsent(key, () => []);
      final previous = lastTimes[key];
      if (previous != null &&
          (segments[key] != segment ||
              time < previous ||
              time - previous > gap)) {
        points.add((time, double.nan));
      }
      points.add((time, value.toDouble()));
      segments[key] = segment;
      lastTimes[key] = time;
      reduceDesktopPoints(points);
    }

    if (name == 'measurements') {
      add('BPM', t, row['heart_rate_bpm']);
    }
    if (name == 'rr') {
      final value = row['rr_ms'];
      if (rrSegment != segment ||
          (rrTime != null && (t < rrTime! || t - rrTime! > 10))) {
        rr.clear();
      }
      rrSegment = segment;
      rrTime = t;
      if (value is num && value.isFinite) {
        final accepted = row['artifact_accepted'] == true && value > 0;
        rr.add((value.toDouble(), accepted));
        if (rr.length > 60) {
          rr.removeAt(0);
        }
        var usable = 0, pairs = 0;
        var sum = 0.0;
        for (var i = 0; i < rr.length; i++) {
          if (!rr[i].$2) {
            continue;
          }
          usable++;
          if (i > 0 && rr[i - 1].$2) {
            final delta = rr[i].$1 - rr[i - 1].$1;
            sum += delta * delta;
            pairs++;
          }
        }
        add('RR (ms, raw)', t, value);
        add(
          'RMSSD (ms, recorded screening)',
          t,
          usable >= 3 && pairs > 0 ? math.sqrt(sum / pairs) : double.nan,
        );
      } else {
        rr.clear();
      }
    }
    if (name == 'events' && row['event'] == 'posture_estimate') {
      try {
        final details = jsonDecode('${row['description']}') as Map;
        const labels = [
          'Unknown',
          'On back',
          'Right side',
          'Left side',
          'Upright',
          'Prone',
          'Uncalibrated',
        ];
        final value = labels.indexOf('${details['position']}');
        add(
          'Sleep position (recorded estimate)',
          t,
          value < 0 ? 0 : value,
          double.infinity,
        );
      } catch (_) {
        add('Sleep position (recorded estimate)', t, 0, double.infinity);
      }
    }
    if (name == 'o2ring_measurements') {
      add('Ring movement (raw)', t, row['motion_raw'], 5);
      add(
        'SpO2 (%)',
        t,
        row['usable'] == false ? double.nan : row['spo2_percent'],
        5,
      );
      add(
        'Ring pulse (bpm)',
        t,
        row['usable'] == false ? double.nan : row['pulse_bpm'],
        5,
      );
    }
    if (name == 'muse_bands' && row['channels'] is Map) {
      final channels = (row['channels'] as Map).values
          .whereType<Map>()
          .toList();
      for (final band in ['Delta', 'Theta', 'Alpha', 'Beta', 'Gamma']) {
        final values = channels
            .map((v) => v[band])
            .whereType<num>()
            .where((v) => v.isFinite)
            .toList();
        add(
          'EEG $band (µV²)',
          t,
          values.length == channels.length && values.isNotEmpty
              ? values.fold<double>(0, (a, b) => a + b) / values.length
              : double.nan,
          5,
        );
      }
    }
    void samples(String key, dynamic values, double rate) {
      if (values is! List || !rate.isFinite || rate <= 0) {
        return;
      }
      for (var i = 0; i < values.length; i++) {
        add(key, t - (values.length - 1 - i) / rate, values[i], 2);
      }
    }

    if (name == 'h10_ecg') {
      samples(
        'ECG (µV)',
        row['samples_uv'],
        (row['sample_rate_hz'] as num?)?.toDouble() ?? 130,
      );
    }
    if (name == 'h10_accelerometer' && row['xyz_mg'] is List) {
      final xyz = row['xyz_mg'] as List;
      var movement = 0.0;
      for (var i = 1; i < xyz.length; i++) {
        final a = xyz[i - 1] as List, b = xyz[i] as List;
        movement += math.sqrt(
          List.generate(
            3,
            (axis) => math.pow(
              (b[axis] as num).toDouble() - (a[axis] as num).toDouble(),
              2,
            ),
          ).fold<double>(0, (sum, value) => sum + value),
        );
      }
      if (xyz.length > 1) {
        add(
          'H10 movement (mean sample delta, mG)',
          t,
          movement / (xyz.length - 1),
          2,
        );
      }
      for (
        var axis = 0;
        axis < (row['_desktop_summary_only'] == true ? 0 : 3);
        axis++
      ) {
        samples(
          'H10 ${['X', 'Y', 'Z'][axis]} (mG)',
          xyz.map((v) => (v as List)[axis]).toList(),
          (row['sample_rate_hz'] as num?)?.toDouble() ?? 50,
        );
      }
    }
    if (name == 'muse_eeg' && row['optical'] is Map) {
      for (final entry in (row['optical'] as Map).entries) {
        if (entry.value is List &&
            (entry.value as List).whereType<num>().any((v) => v != 0)) {
          samples(
            'Athena optical ${entry.key} (raw intensity)',
            entry.value,
            (row['optical_rate_hz'] as num?)?.toDouble() ?? 64,
          );
        }
      }
    }
    if (name == 'muse_eeg' && row['eeg'] is Map) {
      for (final entry in (row['eeg'] as Map).entries) {
        samples(
          'Muse channel ${entry.key} (µV)',
          entry.value,
          (row['eeg_rate_hz'] as num?)?.toDouble() ?? 256,
        );
      }
    }
  }
}

Future<DesktopIndex> indexDesktopSession(String path, DateTime origin) =>
    Isolate.run(() async {
      final index = DesktopIndex(path, origin);
      final decoder = DesktopDecoder();
      for (final name in desktopStreams) {
        final file = File('$path/$name.jsonl');
        if (!await file.exists()) {
          continue;
        }
        index.offsets[name] = [];
        var minute = -999999, count = 0, invalid = 0;
        double? previous;
        await for (final line in desktopLines(file)) {
          try {
            final row = jsonDecode(line.$2) as Map<String, dynamic>;
            final time = DateTime.tryParse('${row['received_utc']}');
            if (time == null) {
              invalid++;
              continue;
            }
            final t = time.difference(origin).inMicroseconds / 1000000;
            if (previous != null && t < previous) {
              index.unordered.add(name);
            }
            previous = t;
            final bucket = (t / 60).floor();
            if (bucket != minute) {
              index.offsets[name]!.add((t, line.$1));
              minute = bucket;
            }
            index.duration = math.max(index.duration, t);
            count++;
            if (!rawStreams.contains(name) || name == 'h10_accelerometer') {
              if (name == 'h10_accelerometer') {
                row['_desktop_summary_only'] = true;
              }
              decoder.decode(name, row, t, index.overview, 0, double.infinity);
            }
          } catch (_) {
            invalid++;
          }
        }
        index.rows[name] = count;
        if (invalid > 0) {
          index.warnings.add('$name: $invalid unreadable rows omitted');
        }
        if (index.unordered.contains(name)) {
          index.warnings.add(
            '$name: backwards receipt time; range reads use full scan',
          );
        }
      }
      final eventsFile = File('$path/events.jsonl');
      if (await eventsFile.exists()) {
        final events = <Map<String, dynamic>>[];
        await for (final line in desktopLines(eventsFile)) {
          try {
            events.add(jsonDecode(line.$2) as Map<String, dynamic>);
          } catch (_) {
            /* Index warnings report malformed rows. */
          }
        }
        index.overview['Sleep position (recorded estimate)'] =
            recordedPosturePoints(events, origin, 0, index.duration);
        if (index.overview['Sleep position (recorded estimate)']!.isEmpty) {
          index.overview.remove('Sleep position (recorded estimate)');
        }
      }
      return index;
    });

Future<(Map<String, List<SignalPoint>>, List<String>)> readDesktopWindow(
  DesktopIndex index,
  double start,
  double end,
  bool raw,
) => Isolate.run(() async {
  final data = <String, List<SignalPoint>>{};
  final warnings = <String>[];
  final decoder = DesktopDecoder();
  for (final name in index.offsets.keys) {
    if (rawStreams.contains(name) && name != 'h10_accelerometer' && !raw) {
      continue;
    }
    var offset = 0;
    // Warm up RR using preceding acquired intervals; include a batch preceding start.
    final lead = name == 'rr' ? 180.0 : 3.0;
    if (!index.unordered.contains(name)) {
      for (final entry in index.offsets[name]!) {
        if (entry.$1 <= start - lead) {
          offset = entry.$2;
        } else {
          break;
        }
      }
    }
    var invalid = 0;
    await for (final line in desktopLines(
      File('${index.path}/$name.jsonl'),
      offset,
    )) {
      try {
        final row = jsonDecode(line.$2) as Map<String, dynamic>;
        final time = DateTime.tryParse('${row['received_utc']}');
        if (time == null) {
          invalid++;
          continue;
        }
        final t = time.difference(index.origin).inMicroseconds / 1000000;
        if (t > end + 3 && !index.unordered.contains(name)) {
          break;
        }
        if (name == 'h10_accelerometer' && !raw) {
          row['_desktop_summary_only'] = true;
        }
        decoder.decode(name, row, t, data, start, end);
      } catch (_) {
        invalid++;
      }
    }
    if (invalid > 0) {
      warnings.add('$name: $invalid unreadable rows in selected range');
    }
  }
  final eventsFile = File('${index.path}/events.jsonl');
  if (await eventsFile.exists()) {
    final events = <Map<String, dynamic>>[];
    await for (final line in desktopLines(eventsFile)) {
      try {
        events.add(jsonDecode(line.$2) as Map<String, dynamic>);
      } catch (_) {
        /* Reported by the stream reader above. */
      }
    }
    final positions = recordedPosturePoints(events, index.origin, start, end);
    if (positions.isNotEmpty) {
      data['Sleep position (recorded estimate)'] = positions;
    }
  }
  return (data, warnings);
});

Future<HistoryEntry> readDesktopEntry(String path) =>
    SessionHistoryRepository().readEntry(Directory(path));
