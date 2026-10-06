import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Definitions travel with every answer; equal numbers are not equal questions.
enum FeedbackQuestion {
  goal(
    'goal_closeness',
    'How close do you feel to your desired state?',
    'Very far away',
    'Fully there',
  ),
  anxiety('anxiety', 'How anxious do you feel?', 'None', 'Extreme'),
  energy('energy', 'How much energy do you feel?', 'None', 'Very high');

  const FeedbackQuestion(this.id, this.label, this.low, this.high);
  final String id, label, low, high;
  Map<String, dynamic> toJson() => {
    'id': id,
    'version': 1,
    'text': label,
    'minimum': 0,
    'maximum': 10,
    'low_label': low,
    'high_label': high,
  };
}

class SessionContext {
  const SessionContext({
    this.purpose = 'personal_tracking',
    this.type = 'monitoring',
    this.desiredState = '',
    this.question = FeedbackQuestion.goal,
  });
  final String purpose, type, desiredState;
  final FeedbackQuestion question;
  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'purpose': purpose,
    'session_type': type,
    'desired_state': desiredState.trim().isEmpty ? null : desiredState.trim(),
    'rating_question': question.toJson(),
  };
}

/// Ratings are separate from raw acquisition and remain append-only after Stop.
class StateFeedbackStore {
  StateFeedbackStore(this.directory, this.sessionId);
  final Directory directory;
  final String sessionId;
  static final Map<String, Future<void>> _writes = {};
  File get _file => File('${directory.path}/state_feedback.jsonl');

  Future<List<Map<String, dynamic>>> read() async {
    final kind = await FileSystemEntity.type(_file.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      return [];
    }
    if (kind != FileSystemEntityType.file) {
      throw const FormatException('Invalid feedback journal');
    }
    final rows = <Map<String, dynamic>>[];
    for (final line in await _file.readAsLines()) {
      if (line.trim().isEmpty) {
        continue;
      }
      final row = jsonDecode(line);
      if (row is! Map<String, dynamic> ||
          row['schema_version'] != 1 ||
          row['session_id'] != sessionId ||
          row['value'] is! int ||
          (row['value'] as int) < 0 ||
          (row['value'] as int) > 10 ||
          row['question'] is! Map ||
          !const ['pre', 'during', 'post', 'followup'].contains(row['phase'])) {
        throw const FormatException(
          'Unsupported or corrupt feedback journal; original preserved',
        );
      }
      rows.add(row);
    }
    return rows;
  }

  Future<void> add({
    required FeedbackQuestion question,
    required int value,
    required String phase,
    required String source,
    String? participantId,
    String? desiredState,
    DateTime? eventAt,
    DateTime? enteredAt,
  }) async {
    if (value < 0 ||
        value > 10 ||
        !const ['pre', 'during', 'post', 'followup'].contains(phase)) {
      throw ArgumentError('Invalid state rating');
    }
    if (question == FeedbackQuestion.goal &&
        (desiredState ?? '').trim().isEmpty) {
      throw ArgumentError('Select a desired state for a goal rating');
    }
    final entered = (enteredAt ?? DateTime.now()).toUtc();
    final event = (eventAt ?? entered).toUtc();
    if (event.isAfter(entered)) {
      throw ArgumentError('Rating time cannot be in the future');
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final row = {
      'schema_version': 1,
      'event': 'state_rating',
      'event_id': id,
      'session_id': sessionId,
      'participant_id': ?participantId,
      'question': question.toJson(),
      'value': value,
      'phase': phase,
      'desired_state': desiredState,
      'event_utc': event.toIso8601String(),
      'entered_utc': entered.toIso8601String(),
      'received_utc': event.toIso8601String(),
      'retrospective': event != entered,
      'source': source,
    };
    final key = _file.absolute.path;
    final operation = (_writes[key] ?? Future<void>.value()).then((_) async {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError('Session directory unavailable');
      }
      final manifestFile = File('${directory.path}/manifest.json');
      if (await FileSystemEntity.type(manifestFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('Invalid session manifest');
      }
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      if (manifest['session_id'] != sessionId) {
        throw const FormatException('Session identity mismatch');
      }
      await read(); // Never append over unreadable or foreign records.
      await _file.writeAsString(
        '${jsonEncode(row)}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    final tail = operation.catchError((Object _) {});
    _writes[key] = tail;
    try {
      await operation;
    } finally {
      if (identical(_writes[key], tail)) {
        _writes.remove(key);
      }
    }
  }
}
