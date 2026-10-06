import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'session_archive.dart';
import 'state_feedback.dart';
import 'device_models.dart';
import 'h10_accelerometer.dart';
import 'h10_ecg.dart';

class SessionLogger {
  SessionLogger._(
    this.directory,
    this.sessionId,
    this.polarId,
    this.participantName,
    this.participantId,
  );

  final Directory directory;
  final String sessionId;
  final String polarId;
  final String participantName;
  final String? participantId;
  Future<void> _writes = Future.value();
  Future<void> _annotationWrites = Future.value();
  final Map<String, IOSink> _sinks = {};
  Timer? _flushTimer;
  int _pendingRows = 0;
  bool _closed = false;
  DateTime? stoppedAt;

  static Future<SessionLogger> start({
    required String polarId,
    required String deviceName,
    required String participantName,
    String description = '',
    String? participantId,
    Future<Directory> Function()? directoryProvider,
    DateTime? startedAt,
    Map<String, dynamic>? additionalDevices,
    String primaryDeviceKind = 'polar_h10',
    SessionContext context = const SessionContext(),
  }) async {
    final documents =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    final timestamp = startedAt ?? DateTime.now().toUtc();
    final id =
        '${timestamp.toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 15)}_${polarId.toUpperCase()}';
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}desired_state_sessions${Platform.pathSeparator}$id',
    );
    await directory.create(recursive: true);
    final logger = SessionLogger._(
      directory,
      id,
      polarId.toUpperCase(),
      participantName,
      participantId,
    );
    await logger._writeJson('manifest.json', {
      'schema_version': 1,
      'session_id': id,
      'source': 'desired_state_flutter',
      'session_context': context.toJson(),
      'state_feedback_version': 1,
      'local_timezone_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
      'participant_id': ?participantId,
      'description': description.trim(),
      'rr_processing': 'mobile-median9-25pct-300-2000-v1',
      'continuity_version': 1,
      'continuity_description': 'Never pair RR across continuity_segment changes; receipt UTC is not beat time.',
      'assignments': {
        polarId.toUpperCase(): participantName,
        for (final id in (additionalDevices ?? {}).keys) id: participantName,
      },
      'auxiliary_streams_version': 1,
      'h10_ecg_stream_version': 1,
      'h10_ecg_units': 'microvolt',
      'h10_accelerometer_stream_version': 1,
      'h10_accelerometer_units': 'milli_g',
      'timestamp_provenance': 'host_receipt_utc',
      'devices': {
        ...?additionalDevices,
        polarId.toUpperCase(): {
          'name': deviceName,
          'kind': primaryDeviceKind,
          if (primaryDeviceKind == 'polar_h10')
            'polar_id': polarId.toUpperCase(),
        },
      },
      'started_utc': timestamp.toIso8601String(),
    });
    logger._openStreams();
    logger._flushTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(logger._enqueue(logger._flushSinks)),
    );
    await logger.writeEvent('session_started');
    return logger;
  }

  /// Attach a previously absent sensor without replacing the primary identity.
  Future<void> registerDevice({
    required String deviceId,
    required String name,
    required String kind,
  }) {
    if (_closed) {
      throw StateError('Session has already stopped');
    }
    return _enqueue(() async {
      final file = File('${directory.path}/manifest.json');
      final manifest =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final devices = Map<String, dynamic>.from(manifest['devices'] as Map);
      if (devices.containsKey(deviceId)) {
        return;
      }
      devices[deviceId] = {'name': name, 'kind': kind};
      final assignments = Map<String, dynamic>.from(
        manifest['assignments'] as Map,
      );
      assignments[deviceId] = participantName;
      manifest['devices'] = devices;
      manifest['assignments'] = assignments;
      await _writeJson('manifest.json', manifest);
      await _appendJsonl('events', {
        'session_id': sessionId,
        'polar_id': polarId,
        'user_id': participantName,
        'event': 'device_attached',
        'received_utc': DateTime.now().toUtc().toIso8601String(),
        'device_id': deviceId,
        'sensor_kind': kind,
        'description': name,
      });
      await _flushSinks();
    });
  }

  Future<void> logMeasurement({
    required String polarId,
    required String participantName,
    required int heartRate,
    required List<LoggedRr> intervals,
    required DateTime receivedAt,
    int? continuitySegment,
  }) {
    return _enqueue(() async {
      final stamp = receivedAt.toUtc().toIso8601String();
      await _appendJsonl('measurements', {
        'session_id': sessionId,
        'polar_id': polarId,
        'user_id': participantName,
        'received_utc': stamp,
        'heart_rate_bpm': heartRate,
        'rr_count': intervals.length,
        'continuity_segment': ?continuitySegment,
      });
      for (var index = 0; index < intervals.length; index++) {
        final interval = intervals[index];
        await _appendJsonl('rr', {
          'session_id': sessionId,
          'polar_id': polarId,
          'user_id': participantName,
          'received_utc': stamp,
          'rr_index': index,
          'rr_ms': interval.rrMs,
          'continuity_segment': ?continuitySegment,
          'artifact_accepted': interval.accepted,
          if (interval.artifactReason != null)
            'artifact_reason': interval.artifactReason,
        });
      }
    });
  }

  Future<void> logEcg({
    required String deviceId,
    required H10EcgFrame frame,
    required int segment,
  }) => _enqueue(
    () => _appendJsonl('h10_ecg', {
      ...frame.toJson(),
      'session_id': sessionId,
      'polar_id': deviceId,
      'user_id': participantName,
      'continuity_segment': segment,
    }),
  );

  Future<void> logAcceleration({
    required String deviceId,
    required H10Acceleration frame,
    required int segment,
  }) => _enqueue(
    () => _appendJsonl('h10_accelerometer', {
      ...frame.toJson(),
      'session_id': sessionId,
      'polar_id': deviceId,
      'user_id': participantName,
      'continuity_segment': segment,
    }),
  );

  Future<void> logPmdPacket({
    required String deviceId,
    required RawBlePacket packet,
  }) => _enqueue(
    () => _appendJsonl('h10_pmd_raw', {
      'schema_version': 1,
      'session_id': sessionId,
      'polar_id': deviceId,
      'user_id': participantName,
      'received_utc': packet.receivedAt.toUtc().toIso8601String(),
      'direction': packet.direction.name,
      'characteristic': packet.characteristic,
      'bytes': packet.bytes,
      'hex': packet.hex,
    }),
  );

  Future<void> logO2RingReading({
    required String deviceId,
    required String deviceName,
    required O2RingReading reading,
  }) => _enqueue(
    () => _appendJsonl('o2ring_measurements', {
      'schema_version': 1,
      'session_id': sessionId,
      'user_id': participantName,
      'device_id': deviceId,
      'device_name': deviceName,
      'sensor_kind': 'wellue_o2ring',
      'received_utc': reading.receivedAt.toUtc().toIso8601String(),
      'timestamp_provenance': 'host_receipt_utc_frame_complete',
      'decoder_version': reading.decoderVersion,
      'spo2_percent': reading.spo2,
      'pulse_bpm': reading.pulse,
      'battery_percent': reading.battery,
      'motion_raw': reading.motion,
      'perfusion_index_raw': reading.perfusionIndexRaw,
      'worn_code': reading.wornCode,
      'worn': reading.worn,
      'usable': reading.usable,
      'raw_frame': reading.rawFrame,
      'crc_valid': reading.rawFrame.isEmpty ? null : true,
    }),
  );

  Future<void> logO2RingPacket({
    required String deviceId,
    required RawBlePacket packet,
  }) => _enqueue(
    () => _appendJsonl('o2ring_raw', {
      'schema_version': 1,
      'session_id': sessionId,
      'user_id': participantName,
      'device_id': deviceId,
      'received_utc': packet.receivedAt.toUtc().toIso8601String(),
      'timestamp_provenance': 'host_receipt_utc',
      'direction': packet.direction.name,
      'characteristic': packet.characteristic,
      'bytes': packet.bytes,
      'hex': packet.hex,
    }),
  );

  Future<void> logMuseBatch(Map<String, dynamic> batch) => _enqueue(
    () => _appendJsonl('muse_eeg', {
      'schema_version': 1,
      'session_id': sessionId,
      'user_id': participantName,
      'device_id': 'MUSE_ATHENA',
      'sensor_kind': 'muse_s_athena',
      'timestamp_provenance': 'brainflow_timestamps_and_host_receipt_utc',
      'eeg_units': 'microvolt',
      ...batch,
    }),
  );

  Future<void> logEegBands(Map<String, dynamic> frame) => _enqueue(
    () => _appendJsonl('muse_bands', {
      ...frame,
      'schema_version': 1,
      'session_id': sessionId,
      'user_id': participantName,
      'device_id': 'MUSE_ATHENA',
      'units': 'microvolt_squared',
      'method': 'hann_periodogram_1_30hz_v1',
    }),
  );

  Future<void> writeEvent(
    String event, {
    String? description,
    DateTime? receivedAt,
    String? eventId,
    String? markerDefinitionId,
    String? markerLabel,
    String? markerType,
    String? activityId,
    bool flush = false,
  }) {
    final timestamp = (receivedAt ?? DateTime.now()).toUtc().toIso8601String();
    return _enqueue(() async {
      await _appendJsonl('events', {
        'session_id': sessionId,
        'polar_id': polarId,
        'user_id': participantName,
        'event': event,
        'received_utc': timestamp,
        'event_id': ?eventId,
        'marker_definition_id': ?markerDefinitionId,
        'marker_label': ?markerLabel,
        'marker_type': ?markerType,
        'activity_id': ?activityId,
        if (activityId != null) 'activity_action': 'mark',
        if (activityId != null) 'activity_schema_version': 1,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
      });
      if (flush) {
        await _flushSinks();
      }
    });
  }

  /// Append-only annotations can be added after Stop without reopening raw sinks.
  Future<void> addMarkerNote(String eventId, String note) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    if (note.trim().isEmpty) {
      throw ArgumentError('Enter a note');
    }
    final row = {
      'schema_version': 1,
      'event': 'marker_note_added',
      'event_id': eventId,
      'session_id': sessionId,
      'polar_id': polarId,
      'user_id': participantName,
      'received_utc': timestamp,
      'description': note.trim(),
    };
    final operation = _annotationWrites.then(
      (_) => File('${directory.path}/marker_notes.jsonl')
          .writeAsString(
            '${jsonEncode(row)}\n',
            mode: FileMode.append,
            flush: true,
          )
          .then((_) {}),
    );
    // Annotation failures must never interrupt raw recording or later notes.
    _annotationWrites = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> flush() => _enqueue(_flushSinks);

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    stoppedAt = DateTime.now().toUtc();
    _flushTimer?.cancel();
    await writeEvent('session_ended');
    await _writes;
    await _annotationWrites;
    await _flushSinks();
    await Future.wait(_sinks.values.map((sink) => sink.close()));
  }

  /// Creates a portable copy of one completed session for a deliberate export.
  Future<File> createExportZip() async {
    await _writes;
    await _annotationWrites;
    return exportSessionDirectory(directory);
  }

  Future<void> _writeJson(String name, Map<String, dynamic> row) {
    return File('${directory.path}${Platform.pathSeparator}$name')
        .writeAsString('${jsonEncode(row)}\n');
  }

  Future<void> _appendJsonl(String stream, Map<String, dynamic> row) {
    final sink = _sinks[stream];
    if (sink == null) {
      throw StateError('Session log stream is not open: $stream');
    }
    sink.writeln(jsonEncode(row));
    _pendingRows++;
    return _pendingRows >= 16 ? _flushSinks() : Future.value();
  }

  void _openStreams() {
    for (final stream in [
      'events',
      'measurements',
      'rr',
      'o2ring_measurements',
      'o2ring_raw',
      'h10_accelerometer',
      'h10_ecg',
      'h10_pmd_raw',
      'muse_eeg',
      'muse_bands',
    ]) {
      _sinks[stream] = File(
        '${directory.path}${Platform.pathSeparator}$stream.jsonl',
      ).openWrite(mode: FileMode.append);
    }
  }

  Future<void> _flushSinks() async {
    if (_sinks.isEmpty || _pendingRows == 0) {
      return;
    }
    await Future.wait(_sinks.values.map((sink) => sink.flush()));
    _pendingRows = 0;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    _writes = _writes.then((_) => operation());
    return _writes;
  }
}

class LoggedRr {
  const LoggedRr({
    required this.rrMs,
    required this.accepted,
    this.artifactReason,
  });

  final double rrMs;
  final bool accepted;
  final String? artifactReason;
}
