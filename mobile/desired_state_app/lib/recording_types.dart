import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

class RecordingType {
  const RecordingType(
    this.id,
    this.name,
    this.definition, {
    this.version = 1,
    this.archived = false,
  });
  final String id, name, definition;
  final int version;
  final bool archived;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'definition': definition,
    'version': version,
    'archived': archived,
  };
  static RecordingType parse(dynamic row) {
    if (row is! Map ||
        row['id'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(row['id'] as String) ||
        row['name'] is! String ||
        (row['name'] as String).trim().isEmpty ||
        (row['name'] as String).length > 80 ||
        row['definition'] is! String ||
        (row['definition'] as String).length > 2000 ||
        row['version'] is! int ||
        row['version'] < 1 ||
        row['archived'] is! bool) {
      throw const FormatException('Invalid recording type; original preserved');
    }
    return RecordingType(
      row['id'] as String,
      row['name'] as String,
      row['definition'] as String,
      version: row['version'] as int,
      archived: row['archived'] as bool,
    );
  }
}

const defaultRecordingTypes = [
  RecordingType(
    'sleep',
    'Sleep',
    'Recording during an intended sleep period, including awakenings. Sleep stages are analysis results, not implied by this category.',
  ),
  RecordingType(
    'daily',
    'Daily recording',
    'General daily monitoring across activities; activity markers describe changes.',
  ),
  RecordingType(
    'breathwork',
    'Breathwork',
    'A recording focused on breathing practice; technique and phases may be marked separately.',
  ),
  RecordingType(
    'exercise',
    'Exercise',
    'A recording focused on physical activity; activity markers identify the exercise.',
  ),
  RecordingType(
    'meditation',
    'Meditation',
    'A recording focused on meditation practice.',
  ),
  RecordingType(
    'research',
    'Research or test',
    'Exploratory or protocol-based data collection. The category alone does not establish a controlled experiment.',
  ),
];

/// Phone-owned, append-only definitions. Each recording carries its own snapshot.
class RecordingTypeStore {
  RecordingTypeStore({this.directoryProvider});
  final Future<Directory> Function()? directoryProvider;
  static Future<void>? _writes;
  Future<File> _file() async => File(
    '${(await (directoryProvider ?? getApplicationDocumentsDirectory)()).path}/recording_types.jsonl',
  );
  Future<Map<String, RecordingType>> _read() async {
    final result = {for (final type in defaultRecordingTypes) type.id: type};
    final file = await _file();
    if (!await file.exists()) {
      return result;
    }
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) {
        continue;
      }
      final type = RecordingType.parse(jsonDecode(line));
      final previous = result[type.id];
      if (previous != null && type.version <= previous.version) {
        throw const FormatException(
          'Recording type revision is not increasing',
        );
      }
      result[type.id] = type;
    }
    return result;
  }

  Future<Map<String, RecordingType>> list() async {
    final pending = _writes;
    if (pending != null) {
      await pending;
    }
    return _read();
  }

  Future<RecordingType> save(
    String name,
    String definition, {
    String? id,
    bool archived = false,
  }) {
    final operation = (_writes ?? Future<void>.value()).then((_) async {
      final types = await _read();
      if (id != null && !types.containsKey(id)) {
        throw const FormatException('Recording type is missing');
      }
      final random = Random.secure();
      final key =
          id ??
          'custom_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      final value = RecordingType.parse(
        RecordingType(
          key,
          name.trim(),
          definition.trim(),
          version: (types[key]?.version ?? 0) + 1,
          archived: archived,
        ).toJson(),
      );
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(value.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      return value;
    });
    late final Future<void> tail;
    void release() {
      if (identical(_writes, tail)) {
        _writes = null;
      }
    }

    tail = operation.then<void>(
      (_) => release(),
      onError: (Object _) => release(),
    );
    _writes = tail;
    return operation;
  }

  Future<String?> lastSelection() async {
    final file = File(
      '${(await _file()).parent.path}/recording_type_selection.json',
    );
    if (!await file.exists()) {
      return null;
    }
    final row = jsonDecode(await file.readAsString());
    if (row is! Map ||
        row['version'] != 1 ||
        (row['id'] != null && row['id'] is! String)) {
      throw const FormatException('Invalid recording type preference');
    }
    return row['id'] as String?;
  }

  Future<void> select(String? id) async {
    if (id != null && !(await list()).containsKey(id)) {
      throw const FormatException('Unknown recording type');
    }
    final file = File(
      '${(await _file()).parent.path}/recording_type_selection.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'version': 1, 'id': id}), flush: true);
  }
}

String recordingTypeId(Map<String, dynamic> manifest) {
  final context = manifest['session_context'];
  final type = context is Map ? context['recording_type'] : null;
  return type is Map && type['id'] is String
      ? type['id'] as String
      : 'unspecified';
}

String recordingTypeLabel(Map<String, dynamic> manifest) {
  final context = manifest['session_context'];
  final type = context is Map ? context['recording_type'] : null;
  return type is Map && type['name'] is String
      ? type['name'] as String
      : 'Unspecified';
}
