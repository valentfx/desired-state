import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'session_history.dart';

HistoryMetadata participantMetadata(
  HistoryMetadata old,
  String name,
  String info, {
  String? participantId,
}) => HistoryMetadata(
  description: old.description,
  notes: old.notes,
  tags: old.tags,
  eventNotes: Map.of(old.eventNotes),
  participantId: participantId,
  participantName: name.trim().isEmpty ? 'unassigned' : name.trim(),
  userInfo: info.trim(),
);

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

  Future<Map<String, ParticipantProfile>> _read() async {
    final file = await _file();
    final values = <String, ParticipantProfile>{};
    if (!await file.exists()) return values;
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final row = jsonDecode(line);
      if (row is! Map ||
          (row['version'] != 1 && row['version'] != 2) ||
          row['name'] is! String ||
          row['info'] is! String ||
          (row['version'] == 2 &&
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
      values[id] = ParticipantProfile(id, name, row['info'] as String);
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

  Future<Map<String, String>> list() async => {
    for (final p in (await profiles()).values) p.name: p.info,
  };
  Future<ParticipantProfile> save(String name, String info, {String? id}) {
    final operation = (_writes ?? Future<void>.value()).then((_) async {
      name = name.trim();
      info = info.trim();
      if (name.isEmpty || name.length > 120 || info.length > 4000) {
        throw const FormatException(
          'Enter a name up to 120 characters and information up to 4000 characters',
        );
      }
      final existing = await _read(); // Validate before appending.
      if (id != null && !existing.containsKey(id)) {
        throw const FormatException(
          'Participant no longer exists; choose a saved profile',
        );
      }
      final random = Random.secure();
      final assigned =
          id ??
          'p-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode({'version': 2, 'participant_id': assigned, 'name': name, 'info': info, 'updated_utc': DateTime.now().toUtc().toIso8601String()})}\n',
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
      final profile = profiles[id];
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

Future<(String, String, String)?> editParticipant(
  BuildContext context, {
  required String name,
  required String info,
  required ParticipantStore store,
  String? participantId,
  bool correction = false,
}) => showDialog<(String, String, String)>(
  context: context,
  builder: (_) => _ParticipantDialog(
    name: name,
    info: info,
    store: store,
    participantId: participantId,
    correction: correction,
  ),
);

class _ParticipantDialog extends StatefulWidget {
  const _ParticipantDialog({
    required this.name,
    required this.info,
    required this.store,
    required this.participantId,
    required this.correction,
  });
  final String name, info;
  final String? participantId;
  final ParticipantStore store;
  final bool correction;
  @override
  State<_ParticipantDialog> createState() => _ParticipantDialogState();
}

class _ParticipantDialogState extends State<_ParticipantDialog> {
  late final _name = TextEditingController(
    text: widget.name == 'unassigned' ? '' : widget.name,
  );
  late final _info = TextEditingController(text: widget.info);
  late String? _selected = widget.participantId;
  Map<String, ParticipantProfile> _saved = {};
  bool _busy = false, _loading = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.store
        .profiles()
        .then((values) {
          if (mounted) {
            setState(() {
              _saved = values;
              _loading = false;
              final selected = values[_selected];
              if (selected != null) {
                _name.text = selected.name;
                _info.text = selected.info;
              }
              if (_selected != null && !values.containsKey(_selected)) {
                _error = 'Assigned profile is missing; choose a participant';
                _selected = null;
              }
            });
          }
        })
        .catchError((Object error) {
          if (mounted) {
            setState(() {
              _error = '$error';
              _loading = false;
            });
          }
        });
  }

  @override
  void dispose() {
    _name.dispose();
    _info.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await widget.store.save(_name.text, _info.text, id: _selected);
      if (mounted) Navigator.pop(context, (p.name, p.info, p.id));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    alignment: Alignment.topCenter,
    title: const Text('Participant'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_loading)
            DropdownButtonFormField<String>(
              key: ValueKey(_selected),
              initialValue: _selected ?? '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Saved profile or new participant',
              ),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('Add new participant'),
                ),
                for (final p in _saved.values)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      '${p.name} · ${p.id.substring(p.id.length > 8 ? p.id.length - 8 : 0)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (id) => setState(() {
                      _selected = id == '' ? null : id;
                      final p = _saved[_selected];
                      _name.text = p?.name ?? '';
                      _info.text = p?.info ?? '';
                    }),
            ),
          TextField(
            controller: _name,
            enabled: !_busy && !_loading,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Participant name'),
          ),
          TextField(
            controller: _info,
            enabled: !_busy && !_loading,
            maxLines: 3,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: 'User information / notes',
            ),
          ),
          if (_selected != null)
            const Text(
              'Editing a saved profile keeps its permanent ID and updates its directory name.',
            ),
          if (widget.correction)
            const Text(
              'Assigns this participant to the entire recording. Original sensor rows remain unchanged; the correction is exported.',
            ),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy || _loading ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}

class ParticipantsScreen extends StatefulWidget {
  const ParticipantsScreen({
    super.key,
    required this.store,
    this.onViewSessions,
  });
  final ParticipantStore store;
  final ValueChanged<ParticipantProfile>? onViewSessions;
  @override
  State<ParticipantsScreen> createState() => _ParticipantsScreenState();
}

class _ParticipantsScreenState extends State<ParticipantsScreen> {
  late Future<Map<String, ParticipantProfile>> _values = widget.store
      .profiles();
  String _query = '';
  Future<void> _edit(ParticipantProfile? profile) async {
    final value = await editParticipant(
      context,
      name: profile?.name ?? '',
      info: profile?.info ?? '',
      participantId: profile?.id,
      store: widget.store,
    );
    if (value != null && mounted) {
      setState(() {
        _values = widget.store.profiles();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Participants'),
      actions: [
        IconButton(
          tooltip: 'Refresh participants',
          onPressed: () => setState(() {
            _values = widget.store.profiles();
          }),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: () => _edit(null),
      tooltip: 'Add participant',
      child: const Icon(Icons.person_add),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              labelText: 'Find participant',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: FutureBuilder<Map<String, ParticipantProfile>>(
            future: _values,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('${snapshot.error}'));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final profiles =
                  snapshot.data!.values
                      .where(
                        (p) => '${p.name} ${p.info} ${p.id}'
                            .toLowerCase()
                            .contains(_query),
                      )
                      .toList()
                    ..sort((a, b) => a.name.compareTo(b.name));
              return ListView(
                padding: const EdgeInsets.only(bottom: 90),
                children: [
                  const ListTile(
                    title: Text('Participant profiles'),
                    subtitle: Text(
                      'Names can change; permanent IDs keep assigned sessions together. Older sessions can be assigned from History.',
                    ),
                  ),
                  if (profiles.isEmpty)
                    const ListTile(title: Text('No matching participants')),
                  for (final p in profiles)
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            title: Text(p.name),
                            subtitle: Text('${p.info}\nID: ${p.id}'),
                            trailing: const Icon(Icons.edit_outlined),
                            onTap: () => _edit(p),
                          ),
                          if (widget.onViewSessions != null)
                            TextButton.icon(
                              onPressed: () => widget.onViewSessions!(p),
                              icon: const Icon(Icons.history),
                              label: const Text('View sessions'),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
