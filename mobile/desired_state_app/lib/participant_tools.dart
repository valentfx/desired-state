import 'package:flutter/material.dart';

import 'session_history.dart';
import 'participant_store.dart';
export 'participant_store.dart';

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
  eventLabels: Map.of(old.eventLabels),
  participantId: participantId,
  participantName: name.trim().isEmpty ? 'unassigned' : name.trim(),
  userInfo: info.trim(),
);

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
  late final _identifier = TextEditingController(
    text: widget.participantId ?? '',
  );
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
                _identifier.text = selected.id;
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
    _identifier.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await widget.store.save(
        _name.text,
        _info.text,
        id: _selected,
        newId: _identifier.text,
      );
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
                      _identifier.text = p?.id ?? '';
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
          TextField(
            controller: _identifier,
            enabled: !_busy && !_loading,
            maxLength: 128,
            decoration: const InputDecoration(
              labelText: 'Participant identifier (blank generates one)',
            ),
          ),
          if (_selected != null)
            const Text(
              'Changing the identifier records a correction linking the old ID to the new one. Original capture IDs are preserved.',
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
    this.onManageRecordings,
  });
  final ParticipantStore store;
  final ValueChanged<ParticipantProfile>? onViewSessions;
  final VoidCallback? onManageRecordings;
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

  Future<void> _merge(ParticipantProfile source) async {
    final profiles = await widget.store.profiles();
    if (!mounted) return;
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Merge ${source.name} (${source.id}) into…'),
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'The selected target profile becomes authoritative. Old IDs remain linked; recordings are not rewritten. Choose only if both profiles are the same person.',
            ),
          ),
          for (final p in profiles.values.where((p) => p.id != source.id))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p.id),
              child: Text('${p.name} · ${p.id}'),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm same person'),
        content: Text('Link ${source.id} to $target?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final p = profiles[target]!;
      await widget.store.save(
        p.name,
        p.info,
        id: source.id,
        newId: p.id,
        merge: true,
      );
      if (mounted) setState(() => _values = widget.store.profiles());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
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
        if (widget.onManageRecordings != null)
          ListTile(
            leading: const Icon(Icons.assignment_ind_outlined),
            title: const Text('Recording assignments'),
            subtitle: const Text(
              'Correct the participant on a saved recording',
            ),
            onTap: widget.onManageRecordings,
          ),
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
                      'Phone profiles are authoritative. Edit names and identifiers or explicitly merge duplicates. Original capture IDs remain traceable.',
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
                          TextButton.icon(
                            onPressed: () => _merge(p),
                            icon: const Icon(Icons.merge),
                            label: const Text('Merge duplicate participant'),
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
