import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'session_archive.dart';

class SessionLogger {
  SessionLogger._(
    this.directory,
    this.sessionId,
    this.polarId,
    this.participantName,
  );

  final Directory directory;
  final String sessionId;
  final String polarId;
  final String participantName;
  Future<void> _writes = Future.value();
  Future<void> _annotationWrites = Future.value();
  final Map<String, IOSink> _sinks = {};
  Timer? _flushTimer;
  int _pendingRows = 0;
  bool _closed = false;

  static Future<SessionLogger> start({
    required String polarId,
    required String deviceName,
    required String participantName,
    String description = '',
    Future<Directory> Function()? directoryProvider,
    DateTime? startedAt,
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
    );
    await logger._writeJson('manifest.json', {
      'schema_version': 1,
      'session_id': id,
      'source': 'desired_state_flutter',
      'description': description.trim(),
      'rr_processing': 'mobile-median9-25pct-300-2000-v1',
      'continuity_version': 1,
      'continuity_description': 'Never pair RR across continuity_segment changes; receipt UTC is not beat time.',
      'assignments': {polarId.toUpperCase(): participantName},
      'devices': {
        polarId.toUpperCase(): {
          'name': deviceName,
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

  Future<void> writeEvent(
    String event, {
    String? description,
    DateTime? receivedAt,
    String? eventId,
    String? markerDefinitionId,
    String? markerLabel,
    String? markerType,
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
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
      });
      if (flush) await _flushSinks();
    });
  }

  /// Append-only annotations can be added after Stop without reopening raw sinks.
  Future<void> addMarkerNote(String eventId, String note) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    if (note.trim().isEmpty) throw ArgumentError('Enter a note');
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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
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
    for (final stream in ['events', 'measurements', 'rr']) {
      _sinks[stream] = File(
        '${directory.path}${Platform.pathSeparator}$stream.jsonl',
      ).openWrite(mode: FileMode.append);
    }
  }

  Future<void> _flushSinks() async {
    if (_sinks.isEmpty || _pendingRows == 0) return;
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
