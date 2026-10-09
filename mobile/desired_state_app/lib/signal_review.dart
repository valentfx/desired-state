import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'eeg_bands.dart';
import 'h10_ecg.dart';
import 'session_history.dart';

class SavedBand {
  const SavedBand(this.frame, this.segment);
  final EegBandFrame frame;
  final int segment;
}

class SignalReview {
  const SignalReview(
    this.bands,
    this.warnings,
    this.windows,
    this.usableWindows,
    this.endTime,
  );
  final List<SavedBand> bands;
  final List<String> warnings;
  final int windows, usableWindows;
  final DateTime? endTime;
}

class ReplayReview {
  const ReplayReview(this.eeg, this.ecg, this.warnings);
  final Map<String, List<(double, double)>> eeg, ecg;
  final List<String> warnings;
}

Map<String, dynamic> _request(HistoryEntry entry) => {
  'directory': entry.directory.path,
  'id': entry.id,
  'assignments': Map<String, dynamic>.from(
    entry.manifest['assignments'] as Map? ?? {},
  ),
  'origin': (entry.started ?? DateTime(1970)).toUtc().toIso8601String(),
};
bool _belongs(Map<String, dynamic> row, Map<String, dynamic> request) {
  final assignments = request['assignments'] as Map;
  final device = row['device_id'] ?? row['polar_id'];
  return row['session_id'] == request['id'] &&
      assignments.containsKey(device) &&
      row['user_id'] == assignments[device] &&
      row['schema_version'] == 1;
}

Stream<Map<String, dynamic>> _rows(
  String directory,
  String name,
  List<String> warnings,
) async* {
  final file = File('$directory/$name.jsonl');
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return;
  }
  if (type != FileSystemEntityType.file) {
    warnings.add('$name is not a regular file');
    return;
  }
  var bad = 0;
  try {
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) {
        continue;
      }
      try {
        final row = jsonDecode(line);
        if (row is Map<String, dynamic>) {
          yield row;
        } else {
          bad++;
          yield {'_malformed': true};
        }
      } catch (_) {
        bad++;
        yield {'_malformed': true};
      }
    }
  } catch (_) {
    warnings.add('Unable to read all of $name');
  }
  if (bad > 0) {
    warnings.add('$name: $bad malformed rows omitted');
  }
}

Future<SignalReview> reviewSignals(HistoryEntry entry, {int eegSeconds = 4}) {
  final request = {..._request(entry), 'eeg_seconds': eegSeconds};
  return Isolate.run(() => _review(request));
}

Future<SignalReview> _review(Map<String, dynamic> request) async {
  final warnings = <String>[];
  final bands = <SavedBand>[];
  final buffers = <String, List<double>>{};
  Object? previousSegment;
  DateTime? previous, lastPower, endTime;
  int rate = 0, segment = 0, windows = 0, usable = 0, bad = 0, stride = 1;
  await for (final row in _rows(
    request['directory'] as String,
    'muse_eeg',
    warnings,
  )) {
    try {
      if (!_belongs(row, request)) {
        throw const FormatException('Identity mismatch');
      }
      if (row['eegCount'] == 0) {
        continue;
      }
      final sampleCount = row['eegCount'] as int;
      if (sampleCount < 1 || sampleCount > 10000) {
        throw const FormatException('Invalid sample count');
      }
      final time = DateTime.parse(row['received_utc'] as String);
      if (endTime == null || time.isAfter(endTime)) {
        endTime = time;
      }
      final sampleRate = row['eeg_rate_hz'] as int;
      final channels = row['eeg'] as Map;
      if (sampleRate < 64 ||
          sampleRate > 512 ||
          (sampleRate & (sampleRate - 1)) != 0 ||
          channels.length > 16) {
        throw const FormatException('Unsupported EEG rate/channels');
      }
      final key =
          '${row['recording_segment']}:${row['continuity_segment']}:$sampleRate';
      if (key != previousSegment ||
          (previous != null &&
              (time.isBefore(previous) ||
                  time.difference(previous) > const Duration(seconds: 2)))) {
        buffers.clear();
        segment++;
        lastPower = null;
      }
      previousSegment = key;
      previous = time;
      rate = sampleRate;
      final validChannels = <String>{};
      for (final entry in channels.entries) {
        final name = entry.key as String;
        final input = List<num>.from(entry.value as List);
        if (input.length != sampleCount || input.any((v) => !v.isFinite)) {
          throw const FormatException('Invalid EEG samples');
        }
        validChannels.add(name);
        final buffer = buffers.putIfAbsent(name, () => []);
        buffer.addAll(input.map((v) => v.toDouble()));
        final limit = rate * (request['eeg_seconds'] as int);
        if (buffer.length > limit) {
          buffer.removeRange(0, buffer.length - limit);
        }
      }
      buffers.removeWhere((name, _) => !validChannels.contains(name));
      if (lastPower != null &&
          time.difference(lastPower) < const Duration(seconds: 1)) {
        continue;
      }
      if (buffers.isEmpty ||
          buffers.values.any(
            (b) => b.length < rate * (request['eeg_seconds'] as int),
          )) {
        continue;
      }
      lastPower = time;
      final frame = buildEegFrame(
        time,
        buffers,
        rate,
        maximumSamples: rate * (request['eeg_seconds'] as int),
        segment: segment,
      );
      windows++;
      if (frame.screenedChannels?.isNotEmpty ?? false) {
        usable++;
      }
      if (windows % stride == 0) {
        bands.add(SavedBand(frame, segment));
      }
      if (bands.length > 12000) {
        final kept = [for (var i = 0; i < bands.length; i += 2) bands[i]];
        bands
          ..clear()
          ..addAll(kept);
        stride *= 2;
      }
    } catch (_) {
      bad++;
      buffers.clear();
      previousSegment = null;
    }
  }
  if (bad > 0) {
    warnings.add(
      'EEG: $bad invalid/unsupported batches omitted; continuity reset',
    );
  }
  if (stride > 1) {
    warnings.add(
      'Long-session band display sampled every $stride valid processing steps; overview excludes skipped points',
    );
  }
  await for (final row in _rows(
    request['directory'] as String,
    'h10_ecg',
    warnings,
  )) {
    if (!_belongs(row, request)) {
      continue;
    }
    final time = DateTime.tryParse('${row['received_utc']}');
    if (time != null && (endTime == null || time.isAfter(endTime))) {
      endTime = time;
    }
  }
  return SignalReview(bands, warnings, windows, usable, endTime);
}

Future<ReplayReview> replaySignals(
  HistoryEntry entry,
  double startSeconds,
  double endSeconds,
) {
  final request = {
    ..._request(entry),
    'start': startSeconds,
    'end': endSeconds,
  };
  return Isolate.run(() => _replay(request));
}

Future<ReplayReview> _replay(Map<String, dynamic> request) async {
  final eeg = <String, List<(double, double)>>{},
      ecg = <String, List<(double, double)>>{};
  final warnings = <String>[];
  final origin = DateTime.parse(request['origin'] as String);
  final start = request['start'] as double, end = request['end'] as double;
  var count = 0, bad = 0;
  for (final source in ['muse_eeg', 'h10_ecg']) {
    Object? previousSegment;
    DateTime? previousReceipt;
    BigInt? previousSensor, anchorSensor;
    double anchorHost = 0;
    await for (final row in _rows(
      request['directory'] as String,
      source,
      warnings,
    )) {
      try {
        if (!_belongs(row, request)) {
          throw const FormatException('Identity mismatch');
        }
        if (source == 'muse_eeg' && row['eegCount'] == 0) {
          continue;
        }
        final received = DateTime.parse(row['received_utc'] as String);
        final host = received.difference(origin).inMicroseconds / 1000000;
        if (host < start - 10 || host > end + 10) {
          continue;
        }
        final key = '${row['recording_segment']}:${row['continuity_segment']}';
        var broken =
            key != previousSegment ||
            (previousReceipt != null &&
                (received.isBefore(previousReceipt) ||
                    received.difference(previousReceipt) >
                        const Duration(seconds: 2)));
        final target = source == 'muse_eeg' ? eeg : ecg;
        final rate =
            (row[source == 'muse_eeg' ? 'eeg_rate_hz' : 'sample_rate_hz']
                    as num)
                .toInt();
        if (rate <= 0 || rate > 512) {
          throw const FormatException('Unsupported rate');
        }
        final Map<String, List<double>> channels;
        double frameEnd = host;
        if (source == 'h10_ecg') {
          final raw = List<int>.from(row['raw_frame'] as List);
          final decoded = H10EcgProtocol.decode(raw, received, rate);
          final sensor = decoded.sensorNanoseconds;
          if (previousSensor != null &&
              (sensor <= previousSensor ||
                  sensor - previousSensor > BigInt.from(2000000000))) {
            broken = true;
          }
          if (broken || anchorSensor == null) {
            anchorSensor = sensor;
            anchorHost = host;
          }
          frameEnd =
              anchorHost + (sensor - anchorSensor).toDouble() / 1000000000;
          previousSensor = sensor;
          channels = {'ECG': decoded.samples.map((v) => v.toDouble()).toList()};
        } else {
          final input = row['eeg'] as Map;
          if (input.length > 16) {
            throw const FormatException('Unsupported channels');
          }
          channels = {
            for (final entry in input.entries)
              entry.key as String: List<num>.from(entry.value as List)
                  .map((v) => v.toDouble())
                  .toList(),
          };
        }
        if (broken) {
          for (final points in target.values) {
            points.add((host, double.nan));
          }
        }
        previousSegment = key;
        previousReceipt = received;
        for (final channel in channels.entries) {
          if (channel.value.length > 10000 ||
              channel.value.any((v) => !v.isFinite)) {
            throw const FormatException('Invalid samples');
          }
          final points = target.putIfAbsent(channel.key, () => []);
          for (var i = 0; i < channel.value.length; i++) {
            final time = frameEnd - (channel.value.length - 1 - i) / rate;
            if (time < start || time > end) {
              continue;
            }
            if (++count > 50000) {
              break;
            }
            points.add((time, channel.value[i]));
          }
        }
        if (count > 50000) {
          break;
        }
      } catch (_) {
        bad++;
        previousSegment = null;
      }
    }
  }
  if (count > 50000) {
    warnings.add('Replay limited to 50,000 points; select a shorter interval');
  }
  if (bad > 0) {
    warnings.add('$bad replay batches omitted: identity/format/settings');
  }
  return ReplayReview(eeg, ecg, warnings);
}
