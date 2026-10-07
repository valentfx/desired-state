import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

class ParticipantProfile {
  const ParticipantProfile(this.id, this.name, this.info);
  final String id, name, info;
}

/// Append-only local profiles. Version-1 names retain deterministic IDs;
/// version-2 edits address IDs so renames never create a different person.
class ParticipantStore {
  ParticipantStore({this.directoryProvider});
  final Future<Directory> Function()? directoryProvider;
  // Keep only pending writes. Retaining a completed Future also retains its
  // creation zone, which can outlive a widget-test fake clock.
  static Future<void>? _writes;
  Future<File> _file() async {
    final root =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    return File('${root.path}/participants_v1.jsonl');
  }

  Future<Map<String, ParticipantProfile>> _read({
    Map<String, String>? aliases,
  }) async {
    final redirects = aliases ?? <String, String>{};
    final file = await _file();
    final values = <String, ParticipantProfile>{};
    if (!await file.exists()) return values;
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final row = jsonDecode(line);
      if (row is! Map ||
          (row['version'] != 1 && row['version'] != 2 && row['version'] != 3) ||
          row['name'] is! String ||
          row['info'] is! String ||
          (row['version'] != 1 &&
              (row['participant_id'] is! String ||
                  (row['participant_id'] as String).isEmpty))) {
        throw const FormatException(
          'Unreadable participant file; original preserved',
        );
      }
      final name = row['name'] as String;
      final id = row['version'] == 1
          ? 'legacy-${base64Url.encode(utf8.encode(name))}'
          : row['participant_id'] as String;
      if (row['version'] == 3) {
        final previous = row['previous_id'];
        if (previous is! String || previous.isEmpty || previous == id) {
          throw const FormatException('Invalid participant correction');
        }
        redirects[previous] = id;
        values.remove(previous);
      }
      var canonical = id;
      final seen = <String>{};
      while (redirects.containsKey(canonical)) {
        if (!seen.add(canonical)) {
          throw const FormatException('Participant correction cycle');
        }
        canonical = redirects[canonical]!;
      }
      values[canonical] = ParticipantProfile(
        canonical,
        name,
        row['info'] as String,
      );
    }
    return values;
  }

  Future<Map<String, ParticipantProfile>> profiles() async {
    final pending = _writes;
    if (pending != null) {
      await pending;
    }
    return _read();
  }

  // Persistent participant selection; redirects keep merged IDs usable.
  Future<File> _selectionFile() async {
    final root =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    return File('${root.path}/participant_selection.jsonl');
  }

  Future<void> rememberParticipant(String id) async {
    final canonical = await canonicalId(id);
    if (!(await profiles()).containsKey(canonical)) {
      throw const FormatException('Selected participant is missing');
    }
    final file = await _selectionFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode({'version': 1, 'participant_id': canonical})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<ParticipantProfile?> lastParticipant() async {
    final values = await profiles();
    final file = await _selectionFile();
    if (await file.exists()) {
      String? id;
      for (final line in await file.readAsLines()) {
        if (line.trim().isEmpty) {
          continue;
        }
        final row = jsonDecode(line);
        if (row is! Map ||
            row['version'] != 1 ||
            row['participant_id'] is! String) {
          throw const FormatException(
            'Unreadable participant selection; original preserved',
          );
        }
        id = row['participant_id'] as String;
      }
      if (id != null) {
        return values[await canonicalId(id)];
      }
    }
    // Upgrade fallback: use the latest recording with an unambiguous profile.
    final sessions = Directory('${file.parent.path}/desired_state_sessions');
    if (!await sessions.exists()) {
      return null;
    }
    final directories = await sessions
        .list(followLinks: false)
        .where((e) => e is Directory)
        .cast<Directory>()
        .toList();
    directories.sort((a, b) => b.path.compareTo(a.path));
    for (final directory in directories) {
      final manifest = File('${directory.path}/manifest.json');
      if (!await manifest.exists()) {
        continue;
      }
      final row = jsonDecode(await manifest.readAsString());
      if (row is! Map) {
        continue;
      }
      final id = row['participant_id'];
      if (id is String) {
        final profile = values[await canonicalId(id)];
        if (profile != null) {
          return profile;
        }
      } else {
        final assignments = row['assignments'];
        final names = assignments is Map
            ? assignments.values.whereType<String>().toSet()
            : <String>{};
        final matches = names.length == 1
            ? values.values.where((p) => p.name == names.single).toList()
            : <ParticipantProfile>[];
        if (matches.length == 1) {
          return matches.single;
        }
      }
    }
    return null;
  }

  Future<String> canonicalId(String id) async {
    final pending = _writes;
    if (pending != null) await pending;
    final aliases = <String, String>{};
    await _read(aliases: aliases);
    final seen = <String>{};
    while (aliases.containsKey(id)) {
      if (!seen.add(id)) {
        throw const FormatException('Participant correction cycle');
      }
      id = aliases[id]!;
    }
    return id;
  }

  Future<Map<String, String>> list() async => {
    for (final p in (await profiles()).values) p.name: p.info,
  };
  Future<ParticipantProfile> save(
    String name,
    String info, {
    String? id,
    String? newId,
    bool merge = false,
  }) {
    final operation = (_writes ?? Future<void>.value()).then((_) async {
      name = name.trim();
      info = info.trim();
      if (name.isEmpty || name.length > 120 || info.length > 4000) {
        throw const FormatException(
          'Enter a name up to 120 characters and information up to 4000 characters',
        );
      }
      final aliases = <String, String>{};
      final existing = await _read(
        aliases: aliases,
      ); // Validate before appending.
      while (id != null && aliases.containsKey(id)) {
        id = aliases[id];
      }
      final requestedId = newId?.trim();
      if (requestedId != null &&
          requestedId.isNotEmpty &&
          !RegExp(r'^[A-Za-z0-9_.=-]{1,128}$').hasMatch(requestedId)) {
        throw const FormatException(
          'Identifier must be 1–128 letters, numbers, _, ., = or -',
        );
      }
      if (requestedId != null &&
          requestedId.isNotEmpty &&
          requestedId != id &&
          (existing.containsKey(requestedId) ||
              aliases.containsKey(requestedId)) &&
          !merge) {
        throw const FormatException(
          'Identifier already belongs to a profile. Use Merge participants explicitly.',
        );
      }
      if (merge &&
          (id == null ||
              requestedId == null ||
              !existing.containsKey(requestedId))) {
        throw const FormatException('Choose an existing merge target');
      }
      if (id != null && !existing.containsKey(id)) {
        throw const FormatException(
          'Participant no longer exists; choose a saved profile',
        );
      }
      final random = Random.secure();
      final assigned =
          (requestedId?.isNotEmpty == true ? requestedId : id) ??
          'p-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode({'version': id != null && assigned != id ? 3 : 2, if (id != null && assigned != id) 'previous_id': id, 'participant_id': assigned, 'name': name, 'info': info, 'updated_utc': DateTime.now().toUtc().toIso8601String()})}\n',
        mode: FileMode.append,
        flush: true,
      );
      return ParticipantProfile(assigned, name, info);
    });
    late final Future<void> pending;
    void release() {
      // A later queued write owns the tail until its own completion.
      if (identical(_writes, pending)) {
        _writes = null;
      }
    }

    pending = operation.then<void>(
      (_) => release(),
      onError: (Object _) => release(),
    );
    _writes = pending;
    return operation;
  }

  Future<ParticipantProfile> resolve(
    String name,
    String info, {
    String? id,
  }) async {
    final profiles = await this.profiles();
    if (id != null) {
      final profile = profiles[await canonicalId(id)];
      if (profile == null) {
        throw const FormatException('Choose an existing participant');
      }
      return profile;
    }
    final matches = profiles.values
        .where((p) => p.name == name.trim())
        .toList();
    if (matches.length > 1) {
      throw const FormatException(
        'Several participants have this name. Choose a saved profile.',
      );
    }
    if (matches.isEmpty) return save(name, info);
    return matches.single;
  }
}
