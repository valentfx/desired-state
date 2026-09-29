import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

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
  final Map<String, IOSink> _sinks = {};
  Timer? _flushTimer;
  int _pendingRows = 0;
  bool _closed = false;

  static Future<SessionLogger> start({
    required String polarId,
    required String deviceName,
    required String participantName,
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
          'artifact_accepted': interval.accepted,
          if (interval.artifactReason != null)
            'artifact_reason': interval.artifactReason,
        });
      }
    });
  }

  Future<void> writeEvent(String event, {String? description}) {
    return _enqueue(
      () => _appendJsonl('events', {
        'session_id': sessionId,
        'polar_id': polarId,
        'user_id': participantName,
        'event': event,
        'received_utc': DateTime.now().toUtc().toIso8601String(),
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
      }),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    await writeEvent('session_ended');
    await _writes;
    await _flushSinks();
    await Future.wait(_sinks.values.map((sink) => sink.close()));
  }

  /// Creates a portable copy of one completed session for a deliberate export.
  Future<File> createExportZip() async {
    await _writes;
    const fileNames = [
      'manifest.json',
      'events.jsonl',
      'measurements.jsonl',
      'rr.jsonl',
    ];
    final archive = Archive();
    for (final name in fileNames) {
      final source = File('${directory.path}${Platform.pathSeparator}$name');
      if (!await source.exists()) continue;
      final bytes = await source.readAsBytes();
      archive.addFile(ArchiveFile('$sessionId/$name', bytes.length, bytes));
    }
    final encoded = ZipEncoder().encodeBytes(archive);
    final exportDirectory = Directory(
      '${directory.parent.parent.path}${Platform.pathSeparator}desired_state_exports',
    );
    await exportDirectory.create(recursive: true);
    final output = File(
      '${exportDirectory.path}${Platform.pathSeparator}$sessionId.zip',
    );
    await output.writeAsBytes(encoded, flush: true);
    return output;
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
