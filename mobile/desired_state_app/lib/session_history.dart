import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import 'rr_history.dart';
import 'session_archive.dart';
import 'processing.dart';

typedef JsonRow = Map<String, dynamic>;

/// Dates are inclusive local calendar days; identity remains the saved snapshot.
class HistoryFilter {
  const HistoryFilter({this.user, this.identifier = '', this.from, this.to});
  final String? user;
  final String identifier;
  final DateTime? from, to;
  bool matches(HistoryEntry entry) {
    if (user != null && entry.participant != user) return false;
    final id = identifier.trim().toLowerCase();
    if (id.isNotEmpty &&
        !entry.id.toLowerCase().contains(id) &&
        !entry.device.toLowerCase().contains(id)) {
      return false;
    }
    if (from != null || to != null) {
      final date = entry.started?.toLocal();
      if (date == null) return false;
      if (from != null &&
          date.isBefore(DateTime(from!.year, from!.month, from!.day))) {
        return false;
      }
      if (to != null &&
          !date.isBefore(DateTime(to!.year, to!.month, to!.day + 1))) {
        return false;
      }
    }
    return true;
  }
}

class HistoryMetadata {
  HistoryMetadata({
    required this.description,
    required this.notes,
    required this.tags,
    Map<String, String>? eventNotes,
  }) : eventNotes = eventNotes ?? {};
  final String description;
  final String notes;
  final List<String> tags;
  final Map<String, String> eventNotes;
  JsonRow toJson() => {
    'description': description,
    'notes': notes,
    'outcome_tags': tags,
    'event_notes': eventNotes,
  };
  factory HistoryMetadata.fromJson(JsonRow row) {
    if (row['description'] is! String ||
        row['notes'] is! String ||
        row['outcome_tags'] is! List ||
        row['event_notes'] is! Map) {
      throw const FormatException('Invalid annotation metadata');
    }
    return HistoryMetadata(
      description: row['description'] as String,
      notes: row['notes'] as String,
      tags: List<String>.from(row['outcome_tags'] as List),
      eventNotes: Map<String, String>.from(row['event_notes'] as Map),
    );
  }
}

class HistoryEntry {
  HistoryEntry(
    this.directory,
    this.manifest,
    this.events,
    this.metadata,
    this.revisions,
    this.warnings,
    this.editsReadable,
    this.markerNoteLine,
  );
  final Directory directory;
  final JsonRow manifest;
  final List<JsonRow> events;
  final HistoryMetadata metadata;
  final List<JsonRow> revisions;
  final List<String> warnings;
  final bool editsReadable;
  final int markerNoteLine;
  String get id =>
      manifest['session_id']?.toString() ??
      directory.uri.pathSegments.where((s) => s.isNotEmpty).last;
  String get participant => (manifest['assignments'] is Map)
      ? (manifest['assignments'] as Map).values.toSet().join(', ')
      : 'Unknown participant';
  String get device => (manifest['assignments'] is Map)
      ? (manifest['assignments'] as Map).keys.join(', ')
      : 'Unknown device';
  DateTime? get started => DateTime.tryParse('${manifest['started_utc']}');
  bool get readable =>
      manifest['schema_version'] == 1 && manifest['session_id'] is String;
  bool get ended => events.any((row) => row['event'] == 'session_ended');
  String eventId(JsonRow row) =>
      row['event_id']?.toString() ?? 'legacy-event-${row['_line']}';
}

class HistoryPoint {
  const HistoryPoint(this.time, this.value, this.segment, {this.sourceIndex});
  final DateTime time;
  final double? value;
  final int segment;
  final int? sourceIndex;
}

class HistoryRr {
  const HistoryRr(
    this.row,
    this.time,
    this.value,
    this.segment,
    this.accepted,
    this.reason,
    this.rawRmssd,
    this.screenedRmssd,
  );
  final JsonRow row;
  final DateTime time;
  final double value;
  final int segment;
  final bool accepted;
  final String? reason;
  final double? rawRmssd;
  final double? screenedRmssd;
}

class HistorySession {
  HistorySession(this.entry, this.hr, this.rr, this.warnings);
  final HistoryEntry entry;
  final List<HistoryPoint> hr;
  final List<HistoryRr> rr;
  final List<String> warnings;
  List<HistoryPoint> rrSeries(bool screened) => [
    for (final (i, sample) in rr.indexed)
      HistoryPoint(
        sample.time,
        screened && !sample.accepted ? null : sample.value,
        sample.segment,
        sourceIndex: i,
      ),
  ];
  List<HistoryPoint> rmssdSeries(bool screened) => [
    for (final (i, sample) in rr.indexed)
      HistoryPoint(
        sample.time,
        screened ? sample.screenedRmssd : sample.rawRmssd,
        sample.segment,
        sourceIndex: i,
      ),
  ];
}

class SessionHistoryRepository {
  SessionHistoryRepository({this.directoryProvider, this.activeSessionId});
  final Future<Directory> Function()? directoryProvider;
  final String? Function()? activeSessionId;
  Future<void> _operations = Future.value();
  bool isActive(String id) => activeSessionId?.call() == id;
  Future<Directory> _root() async => Directory(
    '${(await (directoryProvider ?? getApplicationDocumentsDirectory)()).path}/desired_state_sessions',
  );

  Future<List<HistoryEntry>> list() async {
    final root = await _root();
    if (!await root.exists()) return [];
    final result = <HistoryEntry>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory) result.add(await readEntry(entity));
    }
    result.sort(
      (a, b) =>
          (b.started ?? DateTime(1970)).compareTo(a.started ?? DateTime(1970)),
    );
    return result;
  }

  Future<List<JsonRow>> _rows(
    Directory dir,
    String name,
    List<String> warnings, {
    bool required = false,
  }) async {
    final file = File('${dir.path}/$name.jsonl');
    if (!await file.exists()) {
      if (required) warnings.add('Missing $name.jsonl');
      return [];
    }
    final result = <JsonRow>[];
    var lineNumber = 0;
    try {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        lineNumber++;
        if (line.trim().isEmpty) continue;
        try {
          final value = jsonDecode(line);
          if (value is! Map<String, dynamic>) throw const FormatException();
          result.add({...value, '_line': lineNumber});
        } catch (_) {
          warnings.add(
            '$name.jsonl: unreadable row $lineNumber (possibly interrupted)',
          );
          // A missing RR row must also break derived adjacency.
          result.add({'_line': lineNumber, '_invalid': true});
        }
      }
    } catch (error) {
      warnings.add('Cannot read $name.jsonl: $error');
    }
    return result;
  }

  Future<HistoryEntry> readEntry(Directory dir) async {
    final warnings = <String>[];
    JsonRow manifest = {};
    try {
      manifest = jsonDecode(
        await File('${dir.path}/manifest.json').readAsString(),
      ) as JsonRow;
      if (manifest['schema_version'] != 1 ||
          manifest['session_id'] is! String) {
        warnings.add('Unsupported or invalid manifest');
      }
    } catch (error) {
      warnings.add('Cannot read manifest: $error');
    }
    final events = await _rows(dir, 'events', warnings, required: true);
    final notes = await _rows(dir, 'marker_notes', warnings);
    var metadata = HistoryMetadata(
      description: manifest['description']?.toString() ?? '',
      notes: events
          .where((r) => r['event'] == 'session_outcome')
          .map((r) => r['description'] ?? '')
          .join('\n'),
      tags: [],
    );
    for (final event in events) {
      if (event['event'] == 'marked_event' &&
          event['marker_type'] != 'quick' &&
          event['description'] is String) {
        metadata.eventNotes[event['event_id']?.toString() ??
                'legacy-event-${event['_line']}'] =
            event['description'] as String;
      }
    }
    for (final note in notes) {
      if (note['event_id'] is String && note['description'] is String) {
        final id = note['event_id'] as String;
        metadata.eventNotes[id] = [
          metadata.eventNotes[id],
          note['description'],
        ].whereType<String>().join('\n');
      }
    }
    final editWarnings = <String>[];
    final edits = await _rows(dir, 'history_edits', editWarnings);
    int? notesThrough;
    for (final edit in edits) {
      try {
        if (edit['schema_version'] != 1 ||
            edit['session_id'] != manifest['session_id']) {
          throw const FormatException();
        }
        metadata = HistoryMetadata.fromJson(
          Map<String, dynamic>.from(edit['values'] as Map),
        );
        notesThrough = edit['marker_notes_through_line'] as int? ?? 0;
      } catch (_) {
        editWarnings.add(
          'Unreadable/unsupported history edit at row ${edit['_line']}',
        );
      }
    }
    // Notes can still be added from the last recording's Events screen.
    // Preserve additions made after the latest history snapshot.
    if (notesThrough != null) {
      for (final note in notes) {
        if ((note['_line'] as int) > notesThrough &&
            note['event_id'] is String &&
            note['description'] is String) {
          final id = note['event_id'] as String;
          metadata.eventNotes[id] = [
            metadata.eventNotes[id],
            note['description'],
          ].whereType<String>().where((s) => s.isNotEmpty).join('\n');
        }
      }
    }
    warnings.addAll(editWarnings);
    for (final name in ['measurements', 'rr']) {
      if (!await File('${dir.path}/$name.jsonl').exists()) {
        warnings.add('Missing $name.jsonl');
      }
    }
    return HistoryEntry(
      dir,
      manifest,
      events,
      metadata,
      edits,
      warnings,
      editWarnings.isEmpty,
      notes.isEmpty ? 0 : notes.last['_line'] as int,
    );
  }

  Future<HistorySession> open(HistoryEntry entry) async {
    entry = await readEntry(entry.directory);
    if (!entry.readable) {
      throw const FormatException('This session manifest cannot be opened');
    }
    if (entry.manifest['assignments'] is! Map ||
        (entry.manifest['assignments'] as Map).length != 1) {
      throw const FormatException(
        'History MVP supports one device per session',
      );
    }
    final warnings = List<String>.of(entry.warnings);
    final rrRows = await _rows(entry.directory, 'rr', warnings, required: true);
    final hrRows = await _rows(
      entry.directory,
      'measurements',
      warnings,
      required: true,
    );
    final breaks =
        entry.events
            .where(
              (row) => const {
                'session_paused',
                'session_resumed',
                'bluetooth_disconnected',
                'measurement_gap',
                'measurement_stale',
                'bluetooth_manual_disconnect',
              }.contains(row['event']),
            )
            .map((r) => DateTime.tryParse('${r['received_utc']}'))
            .whereType<DateTime>()
            .toList()
          ..sort();
    final continuity = _Continuity(breaks);
    final filter = RrHistory();
    final rr = <HistoryRr>[];
    final rawWindow = <(double, int)>[];
    for (final row in rrRows) {
      final time = DateTime.tryParse('${row['received_utc']}');
      final value = row['rr_ms'];
      if (time == null ||
          value is! num ||
          !value.isFinite ||
          !_belongs(row, entry)) {
        warnings.add(
          'RR row ${row['_line']} omitted from analysis: invalid value/time/identity',
        );
        continuity.forceBreak();
        filter.breakSequence();
        continue;
      }
      final segment = continuity.next(time, row['continuity_segment']);
      if (rr.isNotEmpty && segment != rr.last.segment) filter.breakSequence();
      final sample = filter.addAll([value.toDouble()]).single;
      rawWindow.add((value.toDouble(), segment));
      if (rawWindow.length > 60) rawWindow.removeAt(0);
      rr.add(
        HistoryRr(
          row,
          time,
          value.toDouble(),
          segment,
          sample.accepted,
          sample.artifactReason,
          _rawRmssd(rawWindow),
          filter.rmssd,
        ),
      );
    }
    final hrContinuity = _Continuity(breaks);
    final hr = <HistoryPoint>[];
    for (final row in hrRows) {
      final time = DateTime.tryParse('${row['received_utc']}');
      final value = row['heart_rate_bpm'];
      if (time == null ||
          value is! num ||
          !value.isFinite ||
          !_belongs(row, entry)) {
        warnings.add(
          'HR row ${row['_line']} omitted from analysis: invalid value/time/identity',
        );
        hrContinuity.forceBreak();
        continue;
      }
      hr.add(
        HistoryPoint(
          time,
          value.toDouble(),
          hrContinuity.next(time, row['continuity_segment']),
        ),
      );
    }
    return HistorySession(entry, hr, rr, warnings.toSet().toList());
  }

  bool _belongs(JsonRow row, HistoryEntry entry) =>
      (row['session_id'] == null || row['session_id'] == entry.id) &&
      (row['polar_id'] == null || row['polar_id'] == entry.device) &&
      (row['user_id'] == null || row['user_id'] == entry.participant);

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _operations.then((_) => action());
    _operations = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> _checkWritable(HistoryEntry entry) async {
    final root = await (await _root()).resolveSymbolicLinks();
    final actual = await entry.directory.resolveSymbolicLinks();
    if (Directory(actual).parent.path.toLowerCase() != root.toLowerCase()) {
      throw StateError('Not a local session directory');
    }
    if (isActive(entry.id)) {
      throw StateError('Stop this session before editing or exporting it');
    }
    if (!entry.readable || !entry.editsReadable) {
      throw StateError('Unreadable metadata; preserve files before repairing');
    }
    if (await FileSystemEntity.type(
          '${entry.directory.path}/history_edits.jsonl',
          followLinks: false,
        ) ==
        FileSystemEntityType.link) {
      throw StateError('Linked annotation files are not supported');
    }
  }

  Future<HistoryEntry> saveMetadata(
    HistoryEntry entry,
    HistoryMetadata values,
  ) => _serial(() async {
    final latest = await readEntry(entry.directory);
    await _checkWritable(latest);
    if (latest.revisions.length != entry.revisions.length ||
        jsonEncode(latest.metadata.toJson()) !=
            jsonEncode(entry.metadata.toJson())) {
      throw StateError('Session changed; reload before saving');
    }
    final edit = {
      'schema_version': 1,
      'session_id': latest.id,
      'edited_utc': DateTime.now().toUtc().toIso8601String(),
      'marker_notes_through_line': latest.markerNoteLine,
      'previous': latest.metadata.toJson(),
      'values': values.toJson(),
    };
    await File('${entry.directory.path}/history_edits.jsonl').writeAsString(
      '${jsonEncode(edit)}\n',
      mode: FileMode.append,
      flush: true,
    );
    return readEntry(entry.directory);
  });

  Future<File> export(HistoryEntry entry) => _serial(() async {
    final latest = await readEntry(entry.directory);
    await _checkWritable(latest);
    return exportSessionDirectory(entry.directory);
  });

  Future<void> recordProcessingView(
    HistoryEntry entry,
    ProcessingConfig config,
  ) => _serial(() async {
    config.validate();
    await _checkWritable(await readEntry(entry.directory));
    final file = File('${entry.directory.path}/processing_views.jsonl');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Linked processing journals are not supported');
    }
    final warnings = <String>[];
    final previous = await _rows(entry.directory, 'processing_views', warnings);
    if (warnings.isNotEmpty ||
        previous.any(
          (r) => r['schema_version'] != 1 || r['session_id'] != entry.id,
        )) {
      throw StateError('Unreadable processing journal; original preserved');
    }
    await file.writeAsString(
      '${jsonEncode({'schema_version': 1, 'session_id': entry.id, 'viewed_utc': DateTime.now().toUtc().toIso8601String(), 'configuration': config.toJson()})}\n',
      mode: FileMode.append,
      flush: true,
    );
  });
}

class _Continuity {
  _Continuity(this.breaks);
  final List<DateTime> breaks;
  DateTime? previous;
  Object? previousSegment;
  int segment = 0;
  int breakIndex = 0;
  void forceBreak() {
    segment++;
  }

  int next(DateTime time, Object? sourceSegment) {
    var eventBreak = false;
    while (breakIndex < breaks.length && !breaks[breakIndex].isAfter(time)) {
      if (previous != null && breaks[breakIndex].isAfter(previous!)) {
        eventBreak = true;
      }
      breakIndex++;
    }
    if (previous != null &&
        (eventBreak ||
            time.isBefore(previous!) ||
            time.difference(previous!) >= const Duration(seconds: 10) ||
            sourceSegment != previousSegment)) {
      segment++;
    }
    previous = time;
    previousSegment = sourceSegment;
    return segment;
  }
}

double? _rawRmssd(List<(double, int)> values) {
  var count = 0;
  var pairs = 0;
  var squares = 0.0;
  for (var i = 0; i < values.length; i++) {
    if (values[i].$1 <= 0) continue;
    count++;
    if (i > 0 && values[i - 1].$1 > 0 && values[i].$2 == values[i - 1].$2) {
      final difference = values[i].$1 - values[i - 1].$1;
      squares += difference * difference;
      pairs++;
    }
  }
  return count >= 3 && pairs > 0 && squares.isFinite
      ? math.sqrt(squares / pairs)
      : null;
}
