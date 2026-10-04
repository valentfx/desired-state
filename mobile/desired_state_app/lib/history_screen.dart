import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'history_plot.dart';
import 'session_controller.dart';
import 'session_history.dart';
import 'participant_tools.dart';
import 'processing_screen.dart';
import 'session_review_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.controller,
    this.repository,
    this.participantStore,
    this.home = false,
    this.revision = 0,
    this.onLive,
    this.initialParticipantId,
    this.analyze = false,
  });
  final bool home, analyze;
  final String? initialParticipantId;
  final int revision;
  final VoidCallback? onLive;
  final SessionController controller;
  final SessionHistoryRepository? repository;
  final ParticipantStore? participantStore;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final repository =
      widget.repository ??
      SessionHistoryRepository(
        directoryProvider: widget.controller.directoryProvider,
        activeSessionId: () => widget.controller.sessionLogger?.sessionId,
      );
  Map<String, ParticipantProfile> _profiles = {};
  String? _profileError;
  late Future<List<HistoryEntry>> _sessions = _load();
  late String? _participantId = widget.initialParticipantId;
  Future<List<HistoryEntry>> _load() async {
    try {
      _profiles =
          await (widget.participantStore ??
                  ParticipantStore(
                    directoryProvider: widget.controller.directoryProvider,
                  ))
              .profiles();
      _profileError = null;
    } catch (error) {
      _profiles = {};
      _profileError =
          'Profile directory unavailable: $error. Recorded sessions remain accessible.';
    }
    final entries = await repository.list();
    return entries;
  }

  String _label(HistoryEntry entry) =>
      _profiles[entry.participantId]?.name ?? entry.participant;
  String get _filterLabel => _participantId != null
      ? _profiles[_participantId]?.name ?? _participantId!
      : _user ?? 'All participants';
  String _query = '';
  final _search = TextEditingController();
  String? _user;
  final _identifier = TextEditingController();
  DateTimeRange? _dates;
  @override
  void didUpdateWidget(covariant HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) _refresh();
  }

  @override
  void dispose() {
    _identifier.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _pickDates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
      initialDateRange: _dates,
    );
    if (range != null && mounted) setState(() => _dates = range);
  }

  void _refresh() => setState(() {
    _sessions = _load();
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.analyze
            ? 'Analyze'
            : widget.home
            ? 'Users & History'
            : 'History',
      ),
      actions: [
        IconButton(
          tooltip: 'Session storage diagnostics',
          icon: const Icon(Icons.folder_open),
          onPressed: () async {
            String report;
            try {
              report = await repository.storageDiagnostics();
            } catch (error) {
              report = 'Storage inspection failed: $error';
            }
            if (!context.mounted) return;
            await showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                alignment: Alignment.topCenter,
                title: const Text('Session storage'),
                content: SelectableText(report),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'Refresh sessions',
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
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                labelText: 'Find a session',
                hintText: 'Participant, device, description, event or tag',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.toLowerCase().trim()),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<HistoryEntry>>(
              future: _sessions,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Could not load history: ${snapshot.error}'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final filter = HistoryFilter(
                  participantId: _participantId,
                  user: _user,
                  identifier: _identifier.text,
                  from: _dates?.start,
                  to: _dates?.end,
                );
                final users = {
                  ...snapshot.data!
                      .where((e) => e.participantId == null)
                      .map((e) => e.participant),
                  ?_user,
                }.toList()..sort();
                final profileIds = {
                  ...snapshot.data!
                      .map((e) => e.participantId)
                      .whereType<String>(),
                  ?_participantId,
                };
                final entries = snapshot.data!
                    .where(filter.matches)
                    .where(
                      (entry) => _user == null || entry.participantId == null,
                    )
                    .where(
                      (entry) => [
                        entry.id,
                        entry.participant,
                        _label(entry),
                        entry.participantId ?? '',
                        entry.device,
                        entry.metadata.description,
                        entry.metadata.notes,
                        entry.metadata.userInfo,
                        ...entry.metadata.tags,
                        ...entry.metadata.eventNotes.values,
                        ...entry.events.map(
                          (r) =>
                              '${r['marker_label'] ?? ''} ${r['description'] ?? ''}',
                        ),
                      ].join(' ').toLowerCase().contains(_query),
                    )
                    .toList();
                return ListView.builder(
                  itemCount: entries.isEmpty ? 2 : entries.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return ExpansionTile(
                        initiallyExpanded:
                            widget.analyze ||
                            widget.initialParticipantId != null,
                        title: const Text('Filter by participant, ID, date'),
                        subtitle: Text(
                          '$_filterLabel · ${_dates == null ? 'All dates' : '${_dates!.start.toLocal().toString().split(' ').first} to ${_dates!.end.toLocal().toString().split(' ').first}'} · ${entries.length} sessions',
                        ),
                        children: [
                          if (_profileError != null)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(_profileError!),
                            ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                DropdownButton<String>(
                                  isExpanded: true,
                                  value: _participantId != null
                                      ? 'profile:$_participantId'
                                      : _user != null
                                      ? 'legacy:$_user'
                                      : '',
                                  items: [
                                    const DropdownMenuItem(
                                      value: '',
                                      child: Text('All participants'),
                                    ),
                                    for (final profile in _profiles.values)
                                      DropdownMenuItem(
                                        value: 'profile:${profile.id}',
                                        child: Text(
                                          '${profile.name} · ${profile.id.substring(profile.id.length > 8 ? profile.id.length - 8 : 0)}',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    for (final id in profileIds)
                                      if (!_profiles.containsKey(id))
                                        DropdownMenuItem(
                                          value: 'profile:$id',
                                          child: Text('Missing profile · $id'),
                                        ),
                                    for (final user in users.where(
                                      (u) => u.isNotEmpty,
                                    ))
                                      DropdownMenuItem(
                                        value: 'legacy:$user',
                                        child: Text(
                                          'Legacy / unassigned ID: $user',
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) => setState(() {
                                    _participantId =
                                        value != null &&
                                            value.startsWith('profile:')
                                        ? value.substring(8)
                                        : null;
                                    _user =
                                        value != null &&
                                            value.startsWith('legacy:')
                                        ? value.substring(7)
                                        : null;
                                  }),
                                ),
                                TextField(
                                  controller: _identifier,
                                  decoration: const InputDecoration(
                                    labelText: 'Session or device ID',
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton.icon(
                                      onPressed: _pickDates,
                                      icon: const Icon(Icons.date_range),
                                      label: const Text('Date range'),
                                    ),
                                    TextButton(
                                      onPressed: () => setState(() {
                                        _user = null;
                                        _participantId = null;
                                        _dates = null;
                                        _identifier.clear();
                                        _search.clear();
                                        _query = '';
                                      }),
                                      child: const Text('Clear filters'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }
                    if (entries.isEmpty) {
                      return const ListTile(
                        title: Text('No saved sessions found.'),
                      );
                    }
                    final entry = entries[index - 1];
                    final state = repository.isActive(entry.id)
                        ? 'Recording / snapshot'
                        : entry.ended && entry.warnings.isEmpty
                        ? 'Stopped (open to check data)'
                        : 'Incomplete / needs review';
                    return ListTile(
                      isThreeLine: true,
                      title: Text(
                        '${_label(entry)} · ${entry.started?.toLocal() ?? entry.id}',
                      ),
                      subtitle: Text(
                        '$state · ${entry.device}${_label(entry) == entry.participant ? '' : ' · recorded as ${entry.participant}'}\n${entry.metadata.description.isEmpty ? entry.id : entry.metadata.description}${entry.warnings.isEmpty ? '' : '\n${entry.warnings.first}'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: !entry.readable
                          ? null
                          : () async {
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
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class RecordingHistoryBanner extends StatelessWidget {
  const RecordingHistoryBanner({
    super.key,
    required this.controller,
    this.onLive,
  });
  final SessionController controller;
  final VoidCallback? onLive;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.sessionLogger == null) return const SizedBox.shrink();
      return Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: ListTile(
          dense: true,
          title: Text(
            '${controller.recordingState == RecordingState.paused ? 'Paused' : 'Recording continues'} · ${controller.connectionStatus}',
          ),
          trailing: TextButton(
            onPressed:
                onLive ??
                () => Navigator.popUntil(context, (route) => route.isFirst),
            child: const Text('Live'),
          ),
        ),
      );
    },
  );
}

class HistoryDetailScreen extends StatefulWidget {
  const HistoryDetailScreen({
    super.key,
    required this.entry,
    required this.repository,
    required this.controller,
    this.onLive,
  });
  final VoidCallback? onLive;
  final HistoryEntry entry;
  final SessionHistoryRepository repository;
  final SessionController controller;
  @override
  State<HistoryDetailScreen> createState() => _HistoryDetailScreenState();
}

class _HistoryDetailScreenState extends State<HistoryDetailScreen> {
  late Future<HistorySession> _loading = widget.repository.open(widget.entry);
  bool _screened = false, _exporting = false;
  RangeValues _range = const RangeValues(0, 1);
  HistoryPoint? _inspected;
  String _inspectedMetric = '';
  void _reload() => setState(() {
    _loading = widget.repository.open(widget.entry);
    _inspected = null;
  });
  Future<void> _edit(HistoryEntry entry, {String? eventId}) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => HistoryMetadataEditor(
          entry: entry,
          repository: widget.repository,
          eventId: eventId,
        ),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _export(HistoryEntry entry) async {
    setState(() => _exporting = true);
    try {
      final zip = await widget.repository.export(entry);
      await SharePlus.instance.share(
        ShareParams(
          subject: 'Desired State session ${entry.id}',
          files: [XFile(zip.path)],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not export: $error')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Session history'),
      actions: [
        IconButton(
          tooltip: 'Processing & plots',
          icon: const Icon(Icons.tune),
          onPressed: () async {
            try {
              final session = await _loading;
              if (!context.mounted) return;
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ProcessingScreen(
                    controller: widget.controller,
                    session: session,
                    repository: widget.repository,
                  ),
                ),
              );
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not open processing: $e')),
                );
              }
            }
          },
        ),
        IconButton(
          tooltip: 'Refresh session',
          onPressed: _reload,
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
            child: FutureBuilder<HistorySession>(
              future: _loading,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Could not open session: ${snapshot.error}'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final session = snapshot.data!, entry = session.entry;
                final active = widget.repository.isActive(entry.id);
                final eventTimes = entry.events
                    .where((r) => r['event'] == 'marked_event')
                    .map((r) => DateTime.tryParse('${r['received_utc']}'))
                    .whereType<DateTime>()
                    .toList();
                final times = [
                  ...session.hr.map((p) => p.time),
                  ...session.rr.map((p) => p.time),
                  ...eventTimes,
                ]..sort();
                final first = times.isEmpty
                    ? (entry.started ?? DateTime(1970))
                    : times.first;
                final last = times.isEmpty ? first : times.last;
                final span = last.difference(first).inMicroseconds;
                final uniqueTimes = times.toSet().toList();
                final start = uniqueTimes.isEmpty
                    ? first
                    : uniqueTimes[((uniqueTimes.length - 1) * _range.start)
                          .floor()];
                final end = uniqueTimes.isEmpty
                    ? last
                    : uniqueTimes[((uniqueTimes.length - 1) * _range.end)
                          .ceil()];
                final canEdit = !active && entry.editsReadable;
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (!active)
                      FilledButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => SessionReviewScreen(
                              session: session,
                              repository: widget.repository,
                              controller: widget.controller,
                              onLive: widget.onLive,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.analytics_outlined),
                        label: const Text('Review session'),
                      ),
                    Text(
                      entry.participant,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${entry.started?.toLocal() ?? 'Unknown start'} · ${entry.device}',
                    ),
                    if (entry.metadata.userInfo.isNotEmpty)
                      Text(entry.metadata.userInfo),
                    OutlinedButton.icon(
                      onPressed: canEdit
                          ? () async {
                              final values = await editParticipant(
                                context,
                                participantId: entry.participantId,
                                name: entry.participant,
                                info: entry.metadata.userInfo,
                                store: ParticipantStore(
                                  directoryProvider:
                                      widget.controller.directoryProvider,
                                ),
                                correction: true,
                              );
                              if (values == null) return;
                              try {
                                await widget.repository.saveMetadata(
                                  entry,
                                  participantMetadata(
                                    entry.metadata,
                                    values.$1,
                                    values.$2,
                                    participantId: values.$3,
                                  ),
                                );
                                if (mounted) _reload();
                              } catch (error) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Participant not saved: $error',
                                      ),
                                    ),
                                  );
                                }
                              }
                            }
                          : null,
                      icon: const Icon(Icons.person_outline),
                      label: const Text('Assign / edit participant'),
                    ),
                    SelectableText(entry.id),
                    Text(
                      'O2Ring: ${session.oxygen.length} readings · '
                      'H10 ACC: ${session.accelerationSamples} samples · EEG: ${session.eegSamples} samples · ECG: ${session.ecgSamples} samples',
                    ),
                    Text(
                      active
                          ? 'Active recording: saved-data snapshot; refresh for more. Stop before editing/export.'
                          : entry.ended && session.warnings.isEmpty
                          ? 'Completed session'
                          : 'Incomplete / needs review: data may be missing.',
                    ),
                    if (session.warnings.isNotEmpty)
                      ExpansionTile(
                        title: Text('${session.warnings.length} data warnings'),
                        children: [
                          for (final warning in session.warnings)
                            ListTile(title: Text(warning)),
                        ],
                      ),
                    Text(
                      entry.metadata.description.isEmpty
                          ? 'No description'
                          : entry.metadata.description,
                    ),
                    Text(
                      'What helped / how I felt: ${entry.metadata.notes.isEmpty ? 'No notes yet' : entry.metadata.notes}',
                    ),
                    Text('Outcome tags: ${entry.metadata.tags.join(', ')}'),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonal(
                          onPressed: canEdit ? () => _edit(entry) : null,
                          child: const Text('Edit notes & tags'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              !active && !_exporting && entry.editsReadable
                              ? () => _export(entry)
                              : null,
                          icon: const Icon(Icons.ios_share),
                          label: Text(
                            _exporting ? 'Preparing…' : 'Re-export session',
                          ),
                        ),
                      ],
                    ),
                    ExpansionTile(
                      title: const Text('Events & notes'),
                      children: [
                        if (entry.events.isEmpty)
                          const Text('No event records'),
                        for (final event in entry.events.where(
                          (r) => r['_invalid'] != true,
                        ))
                          ListTile(
                            title: Text(
                              event['event'] ==
                                      'processing_configuration_initial'
                                  ? 'Initial analysis settings'
                                  : event['event'] ==
                                        'processing_configuration_changed'
                                  ? 'Analysis settings changed'
                                  : '${event['marker_label'] ?? event['description'] ?? event['event'] ?? 'Event'}',
                            ),
                            subtitle: Text(
                              '${event['received_utc'] ?? 'Unknown time'} · ${event['event']}\n${entry.metadata.eventNotes[entry.eventId(event)] ?? ''}',
                            ),
                            trailing: event['event'] == 'marked_event'
                                ? IconButton(
                                    tooltip: 'Edit event note',
                                    icon: const Icon(Icons.note_alt_outlined),
                                    onPressed: canEdit
                                        ? () => _edit(
                                            entry,
                                            eventId: entry.eventId(event),
                                          )
                                        : null,
                                  )
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Raw')),
                        ButtonSegment(
                          value: true,
                          label: Text('Current screened'),
                        ),
                      ],
                      selected: {_screened},
                      onSelectionChanged: (v) => setState(() {
                        _screened = v.first;
                        _inspected = null;
                      }),
                    ),
                    const Text(
                      'Fixed v1 comparison (configurable analysis: tune button above). Current screen: 300–2000 ms, median of 9 accepted RR, 25% deviation. RMSSD: latest 60 acquired RR, at least 3 usable values and 1 contiguous pair. Raw RMSSD excludes nonpositive values only. Pauses/gaps break pairs. Provisional, not ECG-verified NN.',
                    ),
                    Text(
                      '${session.rr.length} raw RR · ${session.rr.where((r) => !r.accepted).length} excluded by current screen. HR is reported by the device and is unchanged by this selector.',
                    ),
                    const Text(
                      'Receipt times, not exact beat timestamps. Purple lines are marked events. Tap a plot to inspect.',
                    ),
                    if (span > 0) ...[
                      Row(
                        children: [
                          const Expanded(child: Text('Visible time range')),
                          TextButton(
                            onPressed: () => setState(() {
                              _range = const RangeValues(0, 1);
                              _inspected = null;
                            }),
                            child: const Text('Fit data'),
                          ),
                        ],
                      ),
                      RangeSlider(
                        values: _range,
                        min: 0,
                        max: 1,
                        onChanged: (value) => setState(() {
                          if (value.end - value.start >=
                              1 / (uniqueTimes.length - 1)) {
                            _range = value;
                          }
                          _inspected = null;
                        }),
                      ),
                    ],
                    Text('${start.toLocal()} – ${end.toLocal()}'),
                    for (final series
                        in <(String, String, List<HistoryPoint>, Color)>[
                          ('HR', 'bpm', session.hr, Colors.blue.shade700),
                          (
                            'RR',
                            'ms',
                            session.rrSeries(_screened),
                            Colors.deepPurple,
                          ),
                          (
                            'RMSSD',
                            'ms',
                            session.rmssdSeries(_screened),
                            Colors.orange.shade800,
                          ),
                        ]) ...[
                      HistoryPlot(
                        title: series.$1,
                        unit: series.$2,
                        points: series.$3,
                        start: start,
                        end: end,
                        events: eventTimes,
                        color: series.$4,
                        cursor: _inspected?.time,
                        onInspect: (point) => setState(() {
                          _inspected = point;
                          _inspectedMetric = series.$1;
                        }),
                      ),
                      if (_inspected != null && _inspectedMetric == series.$1)
                        _inspection(session),
                    ],
                    if (entry.revisions.isNotEmpty)
                      ExpansionTile(
                        title: Text('Edit history (${entry.revisions.length})'),
                        children: [
                          for (final revision in entry.revisions)
                            ListTile(
                              title: Text(
                                '${revision['edited_utc'] ?? 'Unknown edit time'}',
                              ),
                              subtitle: Text(
                                'Description: ${(revision['previous'] is Map ? revision['previous'] as Map : null)?['description'] ?? ''} → ${(revision['values'] is Map ? revision['values'] as Map : null)?['description'] ?? ''}\n'
                                'Notes: ${(revision['previous'] is Map ? revision['previous'] as Map : null)?['notes'] ?? ''} → ${(revision['values'] is Map ? revision['values'] as Map : null)?['notes'] ?? ''}\n'
                                'Tags: ${(revision['values'] is Map ? revision['values'] as Map : null)?['outcome_tags'] ?? ''}',
                              ),
                            ),
                        ],
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  Widget _inspection(HistorySession session) {
    final point = _inspected!;
    final index = point.sourceIndex;
    final sample = index == null ? null : session.rr[index];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$_inspectedMetric: ${point.value?.toStringAsFixed(2) ?? '--'} ${_inspectedMetric == 'HR' ? 'bpm' : 'ms'}',
            ),
            SelectableText(point.time.toUtc().toIso8601String()),
            if (sample != null) ...[
              Text(
                'Raw RR ${sample.value} ms · packet position ${sample.row['rr_index'] ?? 'unknown'} · acquired sample ${index! + 1}',
              ),
              Text(
                'Current screen: ${sample.accepted ? 'accepted' : sample.reason}\nRecorded flag: ${sample.row['artifact_accepted'] ?? 'not recorded'}',
              ),
              Wrap(
                children: [
                  TextButton(
                    onPressed: index > 0
                        ? () => _selectRr(session, index - 1)
                        : null,
                    child: const Text('Previous RR'),
                  ),
                  TextButton(
                    onPressed: index + 1 < session.rr.length
                        ? () => _selectRr(session, index + 1)
                        : null,
                    child: const Text('Next RR'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _selectRr(HistorySession session, int index) => setState(() {
    _inspectedMetric = 'RR';
    _inspected = session.rrSeries(_screened)[index];
  });
}

class HistoryMetadataEditor extends StatefulWidget {
  const HistoryMetadataEditor({
    super.key,
    required this.entry,
    required this.repository,
    this.eventId,
    this.controller,
    this.onLive,
  });
  final SessionController? controller;
  final VoidCallback? onLive;
  final HistoryEntry entry;
  final SessionHistoryRepository repository;
  final String? eventId;
  @override
  State<HistoryMetadataEditor> createState() => _HistoryMetadataEditorState();
}

class _HistoryMetadataEditorState extends State<HistoryMetadataEditor> {
  late final _description = TextEditingController(
    text: widget.entry.metadata.description,
  );
  late final _notes = TextEditingController(
    text: widget.eventId == null
        ? widget.entry.metadata.notes
        : widget.entry.metadata.eventNotes[widget.eventId] ?? '',
  );
  late final _tags = TextEditingController(
    text: widget.entry.metadata.tags.join(', '),
  );
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _description.dispose();
    _notes.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final tags = _tags.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
      if (tags.length > 20 || tags.any((s) => s.length > 48)) {
        throw const FormatException('Use up to 20 tags, 48 characters each');
      }
      final old = widget.entry.metadata;
      final values = HistoryMetadata(
        participantName: old.participantName,
        participantId: old.participantId,
        userInfo: old.userInfo,
        description: _description.text.trim(),
        notes: widget.eventId == null ? _notes.text.trim() : old.notes,
        tags: tags,
        eventNotes: {
          ...old.eventNotes,
          if (widget.eventId != null) widget.eventId!: _notes.text.trim(),
        },
      );
      await widget.repository.saveMetadata(widget.entry, values);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.eventId == null ? 'Session notes' : 'Event note'),
      actions: [
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (widget.controller != null)
            RecordingHistoryBanner(
              controller: widget.controller!,
              onLive: widget.onLive,
            ),
          if (_error != null) Text(_error!),
          if (widget.eventId == null)
            TextField(
              controller: _description,
              enabled: !_saving,
              maxLines: 3,
              maxLength: 4000,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
          TextField(
            controller: _notes,
            enabled: !_saving,
            maxLines: 6,
            maxLength: 16000,
            decoration: InputDecoration(
              labelText: widget.eventId == null
                  ? 'What helped / how I felt'
                  : 'Event note',
            ),
          ),
          if (widget.eventId == null)
            TextField(
              controller: _tags,
              enabled: !_saving,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Outcome tags',
                hintText: 'Comma-separated, e.g. helped, calmer',
              ),
            ),
          const Text(
            'Saving keeps the original data and appends an edit record.',
          ),
        ],
      ),
    ),
  );
}
