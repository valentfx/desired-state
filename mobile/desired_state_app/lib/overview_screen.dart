import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'device_screen.dart';
import 'history_screen.dart';
import 'overview_scope.dart';
import 'session_controller.dart';
import 'session_history.dart';

/// Personal browsing is separate from the active recording assignment.
/// Legacy name snapshots are deliberately not presented as stable profiles.
class OverviewScreen extends StatefulWidget {
  const OverviewScreen({
    super.key,
    required this.controller,
    required this.onLive,
    required this.onAnalyze,
    this.revision = 0,
  });
  final SessionController controller;
  final VoidCallback onLive, onAnalyze;
  final int revision;
  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  late final repository = SessionHistoryRepository(
    directoryProvider: widget.controller.directoryProvider,
    activeSessionId: () => widget.controller.sessionLogger?.sessionId,
  );
  late Future<List<HistoryEntry>> _sessions = _load();
  String? _user, _notice;
  bool _saving = false;

  Future<File> _preferences() async {
    final root =
        await (widget.controller.directoryProvider ??
            getApplicationDocumentsDirectory)();
    return File('${root.path}/overview_preferences_v1.json');
  }

  Future<List<HistoryEntry>> _load() async {
    try {
      final file = await _preferences();
      if (await file.exists()) {
        final value = jsonDecode(await file.readAsString());
        if (value is! Map ||
            value['version'] != 1 ||
            (value['participant_snapshot'] != null &&
                value['participant_snapshot'] is! String)) {
          throw const FormatException('Unsupported overview preferences');
        }
        _user = value['participant_snapshot'] as String?;
      }
    } catch (error) {
      _notice = 'Could not load overview selection: $error';
    }
    return repository.list();
  }

  void _refresh() => setState(() => _sessions = repository.list());

  @override
  void didUpdateWidget(covariant OverviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) _refresh();
  }

  Future<void> _select(String? user) async {
    setState(() => _saving = true);
    try {
      final file = await _preferences();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'version': 1, 'participant_snapshot': user}),
        flush: true,
      );
      if (mounted) {
        setState(() {
          _user = user;
          _notice = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _notice = 'Selection not saved: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _singleUser(HistoryEntry entry) =>
      overviewParticipant(entry.manifest);

  void _devices() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => DeviceScreen(controller: widget.controller),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Overview'),
      actions: [
        IconButton(
          tooltip: 'Devices',
          onPressed: _devices,
          icon: const Icon(Icons.bluetooth),
        ),
        IconButton(
          tooltip: 'Refresh overview',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          RecordingHistoryBanner(
            controller: widget.controller,
            onLive: widget.onLive,
          ),
          Expanded(
            child: FutureBuilder<List<HistoryEntry>>(
              future: _sessions,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Could not load overview: ${snapshot.error}'),
                        TextButton(
                          onPressed: _refresh,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final entries = snapshot.data!;
                final users = {
                  for (final entry in entries)
                    if (_singleUser(entry) != null) _singleUser(entry)!,
                  ?_user,
                }.toList()..sort();
                final personal = _user == null
                    ? <HistoryEntry>[]
                    : entries
                          .where(
                            (entry) =>
                                entry.readable && _singleUser(entry) == _user,
                          )
                          .toList();
                final completed = personal
                    .where(
                      (entry) =>
                          entry.ended &&
                          !repository.isActive(entry.id) &&
                          entry.warnings.isEmpty,
                    )
                    .toList();
                final now = DateTime.now();
                int count(int days) => completed
                    .where(
                      (entry) =>
                          entry.started != null &&
                          !entry.started!.isAfter(now) &&
                          !entry.started!.isBefore(
                            now.subtract(Duration(days: days)),
                          ),
                    )
                    .length;
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text(
                          'Your recordings',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey(_user),
                          initialValue: _user,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Viewing participant',
                          ),
                          hint: const Text('Choose your participant name'),
                          items: [
                            for (final user in users)
                              DropdownMenuItem(
                                value: user,
                                child: Text(
                                  user,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _saving ? null : _select,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Uses saved participant names. Viewing a participant does not change who you are recording.',
                        ),
                        if (_notice != null)
                          Text(
                            _notice!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        if (_user == null)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              'Select a participant to see only their sessions. Unassigned recordings remain in Analyze.',
                            ),
                          ),
                        if (_user != null) ...[
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              for (final days in [7, 30, 90])
                                SizedBox(
                                  width: 140,
                                  child: Card(
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text('Last $days days'),
                                          Text(
                                            '${count(days)}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineMedium,
                                          ),
                                          const Text('ended sessions'),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const Text(
                            'Recording activity; not a measure of physiological improvement.',
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Recent sessions',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (personal.isEmpty)
                            const ListTile(
                              title: Text('No sessions for this participant.'),
                            ),
                          for (final entry in personal.take(5))
                            Card(
                              child: ListTile(
                                title: Text(
                                  entry.metadata.description.isEmpty
                                      ? entry.id
                                      : entry.metadata.description,
                                ),
                                subtitle: Text(
                                  '${entry.started?.toLocal() ?? 'Unknown date'}\n${repository.isActive(entry.id)
                                      ? 'Active snapshot'
                                      : entry.ended && entry.warnings.isEmpty
                                      ? 'Ended session'
                                      : 'Incomplete / needs review'} · ${entry.device}',
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => HistoryDetailScreen(
                                        entry: entry,
                                        repository: repository,
                                        controller: widget.controller,
                                        onLive: widget.onLive,
                                      ),
                                    ),
                                  );
                                  if (mounted) _refresh();
                                },
                              ),
                            ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: widget.onLive,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Open Live'),
                            ),
                            OutlinedButton.icon(
                              onPressed: widget.onAnalyze,
                              icon: const Icon(Icons.insights),
                              label: const Text('Browse all recordings'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
